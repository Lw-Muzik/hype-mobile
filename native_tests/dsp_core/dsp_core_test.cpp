// Host tests for the output stages (output_stages.h), the limiter
// (limiter.h) and the order of the engine chain. Build and run:
// native_tests/dsp_core/run.sh

#include "limiter.h"
#include "output_stages.h"
#include "room_dsp_engine.h"

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

static void gain_stage_glides_without_clicks() {
    std::printf("gain stage glides without clicks\n");
    GainStage g;
    g.reset();
    {   // the first process after a reset snaps; settle it before the change
        float a = 1.0f, b = 1.0f;
        g.process(&a, &b, 1);
    }
    g.setDb(-30.0f);
    std::vector<float> l(1024, 1.0f), r(1024, 1.0f);
    g.process(l.data(), r.data(), 1024);
    float prev = 1.0f, maxStep = 0.0f;
    for (float v : l) {
        maxStep = std::max(maxStep, std::fabs(v - prev));
        prev = v;
    }
    CHECK(maxStep <= 1.0f / 256 + 1e-6f);
    CHECK(l[1023] == std::pow(10.0f, -30.0f / 20.0f));
    CHECK(r[1023] == l[1023]);
}

static void master_volume_floor_is_silence() {
    std::printf("master volume floor is silence\n");
    GainStage g;
    g.setDb(-30.0f, /*muteAtFloor=*/true);
    g.reset();
    float l[4] = {1.0f, -0.5f, 0.25f, 0.9f}, r[4] = {1.0f, 0.5f, -0.25f, -0.9f};
    g.process(l, r, 4);
    for (int i = 0; i < 4; i++) {
        CHECK(l[i] == 0.0f);
        CHECK(r[i] == 0.0f);
    }
    GainStage h;  // without muteAtFloor, -30 dB is only -30 dB
    h.setDb(-30.0f);
    h.reset();
    CHECK(h.gain() > 0.0f);
}

static void balance_full_left_silences_right() {
    std::printf("balance full left silences right\n");
    BalanceStage b;
    b.set(-1.0f);
    b.reset();
    float l[2] = {0.7f, -0.3f}, r[2] = {0.6f, 0.2f};
    b.process(l, r, 2);
    CHECK(l[0] == 0.7f && l[1] == -0.3f);
    CHECK(r[0] == 0.0f && r[1] == 0.0f);
}

static void balance_half_attenuates_opposite_by_24db() {
    std::printf("balance half attenuates the opposite side by 24 dB\n");
    BalanceStage b;
    b.set(0.5f);
    b.reset();
    float l[1] = {0.8f}, r[1] = {0.8f};
    b.process(l, r, 1);
    CHECK(r[0] == 0.8f);
    CHECK(near(l[0], 0.8f * std::pow(10.0f, -24.0f / 20.0f)));
}

static void mono_averages() {
    std::printf("mono averages\n");
    MonoStage m;
    CHECK(!m.active());
    m.set(true);
    std::vector<float> l(300, 0.6f), r(300, 0.2f);
    m.process(l.data(), r.data(), 300);  // past the 256-frame crossfade
    CHECK(near(l[299], 0.4f) && near(r[299], 0.4f));
}

