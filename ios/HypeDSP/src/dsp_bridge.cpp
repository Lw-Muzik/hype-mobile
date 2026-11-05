// C bridge implementation — wraps RoomDSPEngine for Swift access.

#include "dsp_bridge.h"
#include "room_dsp_engine.h"
#include "stems/stem_engine.h"
#include "stems_ios/av_pcm_source.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

extern "C" {

void* dsp_create(int sampleRate, int channels) {
    auto* engine = new RoomDSPEngine();
    engine->init(sampleRate, channels);
    return engine;
}

void dsp_destroy(void* handle) {
    delete static_cast<RoomDSPEngine*>(handle);
}

void dsp_reinit(void* handle, int sampleRate, int channels) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->init(sampleRate, channels);
}

void dsp_reset(void* handle) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->reset();
}

void dsp_process_float(void* handle, float* buffer, int numFrames) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->process(buffer, numFrames);
}

// EQ
void dsp_set_eq_enabled(void* handle, bool enabled) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setEqEnabled(enabled);
}

void dsp_set_preamp_gain(void* handle, float dB) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setPreampGain(dB);
}

void dsp_set_speaker_preamp_db(void* handle, float dB) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setSpeakerPreampDb(dB);
}

void dsp_set_headroom_db(void* handle, float dB) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setHeadroomDb(dB);
}

void dsp_set_smooth_gains(void* handle, bool on) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setSmoothGains(on);
}

void dsp_set_system_volume_db(void* handle, float dB) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setSystemVolumeDb(dB);
}

void dsp_set_track_gain_db(void* handle, float dB) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setTrackGainDb(dB);
}

void dsp_set_master_volume_db(void* handle, float dB) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setMasterVolumeDb(dB);
}

void dsp_set_mono(void* handle, bool enabled) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setMono(enabled);
}

void dsp_set_balance(void* handle, float balance) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setBalance(balance);
}

float dsp_get_preamp_gain(void* handle) {
    // The engine doesn't expose a getter, but we track it via cached params
    return 0.0f;
}

void dsp_set_graphic_band_gain(void* handle, int band, float dB) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setGraphicBandGain(band, dB);
}

void dsp_set_graphic_all_bands(void* handle, const float* gains, int count) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setGraphicAllBands(gains, count);
}

void dsp_set_graphic_layout(void* handle, const float* centresHz,
                            const float* gainsDb, int count) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setGraphicLayout(
        centresHz, count, gainsDb);
}

void dsp_set_parametric_band(void* handle, int band, float freq, float gainDb,
                              float q, int filterType, bool enabled) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setParametricBand(
        band, freq, gainDb, q, filterType, enabled);
}

void dsp_set_parametric_all_bands(void* handle, const float* freqs,
                                   const float* gains, const float* qs, int count) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setParametricAllBands(
        freqs, gains, qs, count);
}

// Speaker correction EQ
void dsp_set_speaker_eq_enabled(void* handle, bool enabled) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setSpeakerEqEnabled(enabled);
}

void dsp_set_speaker_eq_band(void* handle, int band, float freq, float gainDb,
                              float q, int filterType, bool enabled) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setSpeakerEqBand(
        band, freq, gainDb, q, filterType, enabled);
}

void dsp_clear_speaker_eq(void* handle) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->clearSpeakerEq();
}

// Tone
void dsp_set_tone_enabled(void* handle, bool enabled) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setToneEnabled(enabled);
}

void dsp_set_bass_gain(void* handle, float dB) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setBassGain(dB);
}

void dsp_set_bass_freq(void* handle, float hz) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setBassFreq(hz);
}

void dsp_set_bass_q(void* handle, float q) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setBassQ(q);
}

void dsp_set_treble_gain(void* handle, float dB) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setTrebleGain(dB);
}

void dsp_set_treble_freq(void* handle, float hz) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setTrebleFreq(hz);
}

void dsp_set_treble_q(void* handle, float q) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setTrebleQ(q);
}

