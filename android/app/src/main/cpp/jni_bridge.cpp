#include <jni.h>
#include <android/log.h>
#include <algorithm>
#include <mutex>
#include "room_dsp_engine.h"
#include "fft_visualizer.h"

#define LOG_TAG "HypeDSP"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

extern "C" {

JNIEXPORT jlong JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeCreate(JNIEnv* env, jobject, jint sampleRate, jint channels) {
    auto* engine = new RoomDSPEngine();
    engine->init(sampleRate, channels);
    LOGI("DSP engine created: %dHz, %dch", sampleRate, channels);
    return reinterpret_cast<jlong>(engine);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeDestroy(JNIEnv* env, jobject, jlong handle) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    delete engine;
    LOGI("DSP engine destroyed");
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeReset(JNIEnv* env, jobject, jlong handle) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->reset();
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeReinit(JNIEnv* env, jobject, jlong handle, jint sampleRate, jint channels) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->init(sampleRate, channels);
}

// --- Process ---

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeProcessFloat(JNIEnv* env, jobject, jlong handle,
                                                       jobject buffer, jint numFrames) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (!engine) return;

    auto* data = static_cast<float*>(env->GetDirectBufferAddress(buffer));
    if (!data) return;

    engine->process(data, numFrames);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeProcessShort(JNIEnv* env, jobject, jlong handle,
                                                       jobject buffer, jint numFrames) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (!engine) return;

    auto* data = static_cast<short*>(env->GetDirectBufferAddress(buffer));
    if (!data) return;

    int totalSamples = numFrames * 2; // stereo
    constexpr int STACK_LIMIT = 4096;
    float stackBuf[STACK_LIMIT];
    float* floatBuf;
    float* heapBuf = nullptr;

    if (totalSamples <= STACK_LIMIT) {
        floatBuf = stackBuf;
    } else {
        heapBuf = new float[totalSamples];
        floatBuf = heapBuf;
    }

    // Convert short to float (-1.0 to 1.0)
    constexpr float toFloat = 1.0f / 32768.0f;
    for (int i = 0; i < totalSamples; i++) {
        floatBuf[i] = data[i] * toFloat;
    }

    engine->process(floatBuf, numFrames);

    // Convert float back to short with clipping
    for (int i = 0; i < totalSamples; i++) {
        float v = floatBuf[i] * 32768.0f;
        if (v > 32767.0f) v = 32767.0f;
        if (v < -32768.0f) v = -32768.0f;
        data[i] = static_cast<short>(v);
    }

    delete[] heapBuf;
}

// --- Reverb controls ---

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetReverbEnabled(JNIEnv*, jobject, jlong handle, jboolean enabled) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setReverbEnabled(enabled);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetRoomSize(JNIEnv*, jobject, jlong handle, jfloat v) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setRoomSize(v);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetDecay(JNIEnv*, jobject, jlong handle, jfloat v) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setDecay(v);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetDamping(JNIEnv*, jobject, jlong handle, jfloat v) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setDamping(v);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetPreDelay(JNIEnv*, jobject, jlong handle, jfloat ms) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setPreDelay(ms);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetDiffusion(JNIEnv*, jobject, jlong handle, jfloat v) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setDiffusion(v);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetReverbWetDry(JNIEnv*, jobject, jlong handle, jfloat v) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setReverbWetDry(v);
}

// --- Stereo Expand (amount 0..1; 0 = off) ---

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetStereoExpand(JNIEnv*, jobject, jlong handle, jfloat amount) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setStereoExpand(amount);
}

// --- Crossfeed controls ---

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetCrossfeedEnabled(JNIEnv*, jobject, jlong handle, jboolean enabled) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setCrossfeedEnabled(enabled);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetCrossfeedParams(JNIEnv*, jobject, jlong handle,
                                                            jfloat cutoffHz, jfloat feedLevelDb) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setCrossfeedParams(cutoffHz, feedLevelDb);
}