static void limiter_never_exceeds_ceiling() {
    std::printf("limiter never exceeds the ceiling\n");
    RoomDSPEngine e;
    e.init(48000, 2);
    e.setPreampGain(24.0f);
    e.setEqEnabled(true);  // the preamp counts only while an EQ is on
    e.setLimiterEnabled(true);
    std::vector<float> buf(48000 * 2);
    for (int i = 0; i < 48000; i++) {
        float s = std::sin(2.0f * 3.14159265f * 1000.0f * i / 48000.0f);
        buf[2 * i] = buf[2 * i + 1] = s;
    }
    e.process(buf.data(), 48000);
    float mx = 0.0f;
    for (float v : buf) mx = std::max(mx, std::fabs(v));
    CHECK(mx <= 1.0f);
    CHECK(mx > 0.5f);
    CHECK(e.limiterGain() < 1.0f);

    // The limiter itself, without the engine's clamp to hide behind: the same
    // +24 dB overload. After the 256-frame attack every output is in range and
    // the gain has settled near ceiling/peak.
    OutputLimiter lim;
    lim.init(48000);
    lim.setEnabled(true);
    const float peak = std::pow(10.0f, 24.0f / 20.0f);
    float worst = 0.0f;
    for (int i = 0; i < 48000; i++) {
        float s = peak * std::sin(2.0f * 3.14159265f * 1000.0f * i / 48000.0f);
        float l = s, r = s;
        lim.process(&l, &r, 1);
        if (i >= 256) worst = std::max(worst, std::max(std::fabs(l), std::fabs(r)));
    }
    CHECK(worst <= 1.0f + 1e-4f);
    CHECK(lim.gain() <= 1.0f / peak * 1.02f);
}

// Overload with a DC level, then silence; returns frames until gain is 1.0
// and the lowest gain seen.
static int recovery_frames(int fs, float* gMin) {
    OutputLimiter lim;
    lim.init(fs);
    lim.setEnabled(true);
    std::vector<float> l(fs / 2, 4.0f), r(fs / 2, 4.0f);
    *gMin = 1.0f;
    for (size_t i = 0; i < l.size(); i++) {
        lim.process(&l[i], &r[i], 1);
        *gMin = std::min(*gMin, lim.gain());
    }
    int frames = 0;
    while (lim.gain() < 1.0f && frames < 10 * fs) {
        float z = 0.0f, zr = 0.0f;
        lim.process(&z, &zr, 1);
        frames++;
    }
    return frames;
}

static void limiter_recovers_in_341ms() {
    std::printf("limiter recovers in ~341 ms\n");
    float gMin = 1.0f;
    const int frames = recovery_frames(48000, &gMin);
    const int expected = (int)std::lround((1.0f - gMin) * 16384.0f);
    std::printf("    gMin %.4f, %d frames (expected %d)\n", gMin, frames, expected);
    CHECK(gMin < 0.3f);
    CHECK(std::abs(frames - expected) <= 8);
}

static void limiter_slopes_scale_with_rate() {
    std::printf("limiter slopes scale with the sample rate\n");
    float gMin = 1.0f;
    const int frames = recovery_frames(96000, &gMin);
    const int expected = (int)std::lround((1.0f - gMin) * 16384.0f * 2.0f);
    std::printf("    gMin %.4f, %d frames (expected %d)\n", gMin, frames, expected);
    CHECK(std::abs(frames - expected) <= 16);
}

static void chain_order() {
    std::printf("chain order: balance runs after stereo expand\n");
    RoomDSPEngine e;
    e.init(48000, 2);
    e.setStereoExpand(1.0f);
    e.setBalance(-1.0f);
    e.reset();
    std::vector<float> buf(2 * 4096);
    for (int i = 0; i < 4096; i++) {
        buf[2 * i] = 0.2f;  // balance first would leave R = -0.2 after expand
        buf[2 * i + 1] = 0.5f;
    }
    e.process(buf.data(), 4096);
    // The balance glide takes 256 frames; look past it.
    bool rSilent = true;
    for (int i = 512; i < 4096; i++) rSilent = rSilent && buf[2 * i + 1] == 0.0f;
    CHECK(rSilent);
}

static float tailPeak(const std::vector<float>& buf, int frames, int from) {
    float mx = 0.0f;
    for (int i = from; i < frames; i++) mx = std::max(mx, std::fabs(buf[2 * i]));
    return mx;
}

static std::vector<float> sine(int frames, float amp) {
    std::vector<float> b(2 * frames);
    for (int i = 0; i < frames; i++) {
        b[2 * i] = b[2 * i + 1] = amp * std::sin(2.0f * 3.14159265f * 1000.0f * i / 48000.0f);
    }
    return b;
}

