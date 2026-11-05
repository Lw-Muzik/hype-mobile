#pragma once
#include <cmath>
#include <cstring>

// Filter types from the Audio EQ Cookbook (Robert Bristow-Johnson)
enum class BiquadType {
    Peaking,
    LowShelf,
    HighShelf,
    LowPass,
    HighPass,
    Notch,
    BandPass
};

// Normalized biquad coefficients (a0 = 1.0)
struct BiquadCoeffs {
    float b0 = 1.0f, b1 = 0.0f, b2 = 0.0f;
    float a1 = 0.0f, a2 = 0.0f;

    static BiquadCoeffs bypass() { return {1.0f, 0.0f, 0.0f, 0.0f, 0.0f}; }
};

// Coefficient design from Audio EQ Cookbook (Robert Bristow-Johnson).
// All math computed in double precision for clean bass response — float32 trig
// loses precision at low frequencies where w0 is tiny. Coefficients are then
// narrowed to float for real-time DF2T processing (sufficient for ARM NEON).
struct BiquadDesign {
    static BiquadCoeffs peaking(float sampleRate, float freq, float gainDb, float Q) {
        if (Q < 0.01f) Q = 0.01f;
        double A = std::pow(10.0, (double)gainDb / 40.0);
        double w0 = 2.0 * M_PI * (double)freq / (double)sampleRate;
        double sinw = std::sin(w0);
        double cosw = std::cos(w0);
        double alpha = sinw / (2.0 * (double)Q);

        double a0 = 1.0 + alpha / A;
        double a0inv = 1.0 / a0;
        BiquadCoeffs c;
        c.b0 = (float)((1.0 + alpha * A) * a0inv);
        c.b1 = (float)((-2.0 * cosw) * a0inv);
        c.b2 = (float)((1.0 - alpha * A) * a0inv);
        c.a1 = (float)((-2.0 * cosw) * a0inv);
        c.a2 = (float)((1.0 - alpha / A) * a0inv);
        return c;
    }

    static BiquadCoeffs lowShelf(float sampleRate, float freq, float gainDb, float Q) {
        if (Q < 0.01f) Q = 0.01f;
        double A = std::pow(10.0, (double)gainDb / 40.0);
        double w0 = 2.0 * M_PI * (double)freq / (double)sampleRate;
        double sinw = std::sin(w0);
        double cosw = std::cos(w0);
        double alpha = sinw / (2.0 * (double)Q);
        double sqrtA2alpha = 2.0 * std::sqrt(A) * alpha;

        double a0 = (A + 1.0) + (A - 1.0) * cosw + sqrtA2alpha;
        double a0inv = 1.0 / a0;
        BiquadCoeffs c;
        c.b0 = (float)(A * ((A + 1.0) - (A - 1.0) * cosw + sqrtA2alpha) * a0inv);
        c.b1 = (float)(2.0 * A * ((A - 1.0) - (A + 1.0) * cosw) * a0inv);
        c.b2 = (float)(A * ((A + 1.0) - (A - 1.0) * cosw - sqrtA2alpha) * a0inv);
        c.a1 = (float)(-2.0 * ((A - 1.0) + (A + 1.0) * cosw) * a0inv);
        c.a2 = (float)(((A + 1.0) + (A - 1.0) * cosw - sqrtA2alpha) * a0inv);
        return c;
    }

