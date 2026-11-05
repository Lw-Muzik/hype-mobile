// Host unit tests for the N-band graphic EQ (graphic_eq.h, kept identical
// across android/app/src/main/cpp and ios/HypeDSP/src) and its wiring into
// RoomDSPEngine.
// Build and run: native_tests/eq/run.sh

#include "graphic_eq.h"
#include "room_dsp_engine.h"

#include <cmath>
#include <cstdio>
#include <atomic>
#include <chrono>
#include <cstring>
#include <functional>
#include <thread>
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
#define CHECK_NEAR(a, b, eps)                                                \
    do {                                                                     \
        ++gChecks;                                                           \
        const double va_ = (a), vb_ = (b);                                   \
        if (!(std::fabs(va_ - vb_) <= (eps))) {                              \
            ++gFailures;                                                     \
            std::printf("    FAIL %s:%d  %s = %.6f, expected %.6f +- %g\n",  \
                        __FILE__, __LINE__, #a, va_, vb_, (double)(eps));    \
        }                                                                    \
    } while (0)

static const double kPi = 3.14159265358979323846;

// A continuous sine source (phase carries across calls).
struct Sine {
    double freq, amp, sr, phase = 0.0;
    Sine(double f, double a, double sampleRate = 48000.0)
        : freq(f), amp(a), sr(sampleRate) {}
    void fill(std::vector<float>& l, std::vector<float>& r, int n) {
        l.resize(n);
        r.resize(n);
        for (int i = 0; i < n; i++) {
            l[i] = r[i] = (float)(amp * std::sin(phase));
            phase += 2.0 * kPi * freq / sr;
        }
    }
};

static float peakOf(const std::vector<float>& v) {
    float p = 0.0f;
    for (float x : v) p = std::max(p, std::fabs(x));
    return p;
}

static float maxStep(const std::vector<float>& v) {
    float m = 0.0f;
    for (size_t i = 1; i < v.size(); i++) m = std::max(m, std::fabs(v[i] - v[i - 1]));
    return m;
}

static double toDb(double ratio) { return 20.0 * std::log10(ratio); }

// 31.25 * 2^k, k = 0..9 : 31.25 ... 16000 Hz. Index 5 is 1000 Hz.
static std::vector<float> octaveLayout() {
    std::vector<float> c;
    for (int k = 0; k < 10; k++) c.push_back(31.25f * (float)std::pow(2.0, k));
    return c;
}

// 15 ISO centres. Index 8 is 1000 Hz.
static const float kIso15[15] = {25.0f,   40.0f,   63.0f,   100.0f,  160.0f,
                                 250.0f,  400.0f,  630.0f,  1000.0f, 1600.0f,
                                 2500.0f, 4000.0f, 6300.0f, 10000.0f, 16000.0f};

// Runs a settled sine through a graphic EQ and returns the peak gain in dB
// over a window after the settle time.
static double measureDb(GraphicEQ& eq, double freq, double sampleRate = 48000.0) {
    Sine s(freq, 0.1, sampleRate);
    std::vector<float> l, r;
    s.fill(l, r, 4800);
    eq.process(l.data(), r.data(), 4800);
    s.fill(l, r, 4800);
    eq.process(l.data(), r.data(), 4800);
    return toDb(peakOf(l) / 0.1);
}

static void graphic_q_from_spacing() {
    std::printf("graphic_q_from_spacing\n");
    const float oct[5] = {250, 500, 1000, 2000, 4000};
    CHECK_NEAR(GraphicEQ::bandQ(oct, 5, 2), 1.41421, 1e-4);
    CHECK_NEAR(GraphicEQ::bandQ(oct, 5, 0), 1.41421, 1e-4);
    CHECK_NEAR(GraphicEQ::bandQ(oct, 5, 4), 1.41421, 1e-4);
    float third[5];
    for (int k = 0; k < 5; k++) third[k] = 1000.0f * (float)std::pow(2.0, k / 3.0);
    CHECK_NEAR(GraphicEQ::bandQ(third, 5, 1), 4.3185, 1e-3);
    // A single band has no neighbour to measure: still a sane Q.
    const float one[1] = {1000};
    const float q1 = GraphicEQ::bandQ(one, 1, 0);
    CHECK(q1 > 0.3f && q1 < 30.0f);
    // Duplicate centres must not give a runaway Q.
    const float dup[3] = {500, 500, 1000};
    CHECK(GraphicEQ::bandQ(dup, 3, 0) < 100.0f);
}

static void graphic_layout_keeps_gains_by_index() {
    std::printf("graphic_layout_keeps_gains_by_index\n");
    GraphicEQ eq;
    eq.init(48000.0f);
    const std::vector<float> oct = octaveLayout();
    eq.setLayout(oct.data(), 10);
    CHECK(eq.bandCount() == 10);
    for (int i = 0; i < 10; i++) eq.setBandGain(i, (float)(i + 1));
    eq.setLayout(kIso15, 15);
    CHECK(eq.bandCount() == 15);
    for (int i = 0; i < 10; i++) CHECK_NEAR(eq.effectiveGainDb(i), i + 1, 1e-6);
    for (int i = 10; i < 15; i++) CHECK_NEAR(eq.effectiveGainDb(i), 0.0, 1e-6);
    CHECK_NEAR(eq.centreHz(8), 1000.0, 1e-3);
    CHECK_NEAR(eq.q(8), GraphicEQ::bandQ(kIso15, 15, 8), 1e-6);
    // Shrinking drops the upper gains for good: growing again gives zeros.
    eq.setLayout(kIso15, 4);
    CHECK(eq.bandCount() == 4);
    eq.setLayout(kIso15, 15);
    for (int i = 0; i < 4; i++) CHECK_NEAR(eq.effectiveGainDb(i), i + 1, 1e-6);
    for (int i = 4; i < 15; i++) CHECK_NEAR(eq.effectiveGainDb(i), 0.0, 1e-6);
    // Count is clamped to 1..32.
    float many[40];
    for (int i = 0; i < 40; i++) many[i] = 100.0f + 10.0f * i;
    eq.setLayout(many, 40);
    CHECK(eq.bandCount() == kMaxGraphicBands);
    eq.setLayout(many, 0);
    CHECK(eq.bandCount() == 1);
}

static void graphic_band_boosts_its_centre() {
    std::printf("graphic_band_boosts_its_centre\n");
    const std::vector<float> oct = octaveLayout();
    {
        GraphicEQ eq;
        eq.init(48000.0f);
        eq.setLayout(oct.data(), 10);
        eq.setBandGain(5, 12.0f);
        CHECK_NEAR(measureDb(eq, 1000.0), 12.0, 0.3);
    }
    {
        GraphicEQ eq;
        eq.init(48000.0f);
        eq.setLayout(oct.data(), 10);
        eq.setBandGain(5, 12.0f);
        CHECK_NEAR(measureDb(eq, 125.0), 0.0, 0.5);
    }
    {  // setAllGains reaches the same result as per-band calls.
        GraphicEQ eq;
        eq.init(48000.0f);
        eq.setLayout(oct.data(), 10);
        float g[10] = {0};
        g[5] = 12.0f;
        eq.setAllGains(g, 10);
        CHECK_NEAR(measureDb(eq, 1000.0), 12.0, 0.3);
    }
}

static void graphic_flat_is_bit_exact() {
    std::printf("graphic_flat_is_bit_exact\n");
    GraphicEQ eq;
    eq.init(48000.0f);
    std::vector<float> l(1024), r(1024);
    for (int i = 0; i < 1024; i++) {
        l[i] = 0.5f * std::sin(0.01f * i * i * 0.001f + i * 0.37f);
        r[i] = 0.3f * std::cos(i * 0.91f);
    }
    std::vector<float> l0 = l, r0 = r;
    eq.process(l.data(), r.data(), 1024);
    CHECK(std::memcmp(l.data(), l0.data(), 1024 * sizeof(float)) == 0);
    CHECK(std::memcmp(r.data(), r0.data(), 1024 * sizeof(float)) == 0);
    // Below the 0.05 dB activity threshold is still flat.
    eq.setBandGain(5, 0.04f);
    eq.process(l.data(), r.data(), 1024);
    CHECK(std::memcmp(l.data(), l0.data(), 1024 * sizeof(float)) == 0);
    CHECK(std::memcmp(r.data(), r0.data(), 1024 * sizeof(float)) == 0);
}

// Builds a settled octave-layout EQ with band 5 at +12 dB, fed by a 1 kHz sine.
// `offset` extra frames after the settle point set the phase the next change
// lands on: 48 frames per cycle, so offsets 0..47 cover every phase.
struct SettledBoost {
    GraphicEQ eq;
    Sine sine{1000.0, 0.1};
    std::vector<float> l, r;
    float steadyStep = 0.0f;
    float lastOut = 0.0f;
    explicit SettledBoost(int offset) {
        eq.init(48000.0f);
        const std::vector<float> oct = octaveLayout();
        eq.setLayout(oct.data(), 10);
        eq.setBandGain(5, 12.0f);
        sine.fill(l, r, 9600 + offset);
        eq.process(l.data(), r.data(), 9600 + offset);
        sine.fill(l, r, 960);
        eq.process(l.data(), r.data(), 960);
        steadyStep = maxStep(l);
        lastOut = l.back();
    }
    static float joinedStep(float prev, const std::vector<float>& block) {
        std::vector<float> joined;
        joined.push_back(prev);
        joined.insert(joined.end(), block.begin(), block.end());
        return maxStep(joined);
    }
    // Largest step in a block of `n` more frames, including the join to the
    // previous block.
    float stepOver(int n, std::vector<float>* out = nullptr) {
        sine.fill(l, r, n);
        eq.process(l.data(), r.data(), n);
        const float step = joinedStep(lastOut, l);
        lastOut = l.back();
        if (out) *out = l;
        return step;
    }
    // Negative control: the same measurement over a hard cut, i.e. the boost
    // simply disappears (the raw sine continues, nothing is faded).
    float hardCutStep(int n) {
        sine.fill(l, r, n);
        return joinedStep(lastOut, l);
    }
};

static void graphic_band_off_drains_then_bit_exact() {
    std::printf("graphic_band_off_drains_then_bit_exact\n");
    float worst = 0.0f;
    for (int offset = 0; offset < 48; offset++) {
        SettledBoost s(offset);
        if (offset == 0) CHECK(s.steadyStep > 0.04f);  // 0.4 amplitude at 1 kHz / 48 kHz
        s.eq.setBandGain(5, 0.0f);
        const float ratio = s.stepOver(256) / s.steadyStep;
        worst = std::max(worst, ratio);
        // The 96-frame crossfade to dry ends, the old chain is cleared and the
        // band is skipped: exact from there on.
        std::vector<float> l2, r2;
        s.sine.fill(l2, r2, 256);
        std::vector<float> l2c = l2;
        s.eq.process(l2.data(), r2.data(), 256);
        CHECK(std::memcmp(l2.data(), l2c.data(), 256 * sizeof(float)) == 0);
    }
    std::printf("    worst step across the change over 48 phases: x%.3f\n", worst);
    CHECK(worst <= 1.1f);
}

// Proves the harness can fail: a hard cut at the same 48 phases must exceed
// the threshold at (at least) the phases where the boosted wave is not near a
// zero crossing.
static void graphic_click_harness_flags_a_hard_cut() {
    std::printf("graphic_click_harness_flags_a_hard_cut\n");
    float worst = 0.0f, best = 1e9f;
    for (int offset = 0; offset < 48; offset++) {
        SettledBoost s(offset);
        const float ratio = s.hardCutStep(256) / s.steadyStep;
        worst = std::max(worst, ratio);
        best = std::min(best, ratio);
    }
    std::printf("    hard cut: x%.3f at the worst phase, x%.3f at the best\n", worst, best);
    CHECK(worst > 3.0f);   // a quarter-cycle cut is about x5.7
    CHECK(worst > 1.1f);
    CHECK(best <= 1.1f);   // and a cut on a zero crossing slips past, which is
                           // exactly why one phase proves nothing
}

static void graphic_band_off_exact_within_drain_window() {
    std::printf("graphic_band_off_exact_within_drain_window\n");
    SettledBoost s(0);
    s.eq.setBandGain(5, 0.0f);
    // Rebuild the exact input the filter sees for the next 200 frames.
    Sine copy = s.sine;
    std::vector<float> in, inr;
    copy.fill(in, inr, 200);
    std::vector<float> out;
    s.stepOver(200, &out);
    bool exact = true;
    for (int i = 96; i < 200; i++) exact = exact && (out[i] == in[i]);
    CHECK(exact);
    bool changed = false;
    for (int i = 0; i < 90; i++) changed = changed || (out[i] != in[i]);
    CHECK(changed);  // the fade really was processed, not cut off
}

static void graphic_layout_change_without_click() {
    std::printf("graphic_layout_change_without_click\n");
    float worst = 0.0f;
    for (int offset = 0; offset < 48; offset++) {
        SettledBoost s(offset);
        float g[15] = {0};
        g[8] = 12.0f;
        s.eq.setLayout(kIso15, 15, g);  // layout and gains in one call
        if (offset == 0) {
            CHECK_NEAR(s.eq.centreHz(8), 1000.0, 1e-3);
            CHECK_NEAR(s.eq.effectiveGainDb(8), 12.0, 1e-6);
            CHECK_NEAR(s.eq.effectiveGainDb(5), 0.0, 1e-6);
        }
        const float ratio = s.stepOver(512) / s.steadyStep;
        worst = std::max(worst, ratio);
        if (offset == 0) {
            // And it ends up where it was: +12 dB at 1 kHz.
            std::vector<float> out;
            s.stepOver(4800, &out);
            s.stepOver(4800, &out);
            CHECK_NEAR(toDb(peakOf(out) / 0.1), 12.0, 0.3);
        }
    }
    std::printf("    worst step across the change over 48 phases: x%.3f\n", worst);
    CHECK(worst <= 1.1f);
}

// The 32 grid with +6 dB on the low bands, then 10 ISO centres whose gains are
// the same curve resampled. A 4 kHz probe sits well above the lift, so its
// level must not move at any point of the change.
static void graphic_layout_with_gains_is_one_step() {
    std::printf("graphic_layout_with_gains_is_one_step\n");
    static const float kIso10[10] = {31.5f, 63.0f, 125.0f, 250.0f, 500.0f,
                                     1000.0f, 2000.0f, 4000.0f, 8000.0f, 16000.0f};
    float gains32[32], gains10[10];
    for (int i = 0; i < 32; i++) gains32[i] = ISO_FREQUENCIES[i] <= 500.0f ? 6.0f : 0.0f;
    for (int i = 0; i < 10; i++) gains10[i] = kIso10[i] <= 500.0f ? 6.0f : 0.0f;

    // Window peaks (24 frames = 6 cycles of 4 kHz) of a 4 kHz probe.
    auto windowDbs = [](const std::vector<float>& v) {
        std::vector<double> db;
        for (size_t i = 0; i + 24 <= v.size(); i += 24) {
            float p = 0.0f;
            for (size_t k = 0; k < 24; k++) p = std::max(p, std::fabs(v[i + k]));
            db.push_back(toDb(p / 0.1));
        }
        return db;
    };
    // `oneCall` false is the two-call path the single call replaces.
    auto run = [&](int offset, bool oneCall, double* before, double* after) {
        GraphicEQ eq;
        eq.init(48000.0f);
        eq.setLayout(ISO_FREQUENCIES, 32, gains32);
        Sine probe(4000.0, 0.1);
        std::vector<float> l, r, all;
        probe.fill(l, r, 9600 + offset);
        eq.process(l.data(), r.data(), 9600 + offset);
        probe.fill(l, r, 480);
        eq.process(l.data(), r.data(), 480);
        *before = windowDbs(l).back();
        if (oneCall) {
            eq.setLayout(kIso10, 10, gains10);
        } else {
            eq.setLayout(kIso10, 10);  // old gains at the new centres ...
            probe.fill(l, r, 24);       // ... for a block, before the gains arrive
            eq.process(l.data(), r.data(), 24);
            all = l;
            eq.setAllGains(gains10, 10);
        }
        probe.fill(l, r, 480);
        eq.process(l.data(), r.data(), 480);
        all.insert(all.end(), l.begin(), l.end());
        probe.fill(l, r, 9600);
        eq.process(l.data(), r.data(), 9600);
        probe.fill(l, r, 480);
        eq.process(l.data(), r.data(), 480);
        *after = windowDbs(l).back();
        double dev = 0.0;
        for (double d : windowDbs(all)) {
            const double lo = std::min(*before, *after) - d;
            const double hi = d - std::max(*before, *after);
            dev = std::max(dev, std::max(lo, hi));
        }
        return dev;  // how far any window strays outside [before, after]
    };

    double worst = 0.0, worstTwoCall = 0.0, b = 0, a = 0;
    for (int offset = 0; offset < 12; offset++) {
        worst = std::max(worst, run(offset, true, &b, &a));
        worstTwoCall = std::max(worstTwoCall, run(offset, false, &b, &a));
    }
    std::printf("    4 kHz probe: before %.2f dB, after %.2f dB\n", b, a);
    std::printf("    worst excursion, one call: %.3f dB; two calls: %.3f dB\n",
                worst, worstTwoCall);
    CHECK_NEAR(b, 0.0, 0.5);
    CHECK_NEAR(a, 0.0, 0.5);
    CHECK(worst <= 0.5);
    CHECK(worstTwoCall > 0.5);  // negative control: the old way does lift it
}

static void graphic_layout_gains_null_keeps_gains() {
    std::printf("graphic_layout_gains_null_keeps_gains\n");
    GraphicEQ eq;
    eq.init(48000.0f);
    eq.setBandGain(3, 4.0f);
    float g[15] = {0};
    g[1] = 99.0f;  // clamped like any other gain
    eq.setLayout(kIso15, 15, g);
    CHECK_NEAR(eq.effectiveGainDb(3), 0.0, 1e-6);
    CHECK_NEAR(eq.effectiveGainDb(1), 15.0, 1e-6);
    eq.setLayout(kIso15, 15);  // no gains: kept
    CHECK_NEAR(eq.effectiveGainDb(1), 15.0, 1e-6);
}

static void graphic_band_on_without_click() {
    std::printf("graphic_band_on_without_click\n");
    const float ref = SettledBoost(0).steadyStep;  // the boosted wave's own slope
    const std::vector<float> oct = octaveLayout();
    float worst = 0.0f;
    for (int offset = 0; offset < 48; offset++) {
        GraphicEQ eq;
        eq.init(48000.0f);
        eq.setLayout(oct.data(), 10);
        Sine sine(1000.0, 0.1);
        std::vector<float> l, r;
        sine.fill(l, r, 4800 + offset);
        eq.process(l.data(), r.data(), 4800 + offset);
        const float prev = l.back();
        eq.setBandGain(5, 12.0f);
        sine.fill(l, r, 512);
        eq.process(l.data(), r.data(), 512);
        worst = std::max(worst, SettledBoost::joinedStep(prev, l) / ref);
    }
    std::printf("    worst step when the band comes on, 48 phases: x%.3f\n", worst);
    CHECK(worst <= 1.1f);
}

// Dragging a bass band's gain must not drop its ring-out: the level of a
// 62.5 Hz probe moves from the old level to the new one without dipping
// outside them, one cycle (768 frames) at a time.
static void graphic_gain_drag_keeps_bass_level() {
    std::printf("graphic_gain_drag_keeps_bass_level\n");
    const std::vector<float> oct = octaveLayout();  // index 1 = 62.5 Hz
    double worstDev = 0.0;
    for (int offset = 0; offset < 768; offset += 96) {
        GraphicEQ eq;
        eq.init(48000.0f);
        eq.setLayout(oct.data(), 10);
        eq.setBandGain(1, 12.0f);
        Sine sine(62.5, 0.1);
        std::vector<float> l, r;
        sine.fill(l, r, 48000 + offset);
        eq.process(l.data(), r.data(), 48000 + offset);
        sine.fill(l, r, 768);
        eq.process(l.data(), r.data(), 768);
        const double before = toDb(peakOf(l) / 0.1);
        eq.setBandGain(1, 9.0f);
        std::vector<double> levels;
        for (int w = 0; w < 40; w++) {
            sine.fill(l, r, 768);
            eq.process(l.data(), r.data(), 768);
            levels.push_back(toDb(peakOf(l) / 0.1));
        }
        const double after = levels.back();
        for (double d : levels) {
            worstDev = std::max(worstDev, std::min(before, after) - d);
            worstDev = std::max(worstDev, d - std::max(before, after));
        }
        if (offset == 0) {
            CHECK_NEAR(before, 12.0, 0.3);
            CHECK_NEAR(after, 9.0, 0.3);
        }
    }
    std::printf("    worst excursion outside [before, after]: %.3f dB\n", worstDev);
    CHECK(worstDev <= 0.3);
}

static void graphic_gain_clamped() {
    std::printf("graphic_gain_clamped\n");
    GraphicEQ eq;
    eq.init(48000.0f);
    eq.setBandGain(0, 20.0f);
    CHECK_NEAR(eq.effectiveGainDb(0), 15.0, 1e-6);
    eq.setBandGain(0, -20.0f);
    CHECK_NEAR(eq.effectiveGainDb(0), -15.0, 1e-6);
    // Out-of-range bands are ignored.
    eq.setBandGain(-1, 5.0f);
    eq.setBandGain(32, 5.0f);
    eq.setBandGain(99, 5.0f);
    CHECK_NEAR(eq.effectiveGainDb(31), 0.0, 1e-6);
    CHECK_NEAR(eq.effectiveGainDb(99), 0.0, 1e-6);
}

static void graphic_gain_scale() {
    std::printf("graphic_gain_scale\n");
    GraphicEQ eq;
    eq.init(48000.0f);
    const std::vector<float> oct = octaveLayout();
    eq.setLayout(oct.data(), 10);
    eq.setBandGain(5, 12.0f);
    CHECK_NEAR(eq.effectiveGainDb(5), 12.0, 1e-6);
    eq.setGainScale(0.5f);
    CHECK_NEAR(eq.effectiveGainDb(5), 6.0, 1e-6);
    CHECK_NEAR(measureDb(eq, 1000.0), 6.0, 0.3);
    eq.setGainScale(1.0f);
    CHECK_NEAR(eq.effectiveGainDb(5), 12.0, 1e-6);
    // The factor is clamped to 0..1.
    eq.setGainScale(3.0f);
    CHECK_NEAR(eq.effectiveGainDb(5), 12.0, 1e-6);
    eq.setGainScale(-1.0f);
    CHECK_NEAR(eq.effectiveGainDb(5), 0.0, 1e-6);
}

// A band reactivated while it drains must stay on (the audio-side drain end
// only turns off a band that is still draining).
static void graphic_reactivation_during_drain_is_kept() {
    std::printf("graphic_reactivation_during_drain_is_kept\n");
    GraphicEQ eq;
    eq.init(48000.0f);
    const std::vector<float> oct = octaveLayout();
    eq.setLayout(oct.data(), 10);
    eq.setBandGain(5, 12.0f);
    Sine s(1000.0, 0.1);
    std::vector<float> l, r;
    for (int round = 0; round < 8; round++) {
        s.fill(l, r, 4800);
        eq.process(l.data(), r.data(), 4800);
        eq.setBandGain(5, 0.0f);
        s.fill(l, r, 60);   // part-way through the drain ...
        eq.process(l.data(), r.data(), 60);
        eq.setBandGain(5, 12.0f);  // ... and back on
    }
    CHECK_NEAR(measureDb(eq, 1000.0), 12.0, 0.3);
}

static void graphic_init_keeps_layout_and_gains() {
    std::printf("graphic_init_keeps_layout_and_gains\n");
    GraphicEQ eq;
    eq.init(48000.0f);
    eq.setLayout(kIso15, 15);
    eq.setBandGain(8, 12.0f);
    eq.init(44100.0f);
    CHECK(eq.bandCount() == 15);
    CHECK_NEAR(eq.centreHz(8), 1000.0, 1e-3);
    CHECK_NEAR(eq.effectiveGainDb(8), 12.0, 1e-6);
    // Coefficients are live immediately at the new rate (no fade-in).
    Sine s(1000.0, 0.1, 44100.0);
    std::vector<float> l, r;
    s.fill(l, r, 4410);
    eq.process(l.data(), r.data(), 4410);
    s.fill(l, r, 4410);
    eq.process(l.data(), r.data(), 4410);
    CHECK_NEAR(toDb(peakOf(l) / 0.1), 12.0, 0.3);
}

static void graphic_band_near_nyquist_bypassed() {
    std::printf("graphic_band_near_nyquist_bypassed\n");
    // A band whose centre is past 0.45 x the rate is designed at 0.45 x the
    // rate (same Q), not dropped; a band at 0 dB is still bit-exact.
    GraphicEQ eq;
    eq.init(32000.0f);
    const float c[3] = {1000.0f, 4000.0f, 20000.0f};
    eq.setLayout(c, 3);
    std::vector<float> l(2048), r(2048);
    for (int i = 0; i < 2048; i++) {
        l[i] = 0.4f * std::sin(i * 1.7f);
        r[i] = 0.2f * std::sin(i * 0.3f);
    }
    std::vector<float> l0 = l, r0 = r;
    eq.process(l.data(), r.data(), 2048);
    CHECK(std::memcmp(l.data(), l0.data(), 2048 * sizeof(float)) == 0);  // 0 dB: untouched
    CHECK(std::memcmp(r.data(), r0.data(), 2048 * sizeof(float)) == 0);
    eq.setBandGain(2, 12.0f);
    // 14.4 kHz = 0.45 x 32 kHz: the clamped band peaks there.
    CHECK_NEAR(measureDb(eq, 14400.0, 32000.0), 12.0, 0.5);
    CHECK(eq.lowestActiveCentreHz() <= 14400.0f + 1e-3f);
}

// A legacy 5-band user's top band (20 kHz, Q about 0.51) at 44.1 kHz was
// bypassed (20 kHz is past 0.45 x 44.1 kHz); old, it boosted 6.3-20 kHz.
static void graphic_top_band_past_limit_still_works() {
    std::printf("graphic_top_band_past_limit_still_works\n");
    const float c[5] = {20.0f, 112.0f, 632.0f, 3557.0f, 20000.0f};
    for (float fs : {44100.0f, 48000.0f}) {
        GraphicEQ eq;
        eq.init(fs);
        eq.setLayout(c, 5);
        eq.setBandGain(4, 6.0f);
        const double at16k = measureDb(eq, 16000.0, fs);
        std::printf("    %.0f Hz rate: +6 dB top band reads %+.2f dB at 16 kHz\n", fs, at16k);
        // The band does its job where it used to be bypassed (44.1 kHz), and
        // the two rates agree within the warping of a band that close to
        // Nyquist (the same filter at 48 kHz, where it was never bypassed, reads
        // +3.25 dB; the old, dropped 44.1 kHz band read 0).
        CHECK(at16k >= 2.0);
        // Smooth up to Nyquist: no spike or step at the clamp frequency.
        double prev = measureDb(eq, 12000.0, fs), peak = prev, step = 0.0;
        for (double f = 12500.0; f <= 0.47 * fs; f += 500.0) {
            const double g = measureDb(eq, f, fs);
            step = std::max(step, std::fabs(g - prev));
            peak = std::max(peak, g);
            prev = g;
        }
        CHECK(peak <= 6.3);
        CHECK(step <= 1.2);
        // The other bands are not disturbed.
        CHECK_NEAR(measureDb(eq, 632.0, fs), 0.0, 0.3);
    }
}

static void engine_default_layout_is_legacy_32() {
    std::printf("engine_default_layout_is_legacy_32\n");
    RoomDSPEngine e;
    CHECK(e.graphicBandCount() == 32);
    CHECK_NEAR(e.graphicCentreHz(30), 18000.0, 1e-3);
    e.init(48000, 2);
    CHECK(e.graphicBandCount() == 32);
    CHECK_NEAR(e.graphicCentreHz(17), 1000.0, 1e-3);
}

static void engine_layout_survives_init() {
    std::printf("engine_layout_survives_init\n");
    RoomDSPEngine e;
    e.setGraphicLayout(kIso15, 15);
    e.setGraphicBandGain(8, 6.0f);
    e.init(44100, 2);
    CHECK(e.graphicBandCount() == 15);
    CHECK_NEAR(e.graphicCentreHz(8), 1000.0, 1e-3);
    CHECK_NEAR(e.graphicEffectiveGainDb(8), 6.0, 1e-6);
    e.reset();
    CHECK(e.graphicBandCount() == 15);
    CHECK_NEAR(e.graphicCentreHz(8), 1000.0, 1e-3);
}

static void engine_graphic_path_boosts() {
    std::printf("engine_graphic_path_boosts\n");
    RoomDSPEngine e;
    e.init(48000, 2);
    const std::vector<float> oct = octaveLayout();
    e.setGraphicLayout(oct.data(), 10);
    e.setGraphicBandGain(5, 12.0f);
    e.setEqEnabled(true);
    Sine s(1000.0, 0.1);
    std::vector<float> l, r;
    std::vector<float> buf(2 * 4800);
    float peak = 0.0f;
    for (int pass = 0; pass < 3; pass++) {
        s.fill(l, r, 4800);
        for (int i = 0; i < 4800; i++) {
            buf[2 * i] = l[i];
            buf[2 * i + 1] = r[i];
        }
        e.process(buf.data(), 4800);
        peak = 0.0f;
        for (int i = 0; i < 4800; i++) peak = std::max(peak, std::fabs(buf[2 * i]));
    }
    CHECK_NEAR(toDb(peak / 0.1), 12.0, 0.3);
}

// ---- bass: the fade must be long enough for low tones ----

// Click energy: the output through a 4th-order 300 Hz high-pass. A pure bass
// sine leaves almost nothing there, so what the high-pass passes around a
// change is the artefact (a step in the bass tone). dB re the 0.1 input.
static double hpPeakDb(const std::vector<float>& y, int from, int to) {
    Biquad h1, h2;
    const BiquadCoeffs c = BiquadDesign::highPass(48000.0f, 300.0f, 0.7071f);
    h1.setCoefficientsImmediate(c);
    h2.setCoefficientsImmediate(c);
    std::vector<float> a = y, b = y;
    h1.process(a.data(), b.data(), (int)a.size());
    std::vector<float> a2 = a, b2 = a;
    h2.process(a2.data(), b2.data(), (int)a2.size());
    double p = 0;
    for (int i = from; i < to; i++) p = std::max(p, (double)std::fabs(a2[i]));
    return toDb(std::max(p, 1e-12) / 0.1);
}

using EqFn = std::function<void(GraphicEQ&)>;

// Worst high-pass peak over 48 signal phases for a change applied at a block
// boundary (256-frame blocks) after the EQ has settled.
static double bassChangeWorstDb(double f, const EqFn& setup, const EqFn& change) {
    const int period = (int)std::lround(48000.0 / f);
    double worst = -1e9;
    for (int k = 0; k < 48; k++) {
        GraphicEQ eq;
        eq.init(48000.0f);
        setup(eq);
        const int pre = 96000 + k * period / 48, post = 24000;
        std::vector<float> y(pre + post), r;
        for (size_t i = 0; i < y.size(); i++)
            y[i] = (float)(0.1 * std::sin(2.0 * kPi * f * (double)i / 48000.0));
        const int at = (pre / 256) * 256;
        for (int p = 0; p < (int)y.size(); p += 256) {
            if (p == at) change(eq);
            const int n = std::min(256, (int)y.size() - p);
            r.assign(y.begin() + p, y.begin() + p + n);
            eq.process(&y[p], r.data(), n);
        }
        worst = std::max(worst, hpPeakDb(y, at, pre + post));
    }
    return worst;
}

static const float kIso10[10] = {31.5f, 63.0f, 125.0f, 250.0f, 500.0f,
                                 1000.0f, 2000.0f, 4000.0f, 8000.0f, 16000.0f};

static void graphic_bass_changes_do_not_step() {
    std::printf("graphic_bass_changes_do_not_step\n");
    const EqFn flat = [](GraphicEQ& e) { e.setLayout(kIso10, 10); };
    const EqFn bass = [](GraphicEQ& e) {
        const float g[10] = {9, 6, 3};
        e.setLayout(kIso10, 10, g);
    };
    struct Case {
        const char* name;
        EqFn setup, change;
    };
    const Case cases[] = {
        {"bass preset -> flat", bass,
         [](GraphicEQ& e) { const float g[10] = {0}; e.setAllGains(g, 10); }},
        {"flat -> bass preset", flat,
         [](GraphicEQ& e) { const float g[10] = {9, 6, 3}; e.setAllGains(g, 10); }},
        {"31.5 Hz band 0 -> +12", flat, [](GraphicEQ& e) { e.setBandGain(0, 12.0f); }},
        {"gain scale 1 -> 0 on the bass preset", bass,
         [](GraphicEQ& e) { e.setGainScale(0.0f); }},
    };
    for (const Case& c : cases) {
        for (double f : {40.0, 60.0}) {
            const double db = bassChangeWorstDb(f, c.setup, c.change);
            std::printf("    %-38s %2.0f Hz: high-pass residual %6.1f dB\n", c.name, f, db);
            CHECK(db <= -36.0);
        }
    }
    // Negative control: switching one filter's coefficients with no blend, the
    // same measurement, lands far above the limit.
    const BiquadCoeffs pk = BiquadDesign::peaking(48000.0f, 31.5f, 12.0f, 1.41421f);
    double worstHard = -1e9;
    for (int k = 0; k < 48; k++) {
        Biquad q;
        q.setCoefficientsImmediate(pk);
        const int pre = 96000 + k * 1200 / 48, post = 24000;
        std::vector<float> y(pre + post), r;
        for (size_t i = 0; i < y.size(); i++)
            y[i] = (float)(0.1 * std::sin(2.0 * kPi * 40.0 * (double)i / 48000.0));
        const int at = (pre / 256) * 256;
        for (int p = 0; p < (int)y.size(); p += 256) {
            if (p == at) q.setCoefficientsImmediate(BiquadCoeffs::bypass());
            const int n = std::min(256, (int)y.size() - p);
            r.assign(y.begin() + p, y.begin() + p + n);
            q.process(&y[p], r.data(), n);
        }
        worstHard = std::max(worstHard, hpPeakDb(y, at, pre + post));
    }
    std::printf("    negative control, hard coefficient switch: %.1f dB\n", worstHard);
    CHECK(worstHard > -30.0);
}

// ---- init() while audio runs ----

static void graphic_init_during_process_is_safe() {
    std::printf("graphic_init_during_process_is_safe\n");
    GraphicEQ eq;
    eq.init(48000.0f);
    std::atomic<bool> stop{false};
    std::atomic<long> blocks{0}, bad{0};
    std::thread audio([&] {
        std::vector<float> l(64), r(64);
        while (!stop.load()) {
            for (int k = 0; k < 64; k++) l[k] = r[k] = 0.1f * std::sin(k * 0.3f);
            eq.process(l.data(), r.data(), 64);
            for (int k = 0; k < 64; k++) {
                if (!std::isfinite(l[k]) || std::fabs(l[k]) > 10.0f ||
                    !std::isfinite(r[k])) {
                    bad++;
                    break;
                }
            }
            blocks++;
        }
    });
    std::thread control([&] {
        int i = 0;
        float g[15];
        while (!stop.load()) {
            eq.setBandGain(i % 32, (i % 2) ? 6.0f : 0.0f);
            if (i % 50 == 0) {
                for (int k = 0; k < 15; k++) g[k] = (float)((i / 50 + k) % 7) - 3.0f;
                eq.setLayout(kIso15, 15, g);
            }
            if (i % 70 == 0) eq.setGainScale((i / 70) % 2 ? 1.0f : 0.5f);
            i++;
        }
    });
    std::thread prepare([&] {
        int i = 0;
        while (!stop.load()) eq.init((i++ % 2) ? 44100.0f : 48000.0f);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(700));
    stop.store(true);
    audio.join();
    control.join();
    prepare.join();
    std::printf("    %ld blocks, %ld bad\n", blocks.load(), bad.load());
    CHECK(blocks.load() > 100);
    CHECK(bad.load() == 0);
}

// init() with no concurrent process() takes effect on the very next call:
// state cleared, coefficients at the new rate live at once, the Nyquist bypass
// re-evaluated, layout and gains kept.
static void graphic_init_applies_on_next_process() {
    std::printf("graphic_init_applies_on_next_process\n");
    {  // new rate puts the 16 kHz band past 0.45 x rate: designed at the limit
        GraphicEQ eq;
        eq.init(48000.0f);
        eq.setLayout(kIso15, 15);
        eq.setBandGain(14, 12.0f);
        std::vector<float> l(2048), r(2048);
        for (int i = 0; i < 2048; i++) l[i] = r[i] = 0.1f * std::sin(i * 2.0f);
        std::vector<float> l0 = l;
        eq.process(l.data(), r.data(), 2048);
        CHECK(std::memcmp(l.data(), l0.data(), sizeof(float) * 2048) != 0);  // active at 48 kHz
        eq.init(32000.0f);
        l = l0;
        r = l0;
        eq.process(l.data(), r.data(), 2048);
        CHECK(std::memcmp(l.data(), l0.data(), sizeof(float) * 2048) != 0);  // still active, at 0.45 x rate
        CHECK(eq.bandCount() == 15);
        CHECK_NEAR(eq.effectiveGainDb(14), 12.0, 1e-6);
    }
    {  // and back: live again at once (no fade-in), at the new rate
        GraphicEQ eq;
        eq.init(32000.0f);
        eq.setLayout(kIso15, 15);
        eq.setBandGain(8, 12.0f);
        std::vector<float> a(64, 0.0f), b(64, 0.0f);
        eq.process(a.data(), b.data(), 64);
        eq.init(44100.0f);
        Sine sn(1000.0, 0.1, 44100.0);
        std::vector<float> l, r;
        sn.fill(l, r, 4410);
        eq.process(l.data(), r.data(), 4410);
        sn.fill(l, r, 4410);
        eq.process(l.data(), r.data(), 4410);
        CHECK_NEAR(toDb(peakOf(l) / 0.1), 12.0, 0.4);
    }
}

// ---- EQ on/off toggle: a faded transition, no hard switch ----

// Streams a sine through the whole engine in 256-frame blocks. `phase` is the
// sine's starting phase in radians. `atBlock(frameIndex)` runs before each
// block (on the control side), so a setter lands on a block boundary. Returns
// the left channel.
static std::vector<float> engineStream(RoomDSPEngine& e, double f, double phase,
                                       int total,
                                       const std::function<void(int)>& atBlock) {
    std::vector<float> out(total);
    std::vector<float> buf(2 * 256);
    for (int p = 0; p < total; p += 256) {
        if (atBlock) atBlock(p);
        const int n = std::min(256, total - p);
        for (int i = 0; i < n; i++) {
            const float x = (float)(0.1 * std::sin(2.0 * kPi * f * (double)(p + i) / 48000.0 + phase));
            buf[2 * i] = buf[2 * i + 1] = x;
        }
        e.process(buf.data(), n);
        for (int i = 0; i < n; i++) out[p + i] = buf[2 * i];
    }
    return out;
}

static void engineBandBoost(RoomDSPEngine& e, int band, float db) {
    const std::vector<float> oct = octaveLayout();
    e.setGraphicLayout(oct.data(), 10);
    e.setGraphicBandGain(band, db);
}

// Toggle schedule (frames): settled until kOffAt, EQ off until kOnAt, then on.
static const int kOffAt = 94 * 256;           // 24064
static const int kOnAt = kOffAt + 47 * 256;   // 36096
static const int kToggleTotal = kOnAt + 94 * 256;

static void engine_eq_toggle_1k_without_click() {
    std::printf("engine_eq_toggle_1k_without_click\n");
    // Steady-state step of the +12 dB sine, for reference.
    float steady = 0.0f;
    {
        RoomDSPEngine e;
        e.init(48000, 2);
        engineBandBoost(e, 5, 12.0f);
        e.setEqEnabled(true);
        const std::vector<float> y = engineStream(e, 1000.0, 0.0, 12000, nullptr);
        steady = maxStep(std::vector<float>(y.begin() + 6000, y.end()));
    }
    float worstOff = 0.0f, worstOn = 0.0f;
    double exactErr = 0.0, onDb = 0.0;
    for (int k = 0; k < 48; k++) {
        const double phase = 2.0 * kPi * k / 48.0;
        RoomDSPEngine e;
        e.init(48000, 2);
        engineBandBoost(e, 5, 12.0f);
        e.setEqEnabled(true);
        const std::vector<float> y = engineStream(e, 1000.0, phase, kToggleTotal,
            [&](int p) {
                if (p == kOffAt) e.setEqEnabled(false);
                if (p == kOnAt) e.setEqEnabled(true);
            });
        worstOff = std::max(worstOff, maxStep(std::vector<float>(y.begin() + kOffAt - 1, y.begin() + kOnAt)));
        worstOn = std::max(worstOn, maxStep(std::vector<float>(y.begin() + kOnAt - 1, y.end())));
        // Bypassed again: the dry input, bit for bit (checked late in the off span).
        for (int i = kOnAt - 2048; i < kOnAt; i++) {
            const float x = (float)(0.1 * std::sin(2.0 * kPi * 1000.0 * (double)i / 48000.0 + phase));
            exactErr = std::max(exactErr, (double)std::fabs(y[i] - x));
        }
        onDb = std::max(onDb, std::fabs(toDb(peakOf(std::vector<float>(y.end() - 4800, y.end())) / 0.1) - 12.0));
    }
    std::printf("    steady step %.5f  off worst %.5f (x%.2f)  on worst %.5f (x%.2f)\n",
                steady, worstOff, worstOff / steady, worstOn, worstOn / steady);
    CHECK(steady > 0.04f);
    CHECK(worstOff <= 1.1f * steady);
    CHECK(worstOn <= 1.1f * steady);
    CHECK(exactErr == 0.0);
    CHECK(onDb < 0.3);
}

static void engine_eq_toggle_bass_without_click() {
    std::printf("engine_eq_toggle_bass_without_click\n");
    double worst = -1e9;
    for (int k = 0; k < 48; k++) {
        const double phase = 2.0 * kPi * k / 48.0;
        RoomDSPEngine e;
        e.init(48000, 2);
        engineBandBoost(e, 0, 12.0f);  // 31.25 Hz
        e.setEqEnabled(true);
        const std::vector<float> y = engineStream(e, 40.0, phase, kToggleTotal,
            [&](int p) {
                if (p == kOffAt) e.setEqEnabled(false);
                if (p == kOnAt) e.setEqEnabled(true);
            });
        worst = std::max(worst, hpPeakDb(y, kOffAt, kToggleTotal));
    }
    std::printf("    40 Hz toggle off and on: high-pass residual %.1f dB\n", worst);
    CHECK(worst <= -36.0);
}

static void engine_parametric_toggle_without_click() {
    std::printf("engine_parametric_toggle_without_click\n");
    double worst = -1e9;
    for (int k = 0; k < 48; k++) {
        const double phase = 2.0 * kPi * k / 48.0;
        RoomDSPEngine e;
        e.init(48000, 2);
        e.setParametricBand(0, 40.0f, 12.0f, 1.0f, 0, true);
        e.setEqEnabled(true);
        const std::vector<float> y = engineStream(e, 40.0, phase, kToggleTotal,
            [&](int p) {
                if (p == kOffAt) e.setEqEnabled(false);
                if (p == kOnAt) e.setEqEnabled(true);
            });
        worst = std::max(worst, hpPeakDb(y, kOffAt, kToggleTotal));
        // Fully on at the end, fully off (dry) in between.
        CHECK(toDb(peakOf(std::vector<float>(y.end() - 4800, y.end())) / 0.1) > 8.0);
        float dryErr = 0.0f;
        for (int i = kOnAt - 2048; i < kOnAt; i++) {
            const float x = (float)(0.1 * std::sin(2.0 * kPi * 40.0 * (double)i / 48000.0 + phase));
            dryErr = std::max(dryErr, std::fabs(y[i] - x));
        }
        CHECK(dryErr == 0.0f);
    }
    std::printf("    parametric 40 Hz toggle: high-pass residual %.1f dB\n", worst);
    CHECK(worst <= -36.0);
}

// ---- Task 6: smooth equalizer / tone gains ----

static void smooth_scales_follow_the_rule() {
    std::printf("smooth_scales_follow_the_rule\n");
    for (float t : {-40.0f, 0.0f, 6.0f}) {
        const SmoothScales off = smoothGainScales(t, false);
        CHECK_NEAR(off.eqDb, 15.0, 1e-3);
        CHECK_NEAR(off.bassDb, 22.5, 1e-3);
    }
    struct Row { float t, eq, bass; };
    const Row rows[] = {
        {0.0f, 12.5, 15.0},      {-2.9f, 14.9167, 17.175}, {-3.0f, 15.0, 17.25},
        {-7.9f, 15.0, 20.925},   {-8.0f, 15.0, 22.5},      {6.0f, 7.5, 10.5},
        {24.0f, 0.0, 0.0},
    };
    for (const Row& r : rows) {
        const SmoothScales s = smoothGainScales(r.t, true);
        CHECK_NEAR(s.eqDb, r.eq, 1e-3);
        CHECK_NEAR(s.bassDb, r.bass, 1e-3);
    }
}

static void smooth_scales_floor_at_zero() {
    std::printf("smooth_scales_floor_at_zero\n");
    // Past the point where the literal rule would invert the curve, the boost
    // is gone, never a cut; and it only ever shrinks as the level rises.
    SmoothScales prev = smoothGainScales(-60.0f, true);
    for (float t = -59.5f; t <= 60.0f; t += 0.5f) {
        const SmoothScales s = smoothGainScales(t, true);
        CHECK(s.eqDb >= 0.0f && s.bassDb >= 0.0f);
        CHECK(s.eqDb <= prev.eqDb + 1e-6f);
        CHECK(s.bassDb <= prev.bassDb + 1e-6f);
        prev = s;
    }
    CHECK_NEAR(smoothGainScales(16.0f, true).eqDb, 0.0, 1e-6);
    CHECK_NEAR(smoothGainScales(21.0f, true).bassDb, 0.0, 1e-6);
    // Non-finite input counts as "off".
    CHECK_NEAR(smoothGainScales(NAN, true).eqDb, 15.0, 1e-6);
}

// Engine with the 10-octave layout, band 5 (1 kHz) at +12 dB, EQ on.
static void smoothEngine(RoomDSPEngine& e, bool smooth) {
    e.init(48000, 2);
    engineBandBoost(e, 5, 12.0f);
    e.setSmoothGains(smooth);
    e.setEqEnabled(true);
}

static void engine_scales_band_with_volume() {
    std::printf("engine_scales_band_with_volume\n");
    RoomDSPEngine e;
    smoothEngine(e, true);
    // Straight from the setters, no process() call in between.
    CHECK_NEAR(e.graphicEffectiveGainDb(5), 10.0, 1e-4);
    e.setSystemVolumeDb(-10.0f);
    CHECK_NEAR(e.graphicEffectiveGainDb(5), 12.0, 1e-4);
    e.setSystemVolumeDb(0.0f);
    CHECK_NEAR(e.graphicEffectiveGainDb(5), 10.0, 1e-4);
    // The setting off: the stored gain, at any level.
    RoomDSPEngine off;
    smoothEngine(off, false);
    CHECK_NEAR(off.graphicEffectiveGainDb(5), 12.0, 1e-4);
    // What reaches the audio: a 1 kHz sine through the whole engine.
    const std::vector<float> y = engineStream(e, 1000.0, 0.0, 12000, nullptr);
    CHECK_NEAR(toDb(peakOf(std::vector<float>(y.end() - 4800, y.end())) / 0.1), 10.0, 0.3);
    e.setSystemVolumeDb(-10.0f);
    const std::vector<float> y2 = engineStream(e, 1000.0, 0.0, 12000, nullptr);
    CHECK_NEAR(toDb(peakOf(std::vector<float>(y2.end() - 4800, y2.end())) / 0.1), 12.0, 0.3);
    // Each setter that moves T rescales: preamp, master, headroom.
    RoomDSPEngine m;
    smoothEngine(m, true);
    m.setHeadroomDb(-6.0f);  // T = -6: nothing withdrawn
    CHECK_NEAR(m.graphicEffectiveGainDb(5), 12.0, 1e-4);
    m.setHeadroomDb(0.0f);
    m.setPreampGain(6.0f);  // T = +6: 12 x 7.5 / 15
    CHECK_NEAR(m.graphicEffectiveGainDb(5), 6.0, 1e-4);
}

static void t_counts_preamp_only_while_applied() {
    std::printf("t_counts_preamp_only_while_applied\n");
    RoomDSPEngine e;
    e.init(48000, 2);
    e.setPreampGain(6.0f);
    e.setHeadroomDb(-6.0f);
    e.setEqEnabled(true);
    CHECK_NEAR(e.smoothLevelDb(), 0.0, 1e-5);
    e.setEqEnabled(false);
    CHECK_NEAR(e.smoothLevelDb(), -6.0, 1e-5);
    e.setSpeakerEqEnabled(true);  // the speaker EQ applies the preamp too
    CHECK_NEAR(e.smoothLevelDb(), 0.0, 1e-5);
    e.setSpeakerEqEnabled(false);
    CHECK_NEAR(e.smoothLevelDb(), -6.0, 1e-5);
    // The speaker-profile preamp and the track gain are not part of T.
    e.setSpeakerPreampDb(5.0f);
    e.setTrackGainDb(-8.0f);
    CHECK_NEAR(e.smoothLevelDb(), -6.0, 1e-5);
}

static void t_counts_master_volume() {
    std::printf("t_counts_master_volume\n");
    RoomDSPEngine e;
    smoothEngine(e, true);
    e.setMasterVolumeDb(-2.0f);
    CHECK_NEAR(e.smoothLevelDb(), -2.0, 1e-5);
    CHECK_NEAR(e.smoothScales().eqDb, 14.1667, 1e-3);
    e.setSystemVolumeDb(-1.0f);
    CHECK_NEAR(e.smoothLevelDb(), -3.0, 1e-5);
    CHECK_NEAR(e.smoothScales().eqDb, 15.0, 1e-3);
    // The system volume is clamped to -96..0.
    e.setSystemVolumeDb(-200.0f);
    CHECK_NEAR(e.smoothLevelDb(), -98.0, 1e-5);
    e.setSystemVolumeDb(5.0f);
    CHECK_NEAR(e.smoothLevelDb(), -2.0, 1e-5);
}

static void tone_bass_range() {
    std::printf("tone_bass_range\n");
    ToneControls t;
    t.init(48000.0f);
    t.setBassGain(30.0f);
    CHECK_NEAR(t.getBassGain(), 22.5, 1e-6);
    t.setBassGain(-3.0f);
    CHECK_NEAR(t.getBassGain(), 0.0, 1e-6);
    t.setTrebleGain(20.0f);
    CHECK_NEAR(t.getTrebleGain(), 15.0, 1e-6);
    t.setBassFreq(10.0f);
    CHECK_NEAR(t.getBassFreq(), 20.0, 1e-6);
    t.setBassFreq(500.0f);
    CHECK_NEAR(t.getBassFreq(), 250.0, 1e-6);
    t.setTrebleFreq(1000.0f);
    CHECK_NEAR(t.getTrebleFreq(), 5000.0, 1e-6);
    t.setTrebleFreq(20000.0f);
    CHECK_NEAR(t.getTrebleFreq(), 15000.0, 1e-6);
    t.setBassQ(4.0f);
    CHECK_NEAR(t.getBassQ(), 2.0, 1e-6);
    // Through the engine at T = 0 with smoothing on.
    RoomDSPEngine e;
    e.init(48000, 2);
    e.setSmoothGains(true);
    e.setBassGain(30.0f);
    e.setTrebleGain(20.0f);
    CHECK_NEAR(e.toneBassGainDb(), 22.5, 1e-6);
    CHECK_NEAR(e.toneEffectiveBassGainDb(), 15.0, 1e-4);
    CHECK_NEAR(e.toneEffectiveTrebleGainDb(), 12.5, 1e-4);
    e.setSystemVolumeDb(-10.0f);  // T = -10: the stored gains play as set
    CHECK_NEAR(e.toneEffectiveBassGainDb(), 22.5, 1e-4);
    CHECK_NEAR(e.toneEffectiveTrebleGainDb(), 15.0, 1e-4);
    // Smoothing off: the stored gains at any level.
    e.setSystemVolumeDb(0.0f);
    e.setSmoothGains(false);
    CHECK_NEAR(e.toneEffectiveBassGainDb(), 22.5, 1e-4);
}

static void tone_scale_shapes_the_audio() {
    std::printf("tone_scale_shapes_the_audio\n");
    // A 30 Hz sine through a 12 dB bass shelf at 250 Hz plays about 12 dB up
    // at scale 1 and about 6 dB up at scale 0.5.
    auto level = [](float factor) {
        ToneControls t;
        t.init(48000.0f);
        t.setEnabled(true);
        t.setBassFreq(250.0f);
        t.setBassGain(12.0f);
        t.setGainScale(factor, 1.0f);
        Sine s(30.0, 0.1);
        std::vector<float> l, r;
        for (int pass = 0; pass < 4; pass++) {
            s.fill(l, r, 9600);
            t.process(l.data(), r.data(), 9600);
        }
        return toDb(peakOf(l) / 0.1);
    };
    const double full = level(1.0f), half = level(0.5f), none = level(0.0f);
    std::printf("    bass shelf at 30 Hz: scale 1 %.2f dB, 0.5 %.2f dB, 0 %.2f dB\n",
                full, half, none);
    CHECK(full > 11.0 && full < 12.2);
    CHECK_NEAR(half, full / 2.0, 0.4);
    CHECK_NEAR(none, 0.0, 0.01);
}

static void scale_change_without_click() {
    std::printf("scale_change_without_click\n");
    RoomDSPEngine ref;
    smoothEngine(ref, true);
    ref.setSystemVolumeDb(-10.0f);  // 12 dB band, scale 1
    const std::vector<float> steadyY = engineStream(ref, 1000.0, 0.0, 12000, nullptr);
    const float steady = maxStep(std::vector<float>(steadyY.begin() + 6000, steadyY.end()));
    float worst = 0.0f;
    for (int k = 0; k < 48; k++) {
        RoomDSPEngine e;
        smoothEngine(e, true);
        e.setSystemVolumeDb(-10.0f);
        const std::vector<float> y = engineStream(e, 1000.0, 2.0 * kPi * k / 48.0, 24064,
            [&](int p) { if (p == 12032) e.setSystemVolumeDb(0.0f); });
        worst = std::max(worst, maxStep(std::vector<float>(y.begin() + 12031, y.end())));
        CHECK_NEAR(toDb(peakOf(std::vector<float>(y.end() - 4800, y.end())) / 0.1), 10.0, 0.3);
    }
    std::printf("    steady step %.5f  worst across the change %.5f (x%.2f)\n",
                steady, worst, worst / steady);
    CHECK(worst <= 1.1f * steady);
}

// ---- fix round 1 ----

// Worst high-pass residual of a 40 Hz sine over 48 phases for the schedule
// `act(engine, frame)`, measured from kOffAt to the end.
static double engineHpWorst(const std::function<void(RoomDSPEngine&)>& setup,
                            const std::function<void(RoomDSPEngine&, int)>& act,
                            int total = kToggleTotal) {
    double worst = -1e9;
    for (int k = 0; k < 48; k++) {
        RoomDSPEngine e;
        e.init(48000, 2);
        setup(e);
        const std::vector<float> y = engineStream(e, 40.0, 2.0 * kPi * k / 48.0, total,
                                                  [&](int p) { act(e, p); });
        worst = std::max(worst, hpPeakDb(y, kOffAt, total));
    }
    return worst;
}

// An EQ switched on after init() or reset() while it was off must fade in
// from flat like any other toggle: the engine used to leave GraphicEQ's
// pending reset to be applied, bands live at once, on the first block after
// the switch.
static void engine_eq_on_after_init_or_reset_is_faded() {
    std::printf("engine_eq_on_after_init_or_reset_is_faded\n");
    for (int which = 0; which < 2; which++) {
        const char* what = which ? "init()" : "reset()";
        const auto recycle = [which](RoomDSPEngine& e, int p) {
            if (p == 40 * 256) {
                if (which) e.init(48000, 2); else e.reset();
            }
        };
        // 40 Hz, +12 dB at 31.25 Hz.
        const double bass = engineHpWorst(
            [](RoomDSPEngine& e) { engineBandBoost(e, 0, 12.0f); },
            [&](RoomDSPEngine& e, int p) {
                recycle(e, p);
                if (p == kOffAt) e.setEqEnabled(true);
            });
        std::printf("    EQ off, %s, then on (40 Hz): high-pass residual %.1f dB\n", what, bass);
        CHECK(bass <= -36.0);
        // 1 kHz, +12 dB: step against the steady state.
        float steady = 0.0f, worst = 0.0f;
        {
            RoomDSPEngine e;
            e.init(48000, 2);
            engineBandBoost(e, 5, 12.0f);
            e.setEqEnabled(true);
            const std::vector<float> y = engineStream(e, 1000.0, 0.0, 12000, nullptr);
            steady = maxStep(std::vector<float>(y.begin() + 6000, y.end()));
        }
        for (int k = 0; k < 48; k++) {
            RoomDSPEngine e;
            e.init(48000, 2);
            engineBandBoost(e, 5, 12.0f);
            const std::vector<float> y = engineStream(e, 1000.0, 2.0 * kPi * k / 48.0,
                kOffAt + 8192, [&](int p) {
                    recycle(e, p);
                    if (p == kOffAt) e.setEqEnabled(true);
                });
            worst = std::max(worst, maxStep(std::vector<float>(y.begin() + kOffAt - 1, y.end())));
        }
        std::printf("    EQ off, %s, then on (1 kHz): step x%.2f of steady\n", what, worst / steady);
        CHECK(worst <= 1.1f * steady);
    }
}

// Peak of |y| over one period of the tone, in dB re `ref`, for windows that
// start at s.
static double windowDb(const std::vector<float>& y, int s, int per, double ref) {
    float m = 0.0f;
    for (int i = s; i < s + per && i < (int)y.size(); i++) m = std::max(m, std::fabs(y[i]));
    return toDb(std::max((double)m, 1e-9) / ref);
}

// A preamp that offsets the EQ's boost must follow the EQ's fade: switching
// the EQ on used to bring the +12 dB band in over 96 frames but the -12 dB
// preamp over 192, a +8.7 dB overshoot; switching it off, the preamp left
// first and the boost swelled.
static void engine_preamp_follows_eq_fade() {
    std::printf("engine_preamp_follows_eq_fade\n");
    for (int on = 0; on < 2; on++) {
        for (double f : {1000.0, 40.0}) {
            const int band = f < 100.0 ? 0 : 5;
            double worstOver = -1e9;  // above the louder end state, in dB
            int clamped = 0;
            for (int k = 0; k < 48; k += 4) {
                RoomDSPEngine e;
                e.init(48000, 2);
                engineBandBoost(e, band, 12.0f);
                e.setPreampGain(-12.0f);
                e.setEqEnabled(!on);
                const int total = kOffAt + 40 * 256;
                // 0.5 amplitude: a transient above the end state clips at 1.0.
                std::vector<float> y(total), buf(512);
                const double phase = 2.0 * kPi * k / 48.0;
                for (int p = 0; p < total; p += 256) {
                    if (p == kOffAt) e.setEqEnabled(on != 0);
                    for (int i = 0; i < 256; i++) {
                        buf[2 * i] = buf[2 * i + 1] =
                            (float)(0.5 * std::sin(2.0 * kPi * f * (double)(p + i) / 48000.0 + phase));
                    }
                    e.process(buf.data(), 256);
                    for (int i = 0; i < 256; i++) y[p + i] = buf[2 * i];
                }
                const int per = (int)std::lround(48000.0 / f);
                const double before = windowDb(y, kOffAt - 2 * per, per, 0.5);
                const double after = windowDb(y, total - per - 1, per, 0.5);
                for (int s = kOffAt; s < total - per; s += std::max(1, per / 8)) {
                    worstOver = std::max(worstOver, windowDb(y, s, per, 0.5) - std::max(before, after));
                }
                for (int i = kOffAt; i < total; i++) if (std::fabs(y[i]) >= 0.999f) clamped++;
            }
            std::printf("    EQ %s at %4.0f Hz: worst level above the end states %+.2f dB, samples at the clamp %d\n",
                        on ? "on " : "off", f, worstOver, clamped);
            CHECK(worstOver <= 1.0);
            CHECK(clamped == 0);
        }
    }
}

// The tone's coefficient changes used to tick in the bass: one 96-sample
// interpolation of a 40 Hz shelf.
static void tone_changes_do_not_tick() {
    std::printf("tone_changes_do_not_tick\n");
    struct Shelf { float hz, q; };
    for (const Shelf& sh : {Shelf{80.0f, 0.707f}, Shelf{90.0f, 0.80f}}) {
        const auto setup = [&](RoomDSPEngine& e) {
            e.setSmoothGains(true);
            e.setToneEnabled(true);
            e.setBassFreq(sh.hz);
            e.setBassQ(sh.q);
            e.setBassGain(15.0f);
        };
        const double up = engineHpWorst(
            [&](RoomDSPEngine& e) { setup(e); e.setSystemVolumeDb(-10.0f); },
            [](RoomDSPEngine& e, int p) { if (p == kOffAt) e.setSystemVolumeDb(0.0f); });
        const double down = engineHpWorst(
            [&](RoomDSPEngine& e) { setup(e); e.setSystemVolumeDb(0.0f); },
            [](RoomDSPEngine& e, int p) { if (p == kOffAt) e.setSystemVolumeDb(-10.0f); });
        std::printf("    bass +15 at %.0f Hz Q%.2f: system volume -10 -> 0 %.1f dB, 0 -> -10 %.1f dB\n",
                    sh.hz, sh.q, up, down);
        CHECK(up <= -36.0);
        CHECK(down <= -36.0);
    }
    const double slider = engineHpWorst(
        [](RoomDSPEngine& e) { e.setToneEnabled(true); e.setBassGain(15.0f); },
        [](RoomDSPEngine& e, int p) { if (p == kOffAt) e.setBassGain(10.0f); });
    std::printf("    bass slider 15 -> 10 dB: %.1f dB\n", slider);
    CHECK(slider <= -36.0);
    // Tone switched off and on again.
    const double toggle = engineHpWorst(
        [](RoomDSPEngine& e) { e.setToneEnabled(true); e.setBassGain(15.0f); },
        [](RoomDSPEngine& e, int p) {
            if (p == kOffAt) e.setToneEnabled(false);
            if (p == kOnAt) e.setToneEnabled(true);
        });
    std::printf("    tone off then on: %.1f dB\n", toggle);
    CHECK(toggle <= -36.0);
    // Treble: the same change at 1 kHz is a step against the steady state.
    {
        auto run = [](const std::function<void(RoomDSPEngine&, int)>& act, float* steadyOut) {
            float worst = 0.0f;
            for (int k = 0; k < 48; k++) {
                RoomDSPEngine e;
                e.init(48000, 2);
                e.setSmoothGains(true);
                e.setToneEnabled(true);
                e.setTrebleFreq(5000.0f);
                e.setTrebleGain(15.0f);
                e.setSystemVolumeDb(-10.0f);
                const std::vector<float> y = engineStream(e, 5000.0, 2.0 * kPi * k / 48.0,
                    kOffAt + 8192, [&](int p) { act(e, p); });
                worst = std::max(worst, maxStep(std::vector<float>(y.begin() + kOffAt - 1, y.end())));
                if (steadyOut) *steadyOut = maxStep(std::vector<float>(y.begin() + 12000, y.begin() + kOffAt - 256));
            }
            return worst;
        };
        float steady = 0.0f;
        const float worst = run([](RoomDSPEngine& e, int p) { if (p == kOffAt) e.setSystemVolumeDb(0.0f); }, &steady);
        std::printf("    treble +15 at 5 kHz, system volume -10 -> 0: step x%.2f of steady\n", worst / steady);
        CHECK(worst <= 1.1f * steady);
    }
}

// The tone switched on after init()/reset() while it was off: the pending
// reset used to be applied at the on edge, bringing the shelves in at once
// (+12 dB at 80 Hz, a 40 Hz tone: -24.2 dB). Every stream starts with init().
static void tone_on_after_init_or_reset_is_faded() {
    std::printf("tone_on_after_init_or_reset_is_faded\n");
    for (int which = 0; which < 3; which++) {
        const char* what = which == 0 ? "init()" : which == 1 ? "reset()" : "nothing";
        const double worst = engineHpWorst(
            [](RoomDSPEngine& e) {
                e.setBassFreq(80.0f);
                e.setBassGain(12.0f);
            },
            [which](RoomDSPEngine& e, int p) {
                if (p == 40 * 256 && which == 0) e.init(48000, 2);
                if (p == 40 * 256 && which == 1) e.reset();
                if (p == kOffAt) e.setToneEnabled(true);
            });
        std::printf("    tone off, %s, then on (40 Hz): high-pass residual %.1f dB\n", what, worst);
        CHECK(worst <= -36.0);
    }
    // Off stays bit-exact: nothing of the tone reaches the audio.
    RoomDSPEngine e;
    e.init(48000, 2);
    e.setBassGain(12.0f);
    e.setTrebleGain(12.0f);
    const std::vector<float> y = engineStream(e, 1000.0, 0.3, 4096, [&](int p) {
        if (p == 1024) e.reset();
    });
    float err = 0.0f;
    for (int i = 0; i < 4096; i++) {
        err = std::max(err, std::fabs(y[i] - (float)(0.1 * std::sin(2.0 * kPi * 1000.0 * (double)i / 48000.0 + 0.3))));
    }
    CHECK(err == 0.0f);
}

// track gain is applied from the render thread at a gapless boundary: it must
// reach the input gain without the level mutex, and agree with the others.
static void track_gain_does_not_take_the_level_mutex() {
    std::printf("track_gain_does_not_take_the_level_mutex\n");
    RoomDSPEngine e;
    e.init(48000, 2);
    // A control thread holds the level mutex for a long time through a flood of
    // level setters while the "render" thread sets the track gain.
    std::atomic<bool> stop{false};
    std::thread ui([&] {
        for (int i = 0; !stop.load(); i++) {
            e.setHeadroomDb(-(float)(i % 5));
            e.setSystemVolumeDb(-(float)(i % 9));
        }
    });
    for (int i = 0; i < 20000; i++) e.setTrackGainDb((float)(i % 7) - 3.0f);
    stop = true;
    ui.join();
    // Settled: the input gain equals track + headroom.
    e.setHeadroomDb(-4.0f);
    e.setTrackGainDb(2.0f);
    e.reset();
    std::vector<float> buf(512, 0.0f);
    for (int i = 0; i < 256; i++) buf[2 * i] = buf[2 * i + 1] = 0.1f;
    e.process(buf.data(), 256);
    CHECK_NEAR(buf[2 * 255], 0.1 * std::pow(10.0, -2.0 / 20.0), 1e-4);
}

// Wider parametric bands near the tone's frequency need a longer fade than a
// graphic band: one cycle of the band's frequency measured -36.3 dB for a
// 50 Hz Q0.7 band; the engine gives the parametric EQ two cycles.
static void engine_parametric_toggle_margin() {
    std::printf("engine_parametric_toggle_margin\n");
    double worst = -1e9;
    for (float hz : {31.25f, 50.0f, 80.0f}) {
        for (float q : {0.7f, 1.4f}) {
            const double db = engineHpWorst(
                [=](RoomDSPEngine& e) {
                    e.setParametricBand(0, hz, 12.0f, q, 0, true);
                    e.setEqEnabled(true);
                },
                [](RoomDSPEngine& e, int p) {
                    if (p == kOffAt) e.setEqEnabled(false);
                    if (p == kOnAt) e.setEqEnabled(true);
                });
            worst = std::max(worst, db);
        }
    }
    std::printf("    parametric +12 dB bands at 31.25/50/80 Hz, Q0.7/1.4, 40 Hz tone: worst %.1f dB\n", worst);
    CHECK(worst <= -39.0);
}

// Applying a preset sends its gains and then its preamp in separate calls. The
// preamp used to glide in about 4 ms while a 31.5 Hz band's crossfade takes
// about 32 ms: A (31.5 Hz +12, preamp -12) to B (flat, preamp 0) played +10 dB
// for 30 ms. The preamp now moves over the graphic EQ's crossfade, and a change
// waits a few ms for the rest of the preset.
static void engine_preset_with_preamp_does_not_burst() {
    std::printf("engine_preset_with_preamp_does_not_burst\n");
    const std::vector<float> c = {31.5f, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};
    float gA[10] = {12, 0, 0, 0, 0, 0, 0, 0, 0, 0}, gB[10] = {0};
    // The preamp call follows the gains straight away, or one block or two
    // blocks later (5 and 10 ms).
    for (int lag : {0, 256, 512}) {
        for (int aToB = 0; aToB < 2; aToB++) {
            for (double f : {31.5, 40.0, 1000.0}) {
                double worst = -1e9;
                for (int k = 0; k < 48; k += 3) {
                    RoomDSPEngine e;
                    e.init(48000, 2);
                    e.setEqEnabled(true);
                    e.setGraphicLayout(c.data(), 10, aToB ? gA : gB);
                    e.setPreampGain(aToB ? -12.0f : 0.0f);
                    const int total = kOffAt + 60 * 256;
                    std::vector<float> y(total), buf(512);
                    const double phase = 2.0 * kPi * k / 48.0;
                    for (int p = 0; p < total; p += 256) {
                        if (p == kOffAt) e.setGraphicAllBands(aToB ? gB : gA, 10);
                        if (p == kOffAt + lag) e.setPreampGain(aToB ? 0.0f : -12.0f);
                        for (int i = 0; i < 256; i++) {
                            buf[2 * i] = buf[2 * i + 1] =
                                (float)(0.1 * std::sin(2.0 * kPi * f * (double)(p + i) / 48000.0 + phase));
                        }
                        e.process(buf.data(), 256);
                        for (int i = 0; i < 256; i++) y[p + i] = buf[2 * i];
                    }
                    const int per = (int)std::lround(48000.0 / f);
                    const double before = windowDb(y, kOffAt - 2 * per, per, 0.1);
                    const double after = windowDb(y, total - per - 1, per, 0.1);
                    for (int s = kOffAt; s < total - per; s += std::max(1, per / 4)) {
                        worst = std::max(worst, windowDb(y, s, per, 0.1) - std::max(before, after));
                    }
                }
                std::printf("    %s, preamp %d frames after the gains, %5.1f Hz: worst %+.2f dB over the end states\n",
                            aToB ? "A->B" : "B->A", lag, f, worst);
                CHECK(worst <= 0.5);
            }
        }
    }
}

// Several toggles inside one fade, and a layout change around a toggle: the
// blend weight stays continuous, so no step; the 40 Hz limit here is the
// layout change's own (the same change with no toggle measures -36.7 dB).
static void engine_toggle_combinations() {
    std::printf("engine_toggle_combinations\n");
    static const float iso15[15] = {25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600,
                                    2500, 4000, 6300, 10000, 16000};
    float g15[15] = {0};
    g15[1] = 12.0f;
    g15[8] = 12.0f;
    const auto setup = [](RoomDSPEngine& e) {
        engineBandBoost(e, 0, 12.0f);
        e.setGraphicBandGain(5, 12.0f);
        e.setParametricBand(0, 60.0f, 9.0f, 1.0f, 0, true);
        e.setEqEnabled(true);
    };
    const double rapid = engineHpWorst(setup, [](RoomDSPEngine& e, int p) {
        if (p == kOffAt) e.setEqEnabled(false);
        if (p == kOffAt + 512) e.setEqEnabled(true);
        if (p == kOffAt + 1024) e.setEqEnabled(false);
        if (p == kOffAt + 40 * 256) e.setEqEnabled(true);
    });
    std::printf("    off/on/off inside one fade, then on: %.1f dB\n", rapid);
    CHECK(rapid <= -28.0);
    const auto layoutSetup = [](RoomDSPEngine& e) {
        engineBandBoost(e, 0, 12.0f);
        e.setGraphicBandGain(5, 12.0f);
        e.setEqEnabled(true);
    };
    const double a = engineHpWorst(layoutSetup, [&](RoomDSPEngine& e, int p) {
        if (p == kOffAt) e.setGraphicLayout(iso15, 15, g15);
        if (p == kOffAt + 256) e.setEqEnabled(false);
        if (p == kOffAt + 40 * 256) e.setEqEnabled(true);
    });
    const double b = engineHpWorst(layoutSetup, [&](RoomDSPEngine& e, int p) {
        if (p == kOffAt) e.setEqEnabled(false);
        if (p == kOffAt + 256) e.setGraphicLayout(iso15, 15, g15);
        if (p == kOffAt + 512) e.setEqEnabled(true);
    });
    std::printf("    layout change then off then on: %.1f dB; off, layout change, on: %.1f dB\n", a, b);
    CHECK(a <= -35.0);
    CHECK(b <= -35.0);
}

// ---- Task 11: platform (system-wide) mode ----

// Streams a constant stereo input through the engine in 256-frame blocks and
// returns the last output frame.
static void dcStream(RoomDSPEngine& e, float l, float r, int frames,
                     float* outL, float* outR) {
    std::vector<float> buf(2 * 256);
    for (int p = 0; p < frames; p += 256) {
        for (int i = 0; i < 256; i++) {
            buf[2 * i] = l;
            buf[2 * i + 1] = r;
        }
        e.process(buf.data(), 256);
    }
    *outL = buf[2 * 255];
    *outR = buf[2 * 255 + 1];
}

// While the platform equalizer applies the user's equalizer, Hype's own engine
// must not: graphic EQ, tone, the user preamp, headroom, track gain, balance,
// mono and stereo expand all run neutral, and come back with their stored
// values when the flag goes off.
static void platform_eq_neutralises_engine_stages() {
    std::printf("platform_eq_neutralises_engine_stages\n");
    RoomDSPEngine e;
    e.init(48000, 2);
    engineBandBoost(e, 5, 12.0f);
    e.setEqEnabled(true);
    e.setToneEnabled(true);
    e.setBassGain(10.0f);
    e.setPreampGain(6.0f);
    e.setHeadroomDb(-6.0f);
    e.setTrackGainDb(-10.0f);
    e.setBalance(-1.0f);
    e.setMono(true);
    e.setStereoExpand(1.0f);
    e.setLimiterEnabled(false);
    CHECK(!e.platformEqActive());
    e.setPlatformEqActive(true);
    CHECK(e.platformEqActive());
    float l = 0.0f, r = 0.0f;
    dcStream(e, 0.3f, -0.2f, 2048, &l, &r);
    std::printf("    platform on: L %.7f R %.7f\n", l, r);
    CHECK_NEAR(l, 0.3, 1e-6);
    CHECK_NEAR(r, -0.2, 1e-6);
    // The stored values are kept.
    CHECK(e.isToneEnabled());
    CHECK_NEAR(e.toneBassGainDb(), 10.0, 1e-6);
    CHECK(e.isEqEnabled());
    CHECK(e.isStereoExpandEnabled());

    e.setPlatformEqActive(false);
    dcStream(e, 0.3f, -0.2f, 16384, &l, &r);
    std::printf("    platform off: L %.5f R %.7f\n", l, r);
    CHECK(std::fabs(r) < 1e-9);       // balance -1 is back: the right channel is silent
    CHECK(std::fabs(l - 0.3) > 0.01); // mono, gains and tone are back
}

// Only the user's graphic EQ, tone, preamp and headroom move to the platform.
// Speaker correction (and its preamp) and master volume stay in Hype's engine.
static void platform_eq_keeps_speaker_preamp_and_master() {
    std::printf("platform_eq_keeps_speaker_preamp_and_master\n");
    for (int eqOn = 0; eqOn < 2; eqOn++) {
        RoomDSPEngine e;
        e.init(48000, 2);
        e.setSpeakerEqEnabled(true);
        e.setSpeakerPreampDb(-6.0f);
        e.setPreampGain(6.0f);
        e.setMasterVolumeDb(-12.0f);
        e.setEqEnabled(eqOn != 0);
        e.setPlatformEqActive(true);
        float l = 0.0f, r = 0.0f;
        dcStream(e, 0.3f, 0.3f, 16384, &l, &r);
        const double want = 0.3 * std::pow(10.0, -18.0 / 20.0);
        std::printf("    EQ %s: out %.6f, want %.6f\n", eqOn ? "on " : "off", l, want);
        CHECK_NEAR(l, want, 1e-5);
        CHECK_NEAR(r, want, 1e-5);
        // Control: without the platform flag the user preamp counts.
        e.setPlatformEqActive(false);
        dcStream(e, 0.3f, 0.3f, 16384, &l, &r);
        CHECK_NEAR(l, 0.3 * std::pow(10.0, -12.0 / 20.0), 2e-4);
    }
}

// The parametric EQ is not carried by the platform equalizer: it stays live.
static void platform_eq_keeps_parametric_eq() {
    std::printf("platform_eq_keeps_parametric_eq\n");
    RoomDSPEngine e;
    e.init(48000, 2);
    engineBandBoost(e, 0, 12.0f);
    e.setParametricBand(0, 1000.0f, 12.0f, 1.0f, 0, true);
    e.setEqEnabled(true);
    e.setPlatformEqActive(true);
    const std::vector<float> y = engineStream(e, 1000.0, 0.0, 24000, nullptr);
    const double db = toDb(peakOf(std::vector<float>(y.end() - 4800, y.end())) / 0.1);
    // 31 Hz graphic boost gone, 1 kHz parametric boost kept.
    std::printf("    1 kHz with parametric +12 dB under platform mode: %+.2f dB\n", db);
    CHECK_NEAR(db, 12.0, 0.4);
    const std::vector<float> z = engineStream(e, 31.25, 0.0, 24000, nullptr);
    const double bass = toDb(peakOf(std::vector<float>(z.end() - 9600, z.end())) / 0.1);
    std::printf("    31 Hz with the graphic +12 dB under platform mode: %+.2f dB\n", bass);
    CHECK(bass < 1.0);
}

// Switching platform mode on and off is a faded transition at any phase.
static void platform_toggle_without_click() {
    std::printf("platform_toggle_without_click\n");
    // 1 kHz, graphic +12 dB and a +3 dB preamp: step against the steady state.
    const auto setup1k = [](RoomDSPEngine& e) {
        engineBandBoost(e, 5, 12.0f);
        e.setPreampGain(3.0f);
        e.setEqEnabled(true);
    };
    float steady = 0.0f;
    {
        RoomDSPEngine e;
        e.init(48000, 2);
        setup1k(e);
        const std::vector<float> y = engineStream(e, 1000.0, 0.0, 12000, nullptr);
        steady = maxStep(std::vector<float>(y.begin() + 6000, y.end()));
    }
    float worstOn = 0.0f, worstOff = 0.0f;
    double dryErr = 0.0, backDb = 0.0;
    for (int k = 0; k < 48; k++) {
        const double phase = 2.0 * kPi * k / 48.0;
        RoomDSPEngine e;
        e.init(48000, 2);
        setup1k(e);
        const std::vector<float> y = engineStream(e, 1000.0, phase, kToggleTotal,
            [&](int p) {
                if (p == kOffAt) e.setPlatformEqActive(true);
                if (p == kOnAt) e.setPlatformEqActive(false);
            });
        worstOn = std::max(worstOn, maxStep(std::vector<float>(y.begin() + kOffAt - 1, y.begin() + kOnAt)));
        worstOff = std::max(worstOff, maxStep(std::vector<float>(y.begin() + kOnAt - 1, y.end())));
        for (int i = kOnAt - 2048; i < kOnAt; i++) {
            const float x = (float)(0.1 * std::sin(2.0 * kPi * 1000.0 * (double)i / 48000.0 + phase));
            dryErr = std::max(dryErr, (double)std::fabs(y[i] - x));
        }
        backDb = std::max(backDb, std::fabs(toDb(peakOf(std::vector<float>(y.end() - 4800, y.end())) / 0.1) - 15.0));
    }
    std::printf("    1 kHz: platform on x%.2f, off x%.2f of steady; dry error %.2g; back to +15 dB within %.2f\n",
                worstOn / steady, worstOff / steady, dryErr, backDb);
    CHECK(steady > 0.04f);
    CHECK(worstOn <= 1.1f * steady);
    CHECK(worstOff <= 1.1f * steady);
    CHECK(dryErr < 1e-6);
    CHECK(backDb < 0.4);

    // 40 Hz: a +12 dB band at 31.25 Hz, bass tone and preamp - and the speaker
    // EQ on, so the preamp is still counted when the EQ itself is off.
    const double bass = engineHpWorst(
        [](RoomDSPEngine& e) {
            engineBandBoost(e, 0, 12.0f);
            e.setToneEnabled(true);
            e.setBassGain(10.0f);
            e.setPreampGain(-3.0f);
            e.setEqEnabled(true);
        },
        [](RoomDSPEngine& e, int p) {
            if (p == kOffAt) e.setPlatformEqActive(true);
            if (p == kOnAt) e.setPlatformEqActive(false);
        });
    std::printf("    40 Hz graphic + tone + preamp, platform on and off: high-pass residual %.1f dB\n", bass);
    CHECK(bass <= -36.0);
    const double bassSpeaker = engineHpWorst(
        [](RoomDSPEngine& e) {
            engineBandBoost(e, 0, 12.0f);
            e.setPreampGain(6.0f);
            e.setSpeakerEqEnabled(true);
            e.setEqEnabled(false);
        },
        [](RoomDSPEngine& e, int p) {
            if (p == kOffAt) e.setPlatformEqActive(true);
            if (p == kOnAt) e.setPlatformEqActive(false);
        });
    std::printf("    40 Hz, speaker EQ on + preamp +6 (EQ off): high-pass residual %.1f dB\n", bassSpeaker);
    CHECK(bassSpeaker <= -36.0);
    // The same with the headroom, track gain and EQ in play: all glide away.
    const double bassLevels = engineHpWorst(
        [](RoomDSPEngine& e) {
            engineBandBoost(e, 0, 12.0f);
            e.setHeadroomDb(-6.0f);
            e.setTrackGainDb(-3.0f);
            e.setEqEnabled(true);
        },
        [](RoomDSPEngine& e, int p) {
            if (p == kOffAt) e.setPlatformEqActive(true);
            if (p == kOnAt) e.setPlatformEqActive(false);
        });
    std::printf("    40 Hz with headroom -6 and track gain -3: high-pass residual %.1f dB\n", bassLevels);
    CHECK(bassLevels <= -36.0);
}

// Platform mode toggled inside an EQ fade, and the EQ toggled inside a
// platform fade: the weights are continuous.
static void platform_toggle_combinations() {
    std::printf("platform_toggle_combinations\n");
    const auto setup = [](RoomDSPEngine& e) {
        engineBandBoost(e, 0, 12.0f);
        e.setPreampGain(-3.0f);
        e.setEqEnabled(true);
    };
    const double a = engineHpWorst(setup, [](RoomDSPEngine& e, int p) {
        if (p == kOffAt) e.setEqEnabled(false);
        if (p == kOffAt + 512) e.setPlatformEqActive(true);
        if (p == kOffAt + 40 * 256) e.setEqEnabled(true);
        if (p == kOffAt + 80 * 256) e.setPlatformEqActive(false);
    });
    const double b = engineHpWorst(setup, [](RoomDSPEngine& e, int p) {
        if (p == kOffAt) e.setPlatformEqActive(true);
        if (p == kOffAt + 512) e.setPlatformEqActive(false);
        if (p == kOffAt + 1024) e.setPlatformEqActive(true);
        if (p == kOffAt + 40 * 256) e.setPlatformEqActive(false);
    });
    const double c = engineHpWorst(setup, [](RoomDSPEngine& e, int p) {
        if (p == kOffAt) e.setPlatformEqActive(true);
        if (p == kOffAt + 512) e.setEqEnabled(false);
        if (p == kOffAt + 1024) e.setEqEnabled(true);
        if (p == kOffAt + 40 * 256) e.setPlatformEqActive(false);
    });
    std::printf("    eq off then platform on: %.1f dB; platform on/off/on inside one fade: %.1f dB; eq toggled inside platform fade: %.1f dB\n", a, b, c);
    CHECK(a <= -36.0);
    CHECK(b <= -36.0);
    CHECK(c <= -36.0);
}

// A preamp (or headroom) that offsets the graphic boost must follow the
// platform fade the same way the preamp follows the EQ fade: no swell above
// the louder end state.
static void platform_preamp_follows_fade() {
    std::printf("platform_preamp_follows_fade\n");
    for (int via = 0; via < 2; via++) {
    for (int on = 0; on < 2; on++) {
        for (double f : {1000.0, 40.0}) {
            const int band = f < 100.0 ? 0 : 5;
            double worstOver = -1e9;
            int clamped = 0;
            for (int k = 0; k < 48; k += 4) {
                RoomDSPEngine e;
                e.init(48000, 2);
                engineBandBoost(e, band, via ? 10.0f : 12.0f);
                if (via) e.setHeadroomDb(-10.0f); else e.setPreampGain(-12.0f);
                e.setEqEnabled(true);
                e.setPlatformEqActive(!on);
                const int total = kOffAt + 40 * 256;
                std::vector<float> y(total), buf(512);
                const double phase = 2.0 * kPi * k / 48.0;
                for (int p = 0; p < total; p += 256) {
                    if (p == kOffAt) e.setPlatformEqActive(on != 0);
                    for (int i = 0; i < 256; i++) {
                        buf[2 * i] = buf[2 * i + 1] =
                            (float)(0.5 * std::sin(2.0 * kPi * f * (double)(p + i) / 48000.0 + phase));
                    }
                    e.process(buf.data(), 256);
                    for (int i = 0; i < 256; i++) y[p + i] = buf[2 * i];
                }
                const int per = (int)std::lround(48000.0 / f);
                const double before = windowDb(y, kOffAt - 2 * per, per, 0.5);
                const double after = windowDb(y, total - per - 1, per, 0.5);
                for (int s = kOffAt; s < total - per; s += std::max(1, per / 8)) {
                    worstOver = std::max(worstOver, windowDb(y, s, per, 0.5) - std::max(before, after));
                }
                for (int i = kOffAt; i < total; i++) if (std::fabs(y[i]) >= 0.999f) clamped++;
            }
            std::printf("    %s offsets the boost, platform %s at %4.0f Hz: worst level above the end states %+.2f dB, samples at the clamp %d\n",
                        via ? "headroom" : "preamp  ", on ? "on " : "off", f, worstOver, clamped);
            CHECK(worstOver <= 1.0);
            CHECK(clamped == 0);
        }
    }
    }
}

// Worst high-pass residual over 48 phases of a 40 Hz tone on both channels
// (R = rmul x L) for the schedule `act(engine, frame)`, from kOffAt on.
static double worstLR(const std::function<void(RoomDSPEngine&)>& setup,
                      const std::function<void(RoomDSPEngine&, int)>& act, float rmul) {
    double worst = -1e9;
    for (int k = 0; k < 48; k++) {
        RoomDSPEngine e;
        e.init(48000, 2);
        e.setLimiterEnabled(false);
        setup(e);
        std::vector<float> L(kToggleTotal), R(kToggleTotal), buf(512);
        for (int p = 0; p < kToggleTotal; p += 256) {
            act(e, p);
            for (int i = 0; i < 256; i++) {
                const float x = (float)(0.1 * std::sin(2.0 * kPi * 40.0 * (double)(p + i) / 48000.0 +
                                                       2.0 * kPi * k / 48.0));
                buf[2 * i] = x;
                buf[2 * i + 1] = rmul * x;
            }
            e.process(buf.data(), 256);
            for (int i = 0; i < 256; i++) { L[p + i] = buf[2 * i]; R[p + i] = buf[2 * i + 1]; }
        }
        worst = std::max(worst, std::max(hpPeakDb(L, kOffAt, kToggleTotal),
                                         hpPeakDb(R, kOffAt, kToggleTotal)));
    }
    return worst;
}

// Balance, mono and stereo expand are handed over by a blend against their
// input over the platform fade, not through their own slider glides (which
// left -33 dB for balance and -29 dB for expand).
static void platform_stages_hand_over_without_click() {
    std::printf("platform_stages_hand_over_without_click\n");
    const auto plat = [](RoomDSPEngine& e, int p) {
        if (p == kOffAt) e.setPlatformEqActive(true);
        if (p == kOnAt) e.setPlatformEqActive(false);
    };
    for (float b : {0.25f, 0.6f, 1.0f}) {
        const double w = worstLR([b](RoomDSPEngine& e) { e.setBalance(b); }, plat, 1.0f);
        const double g = worstLR([b](RoomDSPEngine& e) {
            engineBandBoost(e, 0, 12.0f); e.setEqEnabled(true); e.setBalance(b);
        }, plat, 1.0f);
        std::printf("    balance %.2f: %.1f dB; with the graphic EQ: %.1f dB\n", b, w, g);
        CHECK(w <= -36.0);
        CHECK(g <= -36.0);
    }
    const double m = worstLR([](RoomDSPEngine& e) { e.setMono(true); }, plat, 0.0f);
    const double x = worstLR([](RoomDSPEngine& e) { e.setStereoExpand(1.0f); }, plat, -0.5f);
    const double all = worstLR([](RoomDSPEngine& e) {
        engineBandBoost(e, 0, 12.0f); e.setEqEnabled(true); e.setPreampGain(-3.0f);
        e.setBalance(0.6f); e.setMono(true); e.setStereoExpand(0.5f);
    }, plat, -0.5f);
    std::printf("    mono %.1f dB; expand 100%% %.1f dB; graphic + preamp + balance + mono + expand %.1f dB\n", m, x, all);
    CHECK(m <= -36.0);
    CHECK(x <= -36.0);
    CHECK(all <= -36.0);
    // Handed over, they are exactly neutral; back, the settings are intact.
    RoomDSPEngine e;
    e.init(48000, 2);
    e.setBalance(-1.0f);
    e.setMono(true);
    e.setStereoExpand(1.0f);
    e.setPlatformEqActive(true);
    float l = 0.0f, r = 0.0f;
    dcStream(e, 0.3f, -0.2f, 4096, &l, &r);
    CHECK_NEAR(l, 0.3, 1e-6);
    CHECK_NEAR(r, -0.2, 1e-6);
    e.setPlatformEqActive(false);
    dcStream(e, 0.3f, -0.2f, 8192, &l, &r);
    CHECK(std::fabs(r) < 1e-9);
    CHECK(std::fabs(l) > 0.01);
}

// An engine created while system-wide is on (nativeCreate -> init, then the
// cached settings and the flag replayed before the first buffer) starts handed
// over: no fade in from Hype's own settings.
static void platform_new_engine_starts_handed_over() {
    std::printf("platform_new_engine_starts_handed_over\n");
    for (double f : {1000.0, 40.0}) {
        double worstDb = -1e9;
        for (int k = 0; k < 48; k += 4) {
            RoomDSPEngine e;
            e.init(48000, 2);
            engineBandBoost(e, f < 100.0 ? 0 : 5, 12.0f);
            e.setEqEnabled(true);
            e.setPreampGain(-3.0f);
            e.setHeadroomDb(-6.0f);
            e.setTrackGainDb(-4.0f);
            e.setBalance(0.5f);
            e.setPlatformEqActive(true);
            const std::vector<float> y = engineStream(e, f, 2.0 * kPi * k / 48.0, 9600, nullptr);
            const int per = (int)std::lround(48000.0 / f);
            for (int s = 0; s + per < 9600; s += std::max(1, per / 4)) {
                worstDb = std::max(worstDb, std::fabs(windowDb(y, s, per, 0.1)));
            }
        }
        std::printf("    %4.0f Hz: worst level error from the first buffer %.3f dB\n", f, worstDb);
        CHECK(worstDb < 0.05);
    }
    // reset() while handed over keeps it handed over, too.
    RoomDSPEngine e;
    e.init(48000, 2);
    engineBandBoost(e, 5, 12.0f);
    e.setEqEnabled(true);
    e.setHeadroomDb(-6.0f);
    e.setPlatformEqActive(true);
    float l = 0.0f, r = 0.0f;
    dcStream(e, 0.3f, 0.3f, 4096, &l, &r);
    e.reset();
    std::vector<float> buf(512, 0.3f);
    e.process(buf.data(), 256);
    CHECK_NEAR(buf[0], 0.3, 1e-6);
}

// Track gain and headroom are a stage of their own now: after init() or reset()
// it starts at the level the replayed settings say (no glide from unity), and
// it glides like the other gain stages when a setting changes.
static void level_stage_snaps_and_glides() {
    std::printf("level_stage_snaps_and_glides\n");
    const double want = 0.3 * std::pow(10.0, -16.0 / 20.0);
    for (int which = 0; which < 2; which++) {
        RoomDSPEngine e;
        e.init(48000, 2);
        e.setTrackGainDb(-10.0f);
        e.setHeadroomDb(-6.0f);
        if (which) e.init(48000, 2); else e.reset();
        std::vector<float> buf(512, 0.3f);
        e.process(buf.data(), 256);
        std::printf("    %s: first frame %.6f, want %.6f\n", which ? "init" : "reset", buf[0], want);
        CHECK_NEAR(buf[0], want, 1e-5);
    }
    RoomDSPEngine e;
    e.init(48000, 2);
    float l = 0.0f, r = 0.0f;
    dcStream(e, 0.3f, 0.3f, 512, &l, &r);
    e.setTrackGainDb(-12.0f);
    std::vector<float> buf(512, 0.3f);
    e.process(buf.data(), 256);
    // A glide: the first frame is still near unity, the last has arrived.
    CHECK(buf[0] > 0.29f);
    CHECK_NEAR(buf[2 * 255], 0.3 * std::pow(10.0, -12.0 / 20.0), 1e-5);
}

// Setters on other threads while the audio thread processes: run under
// ThreadSanitizer by run.sh. Nothing to check beyond finite output.
static void stress_setters_during_process() {
    std::printf("stress_setters_during_process\n");
    RoomDSPEngine e;
    e.init(48000, 2);
    engineBandBoost(e, 0, 6.0f);
    std::atomic<bool> stop{false};
    std::atomic<int> bad{0};
    std::thread audio([&] {
        std::vector<float> buf(512);
        long n = 0;
        while (!stop.load()) {
            for (int i = 0; i < 256; i++) {
                buf[2 * i] = buf[2 * i + 1] = (float)(0.1 * std::sin(0.01 * (double)(n++)));
            }
            e.process(buf.data(), 256);
            for (float x : buf) if (!std::isfinite(x)) bad++;
        }
    });
    auto control = [&](int seed) {
        for (int i = 0; i < 1500; i++) {
            switch ((i + seed) % 18) {
                case 0: e.setSystemVolumeDb((i & 1) ? -10.0f : 0.0f); break;
                case 1: e.setToneEnabled(i & 1); break;
                case 2: e.setBassGain((float)(i % 23)); break;
                case 3: e.setBassFreq(60.0f + (float)(i % 50)); break;
                case 4: e.setBassQ(0.5f + 0.01f * (float)(i % 100)); break;
                case 5: e.setTrebleGain((float)(i % 16)); break;
                case 6: e.setSmoothGains(i & 1); break;
                case 7: e.setEqEnabled(i & 1); break;
                case 8: e.setPreampGain((float)(i % 13) - 6.0f); break;
                case 9: e.setMasterVolumeDb(-(float)(i % 12)); break;
                case 10: e.setHeadroomDb(-(float)(i % 8)); break;
                case 11: e.setGraphicBandGain(i % 10, (float)(i % 13) - 6.0f); break;
                case 12: e.setSpeakerEqEnabled(i & 1); break;
                case 13: e.setPlatformEqActive(i & 1); break;
                case 14: e.setMono(i & 1); break;
                case 15: e.setBalance((float)(i % 5) * 0.4f - 0.8f); break;
                case 16: e.setStereoExpand((float)(i % 5) * 0.25f); break;
                case 17: e.setTrackGainDb((float)(i % 7) - 3.0f); break;
                default: e.setSpeakerPreampDb((float)(i % 5)); break;
            }
            if ((i & 63) == 0) std::this_thread::sleep_for(std::chrono::microseconds(200));
        }
    };
    std::thread c1(control, 0), c2(control, 5);
    c1.join();
    c2.join();
    stop = true;
    audio.join();
    CHECK(bad.load() == 0);
}

int main(int argc, char** argv) {
    if (argc > 1 && std::strcmp(argv[1], "stress") == 0) {
        graphic_init_during_process_is_safe();
        stress_setters_during_process();
        return gFailures == 0 ? 0 : 1;
    }
    graphic_q_from_spacing();
    graphic_layout_keeps_gains_by_index();
    graphic_band_boosts_its_centre();
    graphic_flat_is_bit_exact();
    graphic_band_off_drains_then_bit_exact();
    graphic_click_harness_flags_a_hard_cut();
    graphic_band_off_exact_within_drain_window();
    graphic_layout_change_without_click();
    graphic_band_on_without_click();
    graphic_gain_drag_keeps_bass_level();
    graphic_layout_with_gains_is_one_step();
    graphic_layout_gains_null_keeps_gains();
    graphic_gain_clamped();
    graphic_gain_scale();
    graphic_reactivation_during_drain_is_kept();
    graphic_init_keeps_layout_and_gains();
    graphic_band_near_nyquist_bypassed();
    graphic_top_band_past_limit_still_works();
    graphic_bass_changes_do_not_step();
    graphic_init_applies_on_next_process();
    graphic_init_during_process_is_safe();
    engine_default_layout_is_legacy_32();
    engine_layout_survives_init();
    engine_graphic_path_boosts();
    engine_eq_toggle_1k_without_click();
    engine_eq_toggle_bass_without_click();
    engine_parametric_toggle_without_click();
    engine_parametric_toggle_margin();
    smooth_scales_follow_the_rule();
    smooth_scales_floor_at_zero();
    engine_scales_band_with_volume();
    t_counts_preamp_only_while_applied();
    t_counts_master_volume();
    tone_bass_range();
    tone_scale_shapes_the_audio();
    scale_change_without_click();
    engine_eq_on_after_init_or_reset_is_faded();
    engine_preamp_follows_eq_fade();
    tone_changes_do_not_tick();
    engine_toggle_combinations();
    engine_preset_with_preamp_does_not_burst();
    tone_on_after_init_or_reset_is_faded();
    track_gain_does_not_take_the_level_mutex();
    platform_eq_neutralises_engine_stages();
    platform_eq_keeps_speaker_preamp_and_master();
    platform_eq_keeps_parametric_eq();
    platform_toggle_without_click();
    platform_toggle_combinations();
    platform_preamp_follows_fade();
    level_stage_snaps_and_glides();
    platform_stages_hand_over_without_click();
    platform_new_engine_starts_handed_over();
    stress_setters_during_process();
    std::printf("\n%d checks, %d failures\n", gChecks, gFailures);
    return gFailures == 0 ? 0 : 1;
}
