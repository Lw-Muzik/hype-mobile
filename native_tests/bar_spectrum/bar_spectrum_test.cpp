// Host unit tests for the built-in visualizer spectrum
// (android/app/src/main/cpp/bar_spectrum.h, kept identical to
// ios/HypeDSP/src/bar_spectrum.h).
// Build and run: native_tests/bar_spectrum/run.sh

#include "bar_spectrum.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
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

static void decimation_table() {
    std::printf("decimation table\n");
    struct Row { int sr, d; };
    const Row rows[] = {
        {0, 1},      {-5, 1},     {22050, 1},  {44100, 1},  {48000, 1},
        {64000, 1},  {88200, 2},  {96000, 2},  {176400, 4}, {192000, 4},
        {384000, 8}, {768000, 8},
    };
    for (const Row& r : rows) {
        const int got = BarSpectrum::decimation(r.sr);
        if (got != r.d) std::printf("    sr %d: got %d want %d\n", r.sr, got, r.d);
        CHECK(got == r.d);
    }
}

static void silence_is_the_floor() {
    std::printf("silence is the floor\n");
    BarSpectrum s;
    std::vector<float> in(BarSpectrum::kBlock, 0.0f), out(BarSpectrum::kBins, 1.0f);
    s.compute(in.data(), 1, out.data());
    for (int j = 0; j < BarSpectrum::kBins; j++) CHECK(out[j] == BarSpectrum::kFloor);
}

static void full_scale_sine_on_a_bin() {
    std::printf("full-scale sine on a bin\n");
    BarSpectrum s;
    const double pi = 3.14159265358979323846;
    std::vector<float> in(BarSpectrum::kBlock), out(BarSpectrum::kBins);
    for (int n = 0; n < BarSpectrum::kBlock; n++)
        in[n] = (float)std::cos(2.0 * pi * 10.0 * n / 512.0);
    s.compute(in.data(), 1, out.data());
    const float want = 127.75f * 127.75f;
    CHECK(std::fabs(out[9] - want) <= 0.01f * want);
    for (int j = 0; j < BarSpectrum::kBins; j++) {
        if (std::abs(j - 9) >= 4) CHECK(out[j] < out[9] * 1e-3f);
    }
}

static void decimated_block_equals_hand_averaged_block() {
    std::printf("decimated block equals hand-averaged block\n");
    BarSpectrum s;
    std::srand(12345);
    std::vector<float> in(2 * BarSpectrum::kBlock), means(BarSpectrum::kBlock);
    for (float& v : in) v = (float)(std::rand() % 20001) / 10000.0f - 1.0f;
    for (int n = 0; n < BarSpectrum::kBlock; n++)
        means[n] = (in[2 * n] + in[2 * n + 1]) / 2.0f;
    std::vector<float> a(BarSpectrum::kBins), b(BarSpectrum::kBins);
    s.compute(in.data(), 2, a.data());
    s.compute(means.data(), 1, b.data());
    for (int j = 0; j < BarSpectrum::kBins; j++) CHECK(a[j] == b[j]);
}

int main() {
    decimation_table();
    silence_is_the_floor();
    full_scale_sine_on_a_bin();
    decimated_block_equals_hand_averaged_block();
    std::printf("%d checks, %d failures\n", gChecks, gFailures);
    return gFailures == 0 ? 0 : 1;
}
