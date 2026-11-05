#include "room_dsp_engine.h"
#include <cstring>
#include <algorithm>
#include <cmath>

RoomDSPEngine::RoomDSPEngine()
    : sampleRate_(48000), channels_(2) {
    // The EQ starts off: its scale is 0 until it is switched on.
    updateSmoothScales();
    // Gains, layout and preamp that arrive a few ms apart (a preset) are taken as
    // one change: a change waits 10 ms before its crossfade starts.
    graphicEq_.setSettleFrames(480);
}

void RoomDSPEngine::init(int sampleRate, int channels) {
    sampleRate_ = sampleRate;
    channels_ = channels;

    // EQ init
    graphicEq_.init((float)sampleRate);
    parametricEq_.init((float)sampleRate, MAX_EQ_BANDS);
    speakerEq_.init((float)sampleRate, MAX_EQ_BANDS);

    // Tone controls init
    tone_.init((float)sampleRate);

    // Output limiter init
    limiter_.init(sampleRate);

    // MBC init
    mbc_.init((float)sampleRate);

    // Spatial effects init
    reverb_.init(sampleRate);
    crossfeed_.init(sampleRate);
    surround3d_.init(static_cast<float>(sampleRate));
    crossfeed_.configure(Crossfeed::kChuMoyCutoff, Crossfeed::kChuMoyFeed);

    inputGain_.reset();
    levelCur_ = levelTarget_.load(std::memory_order_relaxed);
    levelSnap_.store(true, std::memory_order_relaxed);
    masterVolume_.reset();
    balance_.reset();
    resetEqStage();
}

void RoomDSPEngine::reset() {
    graphicEq_.init((float)sampleRate_);
    parametricEq_.reinit((float)sampleRate_);
    speakerEq_.reinit((float)sampleRate_);
    tone_.reinit((float)sampleRate_);
    limiter_.init(sampleRate_);
    mbc_.reinit((float)sampleRate_);
    reverb_.reset();
    stereoExpander_.reset();
    inputGain_.reset();
    levelCur_ = levelTarget_.load(std::memory_order_relaxed);
    levelSnap_.store(true, std::memory_order_relaxed);
    masterVolume_.reset();
    balance_.reset();
    crossfeed_.reset();
    resetEqStage();
    // Surround3D has delay lines and reverb tails; re-init clears them.
    surround3d_.init(static_cast<float>(sampleRate_));
}

void RoomDSPEngine::updateInputGain() {
    // Lock-free (see setTrackGainDb): every input is atomic. Two threads may
    // compute at once, so after writing, look again and rewrite if an input
    // moved meanwhile; the last writer then always leaves the current sum.
    // The level (track gain + headroom) is a stage of its own, which platform
    // mode fades out per sample; the speaker preamp stays in the input gain.
    const auto levelDb = [this] {
        return trackGainDb_.load(std::memory_order_relaxed) +
               headroomDb_.load(std::memory_order_relaxed);
    };
    const auto speakerDb = [this] {
        return speakerEqEnabled_.load() ? speakerPreampDb_.load(std::memory_order_relaxed)
                                        : 0.0f;
    };
    for (int attempt = 0; attempt < 3; attempt++) {
        const float level = levelDb();
        const float speaker = speakerDb();
        levelTarget_.store(std::pow(10.0f, level / 20.0f), std::memory_order_relaxed);
        inputGain_.setDb(speaker);
        if (levelDb() == level && speakerDb() == speaker) break;
    }
}

// Whether the level stage has anything to do: its gain is not unity, or is
// still gliding back to it. A stage found idle drops a pending reset-snap.
bool RoomDSPEngine::levelActive() {
    if (levelTarget_.load(std::memory_order_relaxed) != 1.0f || levelCur_ != 1.0f) return true;
    levelSnap_.store(false, std::memory_order_relaxed);
    return false;
}

