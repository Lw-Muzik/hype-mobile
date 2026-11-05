#pragma once
#include "biquad.h"
#include "parametric_eq.h"  // ISO_FREQUENCIES: the default (legacy 32-band) layout
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <mutex>

static constexpr int kMaxGraphicBands = 32;

// N-band graphic EQ at arbitrary centre frequencies (1..32 bands).
//
// Each band is a peaking biquad. Its Q follows the spacing to its neighbours
// so that adjacent bands overlap the same way at any layout: a band whose
// neighbours are N octaves away gets Q = sqrt(2^N) / (2^N - 1) (octave
// spacing: 1.414, 1/3-octave spacing: 4.318).
//
// Gains are kept as nominal dB (clamped +-15). The gain actually applied is
// nominal x a scale factor (setGainScale, 0..1, default 1), so a caller can
// pull the whole curve in or out without touching the stored values.
//
// A band is inactive while its effective gain is under 0.05 dB. Inactive bands
// cost nothing and leave the audio untouched bit for bit. A centre too close to
// Nyquist for a peaking filter to behave (at or above 0.45 x the sample rate)
// is designed at 0.45 x the sample rate instead, with the same Q, so the band
// still does its job (a 20 kHz band at 44.1 kHz) rather than going silent.
//
// When the filters change (a gain, centre or Q moves, or a band goes active or
// inactive) the EQ does not switch: the band chain it had keeps running on the
// same input, the new chain starts beside it, and the output is a linear
// crossfade from old to new. Each chain's output is a continuous signal, so the
// blend does not click at any signal phase - unlike interpolating the
// coefficients of one filter that holds the old filter's state - and bands that
// swap roles (one fading out while another at a different centre fades in) do
// not stack their ramps. A band that stays active keeps its filter state across
// the change (only its coefficients move), so a bass band does not lose its
// ring-out when a slider is dragged. When the new chain is flat the old one
// fades out to the dry signal and is then cleared, after which the EQ is skipped
// (bit-exact).
//
// Crossfade length: the old and new filters differ for as long as their
// low-frequency ringing lasts, and a blend shorter than a cycle of the lowest
// band that changed leaves a step in a bass tone (a 96-sample blend at 40 Hz is
// close to a hard switch). So the length is sample rate / the lowest centre
// among the bands that change (old or new), clamped to 96..2400 frames: 96
// (2 ms) for anything from 500 Hz up, 1524 at 31.5 Hz, 2400 (50 ms) at 20 Hz.
// Only the two chains ever run, so the cost stays at most twice a single EQ.
// A change that arrives mid-crossfade waits for it to finish and then takes
// the latest settings.
//
// Threading: setters run on a control thread, process() on the audio thread.
// Setters are serialised by a mutex and publish the whole parameter set
// (centres, Q, gains, scale, and the sample rate with a reset counter) as one
// snapshot through a seqlock, so the audio thread never sees a half-applied
// change (a layout and its gains arrive together) and never blocks. All filter
// state, including each band's on / fading / off state, is owned by the audio
// thread alone: nothing per-band is shared with the control thread, so a
// reactivation cannot race the end of a fade and be lost, and init() cannot
// corrupt a block in flight. init() only publishes a reset request; process()
// applies it at the start of its next block (filter state cleared, coefficients
// at the new rate, layout and gains kept). Only one thread may run process() at
// a time (as for the other stages; process() is not reentrant).
class GraphicEQ {
public:
    GraphicEQ() {
        for (int i = 0; i < kMaxGraphicBands; i++) {
            centre_[i] = ISO_FREQUENCIES[i];
            q_[i] = GRAPHIC_Q;
        }
        count_ = kMaxGraphicBands;
        publish();
    }

    // (Re)start at a sample rate: the layout and gains are kept. This only
    // publishes the request; the next process() call clears the filter state
    // and takes the new rate with coefficients live at once (no fade), the
    // Nyquist bypass re-evaluated at the new rate. Safe against a concurrent
    // process().
    void init(float sampleRate) {
        std::lock_guard<std::mutex> lock(mutex_);
        ctlRate_ = sampleRate;
        ctlGen_++;
        publish();
    }

