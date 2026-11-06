#pragma once
/**
 * fft_visualizer.h — Lock-free PCM capture + FFT for Flutter visualizer.
 *
 * Replaces Android's Visualizer API (which needs audio session ID) with a
 * custom pipeline that taps PCM directly from ExoPlayer's AudioProcessor.
 *
 * Architecture:
 *   Audio thread  →  ring buffer (SPSC, lock-free)
 *   Viz thread    →  reads ring buffer, applies Hann window, computes FFT,
 *                     maps to log-frequency bands, returns float[NUM_BANDS]
 *
 * FFT: in-place radix-2 Cooley-Tukey via the "pack two reals" trick.
 *       2048-point real FFT at 44.1kHz = 21.5 Hz resolution, 46ms window.
 *
 * Heard time: the tap sits upstream of the AudioTrack, so what it receives is
 * ~0.3 s from being heard (the track's buffer plus output latency; measured
 * 280-316 ms on a Lenovo tablet, more on Bluetooth). Every read here takes an
 * END index — the ring position being heard now, worked out from ExoPlayer's
 * playback clock in VisualizerTapProcessor — so the picture moves with the
 * sound instead of a quarter-second ahead of it. -1 means "newest", the old
 * behaviour, for when no clock is known.
 *
 * Beat frames (computeBeat): the energy below ~150 Hz in ~5.8 ms hops for the
 * stretch heard since the last call, plus 64 band levels in dBFS. The radial
 * visualizer finds bass hits in the hops (lib/visualizers/bass_beat.dart).
 *
 * Bar spectrum (computeSpectrum): the 256 powers the built-in bar visualizers
 * draw, from the 512 * D samples heard (see bar_spectrum.h).
 */

#include <cmath>
#include <cstdint>
#include <cstring>
#include <atomic>
#include <algorithm>

#include "bar_spectrum.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

class FFTVisualizer {
public:
    static constexpr int FFT_SIZE   = 2048;
    static constexpr int HALF_FFT   = FFT_SIZE / 2;
    static constexpr int NUM_BANDS  = 64;

    // Configurable parameters (set from Java/Dart)
    float attackRate  = 0.6f;   // How fast bands rise (0.1 = smooth, 0.9 = snappy)
    float decayRate   = 0.15f;  // How fast bands fall (0.05 = slow, 0.5 = fast)
    float gain        = 1.0f;   // Beat sensitivity / amplitude boost (0.5 = subtle, 3.0 = intense)

    FFTVisualizer() {
        // Pre-compute Hann window coefficients
        for (int i = 0; i < FFT_SIZE; i++) {
            window_[i] = 0.5f * (1.0f - cosf(2.0f * (float)M_PI * i / (FFT_SIZE - 1)));
        }

        // Pre-compute the real-FFT unpack twiddles (k = 1 .. HALF_FFT-1).
        // FFT_SIZE is a compile-time constant, so these never change frame to
        // frame. Same float expression as the original inline computation, so
        // the FFT output stays bit-identical — just without ~1000 cosf/sinf
        // calls per frame. Index 0 is unused (DC/Nyquist handled separately).
        unpackCos_[0] = 1.0f;
        unpackSin_[0] = 0.0f;
        for (int k = 1; k < HALF_FFT; k++) {
            float ang2 = -2.0f * (float)M_PI * k / FFT_SIZE;
            unpackCos_[k] = cosf(ang2);
            unpackSin_[k] = sinf(ang2);
        }

        computeBandEdges();
        designBassFilters();

        memset(ringBuf_, 0, sizeof(ringBuf_));
        memset(smoothBands_, 0, sizeof(smoothBands_));
    }

    // ── Audio thread: write PCM here ──────────────────────────────────