// --- 3D Surround controls (port of the desktop stage; see surround3d.h) ---

extern "C" JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetSurround3dEnabled(JNIEnv*, jobject, jlong handle, jboolean enabled) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setSurround3dEnabled(enabled);
}

extern "C" JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetSurround3dParams(JNIEnv*, jobject, jlong handle,
                                                           jfloat intensity, jfloat subwoofer) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) {
        engine->setSurround3dIntensity(intensity);
        engine->setSurround3dSubwoofer(subwoofer);
    }
}

extern "C" JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetSurround3dSpeakers(JNIEnv*, jobject, jlong handle,
                                                             jboolean frontL, jboolean frontR,
                                                             jboolean sideL, jboolean sideR,
                                                             jboolean surroundL, jboolean surroundR) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setSurround3dSpeakers(frontL, frontR, sideL, sideR, surroundL, surroundR);
}

// --- EQ controls ---

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetEqEnabled(JNIEnv*, jobject, jlong handle, jboolean enabled) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setEqEnabled(enabled);
}

// Android system-wide EQ: the platform equalizer applies the graphic EQ, tone,
// preamp and headroom to the whole mix (this app included), so the engine
// holds those stages (and track gain, balance, mono, stereo expand) neutral.
JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetPlatformEqActive(JNIEnv*, jobject, jlong handle, jboolean active) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setPlatformEqActive(active == JNI_TRUE);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetPreampGain(JNIEnv*, jobject, jlong handle, jfloat dB) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setPreampGain(dB);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetSpeakerPreampDb(JNIEnv*, jobject, jlong handle, jfloat dB) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setSpeakerPreampDb(dB);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetHeadroomDb(JNIEnv*, jobject, jlong handle, jfloat v) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setHeadroomDb(v);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetSmoothGains(JNIEnv*, jobject, jlong handle, jboolean on) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setSmoothGains(on == JNI_TRUE);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetSystemVolumeDb(JNIEnv*, jobject, jlong handle, jfloat v) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setSystemVolumeDb(v);
}

// The smooth-gain rule for a level, for callers without an engine (the
// platform equalizer in system-wide mode): {eqDb, bassDb}.
JNIEXPORT jfloatArray JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSmoothScales(JNIEnv* env, jclass, jfloat levelDb, jboolean on) {
    const SmoothScales s = smoothGainScales(levelDb, on == JNI_TRUE);
    const jfloat out[2] = {s.eqDb, s.bassDb};
    jfloatArray result = env->NewFloatArray(2);
    if (result) env->SetFloatArrayRegion(result, 0, 2, out);
    return result;
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetTrackGainDb(JNIEnv*, jobject, jlong handle, jfloat v) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setTrackGainDb(v);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetMasterVolumeDb(JNIEnv*, jobject, jlong handle, jfloat v) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setMasterVolumeDb(v);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetMono(JNIEnv*, jobject, jlong handle, jboolean v) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setMono(v == JNI_TRUE);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetBalance(JNIEnv*, jobject, jlong handle, jfloat v) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setBalance(v);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetGraphicBandGain(JNIEnv*, jobject, jlong handle,
                                                            jint band, jfloat dB) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setGraphicBandGain(band, dB);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetGraphicAllBands(JNIEnv* env, jobject, jlong handle,
                                                            jfloatArray gains) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (!engine) return;
    jfloat* data = env->GetFloatArrayElements(gains, nullptr);
    if (!data) return;
    int count = env->GetArrayLength(gains);
    engine->setGraphicAllBands(data, count);
    env->ReleaseFloatArrayElements(gains, data, JNI_ABORT);
}

