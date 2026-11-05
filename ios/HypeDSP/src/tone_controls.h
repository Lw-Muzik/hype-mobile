#pragma once
#include "biquad.h"
#include <atomic>
#include <algorithm>
#include <cmath>

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
class ToneControls {
public:
    ToneControls() = default;

    void init(float sampleRate) {
        sampleRate_ = sampleRate;
        bassFilter_.reset();
        trebleFilter_.reset();
        updateBass();
        updateTreble();
    }

    void reinit(float sampleRate) {
        sampleRate_ = sampleRate;
        bassFilter_.reset();
        trebleFilter_.reset();
        updateBass();
        updateTreble();
    }

    void reset() {
        bassFilter_.reset();
        trebleFilter_.reset();
    }

    // Bass controls
    void setBassGain(float dB) {
        bassGainDb_ = std::max(0.0f, std::min(25.0f, dB));
        updateBass();
    }
    void setBassFreq(float hz) {
        bassFreq_ = std::max(20.0f, std::min(500.0f, hz));
        updateBass();
    }
    void setBassQ(float q) {
        bassQ_ = std::max(0.1f, std::min(4.0f, q));
        updateBass();
    }
    float getBassGain() const { return bassGainDb_; }
    float getBassFreq() const { return bassFreq_; }
    float getBassQ() const { return bassQ_; }

    // Treble controls
    void setTrebleGain(float dB) {
        trebleGainDb_ = std::max(0.0f, std::min(20.0f, dB));
        updateTreble();
    }
    void setTrebleFreq(float hz) {
        trebleFreq_ = std::max(1000.0f, std::min(20000.0f, hz));
        updateTreble();
    }
    void setTrebleQ(float q) {
        trebleQ_ = std::max(0.1f, std::min(4.0f, q));
        updateTreble();
    }
    float getTrebleGain() const { return trebleGainDb_; }
    float getTrebleFreq() const { return trebleFreq_; }
    float getTrebleQ() const { return trebleQ_; }

    // Get the max boost from both tone controls (for auto-gain compensation)
    float getPeakGain() const {
        float peak = 0.0f;
        if (bassGainDb_ > peak) peak = bassGainDb_;
        if (trebleGainDb_ > peak) peak = trebleGainDb_;
        return peak;
    }

    void setEnabled(bool enabled) { enabled_.store(enabled); }
    bool isEnabled() const { return enabled_.load(); }

    void process(float* left, float* right, int numFrames) {
        if (!enabled_.load(std::memory_order_relaxed)) return;

        // Apply bass shelf (skip if near 0 dB)
        if (std::fabs(bassGainDb_) > 0.05f) {
            bassFilter_.process(left, right, numFrames);
        }
        // Apply treble shelf (skip if near 0 dB)
        if (std::fabs(trebleGainDb_) > 0.05f) {
            trebleFilter_.process(left, right, numFrames);
        }
    }

private:
    void updateBass() {
        if (sampleRate_ <= 0.0f) return;
        // if (std::fabs(bassGainDb_) < 0.05f) {
        //     bassFilter_.setCoefficients(BiquadCoeffs::bypass());
        // } else {
            bassFilter_.setCoefficients(
                BiquadDesign::lowShelf(sampleRate_, bassFreq_, bassGainDb_, bassQ_));
    //    }
    }

    void updateTreble() {
        if (sampleRate_ <= 0.0f) return;
        // if (std::fabs(trebleGainDb_) < 0.05f) {
        //     trebleFilter_.setCoefficients(BiquadCoeffs::bypass());
        // } else {
            trebleFilter_.setCoefficients(
                BiquadDesign::highShelf(sampleRate_, trebleFreq_, trebleGainDb_, trebleQ_));
        // }
    }

    float sampleRate_ = 48000.0f;
    std::atomic<bool> enabled_{false};

    // Bass defaults: 80 Hz, Butterworth Q (0.707), 0 dB
    float bassGainDb_ = 0.0f;
    float bassFreq_ = 80.0f;
    float bassQ_ = 0.707f;
    Biquad bassFilter_;

    // Treble defaults: 10 kHz, Butterworth Q (0.707), 0 dB
    float trebleGainDb_ = 0.0f;
    float trebleFreq_ = 10000.0f;
    float trebleQ_ = 0.707f;
    Biquad trebleFilter_;
};