// Track gain + headroom: glides toward its target like the other gain stages.
// The gain applied is the user's, pulled toward unity by the platform weight
// in the same form as the user preamp's (1/((1-w) + w/P)): 1/(pm + (1-pm)/gain).
// A headroom that offsets the graphic EQ's boost then stays level-matched with
// the boost's blend all the way through the hand-over, and the gain is exactly
// unity once everything is handed over.
void RoomDSPEngine::processLevel(float* left, float* right, const float* pm,
                                 int numFrames) {
    const float t = levelTarget_.load(std::memory_order_relaxed);
    if (levelSnap_.exchange(false, std::memory_order_relaxed)) levelCur_ = t;
    for (int i = 0; i < numFrames; i++) {
        levelCur_ = hype_stage::glideToward(levelCur_, t);
        const float m = pm[i] == 0.0f ? levelCur_
                                      : 1.0f / (pm[i] + (1.0f - pm[i]) / levelCur_);
        left[i] *= m;
        right[i] *= m;
    }
}

// A fresh stream: the EQ stage starts in the state the switches say, with
// nothing to fade.
void RoomDSPEngine::resetEqStage() {
    eqLastOn_ = eqEnabled_.load();
    eqMix_ = eqLastOn_ ? 1.0f : 0.0f;
    platformLastOn_ = platformEq_.load();
    platformMix_ = platformLastOn_ ? 1.0f : 0.0f;
    platformSnap_.store(true, std::memory_order_relaxed);
    graphicStale_ = false;
    speakerGate_ = speakerEqEnabled_.load() ? 1.0f : 0.0f;
    preR_ = preRFrom_ = preRTo_ = 1.0f / preampTarget_.load(std::memory_order_relaxed);
    preM_ = 1.0f;
}

// Length of a fade of the whole EQ: one cycle of the lowest band that is
// doing something (graphic or parametric), clamped to 96..2400 frames - the
// same rule as the graphic EQ's own crossfade.
int RoomDSPEngine::eqFadeFrames() const {
    // The graphic EQ's share is one cycle of its lowest band; the parametric
    // EQ's is two (its bands are narrower, and 1 cycle left a -36.7 dB step).
    const float graphic = (float)sampleRate_ / std::max(graphicEq_.lowestActiveCentreHz(), 1.0f);
    const float parametric = 2.0f * (float)sampleRate_ / std::max(parametricEq_.lowestActiveFreq(), 1.0f);
    return (int)std::min(2400.0f, std::max(96.0f, std::max(graphic, parametric)));
}

void RoomDSPEngine::setEqEnabled(bool enabled) {
    std::lock_guard<std::mutex> lock(levelMutex_);
    eqEnabled_.store(enabled);
    updateSmoothScales();
    updateInputGain();
}

void RoomDSPEngine::setPlatformEqActive(bool on) {
    std::lock_guard<std::mutex> lock(platformMutex_);
    platformEq_.store(on);
    // Tone goes through its own faded enable; the graphic EQ, the user preamp,
    // headroom, track gain, balance, mono and stereo expand follow platformMix_.
    tone_.setEnabled(toneWanted_.load() && !on);
}

void RoomDSPEngine::setToneEnabled(bool enabled) {
    std::lock_guard<std::mutex> lock(platformMutex_);
    toneWanted_.store(enabled);
    tone_.setEnabled(enabled && !platformEq_.load());
}

void RoomDSPEngine::setSpeakerEqEnabled(bool enabled) {
    std::lock_guard<std::mutex> lock(levelMutex_);
    speakerEqEnabled_.store(enabled);
    updateSmoothScales();
    updateInputGain();
}

void RoomDSPEngine::setSpeakerPreampDb(float dB) {
    std::lock_guard<std::mutex> lock(levelMutex_);
    speakerPreampDb_.store(std::max(-24.0f, std::min(24.0f, dB)), std::memory_order_relaxed);
    updateInputGain();
}

void RoomDSPEngine::setPreampGain(float dB) {
    std::lock_guard<std::mutex> lock(levelMutex_);
    preampGainDb_ = std::max(-24.0f, std::min(24.0f, dB));
    preampTarget_.store(std::pow(10.0f, preampGainDb_ / 20.0f), std::memory_order_relaxed);
    updateSmoothScales();
}