// Layout and gains in one call. `gains` may be null (layout only); a longer
// array than `centres` is read only as far as the centres go, a shorter one
// shortens the layout so no value is read past an array's end.
JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetGraphicLayout(JNIEnv* env, jobject, jlong handle,
                                                          jfloatArray centres, jfloatArray gains) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (!engine || !centres) return;
    int count = env->GetArrayLength(centres);
    if (gains) count = std::min(count, static_cast<int>(env->GetArrayLength(gains)));
    if (count <= 0) return;
    jfloat* c = env->GetFloatArrayElements(centres, nullptr);
    if (!c) return;
    jfloat* g = gains ? env->GetFloatArrayElements(gains, nullptr) : nullptr;
    if (!gains || g) engine->setGraphicLayout(c, count, g);
    if (g) env->ReleaseFloatArrayElements(gains, g, JNI_ABORT);
    env->ReleaseFloatArrayElements(centres, c, JNI_ABORT);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetParametricBand(JNIEnv*, jobject, jlong handle,
                                                           jint band, jfloat freq, jfloat gainDb,
                                                           jfloat q, jint filterType, jboolean enabled) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setParametricBand(band, freq, gainDb, q, filterType, enabled);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetParametricAllBands(JNIEnv* env, jobject, jlong handle,
                                                               jfloatArray freqs, jfloatArray gains,
                                                               jfloatArray qs, jint count) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (!engine) return;
    jfloat* fData = env->GetFloatArrayElements(freqs, nullptr);
    jfloat* gData = env->GetFloatArrayElements(gains, nullptr);
    jfloat* qData = env->GetFloatArrayElements(qs, nullptr);
    if (fData && gData && qData) {
        engine->setParametricAllBands(fData, gData, qData, count);
    }
    if (fData) env->ReleaseFloatArrayElements(freqs, fData, JNI_ABORT);
    if (gData) env->ReleaseFloatArrayElements(gains, gData, JNI_ABORT);
    if (qData) env->ReleaseFloatArrayElements(qs, qData, JNI_ABORT);
}

// --- MBC controls ---

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetMbcEnabled(JNIEnv*, jobject, jlong handle, jboolean enabled) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setMbcEnabled(enabled);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetMbcPreGain(JNIEnv*, jobject, jlong handle, jfloat dB) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setMbcPreGain(dB);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetMbcNoiseGate(JNIEnv*, jobject, jlong handle, jfloat dB) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setMbcNoiseGateThreshold(dB);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetMbcKneeWidth(JNIEnv*, jobject, jlong handle, jfloat dB) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setMbcKneeWidth(dB);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetMbcExpanderRatio(JNIEnv*, jobject, jlong handle, jfloat ratio) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setMbcExpanderRatio(ratio);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetMbcThreshold(JNIEnv*, jobject, jlong handle, jfloat dB) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setMbcThreshold(dB);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetMbcRatio(JNIEnv*, jobject, jlong handle, jfloat ratio) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setMbcRatio(ratio);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetMbcAttackTime(JNIEnv*, jobject, jlong handle, jfloat ms) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setMbcAttackTime(ms);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetMbcReleaseTime(JNIEnv*, jobject, jlong handle, jfloat ms) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setMbcReleaseTime(ms);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetMbcPostGain(JNIEnv*, jobject, jlong handle, jfloat dB) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setMbcPostGain(dB);
}

// --- Speaker correction EQ ---

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetSpeakerEqEnabled(JNIEnv*, jobject, jlong handle, jboolean enabled) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setSpeakerEqEnabled(enabled);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetSpeakerEqBand(JNIEnv*, jobject, jlong handle,
                                                          jint band, jfloat freq, jfloat gainDb,
                                                          jfloat q, jint filterType, jboolean enabled) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setSpeakerEqBand(band, freq, gainDb, q, filterType, enabled);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeClearSpeakerEq(JNIEnv*, jobject, jlong handle) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->clearSpeakerEq();
}

