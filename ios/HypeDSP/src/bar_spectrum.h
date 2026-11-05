#pragma once
#include <cmath>
#include <cstdint>

/// Bar spectrum — the 256-value power spectrum the built-in visualizers draw.
///
/// One call turns a block of mono audio into 256 powers:
///
///   1. Decimate: each of the 512 block samples is the plain average of
///      `decim` consecutive input samples, so high-rate audio is analysed
///      over the same ~11 ms span as 44.1/48 kHz audio. See [decimation].
///   2. Window: w[n] = 0.5 − 0.5·cos(2πn / 511), n = 0..511 (symmetric Hann).
///   3. Transform: an unscaled forward DFT of the 512 windowed samples
///      (iterative radix-2, no 1/N anywhere). A full-scale sine centred on a
///      bin therefore peaks at (255.5 / 2)² ≈ 16320, about 42 dB.
///   4. Power: out[j] = re² + im² of bin j + 1 (bins 1..256; bin 256 is
///      Nyquist and purely real), plus [kFloor] so a log of the result is
///      always finite. Digital silence comes out as exactly [kFloor].
///
/// Dart turns the powers into dB and bar heights; this header only produces
/// the numbers, so both platforms feed it identical blocks and get identical
/// bars.
///
/// Header-only, no allocation after construction, no external libraries.
/// Kept identical to its twin in ios/HypeDSP/src. A single instance is not
/// thread-safe (compute() uses member scratch); give each caller its own.
class BarSpectrum {
public:
    static constexpr int kBlock = 512;          // samples per analysis block (after decimation)
    static constexpr int kBins = 256;           // output powers, FFT bins 1..256
    static constexpr int kMaxDecimation = 8;
    static constexpr float kFloor = 1.5849e-13f;

    /// Decimation factor for a sample rate: 1 below 88.2 kHz, otherwise the
    /// rate's multiple of 48 kHz (or else of 44.1 kHz), clamped to 1..8.
    static int decimation(int sampleRate) {
        if (sampleRate < 88200) return 1;
        const int d = (sampleRate % 48000 == 0) ? sampleRate / 48000
                                                : sampleRate / 44100;
        return d < 1 ? 1 : (d > kMaxDecimation ? kMaxDecimation : d);
    }

    BarSpectrum() {
        const double pi = 3.14159265358979323846;
        for (int n = 0; n < kBlock; n++)
            window_[n] = (float)(0.5 - 0.5 * std::cos(2.0 * pi * n / (kBlock - 1)));
        for (int k = 0; k < kBlock / 2; k++) {
            cos_[k] = (float)std::cos(2.0 * pi * k / kBlock);
            sin_[k] = (float)-std::sin(2.0 * pi * k / kBlock);  // e^(-i·2πk/N)
        }
        int bits = 0;
        while ((1 << bits) < kBlock) bits++;
        for (int i = 0; i < kBlock; i++) {
            int r = 0;
            for (int b = 0; b < bits; b++)
                if (i & (1 << b)) r |= 1 << (bits - 1 - b);
            rev_[i] = (uint16_t)r;
        }
    }

    /// `mono`: kBlock * decim samples, oldest first. `out`: kBins powers.
    /// `decim` is clamped to 1..kMaxDecimation.
    void compute(const float* mono, int decim, float* out) {
        if (decim < 1) decim = 1;
        if (decim > kMaxDecimation) decim = kMaxDecimation;
        for (int n = 0; n < kBlock; n++) {
            float sum = 0.0f;
            const float* p = mono + n * decim;
            for (int k = 0; k < decim; k++) sum += p[k];
            const float v = (decim == 1 ? sum : sum / (float)decim) * window_[n];
            const int r = rev_[n];
            re_[r] = v;
            im_[r] = 0.0f;
        }
        for (int len = 2; len <= kBlock; len <<= 1) {
            const int half = len >> 1;
            const int step = kBlock / len;
            for (int i = 0; i < kBlock; i += len) {
                for (int j = 0; j < half; j++) {
                    const float wr = cos_[j * step], wi = sin_[j * step];
                    const int a = i + j, b = a + half;
                    const float tr = re_[b] * wr - im_[b] * wi;
                    const float ti = re_[b] * wi + im_[b] * wr;
                    re_[b] = re_[a] - tr;
                    im_[b] = im_[a] - ti;
                    re_[a] += tr;
                    im_[a] += ti;
                }
            }
        }
        for (int j = 0; j < kBins; j++) {
            const float r = re_[j + 1], i = im_[j + 1];
            out[j] = r * r + i * i + kFloor;
        }
    }

private:
    float window_[kBlock];
    float cos_[kBlock / 2];
    float sin_[kBlock / 2];
    uint16_t rev_[kBlock];
    float re_[kBlock];
    float im_[kBlock];
};