void RoomDSPEngine::setHeadroomDb(float dB) {
    std::lock_guard<std::mutex> lock(levelMutex_);
    headroomDb_.store(std::max(-10.0f, std::min(0.0f, dB)), std::memory_order_relaxed);
    updateSmoothScales();
    updateInputGain();
}

void RoomDSPEngine::setSmoothGains(bool on) {
    std::lock_guard<std::mutex> lock(levelMutex_);
    smoothGains_ = on;
    updateSmoothScales();
}

void RoomDSPEngine::setSystemVolumeDb(float dB) {
    std::lock_guard<std::mutex> lock(levelMutex_);
    systemVolumeDb_ = std::isfinite(dB) ? std::max(-96.0f, std::min(0.0f, dB)) : 0.0f;
    updateSmoothScales();
}

float RoomDSPEngine::smoothLevelDb() const {
    std::lock_guard<std::mutex> lock(levelMutex_);
    return levelDbLocked();
}

SmoothScales RoomDSPEngine::smoothScales() const {
    std::lock_guard<std::mutex> lock(levelMutex_);
    return smoothGainScales(levelDbLocked(), smoothGains_);
}

float RoomDSPEngine::levelDbLocked() const {
    float t = masterVolumeDb_ + systemVolumeDb_ + headroomDb_;
    if (eqEnabled_.load() || speakerEqEnabled_.load()) t += preampGainDb_;
    return t;
}

void RoomDSPEngine::updateSmoothScales() {
    const SmoothScales s = smoothGainScales(levelDbLocked(), smoothGains_);
    const float eqFactor = s.eqDb / kEqScaleOffDb;
    graphicEq_.setGainScale(eqFactor);
    tone_.setGainScale(s.bassDb / kBassScaleOffDb, eqFactor);
}

// Called from the render thread as well as the control thread (the iOS tap
// applies the next item's gain at a gapless boundary): no locks here. The
// track gain is not part of the smooth-gains level T, so levelMutex_ is not
// needed.
void RoomDSPEngine::setTrackGainDb(float dB) {
    trackGainDb_.store(std::max(-30.0f, std::min(24.0f, dB)),
                       std::memory_order_relaxed);
    updateInputGain();
}

void RoomDSPEngine::setMasterVolumeDb(float dB) {
    std::lock_guard<std::mutex> lock(levelMutex_);
    masterVolumeDb_ = std::max(-30.0f, std::min(0.0f, dB));
    masterVolume_.setDb(masterVolumeDb_, /*muteAtFloor=*/true);
    updateSmoothScales();
}

void RoomDSPEngine::setGraphicLayout(const float* centresHz, int count,
                                     const float* gainsDb) {
    graphicEq_.setLayout(centresHz, count, gainsDb);
}

void RoomDSPEngine::setGraphicBandGain(int band, float dB) {
    graphicEq_.setBandGain(band, dB);
}

void RoomDSPEngine::setGraphicAllBands(const float* gains, int count) {
    graphicEq_.setAllGains(gains, count);
}

void RoomDSPEngine::setParametricBand(int band, float freq, float gainDb,
                                       float q, int filterType, bool enabled) {
    BiquadType type = static_cast<BiquadType>(
        std::min(std::max(filterType, 0), 6));
    parametricEq_.setBand(band, freq, gainDb, q, type, enabled);
}

void RoomDSPEngine::setParametricAllBands(const float* freqs, const float* gains,
                                           const float* qs, int count) {
    count = std::min(count, MAX_EQ_BANDS);
    for (int i = 0; i < count; i++) {
        parametricEq_.setBand(i, freqs[i], gains[i], qs[i],
                              BiquadType::Peaking, true);
    }
}

