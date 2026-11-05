// Host test of the iOS tap's mono path: HypeMonoToStereo / HypeStereoToMono
// (HypeAudioTap.h) around the real stereo-only engine. Build and run:
// native_tests/ios_mono/run.sh

#import "HypeAudioTap.h"
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

static void widen_and_fold_round_trip() {
    std::printf("widen to stereo and fold back is lossless\n");
    std::vector<float> mono = {0.5f, -0.25f, 0.0f, 1.0f, -1.0f};
    std::vector<float> st(mono.size() * 2, 9.0f), back(mono.size(), 9.0f);
    HypeMonoToStereo(mono.data(), st.data(), (int)mono.size());
    for (size_t i = 0; i < mono.size(); i++) {
        CHECK(st[i * 2] == mono[i]);
        CHECK(st[i * 2 + 1] == mono[i]);
    }
    HypeStereoToMono(st.data(), back.data(), (int)mono.size());
    for (size_t i = 0; i < mono.size(); i++) CHECK(near(back[i], mono[i]));
}

static void fold_averages_the_channels() {
    std::printf("fold is (L + R) / 2\n");
    float st[4] = {1.0f, 0.0f, -0.5f, 0.25f};
    float mono[2] = {0, 0};
    HypeStereoToMono(st, mono, 2);
    CHECK(near(mono[0], 0.5f));
    CHECK(near(mono[1], -0.125f));
}

static void engine_track_gain_reaches_a_mono_buffer() {
    std::printf("a mono buffer gets the engine's track gain\n");
    RoomDSPEngine e;
    e.init(48000, 2);  // the tap always (re)initialises the engine as stereo
    e.setTrackGainDb(-6.0f);
    const int n = 512;
    std::vector<float> mono(n), scratch(n * 2);
    for (int i = 0; i < n; i++) mono[i] = 0.5f * std::sin(0.05f * (float)i);
    std::vector<float> ref = mono;
    HypeMonoToStereo(mono.data(), scratch.data(), n);
    e.process(scratch.data(), n);
    HypeStereoToMono(scratch.data(), mono.data(), n);
    const float want = std::pow(10.0f, -6.0f / 20.0f);
    int checked = 0;
    for (int i = n / 2; i < n; i++) {  // past the first-sample glide
        if (std::fabs(ref[i]) < 0.05f) continue;
        CHECK(near(mono[i] / ref[i], want, 1e-3f));
        checked++;
    }
    CHECK(checked > 50);
}

static void mono_engine_would_have_been_bypassed() {
    std::printf("an engine told it is mono leaves the buffer alone (why the tap widens)\n");
    RoomDSPEngine e;
    e.init(48000, 1);
    e.setTrackGainDb(-6.0f);
    std::vector<float> buf(256, 0.5f);
    e.process(buf.data(), 128);
    CHECK(buf[10] == 0.5f);
}

int main() {
    widen_and_fold_round_trip();
    fold_averages_the_channels();
    engine_track_gain_reaches_a_mono_buffer();
    mono_engine_would_have_been_bypassed();
    std::printf("%d checks, %d failures\n", gChecks, gFailures);
    return gFailures == 0 ? 0 : 1;
}