    static BiquadCoeffs highShelf(float sampleRate, float freq, float gainDb, float Q) {
        if (Q < 0.01f) Q = 0.01f;
        double A = std::pow(10.0, (double)gainDb / 40.0);
        double w0 = 2.0 * M_PI * (double)freq / (double)sampleRate;
        double sinw = std::sin(w0);
        double cosw = std::cos(w0);
        double alpha = sinw / (2.0 * (double)Q);
        double sqrtA2alpha = 2.0 * std::sqrt(A) * alpha;

        double a0 = (A + 1.0) - (A - 1.0) * cosw + sqrtA2alpha;
        double a0inv = 1.0 / a0;
        BiquadCoeffs c;
        c.b0 = (float)(A * ((A + 1.0) + (A - 1.0) * cosw + sqrtA2alpha) * a0inv);
        c.b1 = (float)(-2.0 * A * ((A - 1.0) + (A + 1.0) * cosw) * a0inv);
        c.b2 = (float)(A * ((A + 1.0) + (A - 1.0) * cosw - sqrtA2alpha) * a0inv);
        c.a1 = (float)(2.0 * ((A - 1.0) - (A + 1.0) * cosw) * a0inv);
        c.a2 = (float)(((A + 1.0) - (A - 1.0) * cosw - sqrtA2alpha) * a0inv);
        return c;
    }

    static BiquadCoeffs lowPass(float sampleRate, float freq, float Q) {
        if (Q < 0.01f) Q = 0.01f;
        double w0 = 2.0 * M_PI * (double)freq / (double)sampleRate;
        double sinw = std::sin(w0);
        double cosw = std::cos(w0);
        double alpha = sinw / (2.0 * (double)Q);

        double a0 = 1.0 + alpha;
        double a0inv = 1.0 / a0;
        BiquadCoeffs c;
        c.b0 = (float)(((1.0 - cosw) / 2.0) * a0inv);
        c.b1 = (float)((1.0 - cosw) * a0inv);
        c.b2 = c.b0;
        c.a1 = (float)((-2.0 * cosw) * a0inv);
        c.a2 = (float)((1.0 - alpha) * a0inv);
        return c;
    }

    static BiquadCoeffs highPass(float sampleRate, float freq, float Q) {
        if (Q < 0.01f) Q = 0.01f;
        double w0 = 2.0 * M_PI * (double)freq / (double)sampleRate;
        double sinw = std::sin(w0);
        double cosw = std::cos(w0);
        double alpha = sinw / (2.0 * (double)Q);

        double a0 = 1.0 + alpha;
        double a0inv = 1.0 / a0;
        BiquadCoeffs c;
        c.b0 = (float)(((1.0 + cosw) / 2.0) * a0inv);
        c.b1 = (float)(-(1.0 + cosw) * a0inv);
        c.b2 = c.b0;
        c.a1 = (float)((-2.0 * cosw) * a0inv);
        c.a2 = (float)((1.0 - alpha) * a0inv);
        return c;
    }

    static BiquadCoeffs notch(float sampleRate, float freq, float Q) {
        if (Q < 0.01f) Q = 0.01f;
        double w0 = 2.0 * M_PI * (double)freq / (double)sampleRate;
        double sinw = std::sin(w0);
        double cosw = std::cos(w0);
        double alpha = sinw / (2.0 * (double)Q);

        double a0 = 1.0 + alpha;
        double a0inv = 1.0 / a0;
        BiquadCoeffs c;
        c.b0 = (float)(1.0 * a0inv);
        c.b1 = (float)((-2.0 * cosw) * a0inv);
        c.b2 = c.b0;
        c.a1 = c.b1;
        c.a2 = (float)((1.0 - alpha) * a0inv);
        return c;
    }

    static BiquadCoeffs bandPass(float sampleRate, float freq, float Q) {
        if (Q < 0.01f) Q = 0.01f;
        double w0 = 2.0 * M_PI * (double)freq / (double)sampleRate;
        double sinw = std::sin(w0);
        double cosw = std::cos(w0);
        double alpha = sinw / (2.0 * (double)Q);

        double a0 = 1.0 + alpha;
        double a0inv = 1.0 / a0;
        BiquadCoeffs c;
        c.b0 = (float)(alpha * a0inv);
        c.b1 = 0.0f;
        c.b2 = (float)(-alpha * a0inv);
        c.a1 = (float)((-2.0 * cosw) * a0inv);
        c.a2 = (float)((1.0 - alpha) * a0inv);
        return c;
    }