// --- Tone controls (bass/treble) ---

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetToneEnabled(JNIEnv*, jobject, jlong handle, jboolean enabled) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setToneEnabled(enabled);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetBassGain(JNIEnv*, jobject, jlong handle, jfloat dB) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setBassGain(dB);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetBassFreq(JNIEnv*, jobject, jlong handle, jfloat hz) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setBassFreq(hz);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetBassQ(JNIEnv*, jobject, jlong handle, jfloat q) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setBassQ(q);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetTrebleGain(JNIEnv*, jobject, jlong handle, jfloat dB) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setTrebleGain(dB);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetTrebleFreq(JNIEnv*, jobject, jlong handle, jfloat hz) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setTrebleFreq(hz);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetTrebleQ(JNIEnv*, jobject, jlong handle, jfloat q) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setTrebleQ(q);
}

// --- Output limiter controls ---

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetLimiterEnabled(JNIEnv*, jobject, jlong handle, jboolean enabled) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setLimiterEnabled(enabled);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetLimiterCeiling(JNIEnv*, jobject, jlong handle, jfloat v) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setLimiterCeiling(v);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetLimiterRelease(JNIEnv*, jobject, jlong handle, jfloat ms) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setLimiterRelease(ms);
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeSetLimiterKnee(JNIEnv*, jobject, jlong handle, jfloat dB) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->setLimiterKnee(dB);
}

JNIEXPORT jfloat JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeGetLimiterReductionDb(JNIEnv*, jobject, jlong handle) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    return engine ? engine->limiterReductionDb() : 0.0f;
}

// --- Live stems: this player's tap (see stems/stem_tap.h) ---
// Called on the ExoPlayer playback thread, in pipeline order, by
// RoomEffectsProcessor and the audio-sink wrapper in the patched just_audio.

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeStemFlush(JNIEnv*, jobject, jlong handle) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->stemTap().onFlush();
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeStemStreamChange(JNIEnv*, jobject, jlong handle) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->stemTap().onStreamChange();
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeStemBufferTime(JNIEnv*, jobject, jlong handle, jlong mediaTimeUs) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->stemTap().onBufferTime(static_cast<int64_t>(mediaTimeUs));
}

JNIEXPORT void JNICALL
Java_x_a_zix_RoomEffectsProcessor_nativeStemSetKeys(JNIEnv*, jobject, jlong handle, jint current, jint next) {
    auto* engine = reinterpret_cast<RoomDSPEngine*>(handle);
    if (engine) engine->stemTap().setKeys(static_cast<uint32_t>(current), static_cast<uint32_t>(next));
}

// ===================== FFT Visualizer =====================

static FFTVisualizer* g_fftViz = nullptr;
// Two locks, so the audio thread never waits on a visualizer computation:
//  - g_fftMutex guards the pointer against the audio thread (pushSamples,
//    try_lock only) and is held just for create/destroy.
//  - g_vizMutex serialises everything else — the viz tick's computations and
//    the settings — and is also held for create/destroy.
// They used to be one lock, so every push that landed while a viz tick held
// it was dropped: a gap in the ring that the bass filters would read as a
// hit, and an index that no longer matched the player's clock.
static std::mutex g_fftMutex;
static std::mutex g_vizMutex;

JNIEXPORT void JNICALL
Java_x_a_zix_VisualizerTapProcessor_nativeInitFFT(JNIEnv*, jobject) {
    std::lock_guard<std::mutex> viz(g_vizMutex);
    std::lock_guard<std::mutex> lock(g_fftMutex);
    if (!g_fftViz) {
        g_fftViz = new FFTVisualizer();
        LOGI("FFT visualizer initialized (FFT_SIZE=%d, NUM_BANDS=%d)",
             FFTVisualizer::FFT_SIZE, FFTVisualizer::NUM_BANDS);
    }
}

JNIEXPORT void JNICALL
Java_x_a_zix_VisualizerTapProcessor_nativeDestroyFFT(JNIEnv*, jobject) {
    std::lock_guard<std::mutex> viz(g_vizMutex);
    std::lock_guard<std::mutex> lock(g_fftMutex);
    delete g_fftViz;
    g_fftViz = nullptr;
    LOGI("FFT visualizer destroyed");
}