static void preamp_counts_only_while_an_eq_is_on() {
    std::printf("preamp counts only while an EQ is on\n");
    const float k = std::pow(10.0f, 6.0f / 20.0f);
    RoomDSPEngine e;
    e.init(48000, 2);
    e.setPreampGain(6.0f);
    auto b = sine(4096, 0.25f);
    e.process(b.data(), 4096);
    CHECK(near(tailPeak(b, 4096, 1024), 0.25f, 1e-3f));  // EQ off: no preamp

    e.setEqEnabled(true);
    b = sine(4096, 0.25f);
    e.process(b.data(), 4096);
    CHECK(near(tailPeak(b, 4096, 1024), 0.25f * k, 2e-3f));

    // Bypassed again (as for the system-wide EQ): the engine drops it.
    e.setEqEnabled(false);
    b = sine(4096, 0.25f);
    e.process(b.data(), 4096);
    CHECK(near(tailPeak(b, 4096, 1024), 0.25f, 1e-3f));

    // The speaker EQ counts too, and carries its own preamp.
    e.setSpeakerEqEnabled(true);
    b = sine(4096, 0.25f);
    e.process(b.data(), 4096);
    CHECK(near(tailPeak(b, 4096, 1024), 0.25f * k, 2e-3f));
    e.setSpeakerPreampDb(-6.0f);
    b = sine(4096, 0.25f);
    e.process(b.data(), 4096);
    CHECK(near(tailPeak(b, 4096, 1024), 0.25f, 2e-3f));
    e.setSpeakerEqEnabled(false);
    b = sine(4096, 0.25f);
    e.process(b.data(), 4096);
    CHECK(near(tailPeak(b, 4096, 1024), 0.25f, 1e-3f));
}

static void speaker_preamp_is_clamped_and_headroom_unaffected() {
    std::printf("speaker preamp clamps; headroom ignores the EQ gate\n");
    RoomDSPEngine e;
    e.init(48000, 2);
    e.setSpeakerEqEnabled(true);
    e.setSpeakerPreampDb(-60.0f);  // clamps to -24 dB
    e.setHeadroomDb(-6.0f);        // counts with every EQ off or on
    auto b = sine(8192, 0.5f);
    e.process(b.data(), 8192);
    const float want = 0.5f * std::pow(10.0f, -30.0f / 20.0f);
    CHECK(near(tailPeak(b, 8192, 2048), want, 1e-3f));
}

static void mono_toggle_does_not_click() {
    std::printf("mono toggle crossfades without clicks\n");
    MonoStage m;
    m.set(true);
    std::vector<float> l(1024, 0.8f), r(1024, -0.8f);
    m.process(l.data(), r.data(), 1024);
    float prev = 0.8f, maxStep = 0.0f;
    for (float v : l) {
        maxStep = std::max(maxStep, std::fabs(v - prev));
        prev = v;
    }
    CHECK(maxStep <= 0.8f / 256 + 1e-6f);
    CHECK(l[1023] == 0.0f && r[1023] == 0.0f);
    CHECK(m.active());

    m.set(false);
    std::vector<float> l2(1024, 0.8f), r2(1024, -0.8f);
    m.process(l2.data(), r2.data(), 1024);
    prev = 0.0f;
    maxStep = 0.0f;
    for (float v : l2) {
        maxStep = std::max(maxStep, std::fabs(v - prev));
        prev = v;
    }
    CHECK(maxStep <= 0.8f / 256 + 1e-6f);
    CHECK(l2[1023] == 0.8f && r2[1023] == -0.8f);
    CHECK(!m.active());
}

