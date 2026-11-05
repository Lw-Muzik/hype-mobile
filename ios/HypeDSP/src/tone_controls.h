#pragma once
#include "biquad.h"
#include <atomic>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <mutex>

// Independent Bass and Treble tone controls, like the knobs on a hi-fi amp.
// These are shelf filters applied ON TOP of the graphic/parametric EQ,
// giving extra tonal shaping without disturbing the EQ curve.
//
// Bass: Low-shelf filter (default 80 Hz, Q 0.707)
// Treble: High-shelf filter (default 10 kHz, Q 0.707)
//
// Each has configurable: frequency, gain (dB), Q
// The Q controls the slope/resonance of the shelf — higher Q = steeper
// transition with a slight resonance at the corner frequency.
//
// Ranges (kept byte-identical in android/app/src/main/cpp and ios/HypeDSP/src):
// bass gain 0..22.5 dB, treble gain 0..15 dB (boost only), bass frequency
// 20..250 Hz, treble frequency 5..15 kHz, Q 0.1..2. The stored gains are in dB
// at the fixed (smoothing off) scale; setGainScale() pulls the gain that is
// actually applied in or out (see smooth_gains.h), without touching them.
//
// Nothing here switches. Whenever a shelf's filter changes (a gain, frequency,
// Q or scale moves, or the tone is switched on or off) the shelf that ran
// keeps running on the same input, the new one starts beside it, and the
// output is a linear crossfade from old to new, as in graphic_eq.h. Each
// chain's output is a continuous signal, so the blend does not click at any
// phase, which interpolating the coefficients of one filter does for a bass
// tone. The blend is three cycles of the shelf's corner frequency long,
// clamped to 96..2400 frames. Switching the tone off fades the shelves to flat and
// then skips them (bit-exact); switching it on starts them from clean state.
// A change that arrives mid-blend waits for it to finish and takes the latest
// settings.
//
// Threading: setters run on any control thread, process() on the audio
// thread. Setters are serialised by a mutex and publish the whole parameter
// set (and a reset counter) as one snapshot through a seqlock; the audio thread
// reads it at the start of a block, designs the coefficients itself, and never
// blocks. All filter state belongs to the audio thread alone. init(), reinit()
// and reset() only publish a reset request, which process() applies at the
// start of its next block (state cleared, coefficients live at once).
class ToneControls {
public:
    ToneControls() { publish(); }

    void init(float sampleRate) { requestReset(sampleRate); }
    void reinit(float sampleRate) { requestReset(sampleRate); }
    void reset() { requestReset(0.0f); }

    // Bass controls
    void setBassGain(float dB) {
        std::lock_guard<std::mutex> lock(mutex_);
        bassGainDb_ = clampGain(dB, kMaxBassGainDb);
        publish();
    }
    void setBassFreq(float hz) {
        std::lock_guard<std::mutex> lock(mutex_);
        bassFreq_ = clampFreq(hz, 20.0f, 250.0f, bassFreq_);
        publish();
    }
    void setBassQ(float q) {
        std::lock_guard<std::mutex> lock(mutex_);
        bassQ_ = clampQ(q, bassQ_);
        publish();
    }
    float getBassGain() const { return locked(bassGainDb_); }
    // The gain the bass shelf is designed for: the stored gain x its scale.
    float effectiveBassGainDb() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return bassGainDb_ * bassScale_;
    }
    float getBassFreq() const { return locked(bassFreq_); }
    float getBassQ() const { return locked(bassQ_); }

    // Treble controls
    void setTrebleGain(float dB) {
        std::lock_guard<std::mutex> lock(mutex_);
        trebleGainDb_ = clampGain(dB, kMaxTrebleGainDb);
        publish();
    }
    void setTrebleFreq(float hz) {
        std::lock_guard<std::mutex> lock(mutex_);
        trebleFreq_ = clampFreq(hz, 5000.0f, 15000.0f, trebleFreq_);
        publish();
    }
    void setTrebleQ(float q) {
        std::lock_guard<std::mutex> lock(mutex_);
        trebleQ_ = clampQ(q, trebleQ_);
        publish();
    }
    float getTrebleGain() const { return locked(trebleGainDb_); }
    float effectiveTrebleGainDb() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return trebleGainDb_ * trebleScale_;
    }
    float getTrebleFreq() const { return locked(trebleFreq_); }
    float getTrebleQ() const { return locked(trebleQ_); }

    // Pull the applied gains in or out, each factor 0..1 (default 1), without
    // touching the stored gains. A non-finite factor counts as 1.
    void setGainScale(float bassFactor, float trebleFactor) {
        std::lock_guard<std::mutex> lock(mutex_);
        bassScale_ = clampFactor(bassFactor);
        trebleScale_ = clampFactor(trebleFactor);
        publish();
    }

    // Get the max boost from both tone controls (for auto-gain compensation)
    float getPeakGain() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return std::max(0.0f, std::max(bassGainDb_, trebleGainDb_));
    }

    void setEnabled(bool enabled) {
        std::lock_guard<std::mutex> lock(mutex_);
        enabled_.store(enabled, std::memory_order_relaxed);
        publish();
    }
    bool isEnabled() const { return enabled_.load(std::memory_order_relaxed); }

    // Audio thread only: whether either shelf is still doing anything (running
    // or mid-blend). A caller that skips the tone while it is switched off
    // must keep calling process() for as long as this is true, so that the
    // fade to flat finishes.
    bool busy() const { return bass_.busy() || treble_.busy(); }

    // Audio thread only: take the latest published settings and apply a
    // pending init()/reset() request, without touching any audio. Call it every
    // block, even while the tone is off and process() is skipped, so that a
    // reset is consumed while the shelves are flat; otherwise it would be
    // applied at the moment the tone is switched on, bringing the shelves in at
    // once. Cheap: one seqlock read, and only a changed snapshot is copied.
    void sync() {
        readSnapshot();
        if (snap_.gen != appliedGen_) applyReset();
    }

    void process(float* left, float* right, int numFrames) {
        if (numFrames <= 0) return;
        sync();
        bass_.process(want(false), snap_.v[kRate], left, right, numFrames);
        treble_.process(want(true), snap_.v[kRate], left, right, numFrames);
    }