JNIEXPORT jlong JNICALL
Java_x_a_zix_VisualizerTapProcessor_nativePushSamples(
        JNIEnv* env, jobject, jfloatArray samples, jint numFrames) {
    // Called on the real-time ExoPlayer audio thread. Use try_lock so we NEVER
    // block the audio thread; the lock is only contended while the FFT object
    // is being created or destroyed, and then the buffer is skipped.
    // Returns the ring index the buffer landed at, -1 when skipped.
    jlong first = -1;
    float* data = env->GetFloatArrayElements(samples, nullptr);
    {
        std::unique_lock<std::mutex> lock(g_fftMutex, std::try_to_lock);
        if (lock.owns_lock() && g_fftViz) {
            first = static_cast<jlong>(g_fftViz->pushSamples(data, numFrames));
        }
    }
    env->ReleaseFloatArrayElements(samples, data, JNI_ABORT);
    return first;
}

JNIEXPORT jfloatArray JNICALL
Java_x_a_zix_VisualizerTapProcessor_nativeComputeBands(JNIEnv* env, jobject, jlong endIndex) {
    std::lock_guard<std::mutex> lock(g_vizMutex);
    if (!g_fftViz) return nullptr;
    float bands[FFTVisualizer::NUM_BANDS];
    if (!g_fftViz->computeBands(bands, static_cast<int64_t>(endIndex))) return nullptr;

    jfloatArray result = env->NewFloatArray(FFTVisualizer::NUM_BANDS);
    env->SetFloatArrayRegion(result, 0, FFTVisualizer::NUM_BANDS, bands);
    return result;
}

JNIEXPORT jfloatArray JNICALL
Java_x_a_zix_VisualizerTapProcessor_nativeComputeBeat(
        JNIEnv* env, jobject, jlong endIndex, jint sampleRate) {
    std::lock_guard<std::mutex> lock(g_vizMutex);
    if (!g_fftViz) return nullptr;
    g_fftViz->setSampleRate(sampleRate);
    float frame[FFTVisualizer::BEAT_FRAME_MAX];
    const int count = g_fftViz->computeBeat(frame, static_cast<int64_t>(endIndex));
    jfloatArray result = env->NewFloatArray(count);
    env->SetFloatArrayRegion(result, 0, count, frame);
    return result;
}

JNIEXPORT void JNICALL
Java_x_a_zix_VisualizerTapProcessor_nativeSetSmoothing(
        JNIEnv*, jobject, jfloat attack, jfloat decay) {
    std::lock_guard<std::mutex> lock(g_vizMutex);
    if (g_fftViz) {
        g_fftViz->attackRate = attack;
        g_fftViz->decayRate = decay;
    }
}

JNIEXPORT void JNICALL
Java_x_a_zix_VisualizerTapProcessor_nativeSetGain(JNIEnv*, jobject, jfloat gain) {
    std::lock_guard<std::mutex> lock(g_vizMutex);
    if (g_fftViz) {
        g_fftViz->gain = gain;
    }
}

JNIEXPORT jbyteArray JNICALL
Java_x_a_zix_VisualizerTapProcessor_nativeGetWaveform(JNIEnv* env, jobject, jlong endIndex) {
    std::lock_guard<std::mutex> lock(g_vizMutex);
    if (!g_fftViz) return nullptr;
    static constexpr int WAVE_SIZE = 1024;
    uint8_t wave[WAVE_SIZE];
    int count = g_fftViz->getWaveform(wave, WAVE_SIZE, static_cast<int64_t>(endIndex));
    if (count <= 0) return nullptr;

    jbyteArray result = env->NewByteArray(count);
    env->SetByteArrayRegion(result, 0, count, reinterpret_cast<jbyte*>(wave));
    return result;
}

} // extern "C"
