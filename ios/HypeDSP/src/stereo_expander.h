#pragma once
#include <algorithm>
#include <atomic>

/// Stereo Expand — widens the stereo image by raising the side signal and
/// leaving the mid exactly as it is.
///
///     m  = (L + R) / 2
///     L' = m + w · (L − m)
///     R' = m + w · (R − m)        w = 1 + 2 · amount
///
/// `amount` runs 0..1 (shown as 0–100 %), so the side gain runs 1..3 —
/// unchanged up to +9.5 dB. Written as a cross-mix that is
/// L' = (1+w)/2 · L + (1−w)/2 · R: at 100 % the output is 2L − R.
///
/// Deliberately plain:
/// * full band — no filters, no delay, no all-pass, nothing frequency
///   dependent; a mono signal (L = R) passes through untouched;
/// * no narrowing — the amount cannot go below 0;
/// * no loudness compensation — the image gets wider *and* the sides get
///   louder, and the output limiter that runs after this stage catches the
///   peaks;
/// * exactly bypassed at 0 — see [engaged].
///
/// Kept identical to its twin in ios/HypeDSP/src.
///
/// The amount is written from the control thread and read on the audio
/// thread, hence the atomic. A change glides to its new width at a fixed
/// slope — the full 1..3 sweep in [kGlideFrames] — so a slider being dragged
/// does not click; the width it settles on is exactly `1 + 2 · amount`.
class StereoExpander {
public:
    StereoExpander() { reset(); }

    /// Sets the amount, 0..1. Out-of-range values are clamped.
    void setAmount(float amount) {
        target_.store(1.0f + 2.0f * std::clamp(amount, 0.0f, 1.0f),
                      std::memory_order_relaxed);
    }

    /// The amount last set, 0..1.
    float amount() const {
        return (target_.load(std::memory_order_relaxed) - 1.0f) * 0.5f;
    }

    /// Whether an amount above zero is set. At zero the stage is skipped
    /// altogether, so a setting of 0 is bit-exact.
    bool engaged() const {
        return target_.load(std::memory_order_relaxed) > 1.0f;
    }

    /// Whether [process] has anything to do: an amount is set, or the width is
    /// still gliding back to neutral after being set to 0.
    bool active() const { return engaged() || width_ != 1.0f; }

    void process(float* left, float* right, int numFrames) {
        if (!active()) return;  // neutral: leave the samples bit-exact
        const float target = target_.load(std::memory_order_relaxed);
        constexpr float kMaxStep = 2.0f / static_cast<float>(kGlideFrames);
        for (int i = 0; i < numFrames; i++) {
            if (width_ < target) {
                width_ = std::min(width_ + kMaxStep, target);
            } else if (width_ > target) {
                width_ = std::max(width_ - kMaxStep, target);
            }
            const float l = left[i];
            const float r = right[i];
            const float mid = (l + r) * 0.5f;
            left[i]  = mid + width_ * (l - mid);
            right[i] = mid + width_ * (r - mid);
        }
    }

    /// Jumps straight to the target — for a stream that is starting fresh.
    void reset() { width_ = target_.load(std::memory_order_relaxed); }

private:
    /// The full 1..3 sweep takes this many frames: ~5 ms at 48 kHz.
    static constexpr int kGlideFrames = 256;

    std::atomic<float> target_{1.0f};
    float width_ = 1.0f;
};