private:
    static constexpr float kMaxBassGainDb = 22.5f;
    static constexpr float kMaxTrebleGainDb = 15.0f;
    static constexpr float kActiveDb = 0.05f;
    static constexpr int kMinFadeFrames = Biquad::FADE_LENGTH;  // 96
    static constexpr int kMaxFadeFrames = 2400;
    static constexpr int kBlendChunk = 256;  // stack scratch per blend step
    // Blend length in cycles of the corner frequency. A shelf reaches well below
    // its corner, and one cycle left a -33 dB step in a 40 Hz tone under an
    // 80 Hz shelf; three cycles brings it under -40 dB.
    static constexpr float kFadeCycles = 3.0f;

    static float clampGain(float dB, float maxDb) {
        if (!std::isfinite(dB)) return 0.0f;
        return std::max(0.0f, std::min(maxDb, dB));
    }
    static float clampFreq(float hz, float lo, float hi, float keep) {
        if (!std::isfinite(hz)) return keep;
        return std::max(lo, std::min(hi, hz));
    }
    static float clampQ(float q, float keep) {
        if (!std::isfinite(q)) return keep;
        return std::max(0.1f, std::min(2.0f, q));
    }
    static float clampFactor(float f) {
        return std::isfinite(f) ? std::max(0.0f, std::min(1.0f, f)) : 1.0f;
    }

    float locked(const float& v) const {
        std::lock_guard<std::mutex> lock(mutex_);
        return v;
    }

    // What one shelf should be doing.
    struct Target {
        bool active = false;
        float freq = 0.0f, q = 0.0f, gainDb = 0.0f;
        bool operator==(const Target& o) const {
            return active == o.active && freq == o.freq && q == o.q &&
                   gainDb == o.gainDb;
        }
    };

    // One shelf on the audio thread: the running filter, and the outgoing one
    // while a blend runs.
    struct Shelf {
        explicit Shelf(bool isHigh) : high(isHigh) {}
        const bool high;
        Biquad cur, old;
        bool curFlat = true;  // the identity: not run, leaves the audio untouched
        bool oldFlat = true;
        Target applied;       // what `cur` was last designed for
        int fadeLeft = 0;     // frames left in the blend, 0 = none
        int fadeTotal = 0;

        bool busy() const { return !curFlat || fadeLeft > 0; }

        BiquadCoeffs design(float sr, const Target& t) const {
            return high ? BiquadDesign::highShelf(sr, t.freq, t.gainDb, t.q)
                        : BiquadDesign::lowShelf(sr, t.freq, t.gainDb, t.q);
        }

        // Clear everything; the shelf is live at once for `t`.
        void restart(float sr, const Target& t) {
            cur = Biquad();
            old = Biquad();
            oldFlat = true;
            fadeLeft = fadeTotal = 0;
            curFlat = !t.active;
            if (t.active) cur.setCoefficientsImmediate(design(sr, t));
            applied = t;
        }

        void startFadeIfChanged(float sr, const Target& t) {
            if (t == applied) return;
            if (!t.active && curFlat) {  // flat before and after
                applied = t;
                return;
            }
            float corner = 1e9f;
            if (t.active) corner = std::min(corner, t.freq);
            if (!curFlat) corner = std::min(corner, applied.freq);
            const int frames = (int)std::min((float)kMaxFadeFrames,
                                             std::max((float)kMinFadeFrames,
                                                      kFadeCycles * sr / std::max(corner, 1.0f)));
            old = cur;
            oldFlat = curFlat;
            if (t.active) {
                if (curFlat) cur.reset();  // starting from nothing
                // else: the filter keeps its state and only takes new coefficients
                cur.setCoefficientsImmediate(design(sr, t));
                curFlat = false;
            } else {
                cur.reset();
                curFlat = true;
            }
            applied = t;
            fadeTotal = fadeLeft = frames;
        }

        void process(const Target& t, float sr, float* l, float* r, int n) {
            int pos = 0;
            while (pos < n) {
                if (fadeLeft == 0) startFadeIfChanged(sr, t);
                if (fadeLeft == 0) {
                    if (!curFlat) cur.process(l + pos, r + pos, n - pos);
                    return;
                }
                const int len = std::min(std::min(n - pos, fadeLeft), kBlendChunk);
                float* pl = l + pos;
                float* pr = r + pos;
                float oL[kBlendChunk], oR[kBlendChunk];
                std::copy(pl, pl + len, oL);
                std::copy(pr, pr + len, oR);
                if (!oldFlat) old.process(oL, oR, len);
                if (!curFlat) cur.process(pl, pr, len);
                const int done = fadeTotal - fadeLeft;
                for (int k = 0; k < len; k++) {
                    const float w = (float)(done + k + 1) / (float)fadeTotal;
                    pl[k] = oL[k] * (1.0f - w) + pl[k] * w;
                    pr[k] = oR[k] * (1.0f - w) + pr[k] * w;
                }
                fadeLeft -= len;
                if (fadeLeft == 0) {
                    old = Biquad();
                    oldFlat = true;
                }
                pos += len;
            }
        }
    };

    // Parameter indices in the published snapshot.
    enum Param {
        kBassGain, kBassFreq, kBassQ, kBassScale,
        kTrebleGain, kTrebleFreq, kTrebleQ, kTrebleScale,
        kEnabled, kRate, kNumParams
    };

    struct Snapshot {
        float v[kNumParams] = {0.0f, 80.0f, 0.707f, 1.0f,
                               0.0f, 10000.0f, 0.707f, 1.0f,
                               0.0f, 48000.0f};
        uint32_t gen = 0;
    };

    void requestReset(float sampleRate) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (sampleRate > 0.0f) ctlRate_ = sampleRate;
        ctlGen_++;
        publish();
    }

    // ---- control side: publish the parameter set (mutex held) ----
    void publish() {
        const float v[kNumParams] = {
            bassGainDb_, bassFreq_, bassQ_, bassScale_,
            trebleGainDb_, trebleFreq_, trebleQ_, trebleScale_,
            enabled_.load(std::memory_order_relaxed) ? 1.0f : 0.0f, ctlRate_};
        const uint32_t s = seq_.load(std::memory_order_relaxed);
        seq_.store(s + 1, std::memory_order_relaxed);  // odd: writing
        std::atomic_thread_fence(std::memory_order_release);
        for (int i = 0; i < kNumParams; i++) p_[i].store(v[i], std::memory_order_relaxed);
        pGen_.store(ctlGen_, std::memory_order_relaxed);
        seq_.store(s + 2, std::memory_order_release);  // even: stable
    }

    // ---- audio side ----
    // Take a new snapshot when one has been published and is consistent;
    // otherwise keep the previous one (the next block tries again).
    void readSnapshot() {
        const uint32_t s1 = seq_.load(std::memory_order_acquire);
        if (s1 == seenSeq_ || (s1 & 1u)) return;
        Snapshot n;
        for (int i = 0; i < kNumParams; i++) n.v[i] = p_[i].load(std::memory_order_relaxed);
        n.gen = pGen_.load(std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_acquire);
        if (seq_.load(std::memory_order_relaxed) != s1) return;
        snap_ = n;
        seenSeq_ = s1;
    }

    Target want(bool high) const {
        Target t;
        t.freq = snap_.v[high ? kTrebleFreq : kBassFreq];
        t.q = snap_.v[high ? kTrebleQ : kBassQ];
        t.gainDb = snap_.v[high ? kTrebleGain : kBassGain] *
                   snap_.v[high ? kTrebleScale : kBassScale];
        t.active = snap_.v[kEnabled] != 0.0f && std::fabs(t.gainDb) >= kActiveDb;
        return t;
    }

    void applyReset() {
        appliedGen_ = snap_.gen;
        bass_.restart(snap_.v[kRate], want(false));
        treble_.restart(snap_.v[kRate], want(true));
    }

    // control side (mutex_)
    mutable std::mutex mutex_;
    std::atomic<bool> enabled_{false};
    float ctlRate_ = 48000.0f;
    uint32_t ctlGen_ = 0;
    // Bass defaults: 80 Hz, Butterworth Q (0.707), 0 dB
    float bassGainDb_ = 0.0f;
    float bassScale_ = 1.0f;
    float bassFreq_ = 80.0f;
    float bassQ_ = 0.707f;
    // Treble defaults: 10 kHz, Butterworth Q (0.707), 0 dB
    float trebleGainDb_ = 0.0f;
    float trebleScale_ = 1.0f;
    float trebleFreq_ = 10000.0f;
    float trebleQ_ = 0.707f;

    // published snapshot (seqlock)
    std::atomic<uint32_t> seq_{0};
    std::atomic<float> p_[kNumParams] = {};
    std::atomic<uint32_t> pGen_{0};

    // audio side
    uint32_t seenSeq_ = 0xFFFFFFFFu;
    uint32_t appliedGen_ = 0;
    Snapshot snap_;
    Shelf bass_{false};
    Shelf treble_{true};
};
