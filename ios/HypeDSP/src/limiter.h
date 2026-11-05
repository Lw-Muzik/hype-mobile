#pragma once
#include <algorithm>
#include <atomic>
#include <cmath>

// Stereo output limiter. Placed at the end of the DSP chain to catch peaks.
//
// No look-ahead, ceiling 1.0. Per frame the stereo-linked peak is compared
// with the ceiling: above it the target gain drops to ceiling/peak (never
// rising), otherwise the target creeps back toward 1 at the release slope.
// The applied gain follows the target at a fixed slope each way: down by
// 2^-8 per frame (attack), up by 2^-14 per frame (release), both scaled by
// 48000/fs so the times are the same at any sample rate. A full recovery
// from silence-level gain therefore takes 2^14 frames, ~341 ms at 48 kHz.
// Because the attack is a slope and there is no look-ahead, the first ~256
// frames (~5.3 ms at 48 kHz) of a hard transient exceed the ceiling inside
// the limiter and are hard-clipped by the engine's final clamp. This is the
// intended design, not a bug.
class OutputLimiter {
public:
    OutputLimiter() { reset(); }

    void init(int sampleRate) {
        const float scale = sampleRate > 0 ? 48000.0f / (float)sampleRate : 1.0f;
        att_ = kAttack * scale;
        rel_ = kRelease * scale;
        reset();
    }

    void reset() {
        target_ = 1.0f;
        gain_ = 1.0f;
        reductionDb_.store(0.0f, std::memory_order_relaxed);
    }

    // Turning the limiter on after it was off starts it from unity gain: the
    // reduction it had when it was switched off is stale. The reset is done
    // by the audio thread, on its next [process].
    void setEnabled(bool enabled) {
        if (enabled) {
            if (!enabled_.exchange(true, std::memory_order_relaxed)) {
                resetPending_.store(true, std::memory_order_relaxed);
            }
        } else {
            enabled_.store(false, std::memory_order_relaxed);
        }
    }
    bool isEnabled() const { return enabled_.load(std::memory_order_relaxed); }

    // Current applied gain, 1.0 when not limiting.
    float gain() const { return gain_; }

    // Gain reduction in dB (>= 0), published once per block by the audio
    // thread and read lock-free from control threads.
    float reductionDb() const { return reductionDb_.load(std::memory_order_relaxed); }

    void process(float* left, float* right, int numFrames) {
        if (resetPending_.exchange(false, std::memory_order_relaxed)) {
            target_ = 1.0f;
            gain_ = 1.0f;
            reductionDb_.store(0.0f, std::memory_order_relaxed);
        }
        for (int i = 0; i < numFrames; i++) {
            const float peak = std::max(std::fabs(left[i]), std::fabs(right[i]));
            if (peak > kCeiling) {
                target_ = std::min(target_, kCeiling / peak);
            } else {
                target_ = std::min(1.0f, target_ + rel_);
            }
            if (gain_ > target_) {
                gain_ = std::max(target_, gain_ - att_);
            } else if (gain_ < target_) {
                gain_ = std::min(target_, gain_ + rel_);
            }
            if (gain_ != 1.0f) {
                left[i] *= gain_;
                right[i] *= gain_;
            }
        }
        reductionDb_.store(gain_ < 1.0f ? -20.0f * std::log10(gain_) : 0.0f,
                           std::memory_order_relaxed);
    }

private:
    static constexpr float kCeiling = 1.0f;
    static constexpr float kAttack = 1.0f / 256.0f;     // 2^-8
    static constexpr float kRelease = 1.0f / 16384.0f;  // 2^-14

    std::atomic<bool> enabled_{false};
    std::atomic<bool> resetPending_{false};
    std::atomic<float> reductionDb_{0.0f};
    float att_ = kAttack;
    float rel_ = kRelease;
    float target_ = 1.0f;
    float gain_ = 1.0f;
};
