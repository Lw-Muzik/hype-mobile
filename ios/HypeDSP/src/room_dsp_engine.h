#pragma once
#include "parametric_eq.h"
#include "graphic_eq.h"
#include "multiband_compressor.h"
#include "tone_controls.h"
#include "smooth_gains.h"
#include "limiter.h"
#include "output_stages.h"
#include "fdn_reverb.h"
#include "stereo_expander.h"
#include "crossfeed.h"
#include "surround3d.h"
#include <algorithm>
#include <atomic>
#include <mutex>

// Main DSP engine orchestrator — professional-grade signal chain.
//
// Processing chain:
//   [Level: track gain + headroom] -> [Speaker preamp] -> [Speaker Correction EQ]
//   -> [Graphic EQ 1-32 bands, any centres] -> [Parametric EQ 32-band]
//   -> [Tone Controls]
//   -> [MBC 10-band] -> [Crossfeed] -> [3D Surround] -> [FDN Reverb]
//   -> [Master volume] -> [Stereo Expand] -> [Mono] -> [Balance]
//   -> [Output Limiter] -> final clamp -> Output
//
// Key design decisions:
//   - No auto-gain: the level is exactly track gain + headroom (+ the preamp,
//     in its own stage after the EQ, while an EQ is on, + the speaker preamp
//     while the speaker EQ is on); EQ and tone setters never touch it. Each
//     stage is skipped (bit-exact) while at its neutral setting.
//   - Input gain, master volume and balance glide at a fixed slope, so a
//     slider being dragged does not click (see output_stages.h).
//   - Master volume sits after the effects and ahead of Stereo Expand, mono
//     and balance, which are spatial finishing touches on the final level.
//   - The limiter is last and runs only when the user turns it on (no
//     look-ahead; the final hard clamp backstops the first samples of a peak).
//   - Smooth gains (optional): the graphic EQ and the tone shelves play their
//     stored gains scaled by the playback level, so a boost cannot push the
//     output past full scale (see smooth_gains.h). The scales are worked out
//     here, when a setting changes, never per block.
//   - Turning the EQ off or on is a faded transition, not a switch: see
//     setEqEnabled.
//   - Platform equalizer mode (Android system-wide EQ): the platform applies
//     the graphic EQ, tone, preamp and headroom to the whole mix, Hype's own
//     playback included, so here those stages (and track gain, balance, mono
//     and stereo expand, whose controls are disabled then) run neutral - each
//     faded out and back, never skipped. The parametric EQ, speaker EQ and its
//     preamp, MBC, spatial effects, master volume and limiter are unchanged.
//     See setPlatformEqActive.
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
    // The EQ does not switch. Turning it off blends the graphic and parametric
    // EQ out against the dry signal over the fade length (one cycle of the
    // lowest band that is doing something, 96..2400 frames) and only then
    // bypasses; turning it on restarts their filters clean and blends them in.
    // The preamp (which counts only while an EQ is on) follows the same blend,
    // so the level does not jump or overshoot.
    void setEqEnabled(bool enabled);
    bool isEqEnabled() const                { return eqEnabled_.load(); }

    // Platform equalizer mode (Android system-wide EQ). While on, the stages
    // the platform equalizer applies to the whole mix run neutral so nothing is
    // applied twice: the graphic EQ, tone, the user preamp, headroom, track
    // gain, balance, mono and stereo expand. Unchanged: the speaker EQ and its
    // preamp, parametric EQ, MBC, crossfeed, surround, reverb, master volume
    // and limiter. The stored values are kept and come back when the flag goes
    // off. Nothing switches: the graphic EQ and the user preamp share one
    // blend weight that moves over the same fade length as the EQ toggle, tone
    // goes through its own faded enable, and the gain stages glide.
    void setPlatformEqActive(bool on);
    bool platformEqActive() const           { return platformEq_.load(); }

    // Preamp, clamped to +-24 dB. Plain gain — no auto-gain compensation. It
    // is applied only while the EQ or the speaker EQ is on (so not when the
    // EQ is bypassed for system-wide mode, where the platform EQ applies it).
    // It has its own gain, just after the graphic EQ, which fades it in and out
    // with the EQ (see setEqEnabled).
    void setPreampGain(float dB);
    // Preamp of the active speaker/headphone correction profile, clamped to
    // +-24 dB. Added to the input gain only while the speaker EQ is on.
    void setSpeakerPreampDb(float dB);
    // Headroom trim, -10..0 dB, summed into the input gain.
    void setHeadroomDb(float dB);
    // Per-track (replay) gain, -30..+24 dB, summed into the input gain. Set
    // per engine, i.e. per player. Lock-free: it is also called from the
    // render thread (at a gapless boundary the iOS tap applies the next item's
    // gain), so it must never take levelMutex_ or any other lock.
    void setTrackGainDb(float dB);
    // Master volume, -30..0 dB; -30 is silence (gain exactly 0).
    void setMasterVolumeDb(float dB);
    // Smooth equalizer/tone gains on or off. Off until the app sends it.
    void setSmoothGains(bool on);
    // The volume the platform applies after this engine (Android stream
    // volume, iOS output volume), in dB, -96..0; 0 by default and while Hype's
    // own master volume owns the level. Used only to scale the smooth gains.
    void setSystemVolumeDb(float dB);
    // T, the level the smooth gains follow: the preamp (while it is applied,
    // i.e. the EQ or the speaker EQ is on) + master volume + system volume +
    // headroom, in dB. Control thread.
    float smoothLevelDb() const;
    // The scales in force for the current level and setting (smooth_gains.h).
    SmoothScales smoothScales() const;
    // Mono, balance and stereo expand always hold what was asked for; platform
    // mode blends their combined output against its input (see
    // processOutputStages) rather than moving the settings.
    void setMono(bool on)                   { mono_.set(on); }
    // Balance -1..1; negative attenuates the right channel, positive the left.
    void setBalance(float b)                { balance_.set(std::clamp(b, -1.0f, 1.0f)); }
    // Graphic EQ. The layout is 1-32 centre frequencies; until one is sent it
    // is the legacy 32-band 1/3-octave grid. Gains are nominal dB (+-15), kept
    // by index across layout changes. init() and reset() keep layout and gains.
    // `gainsDb` (count values, optional) replaces all band gains in the same
    // call, so the curve and the centres change together.
    void setGraphicLayout(const float* centresHz, int count,
                          const float* gainsDb = nullptr);
    int graphicBandCount() const            { return graphicEq_.bandCount(); }
    float graphicCentreHz(int band) const   { return graphicEq_.centreHz(band); }
    // The gain a band plays at: the stored gain x the smooth-gains factor (1
    // with smoothing off).
    float graphicEffectiveGainDb(int band) const {
        return graphicEq_.effectiveGainDb(band);
    }
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
    // The setting; in platform mode the shelves are held off (faded) while
    // this stays as asked for.
    void setToneEnabled(bool enabled);
    bool isToneEnabled() const              { return toneWanted_.load(); }

    void setBassGain(float dB)              { tone_.setBassGain(dB); }
    void setBassFreq(float hz)              { tone_.setBassFreq(hz); }
    void setBassQ(float q)                  { tone_.setBassQ(q); }
    void setTrebleGain(float dB)            { tone_.setTrebleGain(dB); }
    void setTrebleFreq(float hz)            { tone_.setTrebleFreq(hz); }
    void setTrebleQ(float q)                { tone_.setTrebleQ(q); }
    // Stored (fixed-scale) and applied (smoothed) gains, in dB.
    float toneBassGainDb() const            { return tone_.getBassGain(); }
    float toneTrebleGainDb() const          { return tone_.getTrebleGain(); }
    float toneEffectiveBassGainDb() const   { return tone_.effectiveBassGainDb(); }
    float toneEffectiveTrebleGainDb() const { return tone_.effectiveTrebleGainDb(); }

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

