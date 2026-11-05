#pragma once
#include "parametric_eq.h"
#include "multiband_compressor.h"
#include "tone_controls.h"
#include "limiter.h"
#include "output_stages.h"
#include "fdn_reverb.h"
#include "stereo_expander.h"
#include "crossfeed.h"
#include "surround3d.h"
#include "stems/stem_tap.h"
#include <algorithm>
#include <atomic>

// Main DSP engine orchestrator — professional-grade signal chain.
//
// Processing chain:
//   [Stems] -> [Input gain: track + preamp + headroom] -> [Speaker Correction EQ]
//   -> [Graphic EQ 32-band] -> [Parametric EQ 32-band] -> [Tone Controls]
//   -> [MBC 10-band] -> [Crossfeed] -> [3D Surround] -> [FDN Reverb]
//   -> [Master volume] -> [Stereo Expand] -> [Mono] -> [Balance]
//   -> [Output Limiter] -> final clamp -> Output
//   (the stems stage exists on Android only)
//
// Key design decisions:
//   - No auto-gain: the input gain is exactly track gain + headroom (+ preamp
//     while an EQ is on, + speaker preamp while the speaker EQ is on);
//     EQ and tone setters never touch it. Each stage is skipped (bit-exact)
//     while at its neutral setting.
//   - Input gain, master volume and balance glide at a fixed slope, so a
//     slider being dragged does not click (see output_stages.h).
//   - Master volume sits after the effects and ahead of Stereo Expand, mono
//     and balance, which are spatial finishing touches on the final level.
//   - The limiter is last and runs only when the user turns it on (no
//     look-ahead; the final hard clamp backstops the first samples of a peak).
//   - Tone controls AFTER EQ, BEFORE MBC: EQ shapes frequency, tone adds
//     power, MBC controls dynamics of the combined result
//   - Sample-rate-adaptive smoothing for consistent behavior at all rates
//
// All processing runs in the platform audio pipeline (ExoPlayer AudioProcessor
// on Android, the audio unit callback on iOS). Fully custom C++ DSP.
// All parameter updates are lock-free (atomic targets, per-sample smoothing).
class RoomDSPEngine {
public:
    RoomDSPEngine();

    void init(int sampleRate, int channels);
    void reset();

    // Process interleaved stereo PCM float buffer in-place.
    void process(float* buffer, int numFrames);

    // EQ controls
    // Turning the EQ (or the speaker EQ) on or off also re-evaluates the
    // preamp term of the input gain, which counts only while one of them runs.
    void setEqEnabled(bool enabled);
    bool isEqEnabled() const                { return eqEnabled_.load(); }

    // Preamp, clamped to +-24 dB. Plain gain — no auto-gain compensation. It
    // is applied only while the EQ or the speaker EQ is on (so not when the
    // EQ is bypassed for system-wide mode, where the platform EQ applies it).
    void setPreampGain(float dB);
    // Preamp of the active speaker/headphone correction profile, clamped to
    // +-24 dB. Added to the input gain only while the speaker EQ is on.
    void setSpeakerPreampDb(float dB);
    // Headroom trim, -10..0 dB, summed into the input gain.
    void setHeadroomDb(float dB);
    // Per-track (replay) gain, -30..+24 dB, summed into the input gain. Set
    // per engine, i.e. per player.
    void setTrackGainDb(float dB);
    // Master volume, -30..0 dB; -30 is silence (gain exactly 0).
    void setMasterVolumeDb(float dB);
    void setMono(bool on)                   { mono_.set(on); }
    // Balance -1..1; negative attenuates the right channel, positive the left.
    void setBalance(float b)                { balance_.set(std::clamp(b, -1.0f, 1.0f)); }
    void setGraphicBandGain(int band, float dB);
    void setGraphicAllBands(const float* gains, int count);
    void setParametricBand(int band, float freq, float gainDb, float q,
                           int filterType, bool enabled);
    void setParametricAllBands(const float* freqs, const float* gains,
                               const float* qs, int count);

    // Speaker correction EQ (AutoEq headphone profiles)
    void setSpeakerEqEnabled(bool enabled);
    bool isSpeakerEqEnabled() const         { return speakerEqEnabled_.load(); }
    void setSpeakerEqBand(int band, float freq, float gainDb, float q,
                          int filterType, bool enabled);
    void clearSpeakerEq();

    // Tone controls (independent bass/treble knobs)
    void setToneEnabled(bool enabled)       { tone_.setEnabled(enabled); }
    bool isToneEnabled() const              { return tone_.isEnabled(); }

    void setBassGain(float dB)              { tone_.setBassGain(dB); }
    void setBassFreq(float hz)              { tone_.setBassFreq(hz); }
    void setBassQ(float q)                  { tone_.setBassQ(q); }
    void setTrebleGain(float dB)            { tone_.setTrebleGain(dB); }
    void setTrebleFreq(float hz)            { tone_.setTrebleFreq(hz); }
    void setTrebleQ(float q)                { tone_.setTrebleQ(q); }

    // Output limiter controls
    void setLimiterEnabled(bool enabled)    { limiter_.setEnabled(enabled); }
    bool isLimiterEnabled() const           { return limiter_.isEnabled(); }

    // Current limiter gain, 1.0 when not limiting (for Audio Info).
    float limiterGain() const               { return limiter_.gain(); }