    // Replace the centre frequencies. Count is clamped to 1..32.
    //  - gainsDb == nullptr: gains are kept by index below the new count.
    //  - gainsDb given (`count` values): they replace every band gain in the
    //    same call, so no band is ever designed at its new centre with an old
    //    gain (two calls would let a block play the old curve at the new
    //    centres).
    // Every index from the new count up is set to 0.
    void setLayout(const float* centresHz, int count, const float* gainsDb = nullptr) {
        if (!centresHz) return;
        std::lock_guard<std::mutex> lock(mutex_);
        count = std::max(1, std::min(count, kMaxGraphicBands));
        for (int i = 0; i < count; i++) centre_[i] = std::max(1.0f, centresHz[i]);
        for (int i = count; i < kMaxGraphicBands; i++) nominal_[i] = 0.0f;
        if (gainsDb) {
            for (int i = 0; i < count; i++) nominal_[i] = clampGain(gainsDb[i]);
        }
        count_ = count;
        for (int i = 0; i < count; i++) q_[i] = bandQ(centre_, count, i);
        publish();
    }

    // Nominal gain in dB, clamped +-15. Bands outside the layout are ignored.
    void setBandGain(int band, float nominalDb) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (band < 0 || band >= count_) return;
        nominal_[band] = clampGain(nominalDb);
        publish();
    }

    void setAllGains(const float* nominalDb, int count) {
        if (!nominalDb) return;
        std::lock_guard<std::mutex> lock(mutex_);
        count = std::min(count, count_);
        for (int i = 0; i < count; i++) nominal_[i] = clampGain(nominalDb[i]);
        publish();
    }

    // Effective gain = nominal x factor, factor clamped to 0..1. Default 1.
    void setGainScale(float factor) {
        std::lock_guard<std::mutex> lock(mutex_);
        scale_ = std::isfinite(factor) ? std::max(0.0f, std::min(1.0f, factor)) : 1.0f;
        publish();
    }

    // Accessors report the control-side values, under the setters' mutex. For
    // the control thread only: they take a lock, so keep them off the audio
    // thread.
    int bandCount() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return count_;
    }
    float centreHz(int band) const {
        std::lock_guard<std::mutex> lock(mutex_);
        return inRange(band) ? centre_[band] : 0.0f;
    }
    float q(int band) const {
        std::lock_guard<std::mutex> lock(mutex_);
        return inRange(band) ? q_[band] : 0.0f;
    }
    float effectiveGainDb(int band) const {
        std::lock_guard<std::mutex> lock(mutex_);
        return inRange(band) ? nominal_[band] * scale_ : 0.0f;
    }

    void process(float* left, float* right, int numFrames) {
        if (numFrames <= 0) return;
        readSnapshot();
        if (snap_.gen != appliedGen_) applyReset();
        int pos = 0;
        while (pos < numFrames) {
            // Read the fade state once; anything out of range means "no fade".
            int total = fadeTotal_;
            int left_ = fadeLeft_;
            if (total < kMinFadeFrames || total > kMaxFadeFrames || left_ < 0 ||
                left_ > total) {
                total = 0;
                left_ = 0;
            }
            if (left_ == 0) {
                fadeLeft_ = 0;
                startFadeIfChanged();
                total = fadeTotal_;
                left_ = fadeLeft_;
            }
            float* l = left + pos;
            float* r = right + pos;
            if (left_ == 0) {
                runChain(bands_, l, r, numFrames - pos);
                if (held_) pendingFrames_ += numFrames - pos;
                return;
            }
            const int len = std::min(std::min(numFrames - pos, left_), kBlendChunk);
            float oL[kBlendChunk], oR[kBlendChunk];
            std::copy(l, l + len, oL);
            std::copy(r, r + len, oR);
            runChain(oldBands_, oL, oR, len);
            runChain(bands_, l, r, len);
            const int done = total - left_;
            for (int k = 0; k < len; k++) {
                const float w = (float)(done + k + 1) / (float)total;
                l[k] = oL[k] * (1.0f - w) + l[k] * w;
                r[k] = oR[k] * (1.0f - w) + r[k] * w;
            }
            left_ -= len;
            fadeLeft_ = left_;
            if (left_ == 0) {
                for (int i = 0; i < kMaxGraphicBands; i++) oldBands_[i] = Band();
            }
            pos += len;
        }
    }

    // Audio thread only, call before the first process(): frames a change waits
    // after it is first seen before its crossfade starts (default 0 = at once).
    // Settings that belong together but arrive in separate calls a few ms apart
    // (a preset's gains, then its preamp) are then taken as one change. A change
    // is held at most this long from when it was first seen, however many more
    // arrive, so a slider being dragged is never starved.
    void setSettleFrames(int frames) { settleFrames_ = std::max(0, frames); }

    // Audio thread only. Takes the latest settings and starts the crossfade
    // they call for (if it is due), exactly as the start of process() would,
    // without processing anything; so that a caller about to process() can tell
    // what the block will do. Safe to call before every process().
    void beginBlock() {
        readSnapshot();
        if (snap_.gen != appliedGen_) applyReset();
        if (fadeLeft_ == 0) startFadeIfChanged();
    }
    // Frames left in the running crossfade (0 = none), as of the last
    // beginBlock()/process().
    int fadeFramesLeft() const { return fadeLeft_; }
    // A change is waiting out its settle time.
    bool changePending() const { return held_; }

    // Audio thread only (as process()). Clears all filter state and brings
    // every band in at once, for the current parameters - what the next
    // process() does after init() - without waiting for a request. For a caller
    // that kept the EQ out of the chain and now brings it back: the filters
    // start clean, not from the state they were left in.
    void restart() {
        readSnapshot();
        applyReset();
    }

    // The lowest centre among the bands that are doing something (effective
    // gain at least 0.05 dB), in Hz; a huge value
    // when none is. Updated by the setters, so any thread may read it. A caller
    // that fades the whole EQ in or out uses it to pick the length (see the
    // crossfade length above).
    float lowestActiveCentreHz() const { return pLowestActive_.load(std::memory_order_relaxed); }

    // Q from the spacing around `band`: N is the octave distance to the
    // neighbours (the mean of the left and right gaps; one gap at the edges),
    // Q = sqrt(2^N) / (2^N - 1). A lone band is treated as octave spaced.
    static float bandQ(const float* centresHz, int count, int band) {
        if (!centresHz || band < 0 || band >= count) return GRAPHIC_Q;
        double sum = 0.0;
        int n = 0;
        if (band > 0) {
            sum += octaves(centresHz[band - 1], centresHz[band]);
            n++;
        }
        if (band + 1 < count) {
            sum += octaves(centresHz[band], centresHz[band + 1]);
            n++;
        }
        double N = n > 0 ? sum / n : 1.0;
        N = std::max(0.05, std::min(6.0, N));
        const double span = std::pow(2.0, N);
        return (float)(std::sqrt(span) / (span - 1.0));
    }

