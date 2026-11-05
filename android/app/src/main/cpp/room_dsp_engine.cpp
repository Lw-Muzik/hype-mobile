#include "room_dsp_engine.h"
#include <cstring>
#include <algorithm>
#include <cmath>
#include <cstdint>

namespace {
// RAII guard that enables ARM flush-to-zero (FTZ) for the lifetime of the
// scope and restores the previous FPCR/FPSCR on exit. FTZ collapses denormal
// floats to zero, preventing the ~100x FPU slowdown that IIR feedback tails
// (EQ biquads, tone shelves, MBC, crossfeed, limiter, reverb) trigger on quiet
// passages and fade-outs. Setting it once here covers the ENTIRE DSP chain.
// No-op on non-ARM targets (e.g. the x86_64 emulator).
struct DenormalGuard {
#if defined(__aarch64__)
    uint64_t oldFpcr_;
    DenormalGuard() {
        __asm__ __volatile__("mrs %0, fpcr" : "=r"(oldFpcr_));
        __asm__ __volatile__("msr fpcr, %0" : : "r"(oldFpcr_ | (1ULL << 24)));
    }
    ~DenormalGuard() {
        __asm__ __volatile__("msr fpcr, %0" : : "r"(oldFpcr_));
    }
#elif defined(__arm__)
    unsigned int oldFpscr_;
    DenormalGuard() {
        __asm__ __volatile__("vmrs %0, fpscr" : "=r"(oldFpscr_));
        __asm__ __volatile__("vmsr fpscr, %0" : : "r"(oldFpscr_ | (1 << 24)));
    }
    ~DenormalGuard() {
        __asm__ __volatile__("vmsr fpscr, %0" : : "r"(oldFpscr_));
    }
#else
    DenormalGuard() {}
    ~DenormalGuard() {}
#endif
    DenormalGuard(const DenormalGuard&) = delete;
    DenormalGuard& operator=(const DenormalGuard&) = delete;
};
} // namespace

RoomDSPEngine::RoomDSPEngine()
    : sampleRate_(48000), channels_(2) {
}

void RoomDSPEngine::init(int sampleRate, int channels) {
    sampleRate_ = sampleRate;
    channels_ = channels;
    stemTap_.setSampleRate(channels == 2 ? sampleRate : 0);

    // EQ init
    graphicEq_.initGraphic((float)sampleRate, MAX_EQ_BANDS);
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
    masterVolume_.reset();
    balance_.reset();
}

void RoomDSPEngine::reset() {
    graphicEq_.reinit((float)sampleRate_);
    parametricEq_.reinit((float)sampleRate_);
    speakerEq_.reinit((float)sampleRate_);
    tone_.reinit((float)sampleRate_);
    limiter_.init(sampleRate_);
    mbc_.reinit((float)sampleRate_);
    reverb_.reset();
    stereoExpander_.reset();
    inputGain_.reset();
    masterVolume_.reset();
    balance_.reset();
    crossfeed_.reset();
    // Surround3D has delay lines and reverb tails; re-init clears them.
    surround3d_.init(static_cast<float>(sampleRate_));
}

void RoomDSPEngine::updateInputGain() {
    float db = trackGainDb_ + headroomDb_;
    if (eqEnabled_.load() || speakerEqEnabled_.load()) db += preampGainDb_;
    if (speakerEqEnabled_.load()) db += speakerPreampDb_;
    inputGain_.setDb(db);
}

void RoomDSPEngine::setEqEnabled(bool enabled) {
    eqEnabled_.store(enabled);
    updateInputGain();
}

void RoomDSPEngine::setSpeakerEqEnabled(bool enabled) {
    speakerEqEnabled_.store(enabled);
    updateInputGain();
}

void RoomDSPEngine::setSpeakerPreampDb(float dB) {
    speakerPreampDb_ = std::max(-24.0f, std::min(24.0f, dB));
    updateInputGain();
}

void RoomDSPEngine::setPreampGain(float dB) {
    preampGainDb_ = std::max(-24.0f, std::min(24.0f, dB));
    updateInputGain();
}

void RoomDSPEngine::setHeadroomDb(float dB) {
    headroomDb_ = std::max(-10.0f, std::min(0.0f, dB));
    updateInputGain();
}

void RoomDSPEngine::setTrackGainDb(float dB) {
    trackGainDb_ = std::max(-30.0f, std::min(24.0f, dB));
    updateInputGain();
}

void RoomDSPEngine::setMasterVolumeDb(float dB) {
    masterVolume_.setDb(std::max(-30.0f, std::min(0.0f, dB)), /*muteAtFloor=*/true);
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

    // Enable flush-to-zero for the whole chain (denormal protection). The
    // previous FPCR is restored automatically when this scope exits.
    DenormalGuard denormalGuard;

    // Live stems first: while any stem level is below 100% and separated
    // audio exists for this range, the tap swaps ExoPlayer's decoded audio for
    // gV*vocals + gD*drums + gI*instruments. The rest of the chain then
    // shapes that mix exactly as it would the original.
    stemTap_.process(buffer, numFrames);
    const bool doStems = stemTap_.active();

    bool doEq = eqEnabled_.load(std::memory_order_relaxed);
    bool doSpeakerEq = speakerEqEnabled_.load(std::memory_order_relaxed);
    bool doTone = tone_.isEnabled();
    bool doMbc = mbc_.isEnabled();
    // On whenever an amount is set, and while gliding back to neutral.
    bool doExpand = stereoExpander_.active();
    bool doCrossfeed = crossfeedEnabled_.load(std::memory_order_relaxed);
    bool doReverb = reverbEnabled_.load(std::memory_order_relaxed);
    bool doSurround3d = surround3dEnabled_.load(std::memory_order_relaxed);
    bool doInputGain = inputGain_.active();
    bool doMaster = masterVolume_.active();
    bool doMono = mono_.active();
    bool doBalance = balance_.active();

    bool doLimiter = limiter_.isEnabled();

    // Early out if nothing is enabled (but always continue if stems are active
    // since the buffer was just replaced and may need DSP processing)
    if (!doStems && !doInputGain && !doMaster && !doMono && !doBalance && !doEq && !doSpeakerEq && !doTone && !doMbc && !doExpand && !doCrossfeed && !doReverb && !doSurround3d && !doLimiter) return;

    // Deinterleave to separate L/R channels
    constexpr int STACK_LIMIT = 2048;
    float stackL[STACK_LIMIT], stackR[STACK_LIMIT];
    float* left;
    float* right;
    float* heapBuf = nullptr;

    if (numFrames <= STACK_LIMIT) {
        left = stackL;
        right = stackR;
    } else {
        heapBuf = new float[numFrames * 2];
        left = heapBuf;
        right = heapBuf + numFrames;
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

    // Input gain: track gain + preamp + headroom. Runs whenever it is not at
    // unity, whether or not the EQ is on.
    if (doInputGain) {
        inputGain_.process(left, right, numFrames);
    }

    // Speaker correction EQ — flattens headphone response before user EQ
    if (doSpeakerEq) {
        speakerEq_.process(left, right, numFrames);
    }

    if (doEq) {
        graphicEq_.process(left, right, numFrames);
        parametricEq_.process(left, right, numFrames);
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

    // Stereo Expand widens the finished mix, reverb included.
    if (doExpand) {
        stereoExpander_.process(left, right, numFrames);
    }

    if (doMono) {
        mono_.process(left, right, numFrames);
    }
    if (doBalance) {
        balance_.process(left, right, numFrames);
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