    /**
     * Called from audio thread (ExoPlayer AudioProcessor).
     * Downmixes stereo-interleaved float PCM to mono and writes to ring buffer.
     * Returns the ring index the first frame landed at, which is how the tap
     * maps the player's clock onto the ring.
     */
    int64_t pushSamples(const float* stereoInterleaved, int numFrames) {
        const int64_t first = writePos_.load(std::memory_order_relaxed);
        for (int i = 0; i < numFrames; i++) {
            float mono = (stereoInterleaved[i * 2] + stereoInterleaved[i * 2 + 1]) * 0.5f;
            ringBuf_[(first + i) & RING_MASK] = mono;
        }
        writePos_.store(first + numFrames, std::memory_order_release);
        // Saturate instead of wrapping: with only the spectrum sink attached
        // nothing resets this counter. CAS keeps the viz thread's reset safe.
        int cur = samplesAvailable_.load(std::memory_order_relaxed);
        int next;
        do {
            next = cur >= RING_SIZE - numFrames ? RING_SIZE : cur + numFrames;
        } while (!samplesAvailable_.compare_exchange_weak(
            cur, next, std::memory_order_release, std::memory_order_relaxed));
        return first;
    }

    /** The sample rate the bass filters are tuned for. Viz thread. */
    void setSampleRate(int sampleRate) {
        if (sampleRate <= 0 || sampleRate == sampleRate_) return;
        sampleRate_ = sampleRate;
        designBassFilters();
    }

    // ── Viz thread: compute FFT + bands here (~30fps) ─────────────────

    /**
     * Computes FFT and maps to log-frequency bands.
     * Returns true if new data was computed.
     * Output: bands[0..NUM_BANDS-1] = smoothed magnitude 0.0–1.0
     */
    bool computeBands(float* bands, int64_t endIndex = -1) {
        int avail = samplesAvailable_.load(std::memory_order_acquire);
        if (avail < FFT_SIZE) return false;

        // Snap the FFT_SIZE samples ending at the heard position (or the
        // newest, without a clock) + apply Hann window
        const int64_t rp = windowEnd(endIndex) - FFT_SIZE;
        for (int i = 0; i < FFT_SIZE; i++) {
            inputBuf_[i] = ringBuf_[(rp + i) & RING_MASK] * window_[i];
        }
        samplesAvailable_.store(0, std::memory_order_release);

        // ── Radix-2 FFT (real input via pack-two-reals trick) ──
        realFFT(inputBuf_, fftOut_, FFT_SIZE);

        // ── Magnitude spectrum ──
        magnitudes_[0] = fabsf(fftOut_[0]);          // DC
        magnitudes_[HALF_FFT] = fabsf(fftOut_[1]);   // Nyquist
        float peak = 0.0001f;
        for (int i = 1; i < HALF_FFT; i++) {
            float re = fftOut_[i * 2];
            float im = fftOut_[i * 2 + 1];
            magnitudes_[i] = sqrtf(re * re + im * im);
            if (magnitudes_[i] > peak) peak = magnitudes_[i];
        }

        // ── Map to log-frequency bands with smoothing ──
        for (int b = 0; b < NUM_BANDS; b++) {
            int lo = bandEdges_[b];
            int hi = bandEdges_[b + 1];
            float sum = 0;
            for (int i = lo; i < hi; i++) {
                sum += magnitudes_[i];
            }
            float avg = sum / std::max(1, hi - lo);
            // Normalize + perceptual compression + gain (beat sensitivity)
            float normalized = powf(avg / peak, 0.6f) * gain;
            if (normalized > 1.0f) normalized = 1.0f;

            // Asymmetric smoothing with configurable attack/decay
            if (normalized > smoothBands_[b]) {
                smoothBands_[b] += (normalized - smoothBands_[b]) * attackRate;
            } else {
                smoothBands_[b] += (normalized - smoothBands_[b]) * decayRate;
            }
            bands[b] = smoothBands_[b];
        }
        return true;
    }

    /**
     * Also produce waveform bytes (0-255, center=128) for compatibility
     * with existing Flutter visualizer painters.
     * Output: wave[0..size-1], returns actual size written.
     */
    int getWaveform(uint8_t* wave, int maxSize, int64_t endIndex = -1) {
        int count = std::min(maxSize, (int)FFT_SIZE);
        const int64_t rp = windowEnd(endIndex) - count;
        for (int i = 0; i < count; i++) {
            float s = ringBuf_[(rp + i) & RING_MASK];
            // Clamp [-1,1] → [0,255]
            int v = (int)((s + 1.0f) * 127.5f);
            if (v < 0) v = 0; else if (v > 255) v = 255;
            wave[i] = (uint8_t)v;
        }
        return count;
    }