void RoomDSPEngine::process(float* buffer, int numFrames) {
    if (channels_ != 2 || numFrames <= 0) return;

    // Let the tone take a pending init()/reset() while it is off (see sync()).
    tone_.sync();

    // The EQ stage runs while the EQ or the speaker EQ is on, and for as long
    // as it takes to fade out after either is switched off.
    const bool eqOn = eqEnabled_.load(std::memory_order_relaxed);
    bool doSpeakerEq = speakerEqEnabled_.load(std::memory_order_relaxed);
    const bool doEq = eqOn || eqMix_ > 0.0f || doSpeakerEq || speakerGate_ > 0.0f;
    // Out of the chain, the preamp is not counted: it takes its setting at once.
    if (!doEq) {
        preR_ = preRFrom_ = preRTo_ = 1.0f / preampTarget_.load(std::memory_order_relaxed);
        preM_ = 1.0f;
    }
    // Track gain + headroom, and the platform hand-over that fades them.
    const bool doLevel = levelActive();
    const bool platformOn = platformEq_.load(std::memory_order_relaxed);
    // A new stream (init/reset) starts in the state the flag says, which the
    // platform layer replays after init(): nothing to fade.
    const bool snapPlatform = platformSnap_.exchange(false, std::memory_order_relaxed);
    // With none of the stages that follow the hand-over running there is
    // nothing audible to fade: it takes its state at once.
    // On whenever an amount is set, and while gliding back to neutral.
    const bool doExpand = stereoExpander_.active();
    const bool doMono = mono_.active();
    const bool doBalance = balance_.active();
    const bool usesPlatformMix = doEq || doLevel || doExpand || doMono || doBalance;
    if (snapPlatform || !usesPlatformMix) {
        platformMix_ = platformOn ? 1.0f : 0.0f;
        platformLastOn_ = platformOn;
    }
    // The tone runs while it is on, and until its fade to flat has finished.
    bool doTone = tone_.isEnabled() || tone_.busy();
    bool doMbc = mbc_.isEnabled();
    bool doCrossfeed = crossfeedEnabled_.load(std::memory_order_relaxed);
    bool doReverb = reverbEnabled_.load(std::memory_order_relaxed);
    bool doSurround3d = surround3dEnabled_.load(std::memory_order_relaxed);
    bool doInputGain = inputGain_.active();
    bool doMaster = masterVolume_.active();
    bool doLimiter = limiter_.isEnabled();

    // Early out if nothing is enabled
    if (!doInputGain && !doLevel && !doMaster && !doMono && !doBalance && !doEq && !doSpeakerEq && !doTone && !doMbc && !doExpand && !doCrossfeed && !doReverb && !doSurround3d && !doLimiter) return;

    // Deinterleave to separate L/R channels
    constexpr int STACK_LIMIT = 2048;
    float stackL[STACK_LIMIT], stackR[STACK_LIMIT], stackP[STACK_LIMIT];
    float* left;
    float* right;
    float* pm;  // the platform weight, per sample
    float* heapBuf = nullptr;

    if (numFrames <= STACK_LIMIT) {
        left = stackL;
        right = stackR;
        pm = stackP;
    } else {
        heapBuf = new float[numFrames * 3];
        left = heapBuf;
        right = heapBuf + numFrames;
        pm = heapBuf + 2 * numFrames;
    }

    for (int i = 0; i < numFrames; i++) {
        left[i]  = buffer[i * 2];
        right[i] = buffer[i * 2 + 1];
    }

    // Signal chain (see room_dsp_engine.h):
    //   [Input gain] -> [Speaker Correction EQ] -> [Graphic EQ]
    //   -> [Parametric EQ] -> [Tone Controls] -> [MBC]
    //   -> [Crossfeed] -> [3D Surround] -> [Reverb] -> [Master volume]
    //   -> [Stereo Expand] -> [Mono] -> [Balance] -> [Output Limiter]

    if (usesPlatformMix) fillPlatformMix(pm, numFrames, platformOn);

    // Level: track gain + headroom, and the speaker preamp's input gain. Each
    // runs whenever it is not at unity, whether or not the EQ is on.
    if (doLevel) {
        processLevel(left, right, pm, numFrames);
    }
    if (doInputGain) {
        inputGain_.process(left, right, numFrames);
    }

    // Speaker correction EQ — flattens headphone response before user EQ
    if (doSpeakerEq) {
        speakerEq_.process(left, right, numFrames);
    }

    if (doEq) {
        processEqStage(left, right, pm, numFrames, eqOn, doSpeakerEq);
    }

    // Tone controls (bass/treble shelves — applied even if EQ is off,
    // they're independent knobs like on a hi-fi amp)
    if (doTone) {
        tone_.process(left, right, numFrames);
    }

    // MBC (after EQ + tone, before spatial effects)
    if (doMbc) {
        mbc_.process(left, right, numFrames);
    }

    // Spatial effects
    if (doCrossfeed) {
        crossfeed_.process(left, right, numFrames);
    }
    if (doSurround3d) {
        surround3d_.process(left, right, numFrames);
    }
    if (doReverb) {
        reverb_.process(left, right, numFrames);
    }

    // Master volume sits after every effect, ahead of the finishing stages.
    if (doMaster) {
        masterVolume_.process(left, right, numFrames);
    }

    // Stereo Expand widens the finished mix, reverb included; then mono, then
    // balance. Handed over to the platform with the rest.
    if (doExpand || doMono || doBalance) {
        processOutputStages(left, right, pm, numFrames, doExpand, doMono, doBalance);
    }

    // Output limiter — only when the user turns it on. The hard clamp below
    // still prevents digital clipping as a safety net.
    if (doLimiter) {
        limiter_.process(left, right, numFrames);
    }

    // Re-interleave with safety clamp (belt-and-suspenders after limiter)
    for (int i = 0; i < numFrames; i++) {
        buffer[i * 2]     = std::clamp(left[i],  -1.0f, 1.0f);
        buffer[i * 2 + 1] = std::clamp(right[i], -1.0f, 1.0f);
    }

    delete[] heapBuf;
}

