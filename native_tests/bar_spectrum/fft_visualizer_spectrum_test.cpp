// Host tests for FFTVisualizer::computeSpectrum
// (android/app/src/main/cpp/fft_visualizer.h).
// Build and run: native_tests/bar_spectrum/run.sh

#include "fft_visualizer.h"

#include <cmath>
#include <cstdio>
#include <memory>
#include <vector>

static int gFailures = 0;
static int gChecks = 0;
#define CHECK(cond)                                                          \
    do {                                                                     \
        ++gChecks;                                                           \
        if (!(cond)) {                                                       \
            ++gFailures;                                                     \
            std::printf("    FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);  \
        }                                                                    \
    } while (0)

static void pushSine(FFTVisualizer& v, int frames, double hz, int sampleRate) {
    std::vector<float> st(frames * 2);
    for (int i = 0; i < frames; i++) {
        const float s = (float)std::sin(2.0 * M_PI * hz * i / sampleRate);
        st[2 * i] = s;
        st[2 * i + 1] = s;
    }
    v.pushSamples(st.data(), frames);
}

static int peakBin(const float* out) {
    int best = 0;
    for (int j = 1; j < 256; j++)
        if (out[j] > out[best]) best = j;
    return best;
}

static void sine_48k() {
    std::printf("1 kHz at 48 kHz\n");
    auto v = std::make_unique<FFTVisualizer>();
    float out[256];
    CHECK(!v->computeSpectrum(out, -1, 48000));  // nothing written yet
    pushSine(*v, 4096, 1000.0, 48000);
    CHECK(v->computeSpectrum(out, -1, 48000));
    const int p = peakBin(out);
    CHECK(p >= 9 && p <= 10);
    CHECK(!v->computeSpectrum(out, -1, 48000));  // no new audio, no frame
    pushSine(*v, 64, 1000.0, 48000);
    CHECK(v->computeSpectrum(out, -1, 48000));   // new audio, frame again
}

static void too_few_samples() {
    std::printf("fewer than 512 * D samples\n");
    auto v = std::make_unique<FFTVisualizer>();
    float out[256];
    pushSine(*v, 511, 1000.0, 48000);
    CHECK(!v->computeSpectrum(out, -1, 48000));
    pushSine(*v, 1, 1000.0, 48000);
    CHECK(v->computeSpectrum(out, -1, 48000));
    auto w = std::make_unique<FFTVisualizer>();
    pushSine(*w, 1000, 1000.0, 96000);  // D = 2 needs 1024
    CHECK(!w->computeSpectrum(out, -1, 96000));
}

static void sine_96k() {
    std::printf("1 kHz at 96 kHz\n");
    auto v = std::make_unique<FFTVisualizer>();
    float out[256];
    pushSine(*v, 8192, 1000.0, 96000);
    CHECK(v->computeSpectrum(out, -1, 96000));
    const int p = peakBin(out);
    CHECK(p >= 9 && p <= 10);
}

static void advancing_end_without_pushes() {
    std::printf("gating follows the resolved end\n");
    auto v = std::make_unique<FFTVisualizer>();
    float out[256];
    pushSine(*v, 4096, 1000.0, 48000);
    CHECK(v->computeSpectrum(out, 2000, 48000));
    CHECK(v->computeSpectrum(out, 2100, 48000));  // (a) no pushes, end moved
    CHECK(v->computeSpectrum(out, 2200, 48000));
    CHECK(!v->computeSpectrum(out, 2200, 48000)); // (b) same end twice
    CHECK(v->computeSpectrum(out, -1, 48000));    // newest differs from 2200
    CHECK(!v->computeSpectrum(out, -1, 48000));   // (c) stale clock, no pushes
    pushSine(*v, 64, 1000.0, 48000);
    CHECK(v->computeSpectrum(out, -1, 48000));
}

static void end_picks_the_stretch(int sampleRate, int n, int expect1k, int expect4k) {
    auto v = std::make_unique<FFTVisualizer>();
    float out[256];
    pushSine(*v, n, 1000.0, sampleRate);
    // 4 kHz continues in phase-agnostic fashion; a seam does not matter here.
    pushSine(*v, n, 4000.0, sampleRate);
    CHECK(v->computeSpectrum(out, n, sampleRate));  // ends inside the 1 kHz stretch
    int p = peakBin(out);
    CHECK(p >= expect1k - 1 && p <= expect1k);
    CHECK(v->computeSpectrum(out, 2 * n, sampleRate));  // inside the 4 kHz stretch
    p = peakBin(out);
    CHECK(p >= expect4k - 1 && p <= expect4k + 1);
}

static void heard_end_index() {
    std::printf("explicit end index, D = 1\n");
    end_picks_the_stretch(48000, 4096, 10, 42);
    std::printf("explicit end index, D = 2\n");
    end_picks_the_stretch(96000, 8192, 10, 42);
    auto v = std::make_unique<FFTVisualizer>();
    float out[256];
    pushSine(*v, 8192, 1000.0, 96000);
    CHECK(v->computeSpectrum(out, 10, 96000));  // early end raised, not read before 0
    const int p = peakBin(out);
    CHECK(p >= 9 && p <= 10);
}

static void counter_saturates() {
    std::printf("samplesAvailable_ saturates (spectrum-only sink)\n");
    auto v = std::make_unique<FFTVisualizer>();
    std::vector<float> st(65536 * 2, 0.25f);
    // 2^31 + 2^21 frames pushed, nothing ever resets the counter.
    for (int i = 0; i < 32768 + 32; i++) v->pushSamples(st.data(), 65536);
    float bands[64];
    CHECK(v->computeBands(bands));  // a wrapped counter would be negative
}

int main() {
    sine_48k();
    too_few_samples();
    sine_96k();
    advancing_end_without_pushes();
    heard_end_index();
    counter_saturates();
    std::printf("%d checks, %d failures\n", gChecks, gFailures);
    return gFailures ? 1 : 0;
}