private:
    static constexpr float kActiveDb = 0.05f;
    static constexpr float kNyquistFraction = 0.45f;
    static constexpr int kMinFadeFrames = Biquad::FADE_LENGTH;  // 96
    static constexpr int kMaxFadeFrames = 2400;
    static constexpr int kBlendChunk = 256;  // stack scratch per blend step

    // What one band should be doing.
    struct Target {
        bool active = false;
        float centre = 0.0f, q = 0.0f, gainDb = 0.0f;
        bool operator==(const Target& o) const {
            return active == o.active && centre == o.centre && q == o.q &&
                   gainDb == o.gainDb;
        }
    };

    // Audio-thread state of one band.
    struct Band {
        Biquad filter;
        bool flat = true;  // the identity: not run, leaves the audio untouched
        Target applied;    // what the filter was last designed for
    };

    static float clampGain(float db) {
        if (!std::isfinite(db)) return 0.0f;
        return std::max(-15.0f, std::min(15.0f, db));
    }

    static double octaves(float lo, float hi) {
        return std::fabs(std::log2((double)std::max(hi, 1.0f) / (double)std::max(lo, 1.0f)));
    }

    // Caller holds mutex_.
    bool inRange(int band) const { return band >= 0 && band < count_; }

    static Target makeTarget(int band, int count, float centre, float q,
                             float nominal, float scale, float sampleRate) {
        Target t;
        t.centre = std::min(centre, kNyquistFraction * sampleRate);
        t.q = q;
        t.gainDb = nominal * scale;
        t.active = band < count && std::fabs(t.gainDb) >= kActiveDb;
        return t;
    }

    Target snapTarget(int band) const {
        return makeTarget(band, snap_.count, snap_.centre[band], snap_.q[band],
                          snap_.nominal[band], snap_.scale, snap_.sampleRate);
    }

    BiquadCoeffs design(const Target& t) const {
        return BiquadDesign::peaking(snap_.sampleRate, t.centre, t.gainDb, t.q);
    }

    // ---- control side: publish the parameter set (mutex held) ----
    void publish() {
        const uint32_t s = seq_.load(std::memory_order_relaxed);
        seq_.store(s + 1, std::memory_order_relaxed);  // odd: writing
        std::atomic_thread_fence(std::memory_order_release);
        for (int i = 0; i < kMaxGraphicBands; i++) {
            pCentre_[i].store(centre_[i], std::memory_order_relaxed);
            pQ_[i].store(q_[i], std::memory_order_relaxed);
            pNominal_[i].store(nominal_[i], std::memory_order_relaxed);
        }
        pCount_.store(count_, std::memory_order_relaxed);
        pScale_.store(scale_, std::memory_order_relaxed);
        pRate_.store(ctlRate_, std::memory_order_relaxed);
        pGen_.store(ctlGen_, std::memory_order_relaxed);
        float lowest = 1e9f;
        for (int i = 0; i < count_; i++) {
            if (std::fabs(nominal_[i] * scale_) >= kActiveDb) {
                lowest = std::min(lowest, std::min(centre_[i], kNyquistFraction * ctlRate_));
            }
        }
        pLowestActive_.store(lowest, std::memory_order_relaxed);
        seq_.store(s + 2, std::memory_order_release);  // even: stable
    }

    // Apply a reset request: clear all filter state and bring every band's
    // coefficients live at once, for the snapshot's sample rate.
    void applyReset() {
        appliedGen_ = snap_.gen;
        held_ = false;
        pendingFrames_ = 0;
        fadeLeft_ = 0;
        fadeTotal_ = 0;
        for (int i = 0; i < kMaxGraphicBands; i++) {
            bands_[i] = Band();
            oldBands_[i] = Band();
            const Target t = snapTarget(i);
            if (t.active) {
                bands_[i].filter.setCoefficientsImmediate(design(t));
                bands_[i].flat = false;
            }
            bands_[i].applied = t;
        }
    }

    // ---- audio side ----
    // Take a new snapshot when one has been published and is consistent;
    // otherwise keep the previous one (the next block tries again).
    void readSnapshot() {
        const uint32_t s1 = seq_.load(std::memory_order_acquire);
        if (s1 == seenSeq_ || (s1 & 1u)) return;
        Snapshot n;
        for (int i = 0; i < kMaxGraphicBands; i++) {
            n.centre[i] = pCentre_[i].load(std::memory_order_relaxed);
            n.q[i] = pQ_[i].load(std::memory_order_relaxed);
            n.nominal[i] = pNominal_[i].load(std::memory_order_relaxed);
        }
        n.count = pCount_.load(std::memory_order_relaxed);
        n.scale = pScale_.load(std::memory_order_relaxed);
        n.sampleRate = pRate_.load(std::memory_order_relaxed);
        n.gen = pGen_.load(std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_acquire);
        if (seq_.load(std::memory_order_relaxed) != s1) return;
        snap_ = n;
        seenSeq_ = s1;
    }

    static void runChain(Band* bands, float* l, float* r, int n) {
        for (int i = 0; i < kMaxGraphicBands; i++) {
            if (!bands[i].flat) bands[i].filter.process(l, r, n);
        }
    }

    // If the snapshot asks for different filters than the running ones, keep
    // the running chain as the outgoing one, move the bands to their new
    // filters and start a crossfade.
    void startFadeIfChanged() {
        Target want[kMaxGraphicBands];
        bool changed = false;
        float lowest = 1e9f;  // lowest centre among the bands that change
        for (int i = 0; i < kMaxGraphicBands; i++) {
            want[i] = snapTarget(i);
            Band& b = bands_[i];
            if (want[i] == b.applied) continue;
            if (!want[i].active && b.flat) {  // flat before and after
                b.applied = want[i];
                continue;
            }
            changed = true;
            if (want[i].active) lowest = std::min(lowest, want[i].centre);
            if (!b.flat) lowest = std::min(lowest, b.applied.centre);
        }
        if (!changed) {
            held_ = false;
            pendingFrames_ = 0;
            return;
        }
        if (pendingFrames_ < settleFrames_) {  // wait for the rest of the change
            held_ = true;
            return;
        }
        held_ = false;
        pendingFrames_ = 0;
        const int frames = (int)std::min((float)kMaxFadeFrames,
                                         std::max((float)kMinFadeFrames,
                                                  snap_.sampleRate / std::max(lowest, 1.0f)));
        std::copy(bands_, bands_ + kMaxGraphicBands, oldBands_);
        for (int i = 0; i < kMaxGraphicBands; i++) {
            Band& b = bands_[i];
            if (want[i] == b.applied) continue;
            if (want[i].active) {
                if (b.flat) b.filter.reset();  // starting from nothing
                // else: the filter keeps its state and only takes new coefficients
                b.filter.setCoefficientsImmediate(design(want[i]));
                b.flat = false;
            } else {
                b.filter.reset();
                b.flat = true;
            }
            b.applied = want[i];
        }
        fadeTotal_ = frames;
        fadeLeft_ = frames;
    }

    struct Snapshot {
        float centre[kMaxGraphicBands];
        float q[kMaxGraphicBands];
        float nominal[kMaxGraphicBands];
        int count = kMaxGraphicBands;
        float scale = 1.0f;
        float sampleRate = 48000.0f;
        uint32_t gen = 0;  // bumped by init(): a reset request
        Snapshot() {
            for (int i = 0; i < kMaxGraphicBands; i++) {
                centre[i] = ISO_FREQUENCIES[i];
                q[i] = GRAPHIC_Q;
                nominal[i] = 0.0f;
            }
        }
    };

    // control side (mutex_)
    mutable std::mutex mutex_;
    int count_ = kMaxGraphicBands;
    float scale_ = 1.0f;
    float ctlRate_ = 48000.0f;
    uint32_t ctlGen_ = 0;
    float centre_[kMaxGraphicBands];
    float q_[kMaxGraphicBands];
    float nominal_[kMaxGraphicBands] = {};

    // published snapshot (seqlock)
    std::atomic<uint32_t> seq_{0};
    std::atomic<float> pCentre_[kMaxGraphicBands];
    std::atomic<float> pQ_[kMaxGraphicBands];
    std::atomic<float> pNominal_[kMaxGraphicBands];
    std::atomic<int> pCount_{kMaxGraphicBands};
    std::atomic<float> pScale_{1.0f};
    std::atomic<float> pRate_{48000.0f};
    std::atomic<uint32_t> pGen_{0};
    std::atomic<float> pLowestActive_{1e9f};

    // audio side
    uint32_t seenSeq_ = 0xFFFFFFFFu;
    uint32_t appliedGen_ = 0;
    Snapshot snap_;
    Band bands_[kMaxGraphicBands];     // the chain the audio is heading for
    Band oldBands_[kMaxGraphicBands];  // the outgoing chain while crossfading
    int settleFrames_ = 0;
    int pendingFrames_ = 0;            // frames a change has waited so far
    bool held_ = false;                // a change is waiting out its settle time
    int fadeLeft_ = 0;                 // frames left in the crossfade, 0 = none
    int fadeTotal_ = 0;                // length of the running crossfade
};
