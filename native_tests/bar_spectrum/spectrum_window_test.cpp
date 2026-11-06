// Host tests for spectrumWindowEnd (ios/HypeDSP/src/spectrum_window.h).
// Build and run: native_tests/bar_spectrum/run.sh

#include "spectrum_window.h"

#include <cstdio>

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

static const int kRate = 48000;
static const int kBuf = 4096;  // one tap buffer, ~85 ms

static void starts_one_buffer_behind() {
    std::printf("starts at the end of the previous buffer\n");
    CHECK(spectrumWindowEnd(8192, 12288, 0.0, kRate) == 8192);
    CHECK(spectrumWindowEnd(8192, 12288, -1.0, kRate) == 8192);
}

static void advances_per_call() {
    std::printf("advances on every call between buffers\n");
    int64_t last = spectrumWindowEnd(8192, 12288, 0.0, kRate);
    int moved = 0;
    // 60 Hz display ticks across one 85.3 ms buffer period.
    for (int tick = 1; tick * 16.667e-3 < kBuf / (double)kRate; tick++) {
        const int64_t e = spectrumWindowEnd(8192, 12288, tick * 16.667e-3, kRate);
        if (e > last) moved++;
        CHECK(e >= last);
        last = e;
    }
    CHECK(moved == 5);
    CHECK(last < 12288);
}

static void clamps_at_latest() {
    std::printf("clamps at the latest count\n");
    const double period = kBuf / (double)kRate;
    CHECK(spectrumWindowEnd(8192, 12288, period, kRate) == 12288);
    CHECK(spectrumWindowEnd(8192, 12288, period * 1.5, kRate) == 12288);
}

static void stops_when_stale() {
    std::printf("stops at latest when no buffer arrives for 2 periods\n");
    const double period = kBuf / (double)kRate;
    CHECK(spectrumWindowEnd(8192, 12288, period * 2.5, kRate) == 12288);
    CHECK(spectrumWindowEnd(8192, 12288, 3600.0, kRate) == 12288);
}

static void continuous_across_buffers() {
    std::printf("continuous when the next buffer lands\n");
    const double period = kBuf / (double)kRate;
    // Just before and just after the next buffer is published.
    const int64_t before = spectrumWindowEnd(8192, 12288, period * 0.999, kRate);
    const int64_t after = spectrumWindowEnd(12288, 16384, 0.001, kRate);
    CHECK(after >= before);
    CHECK(after - before < 100);
}

static void degenerate() {
    std::printf("degenerate inputs\n");
    CHECK(spectrumWindowEnd(0, 0, 1.0, kRate) == 0);
    CHECK(spectrumWindowEnd(100, 4196, 0.01, 0) == 4196);
}

int main() {
    starts_one_buffer_behind();
    advances_per_call();
    clamps_at_latest();
    stops_when_stale();
    continuous_across_buffers();
    degenerate();
    std::printf("%d checks, %d failures\n", gChecks, gFailures);
    return gFailures ? 1 : 0;
}