    /** Hops at most per beat frame: 0.75 s of them, more than a slow tick needs. */
    static constexpr int MAX_HOPS = 128;
    /** Floats in the largest frame computeBeat writes. */
    static constexpr int BEAT_FRAME_MAX = 6 + MAX_HOPS + NUM_BANDS;

    /**
     * Writes a beat frame for the stretch heard since the previous call:
     *
     *   [0] format (1)   [1] sample rate   [2] hop seconds   [3] synced (1/0)
     *   [4] hop count n  [5 .. 5+n) mean square below ~150 Hz per hop
     *   [5+n] band count (64)  then the bands' levels, dBFS, at the heard end
     *
     * Returns the number of floats written. Viz thread only.
     */
    int computeBeat(float* out, int64_t endIndex) {
        const int64_t end = windowEnd(endIndex);
        const double hopSeconds = (double)hopSize_ / sampleRate_;

        // Restart cleanly rather than filter a backlog: first frame, a seek, a
        // pause longer than half a second, or the clock stepping backwards.
        const int64_t resync = sampleRate_ / 2;
        if (bassCursor_ < 0 || end - bassCursor_ > resync || bassCursor_ - end > resync / 2) {
            bassCursor_ = end;
            hp_.reset();
            lp1_.reset();
            lp2_.reset();
            hopAcc_ = 0;
            hopFill_ = 0;
        }
        int n = 0;
        float* hops = out + 5;
        for (int64_t i = bassCursor_; i < end; i++) {
            const double y = lp2_.process(lp1_.process(hp_.process(ringBuf_[i & RING_MASK])));
            hopAcc_ += y * y;
            if (++hopFill_ >= hopSize_) {
                if (n < MAX_HOPS) hops[n++] = (float)(hopAcc_ / hopSize_);
                hopAcc_ = 0;
                hopFill_ = 0;
            }
        }
        if (end > bassCursor_) bassCursor_ = end;

        out[0] = 1.0f;
        out[1] = (float)sampleRate_;
        out[2] = (float)hopSeconds;
        out[3] = endIndex >= 0 ? 1.0f : 0.0f;
        out[4] = (float)n;

        // Absolute band levels where the hops end: the radial's bars.
        const int64_t rp = end - FFT_SIZE;
        for (int i = 0; i < FFT_SIZE; i++) {
            inputBuf_[i] = ringBuf_[(rp + i) & RING_MASK] * window_[i];
        }
        realFFT(inputBuf_, fftOut_, FFT_SIZE);
        float* bands = out + 6 + n;
        out[5 + n] = (float)NUM_BANDS;
        for (int b = 0; b < NUM_BANDS; b++) {
            const int lo = bandEdges_[b];
            const int hi = bandEdges_[b + 1];
            float sum = 0;
            for (int i = lo; i < hi; i++) {
                const float re = fftOut_[i * 2];
                const float im = fftOut_[i * 2 + 1];
                sum += sqrtf(re * re + im * im);
            }
            const float mean = sum / std::max(1, hi - lo);
            // A full-scale sine peaks at FFT_SIZE/4 through a Hann window.
            bands[b] = 20.0f * log10f(mean / (FFT_SIZE / 4) + 1e-9f);
        }
        return 6 + n + NUM_BANDS;
    }

