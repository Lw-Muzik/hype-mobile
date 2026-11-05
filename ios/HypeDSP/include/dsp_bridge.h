// C bridge for RoomDSPEngine — called from Swift via bridging header.
// All functions are plain C so they can be used from both Objective-C and Swift.

#ifndef DSP_BRIDGE_H
#define DSP_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Lifecycle
void* dsp_create(int sampleRate, int channels);
void  dsp_destroy(void* handle);
void  dsp_reinit(void* handle, int sampleRate, int channels);
void  dsp_reset(void* handle);

// Process interleaved stereo float PCM in-place
void  dsp_process_float(void* handle, float* buffer, int numFrames);

// EQ
void  dsp_set_eq_enabled(void* handle, bool enabled);
void  dsp_set_preamp_gain(void* handle, float dB);
float dsp_get_preamp_gain(void* handle);
void  dsp_set_headroom_db(void* handle, float dB);
void  dsp_set_speaker_preamp_db(void* handle, float dB);
void  dsp_set_track_gain_db(void* handle, float dB);
void  dsp_set_master_volume_db(void* handle, float dB);
void  dsp_set_mono(void* handle, bool enabled);
void  dsp_set_balance(void* handle, float balance);
void  dsp_set_graphic_band_gain(void* handle, int band, float dB);
void  dsp_set_graphic_all_bands(void* handle, const float* gains, int count);
void  dsp_set_parametric_band(void* handle, int band, float freq, float gainDb,
                               float q, int filterType, bool enabled);
void  dsp_set_parametric_all_bands(void* handle, const float* freqs,
                                    const float* gains, const float* qs, int count);

// Speaker correction EQ
void  dsp_set_speaker_eq_enabled(void* handle, bool enabled);
void  dsp_set_speaker_eq_band(void* handle, int band, float freq, float gainDb,
                               float q, int filterType, bool enabled);
void  dsp_clear_speaker_eq(void* handle);

// Tone controls
void  dsp_set_tone_enabled(void* handle, bool enabled);
void  dsp_set_bass_gain(void* handle, float dB);
void  dsp_set_bass_freq(void* handle, float hz);
void  dsp_set_bass_q(void* handle, float q);
void  dsp_set_treble_gain(void* handle, float dB);
void  dsp_set_treble_freq(void* handle, float hz);
void  dsp_set_treble_q(void* handle, float q);

// Output limiter
void  dsp_set_limiter_enabled(void* handle, bool enabled);
void  dsp_set_limiter_ceiling(void* handle, float v);
void  dsp_set_limiter_release(void* handle, float ms);
void  dsp_set_limiter_knee(void* handle, float dB);

// MBC
void  dsp_set_mbc_enabled(void* handle, bool enabled);
bool  dsp_is_mbc_enabled(void* handle);
void  dsp_set_mbc_pre_gain(void* handle, float dB);
void  dsp_set_mbc_noise_gate(void* handle, float dB);
void  dsp_set_mbc_knee_width(void* handle, float dB);
void  dsp_set_mbc_expander_ratio(void* handle, float ratio);
void  dsp_set_mbc_threshold(void* handle, float dB);
void  dsp_set_mbc_ratio(void* handle, float ratio);
void  dsp_set_mbc_attack_time(void* handle, float ms);
void  dsp_set_mbc_release_time(void* handle, float ms);
void  dsp_set_mbc_post_gain(void* handle, float dB);

// Reverb
void  dsp_set_reverb_enabled(void* handle, bool enabled);
void  dsp_set_room_size(void* handle, float v);
void  dsp_set_decay(void* handle, float v);
void  dsp_set_damping(void* handle, float v);
void  dsp_set_pre_delay(void* handle, float ms);
void  dsp_set_diffusion(void* handle, float v);
void  dsp_set_reverb_wet_dry(void* handle, float v);

// Stereo Expand (amount 0..1; 0 = off)
void  dsp_set_stereo_expand(void* handle, float amount);

// Crossfeed
void  dsp_set_crossfeed_enabled(void* handle, bool enabled);
void  dsp_set_crossfeed_params(void* handle, float cutoffHz, float feedLevelDb);

// 3D Surround (port of the desktop stage; see surround3d.h)
void  dsp_set_surround3d_enabled(void* handle, bool enabled);
void  dsp_set_surround3d_params(void* handle, float intensity, float subwoofer);
void  dsp_set_surround3d_speakers(void* handle, bool frontL, bool frontR,
                                  bool sideL, bool sideR,
                                  bool surroundL, bool surroundR);

// Live stems (stems/stem_engine.h): one engine per process, one tap per
// AVPlayerItem audio tap. See HypeAudioTap.m.
void  dsp_stems_init(const char* cacheDir);
bool  dsp_stems_load_model(const char* dir, char* error, int errorLen);
void  dsp_stems_unload_model(void);
// Writes {"ok":bool,"rtf":double,"millis":int,"error":string} into `json`.
void  dsp_stems_benchmark(char* json, int jsonLen);
void  dsp_stems_set_armed(bool armed);
void  dsp_stems_set_levels(float vocals, float drums, float instruments);
// A local copy (file URL) of the stream the player plays from `streamUrl`.
void  dsp_stems_provide_stream(const char* streamUrl, const char* fileUrl);
// Writes the current status as JSON (same shape as the callback's).
void  dsp_stems_status_json(char* json, int jsonLen);
typedef void (*dsp_stems_status_cb)(const char* json, void* ctx);
// `cb` runs on the engine's worker thread.
void  dsp_stems_set_status_callback(dsp_stems_status_cb cb, void* ctx);

void* dsp_stem_tap_create(const char* trackUrl);
void  dsp_stem_tap_destroy(void* tap);
void  dsp_stem_tap_prepare(void* tap, int sampleRate);
// Real-time safe. `framePos` = asset time of the first frame, in frames.
void  dsp_stem_tap_process(void* tap, float* interleaved, int frames,
                           int64_t framePos, bool discontinuity);

#ifdef __cplusplus
}
#endif

#endif // DSP_BRIDGE_H