    // The limiter has a fixed ceiling (1.0) and fixed slopes; these remain
    // only so the platform bridges that still call them keep compiling.
    void setLimiterCeiling(float)           {}
    void setLimiterRelease(float)           {}
    void setLimiterKnee(float)              {}

    // MBC controls
    void setMbcEnabled(bool enabled)        { mbc_.setEnabled(enabled); }
    bool isMbcEnabled() const               { return mbc_.isEnabled(); }

    void setMbcPreGain(float dB)            { mbc_.setAllPreGains(dB); }
    void setMbcNoiseGateThreshold(float dB) { mbc_.setAllNoiseGateThresholds(dB); }
    void setMbcKneeWidth(float dB)          { mbc_.setAllKneeWidths(dB); }
    void setMbcExpanderRatio(float r)       { mbc_.setAllExpanderRatios(r); }
    void setMbcThreshold(float dB)          { mbc_.setAllThresholds(dB); }
    void setMbcRatio(float r)               { mbc_.setAllRatios(r); }
    void setMbcAttackTime(float ms)         { mbc_.setAllAttackTimes(ms); }
    void setMbcReleaseTime(float ms)        { mbc_.setAllReleaseTimes(ms); }
    void setMbcPostGain(float dB)           { mbc_.setAllPostGains(dB); }

    // Reverb controls
    void setReverbEnabled(bool enabled)     { reverbEnabled_.store(enabled); }
    void setRoomSize(float v)               { reverb_.setRoomSize(v); }
    void setDecay(float v)                  { reverb_.setDecay(v); }
    void setDamping(float v)                { reverb_.setDamping(v); }
    void setPreDelay(float ms)              { reverb_.setPreDelay(ms); }
    void setDiffusion(float v)              { reverb_.setDiffusion(v); }
    void setReverbWetDry(float v)           { reverb_.setWetDry(v); }

    // Stereo Expand: amount 0..1, shown as 0–100 %. There is no separate on
    // switch — it is on whenever the amount is above zero, and exactly
    // bypassed at zero. See stereo_expander.h.
    void setStereoExpand(float amount)      { stereoExpander_.setAmount(amount); }

    // Crossfeed controls
    void setCrossfeedEnabled(bool enabled)  { crossfeedEnabled_.store(enabled); }
    void setCrossfeedParams(float cutoffHz, float feedLevelDb) {
        crossfeed_.configure(cutoffHz, feedLevelDb);
    }

    // 3D Surround controls — a port of the desktop stage (see surround3d.h).
    // Placed after Crossfeed for the same reason desktop places it after the
    // Spatializer: it renders a whole virtual speaker ring, so anything that
    // merely crossfeeds the stereo pair belongs upstream of it. Stereo Expand
    // is the exception by design: it widens the finished mix — reverb and
    // all — after master volume.
    void setSurround3dEnabled(bool enabled) {
        surround3dEnabled_.store(enabled);
        surround3d_.setEnabled(enabled);
    }
    void setSurround3dIntensity(float v)    { surround3d_.setIntensity(v); }
    void setSurround3dSubwoofer(float v)    { surround3d_.setSubwoofer(v); }
    void setSurround3dSpeakers(bool frontL, bool frontR, bool sideL,
                               bool sideR, bool surroundL, bool surroundR) {
        hype::SurroundSpeakers sp;
        sp.frontL = frontL;   sp.frontR = frontR;
        sp.sideL = sideL;     sp.sideR = sideR;
        sp.surroundL = surroundL; sp.surroundR = surroundR;
        surround3d_.setSpeakers(sp);
    }
    bool isSurround3dEnabled() const        { return surround3dEnabled_.load(); }

    bool isReverbEnabled() const            { return reverbEnabled_.load(); }
    bool isStereoExpandEnabled() const      { return stereoExpander_.engaged(); }
    bool isCrossfeedEnabled() const         { return crossfeedEnabled_.load(); }

    // Live stems: this player's tap into the shared stem engine.
    hype::stems::StemTap& stemTap()         { return stemTap_; }

private:

    // EQ
    ParametricEQ graphicEq_;
    ParametricEQ parametricEq_;
    std::atomic<bool> eqEnabled_{false};

    // Speaker correction EQ (independent from user EQ)
    ParametricEQ speakerEq_;
    std::atomic<bool> speakerEqEnabled_{false};

    // Tone controls (bass/treble shelf filters)
    ToneControls tone_;

    // Input gain = track gain + headroom, plus preamp while the EQ is on and
    // speaker preamp while the speaker EQ is on, through one gliding stage.
    void updateInputGain();
    float trackGainDb_ = 0.0f;
    float preampGainDb_ = 0.0f;
    float speakerPreampDb_ = 0.0f;
    float headroomDb_ = 0.0f;
    GainStage inputGain_;

    // Output-side stages
    GainStage masterVolume_;
    MonoStage mono_;
    BalanceStage balance_;

    // Output limiter
    OutputLimiter limiter_;

    // Multi-band compressor
    MultibandCompressor mbc_;

    // Spatial effects
    FDNReverb reverb_;
    StereoExpander stereoExpander_;
    Crossfeed crossfeed_;
    hype::Surround3D surround3d_;

    std::atomic<bool> reverbEnabled_{false};
    std::atomic<bool> crossfeedEnabled_{false};
    std::atomic<bool> surround3dEnabled_{false};

    int sampleRate_;
    int channels_;

    // Live stems — swaps in separated audio while a stem level is changed.
    hype::stems::StemTap stemTap_;
};
