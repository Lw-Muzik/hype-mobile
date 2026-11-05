// Host unit tests for Stereo Expand (android/app/src/main/cpp/stereo_expander.h,
// kept identical to ios/HypeDSP/src/stereo_expander.h).
// Build and run: native_tests/stereo/run.sh

#include "stereo_expander.h"

#include <cmath>
#include <cstdio>
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

static bool near(float a, float b, float eps = 1e-5f) { return std::fabs(a - b) <= eps; }

// A settled expander: set, then reset so the glide is already over.
static void settle(StereoExpander& e, float amount) {
    e.setAmount(amount);
    e.reset();
}

static void zero_is_off_and_bit_exact() {
    std::printf("zero is off, and bit-exact\n");
    StereoExpander e;
    CHECK(!e.engaged());
    CHECK(!e.active());
    float l[3] = {0.3f, -0.7f, 0.123456f};
    float r[3] = {-0.2f, 0.9f, 0.654321f};
    const float l0[3] = {l[0], l[1], l[2]};
    const float r0[3] = {r[0], r[1], r[2]};
    e.process(l, r, 3);
    for (int i = 0; i < 3; i++) {
        CHECK(l[i] == l0[i]);
        CHECK(r[i] == r0[i]);
    }
}

static void side_gain_is_one_plus_twice_the_amount() {
    std::printf("side gain = 1 + 2 * amount, mid untouched\n");
    for (float amount : {0.25f, 0.5f, 1.0f}) {
        StereoExpander e;
        settle(e, amount);
        const float L = 0.6f, R = 0.2f;
        float l[1] = {L}, r[1] = {R};
        e.process(l, r, 1);
        const float mid = (L + R) * 0.5f, side = (L - R) * 0.5f;
        const float w = 1.0f + 2.0f * amount;
        CHECK(near((l[0] + r[0]) * 0.5f, mid));       // mid kept
        CHECK(near((l[0] - r[0]) * 0.5f, side * w));  // side scaled
    }
}

static void full_amount_is_two_l_minus_r() {
    std::printf("100%% is 2L - R\n");
    StereoExpander e;
    settle(e, 1.0f);
    float l[1] = {0.5f}, r[1] = {0.1f};
    e.process(l, r, 1);
    CHECK(near(l[0], 2 * 0.5f - 0.1f));
    CHECK(near(r[0], 2 * 0.1f - 0.5f));
}

static void mono_passes_through() {
    std::printf("a mono signal passes through\n");
    StereoExpander e;
    settle(e, 1.0f);
    float l[2] = {0.4f, -0.8f}, r[2] = {0.4f, -0.8f};
    e.process(l, r, 2);
    CHECK(near(l[0], 0.4f) && near(r[0], 0.4f));
    CHECK(near(l[1], -0.8f) && near(r[1], -0.8f));
}

static void amount_is_clamped() {
    std::printf("the amount is clamped to 0..1 (no narrowing)\n");
    StereoExpander e;
    e.setAmount(-0.5f);
    CHECK(!e.engaged());
    CHECK(near(e.amount(), 0.0f));
    e.setAmount(3.0f);
    CHECK(near(e.amount(), 1.0f));
}

static void glide_lands_exactly_and_switches_off() {
    std::printf("a change glides and lands exactly; back at 0 it switches off\n");
    StereoExpander e;
    e.setAmount(1.0f);
    CHECK(e.engaged());
    std::vector<float> l(1024, 0.5f), r(1024, -0.5f);  // pure side
    e.process(l.data(), r.data(), static_cast<int>(l.size()));
    // First frame barely moved, last frame at the full width of 3.
    CHECK(l.front() < 0.51f);
    CHECK(near(l.back(), 1.5f));
    CHECK(near(r.back(), -1.5f));

    e.setAmount(0.0f);
    CHECK(!e.engaged());
    CHECK(e.active());  // still on its way back
    std::vector<float> l2(1024, 0.5f), r2(1024, -0.5f);
    e.process(l2.data(), r2.data(), static_cast<int>(l2.size()));
    CHECK(!e.active());
    CHECK(l2.back() == 0.5f);
}

int main() {
    zero_is_off_and_bit_exact();
    side_gain_is_one_plus_twice_the_amount();
    full_amount_is_two_l_minus_r();
    mono_passes_through();
    amount_is_clamped();
    glide_lands_exactly_and_switches_off();
    std::printf("\n%d checks, %d failures\n", gChecks, gFailures);
    return gFailures == 0 ? 0 : 1;
}