// Limiter
void dsp_set_limiter_enabled(void* handle, bool enabled) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setLimiterEnabled(enabled);
}

void dsp_set_limiter_ceiling(void* handle, float v) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setLimiterCeiling(v);
}

void dsp_set_limiter_release(void* handle, float ms) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setLimiterRelease(ms);
}

float dsp_get_limiter_reduction_db(void* handle) {
    return handle ? static_cast<RoomDSPEngine*>(handle)->limiterReductionDb() : 0.0f;
}

int dsp_get_sample_rate(void* handle) {
    return handle ? static_cast<RoomDSPEngine*>(handle)->configuredSampleRate() : 0;
}

int dsp_get_channels(void* handle) {
    return handle ? static_cast<RoomDSPEngine*>(handle)->configuredChannels() : 0;
}

void dsp_set_limiter_knee(void* handle, float dB) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setLimiterKnee(dB);
}

// MBC
void dsp_set_mbc_enabled(void* handle, bool enabled) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setMbcEnabled(enabled);
}

bool dsp_is_mbc_enabled(void* handle) {
    if (handle) return static_cast<RoomDSPEngine*>(handle)->isMbcEnabled();
    return false;
}

void dsp_set_mbc_pre_gain(void* handle, float dB) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setMbcPreGain(dB);
}

void dsp_set_mbc_noise_gate(void* handle, float dB) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setMbcNoiseGateThreshold(dB);
}

void dsp_set_mbc_knee_width(void* handle, float dB) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setMbcKneeWidth(dB);
}

void dsp_set_mbc_expander_ratio(void* handle, float ratio) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setMbcExpanderRatio(ratio);
}

void dsp_set_mbc_threshold(void* handle, float dB) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setMbcThreshold(dB);
}

void dsp_set_mbc_ratio(void* handle, float ratio) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setMbcRatio(ratio);
}

void dsp_set_mbc_attack_time(void* handle, float ms) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setMbcAttackTime(ms);
}

void dsp_set_mbc_release_time(void* handle, float ms) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setMbcReleaseTime(ms);
}

void dsp_set_mbc_post_gain(void* handle, float dB) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setMbcPostGain(dB);
}

// Reverb
void dsp_set_reverb_enabled(void* handle, bool enabled) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setReverbEnabled(enabled);
}

void dsp_set_room_size(void* handle, float v) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setRoomSize(v);
}

void dsp_set_decay(void* handle, float v) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setDecay(v);
}

void dsp_set_damping(void* handle, float v) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setDamping(v);
}

void dsp_set_pre_delay(void* handle, float ms) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setPreDelay(ms);
}

void dsp_set_diffusion(void* handle, float v) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setDiffusion(v);
}

void dsp_set_reverb_wet_dry(void* handle, float v) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setReverbWetDry(v);
}

// Stereo Expand (amount 0..1; 0 = off)
void dsp_set_stereo_expand(void* handle, float amount) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setStereoExpand(amount);
}

// Crossfeed
void dsp_set_crossfeed_enabled(void* handle, bool enabled) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setCrossfeedEnabled(enabled);
}

void dsp_set_crossfeed_params(void* handle, float cutoffHz, float feedLevelDb) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setCrossfeedParams(cutoffHz, feedLevelDb);
}

void dsp_set_surround3d_enabled(void* handle, bool enabled) {
    if (handle) static_cast<RoomDSPEngine*>(handle)->setSurround3dEnabled(enabled);
}

void dsp_set_surround3d_params(void* handle, float intensity, float subwoofer) {
    if (handle) {
        auto* e = static_cast<RoomDSPEngine*>(handle);
        e->setSurround3dIntensity(intensity);
        e->setSurround3dSubwoofer(subwoofer);
    }
}

void dsp_set_surround3d_speakers(void* handle, bool frontL, bool frontR,
                                 bool sideL, bool sideR,
                                 bool surroundL, bool surroundR) {
    if (handle) {
        static_cast<RoomDSPEngine*>(handle)->setSurround3dSpeakers(
            frontL, frontR, sideL, sideR, surroundL, surroundR);
    }
}

