#pragma once
#include <algorithm>
#include <atomic>
#include <cmath>

// Small output-side stages of the chain: a gliding gain (input gain and master
// volume), mono, and balance. Kept byte-identical in android/app/src/main/cpp
// and ios/HypeDSP/src.
//
// Every gain here moves toward its target at a fixed slope of 1/256 of full
// scale per frame, so a slider being dragged does not click. Targets are
// written from the control thread and read on the audio thread, hence the
// atomics; the current values belong to the audio thread alone.

namespace hype_stage {

constexpr float kGlideStep = 1.0f / 256.0f;

inline float glideToward(float current, float target) {
    if (current < target) return std::min(current + kGlideStep, target);
    if (current > target) return std::max(current - kGlideStep, target);
    return current;
}

}  // namespace hype_stage

// One gain applied to both channels.
class GainStage {
public:
    // Sets the gain in dB. With [muteAtFloor], -30 dB or below is silence
    // (gain exactly 0), as for a volume control; otherwise it is just -30 dB.
    void setDb(float dB, bool muteAtFloor = false) {
        const float t = (muteAtFloor && dB <= -30.0f)
                            ? 0.0f
                            : std::pow(10.0f, dB / 20.0f);
        target_.store(t, std::memory_order_relaxed);
    }

    // Whether [process] has anything to do: the gain is not unity, or it is
    // still gliding back to it. At unity the stage is skipped (bit-exact).
    // A stage found idle drops a pending reset-snap: it has nothing to snap
    // to, and a later change from the user must glide.
    bool active() {
        if (target_.load(std::memory_order_relaxed) != 1.0f || current_ != 1.0f) return true;
        snap_.store(false, std::memory_order_relaxed);
        return false;
    }

    float gain() const { return current_; }

    void process(float* l, float* r, int n) {
        const float t = target_.load(std::memory_order_relaxed);
        if (snap_.exchange(false, std::memory_order_relaxed)) current_ = t;
        for (int i = 0; i < n; i++) {
            current_ = hype_stage::glideToward(current_, t);
            l[i] *= current_;
            r[i] *= current_;
        }
    }

    // Jumps straight to the target — for a stream that is starting fresh. The
    // targets are often (re)written right after a reset, so the next
    // [process] snaps to the target as it then stands rather than gliding
    // from the old value.
    void reset() {
        current_ = target_.load(std::memory_order_relaxed);
        snap_.store(true, std::memory_order_relaxed);
    }

private:
    std::atomic<float> target_{1.0f};
    std::atomic<bool> snap_{false};
    float current_ = 1.0f;
};

// Sums to mono: L = R = (L + R) / 2 while on. Switching crossfades between
// stereo and mono over 256 frames, so the toggle does not click.
class MonoStage {
public:
    void set(bool on) { on_.store(on, std::memory_order_relaxed); }
    bool active() const { return on_.load(std::memory_order_relaxed) || mix_ != 0.0f; }

    void process(float* l, float* r, int n) {
        const float t = on_.load(std::memory_order_relaxed) ? 1.0f : 0.0f;
        for (int i = 0; i < n; i++) {
            mix_ = hype_stage::glideToward(mix_, t);
            const float m = (l[i] + r[i]) * 0.5f;
            l[i] += (m - l[i]) * mix_;
            r[i] += (m - r[i]) * mix_;
        }
    }

private:
    std::atomic<bool> on_{false};
    float mix_ = 0.0f;  // 0 = stereo, 1 = mono; audio thread only
};

// Balance in -1..1. Negative attenuates the right channel, positive the left,
// by 48 dB at full tilt scaled linearly in dB; at exactly +-1 the far channel
// is silent (gain 0).
class BalanceStage {
public:
    void set(float b) {
        b = std::clamp(b, -1.0f, 1.0f);
        const float a = std::fabs(b);
        const float far = (a >= 1.0f) ? 0.0f : std::pow(10.0f, -48.0f * a / 20.0f);
        targetL_.store(b > 0.0f ? far : 1.0f, std::memory_order_relaxed);
        targetR_.store(b < 0.0f ? far : 1.0f, std::memory_order_relaxed);
    }

    bool active() {
        if (targetL_.load(std::memory_order_relaxed) != 1.0f ||
            targetR_.load(std::memory_order_relaxed) != 1.0f ||
            curL_ != 1.0f || curR_ != 1.0f) {
            return true;
        }
        snap_.store(false, std::memory_order_relaxed);
        return false;
    }

    void process(float* l, float* r, int n) {
        const float tl = targetL_.load(std::memory_order_relaxed);
        const float tr = targetR_.load(std::memory_order_relaxed);
        if (snap_.exchange(false, std::memory_order_relaxed)) {
            curL_ = tl;
            curR_ = tr;
        }
        for (int i = 0; i < n; i++) {
            curL_ = hype_stage::glideToward(curL_, tl);
            curR_ = hype_stage::glideToward(curR_, tr);
            l[i] *= curL_;
            r[i] *= curR_;
        }
    }

    // As [GainStage::reset]: the next [process] snaps to the targets.
    void reset() {
        curL_ = targetL_.load(std::memory_order_relaxed);
        curR_ = targetR_.load(std::memory_order_relaxed);
        snap_.store(true, std::memory_order_relaxed);
    }

private:
    std::atomic<float> targetL_{1.0f};
    std::atomic<float> targetR_{1.0f};
    std::atomic<bool> snap_{false};
    float curL_ = 1.0f;
    float curR_ = 1.0f;
};