    static BiquadCoeffs compute(BiquadType type, float sampleRate, float freq,
                                 float gainDb, float Q) {
        switch (type) {
            case BiquadType::Peaking:   return peaking(sampleRate, freq, gainDb, Q);
            case BiquadType::LowShelf:  return lowShelf(sampleRate, freq, gainDb, Q);
            case BiquadType::HighShelf: return highShelf(sampleRate, freq, gainDb, Q);
            case BiquadType::LowPass:   return lowPass(sampleRate, freq, Q);
            case BiquadType::HighPass:  return highPass(sampleRate, freq, Q);
            case BiquadType::Notch:     return notch(sampleRate, freq, Q);
            case BiquadType::BandPass:  return bandPass(sampleRate, freq, Q);
            default:                    return BiquadCoeffs::bypass();
        }
    }
};

// Single stereo biquad filter — Direct Form II Transposed.
// Coefficient crossfade (~96 samples / ~2ms at 48kHz) to prevent clicks.
class Biquad {
public:
    // Length of the coefficient crossfade, in samples.
    static constexpr int FADE_LENGTH = 96;

    Biquad() { reset(); }

    void setCoefficients(const BiquadCoeffs& c) {
        if (!initialized_) {
            setCoefficientsImmediate(c);
            return;
        }
        target_ = c;
        fadeSamples_ = FADE_LENGTH;
        // Snapshot current coefficients as source for crossfade
        fadeFrom_ = current_;
    }

    void setCoefficientsImmediate(const BiquadCoeffs& c) {
        current_ = c;
        target_ = c;
        fadeSamples_ = 0;
        initialized_ = true;
    }

    // True while a coefficient crossfade is still running.
    bool fading() const { return fadeSamples_ > 0; }

    // Zero the delay states only; coefficients and any running fade stay.
    void clearState() {
        s1L_ = s1R_ = s2L_ = s2R_ = 0.0f;
    }

    void reset() {
        s1L_ = s1R_ = s2L_ = s2R_ = 0.0f;
        fadeSamples_ = 0;
        initialized_ = false;
        current_ = BiquadCoeffs::bypass();
        target_ = BiquadCoeffs::bypass();
    }

    void process(float* left, float* right, int numFrames) {
        for (int i = 0; i < numFrames; i++) {
            if (fadeSamples_ > 0) {
                // Crossfade coefficients
                float t = 1.0f - (float)fadeSamples_ / (float)FADE_LENGTH;
                BiquadCoeffs c;
                c.b0 = fadeFrom_.b0 + t * (target_.b0 - fadeFrom_.b0);
                c.b1 = fadeFrom_.b1 + t * (target_.b1 - fadeFrom_.b1);
                c.b2 = fadeFrom_.b2 + t * (target_.b2 - fadeFrom_.b2);
                c.a1 = fadeFrom_.a1 + t * (target_.a1 - fadeFrom_.a1);
                c.a2 = fadeFrom_.a2 + t * (target_.a2 - fadeFrom_.a2);
                current_ = c;
                fadeSamples_--;
                if (fadeSamples_ == 0) {
                    current_ = target_;
                }
            }

            // DF2T Left
            float xL = left[i];
            float yL = current_.b0 * xL + s1L_;
            s1L_ = current_.b1 * xL - current_.a1 * yL + s2L_;
            s2L_ = current_.b2 * xL - current_.a2 * yL;
            left[i] = yL;

            // DF2T Right
            float xR = right[i];
            float yR = current_.b0 * xR + s1R_;
            s1R_ = current_.b1 * xR - current_.a1 * yR + s2R_;
            s2R_ = current_.b2 * xR - current_.a2 * yR;
            right[i] = yR;
        }
    }

private:
    BiquadCoeffs current_;
    BiquadCoeffs target_;
    BiquadCoeffs fadeFrom_;
    int fadeSamples_ = 0;
    bool initialized_ = false;

    // DF2T delay states — independent L/R
    float s1L_ = 0.0f, s2L_ = 0.0f;
    float s1R_ = 0.0f, s2R_ = 0.0f;
};