private:
    // EQ
    GraphicEQ graphicEq_;
    ParametricEQ parametricEq_;
    std::atomic<bool> eqEnabled_{false};

    // Speaker correction EQ (independent from user EQ)
    ParametricEQ speakerEq_;
    std::atomic<bool> speakerEqEnabled_{false};

    // Tone controls (bass/treble shelf filters)
    ToneControls tone_;

    // Recomputes T and hands the scales to the graphic EQ (factor eqDb / 15)
    // and to the tone shelves (bassDb / 22.5 and eqDb / 15). Runs from the
    // setters that move T or the smooth setting; never per block.
    void updateSmoothScales();
    float levelDbLocked() const;  // T; the caller holds levelMutex_
    // Serialises the level setters (which are called from more than one
    // thread: the UI thread and whatever replays settings onto a new engine),
    // so each recomputes from a consistent set of values. Control side only.
    mutable std::mutex levelMutex_;
    float masterVolumeDb_ = 0.0f;
    float systemVolumeDb_ = 0.0f;
    bool smoothGains_ = false;

    // The EQ stage (audio thread): the graphic and parametric EQ blended
    // against the dry signal by eqMix_, then the preamp. See setEqEnabled.
    // `pm` holds the platform weight for each of the numFrames samples.
    void processEqStage(float* left, float* right, const float* pm, int numFrames,
                        bool eqOn, bool speakerOn);
    int eqFadeFrames() const;
    void resetEqStage();
    float eqMix_ = 0.0f;         // 0 = EQ out of the chain, 1 = fully in
    // Platform mode: 0 = Hype's own graphic EQ, user preamp, headroom and
    // track gain are in, 1 = fully handed over to the platform. One weight,
    // advanced once per block (fillPlatformMix) and read per sample by the
    // level stage and the EQ stage, so everything handed over leaves together.
    float platformMix_ = 0.0f;
    float platformStep_ = 1.0f / 96.0f;
    bool platformLastOn_ = false;
    void fillPlatformMix(float* pm, int numFrames, bool platformOn);
    // Set by init()/reset(): the next block takes the platform state at once
    // (a new stream has nothing to fade, and the flag is replayed after init).
    std::atomic<bool> platformSnap_{false};
    // Expand -> mono -> balance, each only if `do*`, blended out against the
    // chain's input by pm (per sample) so a platform hand-over never goes
    // through the sliders' own glides.
    void processOutputStages(float* left, float* right, const float* pm,
                             int numFrames, bool doExpand, bool doMono,
                             bool doBalance);
    // The graphic EQ was not run (handed over): its filters hold old state and
    // restart clean before they are blended back in.
    bool graphicStale_ = false;
    float eqStep_ = 1.0f / 96.0f;  // per-frame move of eqMix_ toward its target
    bool eqLastOn_ = false;
    float speakerGate_ = 0.0f;   // the speaker EQ's share of the preamp term
    // The preamp, as the reciprocal of its gain R = 1/P (so that a blend of two
    // preamps is a plain linear blend of their R, the form the net level
    // stays steady in beside a linear EQ blend). preR_ is the current value; it
    // moves from preRFrom_ to preRTo_ as preM_ goes 0..1 by preStep_ per frame.
    float preR_ = 1.0f, preRFrom_ = 1.0f, preRTo_ = 1.0f;
    float preM_ = 1.0f, preStep_ = 1.0f;
    std::atomic<float> preampTarget_{1.0f};

    // Platform mode, and the tone setting it holds off. The setters are
    // serialised by platformMutex_ so the setting and the flag never cross.
    // Control side only.
    std::atomic<bool> platformEq_{false};
    std::mutex platformMutex_;
    std::atomic<bool> toneWanted_{false};

    // Level stage = track gain + headroom, gliding at the same slope as the
    // other gain stages; in platform mode it fades to unity with platformMix_.
    // The input gain stage carries the speaker preamp while the speaker EQ is
    // on. (The user preamp has its own stage, after the EQ.)
    void updateInputGain();
    void processLevel(float* left, float* right, const float* pm, int numFrames);
    bool levelActive();
    std::atomic<float> levelTarget_{1.0f};  // linear; written from any thread
    std::atomic<bool> levelSnap_{false};
    float levelCur_ = 1.0f;                 // audio thread only
    // Written from the control thread, read on the audio thread (and by a
    // tap applying a gapless boundary gain), so atomic.
    std::atomic<float> trackGainDb_{0.0f};
    float preampGainDb_ = 0.0f;
    // Atomic: updateInputGain() reads them from the render thread too (see
    // setTrackGainDb).
    std::atomic<float> speakerPreampDb_{0.0f};
    std::atomic<float> headroomDb_{0.0f};
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

};