// Expand, mono and balance. Their settings are the user's at all times; the
// platform hand-over blends the three stages' output against their input by
// (1 - pm), per sample: both ends are continuous signals, so it does not click,
// which a hand-over through the stages' own 256-frame glides did. Once fully
// handed over they are not run (their glides simply hold).
void RoomDSPEngine::processOutputStages(float* left, float* right, const float* pm,
                                        int numFrames, bool doExpand, bool doMono,
                                        bool doBalance) {
    constexpr int kChunk = 256;
    for (int pos = 0; pos < numFrames; pos += kChunk) {
        const int len = std::min(kChunk, numFrames - pos);
        float* l = left + pos;
        float* r = right + pos;
        const float* w = pm + pos;
        if (w[0] >= 1.0f && w[len - 1] >= 1.0f) continue;  // handed over
        const bool blend = w[0] != 0.0f || w[len - 1] != 0.0f;
        float dryL[kChunk], dryR[kChunk];
        if (blend) {
            std::copy(l, l + len, dryL);
            std::copy(r, r + len, dryR);
        }
        if (doExpand) stereoExpander_.process(l, r, len);
        if (doMono) mono_.process(l, r, len);
        if (doBalance) balance_.process(l, r, len);
        if (blend) {
            for (int k = 0; k < len; k++) {
                const float u = 1.0f - w[k];
                l[k] = dryL[k] + (l[k] - dryL[k]) * u;
                r[k] = dryR[k] + (r[k] - dryR[k]) * u;
            }
        }
    }
}

// The platform weight for a block: 0 = Hype's own stages, 1 = handed over to
// the platform, moving linearly over the fade length (the EQ's own, and not
// shorter than kPlatformMinFade, so that headroom and track gain, which glide
// out with it, are not rushed). Advanced here once so that the level stage and
// the EQ stage see the same value at every sample.
void RoomDSPEngine::fillPlatformMix(float* pm, int numFrames, bool platformOn) {
    constexpr int kPlatformMinFade = 960;
    if (platformOn != platformLastOn_) {
        platformStep_ = 1.0f / (float)std::max(eqFadeFrames(), kPlatformMinFade);
        platformLastOn_ = platformOn;
    }
    const float target = platformOn ? 1.0f : 0.0f;
    for (int i = 0; i < numFrames; i++) {
        if (platformMix_ != target) {
            platformMix_ = platformMix_ < target ? std::min(platformMix_ + platformStep_, target)
                                                 : std::max(platformMix_ - platformStep_, target);
        }
        pm[i] = platformMix_;
    }
}