static void limiter_restarts_at_unity_when_reenabled() {
    std::printf("limiter restarts at unity when re-enabled\n");
    OutputLimiter lim;
    lim.init(48000);
    lim.setEnabled(true);
    float l[512], r[512];
    for (int i = 0; i < 512; i++) l[i] = r[i] = 8.0f;
    lim.process(l, r, 512);
    CHECK(lim.gain() < 0.2f);
    lim.setEnabled(false);
    lim.setEnabled(true);
    float ql[16], qr[16];
    for (int i = 0; i < 16; i++) ql[i] = qr[i] = 0.1f;
    lim.process(ql, qr, 16);
    CHECK(lim.gain() == 1.0f);
    CHECK(ql[0] == 0.1f);
    // Enabling twice in a row is not a transition.
    for (int i = 0; i < 512; i++) l[i] = r[i] = 8.0f;
    lim.process(l, r, 512);
    const float g = lim.gain();
    lim.setEnabled(true);
    lim.process(ql, qr, 1);
    CHECK(lim.gain() <= g + 1e-3f);
}

static void fresh_stages_snap_to_target_after_reset() {
    std::printf("stages snap to the replayed target on the first process\n");
    GainStage g;
    g.reset();
    g.setDb(-12.0f);  // the replay after a reset
    float l[4] = {1, 1, 1, 1}, r[4] = {1, 1, 1, 1};
    g.process(l, r, 4);
    CHECK(near(l[0], std::pow(10.0f, -12.0f / 20.0f), 1e-6f));
    CHECK(l[0] == l[3]);

    BalanceStage b;
    b.reset();
    b.set(1.0f);
    float bl[2] = {1, 1}, br[2] = {1, 1};
    b.process(bl, br, 2);
    CHECK(bl[0] == 0.0f && br[0] == 1.0f);

    // An idle stage forgets the pending snap: a later change must glide.
    GainStage idle;
    idle.reset();
    CHECK(!idle.active());
    idle.setDb(-12.0f);
    float il[1] = {1}, ir[1] = {1};
    idle.process(il, ir, 1);
    CHECK(il[0] > 0.99f);

    // Through the engine: master volume set right after a reset.
    RoomDSPEngine e;
    e.init(48000, 2);
    e.reset();
    e.setMasterVolumeDb(-12.0f);
    std::vector<float> buf(2 * 8, 1.0f);
    e.process(buf.data(), 8);
    CHECK(near(buf[0], std::pow(10.0f, -12.0f / 20.0f), 1e-6f));
}

static void limiter_reduction_db_reports_gain_reduction() {
    std::printf("limiter reduction dB: >0 while limiting, 0 when off or quiet\n");
    RoomDSPEngine e;
    e.init(48000, 2);
    e.setLimiterEnabled(true);
    std::vector<float> buf(4800 * 2);
    auto fill = [&](float amp) {
        for (int i = 0; i < 4800; i++)
            buf[2 * i] = buf[2 * i + 1] = amp * std::sin(2.0f * 3.14159265f * 1000.0f * i / 48000.0f);
    };
    CHECK(e.limiterReductionDb() == 0.0f);
    for (int k = 0; k < 4; k++) { fill(2.0f); e.process(buf.data(), 4800); }  // +6 dBFS
    const float db = e.limiterReductionDb();
    CHECK(db > 0.5f && db < 12.5f);
    e.setLimiterEnabled(false);
    CHECK(e.limiterReductionDb() == 0.0f);
    e.setLimiterEnabled(true);
    for (int k = 0; k < 20; k++) { fill(0.1f); e.process(buf.data(), 4800); }  // quiet, recovers
    CHECK(e.limiterReductionDb() == 0.0f);
}

int main() {
    gain_stage_glides_without_clicks();
    master_volume_floor_is_silence();
    balance_full_left_silences_right();
    balance_half_attenuates_opposite_by_24db();
    mono_averages();
    limiter_never_exceeds_ceiling();
    limiter_recovers_in_341ms();
    limiter_slopes_scale_with_rate();
    chain_order();
    limiter_reduction_db_reports_gain_reduction();
    preamp_counts_only_while_an_eq_is_on();
    speaker_preamp_is_clamped_and_headroom_unaffected();
    mono_toggle_does_not_click();
    limiter_restarts_at_unity_when_reenabled();
    fresh_stages_snap_to_target_after_reset();
    std::printf("%d checks, %d failures\n", gChecks, gFailures);
    return gFailures == 0 ? 0 : 1;
}