    /**
     * Writes the 256-power bar spectrum of the 512 * D samples ending at the
     * heard position (D = BarSpectrum::decimation(sampleRate)). Viz thread only.
     *
     * False when fewer than 512 * D samples were ever written, or when the
     * resolved window end is the one the last frame used. The end follows the
     * playback clock, so it advances every tick while music plays even between
     * the bursts the player writes PCM in; when paused the clock goes stale,
     * the caller passes -1, the end sticks at the newest sample and no frame
     * is made, so the consumer can fall to silence.
     */
    bool computeSpectrum(float* out256, int64_t endIndex, int sampleRate) {
        const int decim = BarSpectrum::decimation(sampleRate);
        const int64_t need = (int64_t)BarSpectrum::kBlock * decim;
        const int64_t newest = writePos_.load(std::memory_order_acquire);
        if (newest < need) return false;

        // The clock can trail the start of the stream: never read before it.
        const int64_t end = std::max(need, windowEnd(endIndex));
        if (end == spectrumEnd_) return false;
        spectrumEnd_ = end;

        const int64_t start = end - need;
        for (int64_t i = 0; i < need; i++) {
            spectrumIn_[i] = ringBuf_[(start + i) & RING_MASK];
        }
        spectrum_.compute(spectrumIn_, decim, out256);
        return true;
    }

private:
    // ~1.5 s at 44.1 kHz: the heard position trails the newest sample by the
    // sink's lead (~0.3 s, more on Bluetooth), and a window must fit behind it.
    static constexpr int RING_SIZE = 65536;  // power of 2
    static constexpr int RING_MASK = RING_SIZE - 1;
    // Never read closer than this to being overwritten by the audio thread.
    static constexpr int RING_GUARD = 8192;

    // Ring buffer (SPSC: audio thread writes, viz thread reads)
    float ringBuf_[RING_SIZE];
    std::atomic<int64_t> writePos_{0};  // only written by audio thread
    std::atomic<int> samplesAvailable_{0};

    /**
     * Where a read window ends: the heard position when known, kept inside
     * what the ring still holds; the newest sample otherwise.
     */
    int64_t windowEnd(int64_t endIndex) const {
        const int64_t newest = writePos_.load(std::memory_order_acquire);
        if (endIndex < 0) return newest;
        const int64_t oldest = newest - (RING_SIZE - RING_GUARD) + FFT_SIZE;
        return std::max(oldest, std::min(endIndex, newest));
    }

    // ── Bar spectrum (viz thread) ──
    BarSpectrum spectrum_;
    int64_t spectrumEnd_ = -1;   // window end of the last successful frame
    float spectrumIn_[BarSpectrum::kBlock * BarSpectrum::kMaxDecimation];

    // ── Bass hops (viz thread) ──
    // Direct form I biquad in double: a 35 Hz high-pass at 44.1 kHz puts its
    // poles within 0.005 of the unit circle, too close for float state.
    struct Biquad {
        double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
        double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
        double process(double x) {
            const double y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
            x2 = x1; x1 = x; y2 = y1; y1 = y;
            return y;
        }
        void reset() { x1 = x2 = y1 = y2 = 0; }
        // RBJ cookbook, Q = 1/sqrt(2): a second-order Butterworth section.
        void design(bool highPass, double fc, double fs) {
            const double w0 = 2.0 * M_PI * fc / fs;
            const double cw = std::cos(w0);
            const double alpha = std::sin(w0) / (2.0 * 0.7071067811865476);
            const double a0 = 1.0 + alpha;
            if (highPass) {
                b0 = (1.0 + cw) / 2.0 / a0; b1 = -(1.0 + cw) / a0; b2 = b0;
            } else {
                b0 = (1.0 - cw) / 2.0 / a0; b1 = (1.0 - cw) / a0; b2 = b0;
            }
            a1 = -2.0 * cw / a0;
            a2 = (1.0 - alpha) / a0;
        }
    };

    // 35 Hz high-pass (rumble, DC) then a 4th-order 150 Hz low-pass: where a
    // kick or an 808 is most of the energy.
    Biquad hp_, lp1_, lp2_;
    int sampleRate_ = 44100;
    int hopSize_ = 256;         // ~5.8 ms
    int64_t bassCursor_ = -1;   // next ring index to filter
    double hopAcc_ = 0;
    int hopFill_ = 0;

    void designBassFilters() {
        hp_.design(true, 35.0, sampleRate_);
        lp1_.design(false, 150.0, sampleRate_);
        lp2_.design(false, 150.0, sampleRate_);
        hp_.reset();
        lp1_.reset();
        lp2_.reset();
        // Keep the hop near 5.8 ms whatever the rate, so the detector's
        // windows (counted in hops) mean the same time.
        hopSize_ = std::max(64, (int)std::lround(sampleRate_ / 172.27));
        bassCursor_ = -1;
    }

    // FFT working buffers
    float window_[FFT_SIZE];
    float inputBuf_[FFT_SIZE];
    float fftOut_[FFT_SIZE];
    float magnitudes_[HALF_FFT + 1];