// Live stems
static void copyOut(const std::string& s, char* buf, int len) {
    if (!buf || len <= 0) return;
    const size_t n = std::min(s.size(), size_t(len - 1));
    std::memcpy(buf, s.data(), n);
    buf[n] = 0;
}

void dsp_stems_init(const char* cacheDir) {
    hype::stems::StemEngine::instance().setCacheDir(cacheDir ? cacheDir : "");
}

bool dsp_stems_load_model(const char* dir, char* error, int errorLen) {
    std::string err;
    const bool ok = hype::stems::StemEngine::instance().loadModel(dir ? dir : "", &err);
    copyOut(err, error, errorLen);
    return ok;
}

void dsp_stems_unload_model(void) {
    hype::stems::StemEngine::instance().unloadModel();
}

void dsp_stems_benchmark(char* json, int jsonLen) {
    const auto b = hype::stems::StemEngine::instance().benchmark();
    char head[96];
    std::snprintf(head, sizeof head, "{\"ok\":%s,\"rtf\":%.4f,\"millis\":%d,\"error\":\"",
                  b.ok ? "true" : "false", b.rtf, b.millis);
    copyOut(std::string(head) + hype::stems::jsonEscape(b.error) + "\"}", json, jsonLen);
}

void dsp_stems_set_armed(bool armed) {
    hype::stems::StemEngine::instance().setArmed(armed);
}

void dsp_stems_set_levels(float vocals, float drums, float instruments) {
    hype::stems::StemEngine::instance().setLevels(vocals, drums, instruments);
}

void dsp_stems_provide_stream(const char* streamUrl, const char* fileUrl) {
    if (!streamUrl || !fileUrl || !*fileUrl) return;
    const std::string file = fileUrl;
    hype::stems::StemEngine::instance().provideSource(
        streamUrl, [file] { return hype::stems::createAvPcmSource(file); });
}

void dsp_stems_status_json(char* json, int jsonLen) {
    copyOut(hype::stems::StemEngine::instance().status().toJson(), json, jsonLen);
}

void dsp_stems_set_status_callback(dsp_stems_status_cb cb, void* ctx) {
    auto& engine = hype::stems::StemEngine::instance();
    if (!cb) {
        engine.setStatusCallback(nullptr);
        return;
    }
    engine.setStatusCallback([cb, ctx](const hype::stems::StemStatus& st) { cb(st.toJson().c_str(), ctx); });
}

void* dsp_stem_tap_create(const char* trackUrl) {
    const std::string url = trackUrl ? trackUrl : "";
    hype::stems::PcmSourceFactory factory;
    std::string reason;
    if (url.rfind("file://", 0) == 0 || url.rfind("ipod-library://", 0) == 0) {
        factory = [url] { return hype::stems::createAvPcmSource(url); };
    } else if (url.rfind("http://", 0) != 0 && url.rfind("https://", 0) != 0) {
        reason = "unsupported";  // the engine itself marks http(s) as "stream"
    }
    auto& engine = hype::stems::StemEngine::instance();
    const uint32_t id = url.empty() ? 0 : engine.registerTrack(url, factory, reason);
    auto* tap = new hype::stems::StemTap(engine);
    tap->bindTrack(id);
    return tap;
}

void dsp_stem_tap_destroy(void* tap) {
    delete static_cast<hype::stems::StemTap*>(tap);
}

void dsp_stem_tap_prepare(void* tap, int sampleRate) {
    if (tap) static_cast<hype::stems::StemTap*>(tap)->setSampleRate(sampleRate);
}

void dsp_stem_tap_process(void* tap, float* interleaved, int frames, int64_t framePos,
                          bool discontinuity) {
    if (!tap) return;
    auto* t = static_cast<hype::stems::StemTap*>(tap);
    t->setPosition(framePos, discontinuity);
    t->process(interleaved, frames);
}

} // extern "C"