// The graphic and parametric EQ, then the user preamp, in one stage so that
// they share one blend weight w (0 = EQ out, 1 = in), which moves linearly
// over the fade length. The EQ output is (1-w) dry + w EQ(dry): both ends are
// continuous signals, so it does not click. The preamp gain follows the same
// w - it is 1/((1-w) + w/P) for a preamp P - which keeps the net level of a
// preamp that offsets the EQ's boost steady through the fade, instead of the
// preamp arriving at a different time from the boost. (It comes after the EQ
// so that the filters never see a level that is still changing.) It counts
// while the EQ is on (w) or the speaker EQ is (speakerGate_, which glides like
// the other stages); the larger of the two applies.
//
// Platform mode hands the graphic EQ and the user preamp to the platform with a
// second weight, pm (0 = Hype's own, 1 = the platform's), which also fades the
// level stage. The graphic EQ's output is blended out against its input by
// 1 - pm before the parametric EQ (which stays live), and the preamp's weight
// is scaled by the same 1 - pm, so the boost and the preamp that offsets it
// leave together - even while only the speaker EQ is keeping the preamp term
// on. Once fully handed over the graphic EQ is not run at all; it restarts
// clean when it is brought back, like an EQ switched on after being off.
void RoomDSPEngine::processEqStage(float* left, float* right, const float* pm,
                                   int numFrames, bool eqOn, bool speakerOn) {
    constexpr int kChunk = 256;
    const float eqTarget = eqOn ? 1.0f : 0.0f;
    const float speakerTarget = speakerOn ? 1.0f : 0.0f;
    if (eqOn != eqLastOn_) {
        // Coming back from bypass: the filters start clean and the blend from 0.
        if (eqOn && eqMix_ <= 0.0f) {
            graphicEq_.restart();
            graphicStale_ = false;
            parametricEq_.clearState();
        }
        eqStep_ = 1.0f / (float)eqFadeFrames();
        eqLastOn_ = eqOn;
    }
    // The preamp moves over the graphic EQ's crossfade, so that a preset's boost
    // and the preamp that offsets it arrive together; a change on its own
    // glides at the stage slope. A graphic change still waiting out its settle
    // time holds the preamp back too, so the two start the same block.
    const bool graphicProbe = (eqOn || eqMix_ > 0.0f) && !graphicStale_ &&
                              !(pm[0] >= 1.0f && pm[numFrames - 1] >= 1.0f);
    int graphicLeft = 0;
    bool graphicPending = false;
    if (graphicProbe) {
        graphicEq_.beginBlock();
        graphicLeft = graphicEq_.fadeFramesLeft();
        graphicPending = graphicEq_.changePending();
    }
    const float rTarget = 1.0f / preampTarget_.load(std::memory_order_relaxed);
    if (rTarget != preRTo_ && !graphicPending) {
        preRFrom_ = preR_;
        preRTo_ = rTarget;
        preM_ = 0.0f;
        const float slope = 256.0f * std::fabs(1.0f / rTarget - 1.0f / preRFrom_);
        const float frames = graphicLeft > 0 ? (float)std::max(graphicLeft, 96)
                                             : std::max(1.0f, std::ceil(slope));
        preStep_ = 1.0f / frames;
    }
    int pos = 0;
    while (pos < numFrames) {
        // The hand-over is settled when pm no longer moves for the rest of the
        // block (it then sits at 0 or 1).
        const float pmNow = pm[pos];
        const bool pmSettled = pmNow == pm[numFrames - 1];
        const bool settled = eqMix_ == eqTarget && speakerGate_ == speakerTarget &&
                             pmSettled && preM_ >= 1.0f && preRTo_ == rTarget;
        float* l = left + pos;
        float* r = right + pos;
        if (settled) {
            const int len = numFrames - pos;
            if (eqTarget == 1.0f) {
                if (pmNow < 1.0f) {
                    if (graphicStale_) {
                        graphicEq_.restart();
                        graphicStale_ = false;
                    }
                    graphicEq_.process(l, r, len);
                } else {
                    graphicStale_ = true;
                }
                parametricEq_.process(l, r, len);
            }
            const float g = std::max(eqMix_, speakerGate_) * (1.0f - pmNow);
            if (g > 0.0f && preR_ != 1.0f) {
                const float a = 1.0f / ((1.0f - g) + g * preR_);
                for (int k = 0; k < len; k++) {
                    l[k] *= a;
                    r[k] *= a;
                }
            }
            return;
        }
        const int len = std::min(kChunk, numFrames - pos);
        const bool eqNeeded = eqTarget == 1.0f || eqMix_ > 0.0f;
        // Any sample of this chunk with some of the graphic EQ still in.
        const bool graphicOut = pm[pos] >= 1.0f && pm[pos + len - 1] >= 1.0f;
        const bool graphicNeeded = eqNeeded && !graphicOut;
        const bool platformBlend = pm[pos + len - 1] != 0.0f || pm[pos] != 0.0f;
        float w[kChunk], a[kChunk];
        for (int k = 0; k < len; k++) {
            if (eqMix_ != eqTarget) {
                eqMix_ = eqMix_ < eqTarget ? std::min(eqMix_ + eqStep_, eqTarget)
                                           : std::max(eqMix_ - eqStep_, eqTarget);
            }
            speakerGate_ = hype_stage::glideToward(speakerGate_, speakerTarget);
            const float g = std::max(eqMix_, speakerGate_) * (1.0f - pm[pos + k]);
            if (preM_ < 1.0f) {
                preM_ = std::min(preM_ + preStep_, 1.0f);
                preR_ = preRFrom_ + (preRTo_ - preRFrom_) * preM_;
            }
            // Not counted (g = 0): nothing to move, so the preamp is already at
            // its setting when it comes in.
            if (g == 0.0f) {
                preR_ = preRFrom_ = preRTo_ = rTarget;
                preM_ = 1.0f;
            }
            w[k] = eqMix_;
            a[k] = 1.0f / ((1.0f - g) + g * preR_);
        }
        if (graphicOut && eqNeeded) graphicStale_ = true;
        if (eqNeeded) {
            float dryL[kChunk], dryR[kChunk];
            std::copy(l, l + len, dryL);
            std::copy(r, r + len, dryR);
            if (graphicNeeded) {
                if (graphicStale_) {
                    graphicEq_.restart();
                    graphicStale_ = false;
                }
                graphicEq_.process(l, r, len);
                if (platformBlend) {
                    for (int k = 0; k < len; k++) {
                        const float u = 1.0f - pm[pos + k];
                        l[k] = dryL[k] + (l[k] - dryL[k]) * u;
                        r[k] = dryR[k] + (r[k] - dryR[k]) * u;
                    }
                }
            }
            parametricEq_.process(l, r, len);
            for (int k = 0; k < len; k++) {
                l[k] = dryL[k] + (l[k] - dryL[k]) * w[k];
                r[k] = dryR[k] + (r[k] - dryR[k]) * w[k];
            }
        }
        for (int k = 0; k < len; k++) {
            l[k] *= a[k];
            r[k] *= a[k];
        }
        pos += len;
    }
}

void RoomDSPEngine::setSpeakerEqBand(int band, float freq, float gainDb,
                                      float q, int filterType, bool enabled) {
    BiquadType type = static_cast<BiquadType>(
        std::min(std::max(filterType, 0), 6));
    speakerEq_.setBand(band, freq, gainDb, q, type, enabled);
}

void RoomDSPEngine::clearSpeakerEq() {
    for (int i = 0; i < MAX_EQ_BANDS; i++) {
        speakerEq_.setBand(i, 1000.0f, 0.0f, 1.0f, BiquadType::Peaking, false);
    }
}