    // Precomputed real-FFT unpack twiddles (cos/sin of -2*pi*k/FFT_SIZE),
    // indices 1 .. HALF_FFT-1. Built once in the constructor.
    float unpackCos_[HALF_FFT];
    float unpackSin_[HALF_FFT];

    // Smoothed output bands (persisted across frames for attack/decay)
    float smoothBands_[NUM_BANDS];

    // Log-frequency band edges (FFT bin indices)
    int bandEdges_[NUM_BANDS + 1];

    void computeBandEdges() {
        // Power-curve mapping: more resolution in bass, less in treble
        // bin = 1 + (HALF_FFT-1) * (b/NUM_BANDS)^2.0
        for (int b = 0; b <= NUM_BANDS; b++) {
            float t = (float)b / NUM_BANDS;
            bandEdges_[b] = 1 + (int)(powf(t, 2.0f) * (HALF_FFT - 1));
        }
        // Ensure monotonic and non-empty
        for (int b = 1; b <= NUM_BANDS; b++) {
            if (bandEdges_[b] <= bandEdges_[b - 1]) {
                bandEdges_[b] = bandEdges_[b - 1] + 1;
            }
        }
    }

    // ── Radix-2 real FFT via "pack two reals into one complex" ──
    // Non-static so it can read the precomputed unpack twiddle tables.

    void realFFT(const float* input, float* output, int N) const {
        const int M = N / 2;

        // Pack: z[k] = input[2k] + j * input[2k+1]
        float z[4096]; // M*2 complex values (M <= 1024 for N=2048)
        for (int k = 0; k < M; k++) {
            z[2 * k]     = input[2 * k];
            z[2 * k + 1] = input[2 * k + 1];
        }

        // Bit-reversal permutation
        for (int i = 1, j = 0; i < M; i++) {
            int bit = M >> 1;
            for (; j & bit; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) {
                std::swap(z[2 * i],     z[2 * j]);
                std::swap(z[2 * i + 1], z[2 * j + 1]);
            }
        }

        // Cooley-Tukey butterfly
        for (int len = 2; len <= M; len <<= 1) {
            float ang = -2.0f * (float)M_PI / len;
            float wRe = cosf(ang), wIm = sinf(ang);
            for (int i = 0; i < M; i += len) {
                float curRe = 1.0f, curIm = 0.0f;
                for (int j = 0; j < len / 2; j++) {
                    int u = i + j, v = i + j + len / 2;
                    float tRe = z[2 * v]     * curRe - z[2 * v + 1] * curIm;
                    float tIm = z[2 * v]     * curIm + z[2 * v + 1] * curRe;
                    z[2 * v]     = z[2 * u]     - tRe;
                    z[2 * v + 1] = z[2 * u + 1] - tIm;
                    z[2 * u]     += tRe;
                    z[2 * u + 1] += tIm;
                    float newRe = curRe * wRe - curIm * wIm;
                    curIm = curRe * wIm + curIm * wRe;
                    curRe = newRe;
                }
            }
        }

        // Unpack N/2-complex → N-real FFT
        // output layout: [DC, Nyquist, Re[1], Im[1], Re[2], Im[2], ...]
        output[0] = z[0] + z[1];   // DC (real)
        output[1] = z[0] - z[1];   // Nyquist (real)
        for (int k = 1; k < M; k++) {
            int mk = M - k;
            float eRe =  0.5f * (z[2 * k]     + z[2 * mk]);
            float eIm =  0.5f * (z[2 * k + 1] - z[2 * mk + 1]);
            float oRe =  0.5f * (z[2 * k + 1] + z[2 * mk + 1]);
            float oIm = -0.5f * (z[2 * k]     - z[2 * mk]);
            // Precomputed twiddle (identical to -2*pi*k/FFT_SIZE; N == FFT_SIZE)
            float wR = unpackCos_[k], wI = unpackSin_[k];
            float tRe = oRe * wR - oIm * wI;
            float tIm = oRe * wI + oIm * wR;
            output[2 * k]     = eRe + tRe;
            output[2 * k + 1] = eIm + tIm;
        }
    }
};
