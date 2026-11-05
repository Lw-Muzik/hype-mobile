package x.a.zix;

import android.os.Build;
import android.util.Log;
import androidx.annotation.NonNull;
import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.audio.BaseAudioProcessor;
import com.ryanheise.just_audio.StemSinkListener;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * Media3 AudioProcessor that processes PCM audio through a native C++ DSP engine.
 * Supports reverb (Freeverb), stereo expansion (M/S), and crossfeed (BS2B).
 *
 * Each ExoPlayer instance gets its own processor via {@link #createPlayerInstance()},
 * ensuring independent buffer management and native DSP state. This is critical for
 * crossfade where two players process audio concurrently — a shared singleton would
 * corrupt BaseAudioProcessor's internal buffer and the native engine state.
 *
 * Parameter changes from the UI are broadcast to all player instances via the
 * static broadcast methods. Cached params are applied when a new native handle
 * is created (in onFlush) so late-initialized players get current settings.
 *
 * Live stems: each instance's native engine owns a StemTap (cpp/stems). The
 * patched just_audio reports, through {@link StemSinkListener}, which queue
 * item this player is on and the media time of the buffers reaching its sink,
 * so the tap knows which track and sample it is processing.
 */
public class RoomEffectsProcessor extends BaseAudioProcessor implements StemSinkListener {
    private static final String TAG = "RoomEffectsProcessor";

    static {
        System.loadLibrary("eq_app");
    }

    // All player-attached instances — each ExoPlayer gets its own
    private static final CopyOnWriteArrayList<RoomEffectsProcessor> playerInstances =
            new CopyOnWriteArrayList<>();

    // The same instances, addressable by just_audio player id (per-player
    // settings such as track gain). Instances created without an id are only
    // in the list above.
    private static final ConcurrentHashMap<String, RoomEffectsProcessor> instancesByPlayerId =
            new ConcurrentHashMap<>();

    // Track gain per player id — applied to that player's engine on every flush.
    private static final ConcurrentHashMap<String, Float> cachedTrackGainDb =
            new ConcurrentHashMap<>();

    // Cached params — applied to new native handles on creation
    private static volatile boolean cachedReverbEnabled = false;
    private static volatile float cachedRoomSize = 0.5f;
    private static volatile float cachedDecay = 0.5f;
    private static volatile float cachedDamping = 0.5f;
    private static volatile float cachedPreDelay = 0f;
    private static volatile float cachedDiffusion = 0.5f;
    private static volatile float cachedReverbWetDry = 0.3f;
    private static volatile float cachedStereoExpand = 0f;
    private static volatile boolean cachedCrossfeedEnabled = false;
    private static volatile float cachedCrossfeedCutoff = 700f;
    private static volatile float cachedCrossfeedFeed = 4.5f;
    // 3D Surround. Defaults mirror the desktop panel: off, and a moderate
    // intensity so switching it on is audible without being a cliff.
    private static volatile boolean cachedSurround3dEnabled = false;
    private static volatile float cachedSurround3dIntensity = 0.6f;
    private static volatile float cachedSurround3dSubwoofer = 0.35f;
    private static volatile boolean cachedS3dFrontL = true;
    private static volatile boolean cachedS3dFrontR = true;
    private static volatile boolean cachedS3dSideL = true;
    private static volatile boolean cachedS3dSideR = true;
    private static volatile boolean cachedS3dSurroundL = true;
    private static volatile boolean cachedS3dSurroundR = true;

    // Cached EQ params
    private static volatile boolean cachedEqEnabled = false;
    // True while GlobalEqService is running — bypasses C++ EQ for own app to prevent double-EQ.
    private static volatile boolean cachedGlobalEqActive = false;
    private static volatile float cachedPreampGain = 0f;
    private static volatile float cachedHeadroomDb = 0f;
    private static volatile float cachedSpeakerPreampDb = 0f;
    private static volatile float cachedMasterVolumeDb = 0f;
    private static volatile boolean cachedMono = false;
    private static volatile float cachedBalance = 0f;
    private static final float[] cachedGraphicGains = new float[32]; // all 0.0f
    private static final float[] cachedParametricFreqs = new float[32];
    private static final float[] cachedParametricGains = new float[32];
    private static final float[] cachedParametricQs = new float[32];
    // Cached MBC params
    private static volatile boolean cachedMbcEnabled = false;
    private static volatile float cachedMbcPreGain = 0f;
    private static volatile float cachedMbcNoiseGate = -70f;
    private static volatile float cachedMbcKneeWidth = 8f;
    private static volatile float cachedMbcExpanderRatio = 2f;
    private static volatile float cachedMbcThreshold = -24f;
    private static volatile float cachedMbcRatio = 4f;
    private static volatile float cachedMbcAttackTime = 5f;
    private static volatile float cachedMbcReleaseTime = 50f;
    private static volatile float cachedMbcPostGain = 0f;

    // Cached Tone controls (bass/treble)
    private static volatile boolean cachedToneEnabled = false;
    private static volatile float cachedBassGain = 0f;
    private static volatile float cachedBassFreq = 80f;
    private static volatile float cachedBassQ = 0.707f;
    private static volatile float cachedTrebleGain = 0f;
    private static volatile float cachedTrebleFreq = 10000f;
    private static volatile float cachedTrebleQ = 0.707f;

    // Cached Limiter
    private static volatile boolean cachedLimiterEnabled = true;
    private static volatile float cachedLimiterCeiling = 0.98f;
    private static volatile float cachedLimiterRelease = 50f;
    private static volatile float cachedLimiterKnee = 6f;

    // Cached Speaker correction EQ (AutoEq headphone profiles)
    private static volatile boolean cachedSpeakerEqEnabled = false;
    private static volatile int cachedSpeakerBandCount = 0;
    private static final float[] cachedSpeakerEqFreqs = new float[32];
    private static final float[] cachedSpeakerEqGains = new float[32];
    private static final float[] cachedSpeakerEqQs = new float[32];
    private static final int[] cachedSpeakerEqTypes = new int[32];

    static {
        // Initialize parametric defaults
        for (int i = 0; i < 32; i++) {
            cachedParametricFreqs[i] = 1000f;
            cachedParametricQs[i] = 1.4f;
        }
    }

    /**
     * Called from MainActivity.onCreate() to ensure the native library is loaded.
     * No longer creates a singleton used in the audio pipeline.
     */
    public static RoomEffectsProcessor getInstance() {
        // Just ensure class is loaded (static block loads native lib).
        // Return a dummy instance for backward compat — not used in audio pipeline.
        return new RoomEffectsProcessor();
    }

    public static boolean hasInstance() {
        return !playerInstances.isEmpty();
    }

    /**
     * Called by just_audio's AudioPlayer.java via reflection.
     * Each ExoPlayer gets its own processor with independent buffer state
     * and native DSP engine handle.
     */
    public static RoomEffectsProcessor createPlayerInstance() {
        return createPlayerInstance("");
    }

    /**
     * Same, for the just_audio player with the given id, so per-player
     * settings (track gain) can be addressed to this instance's engine.
     */
    public static RoomEffectsProcessor createPlayerInstance(String playerId) {
        RoomEffectsProcessor p = new RoomEffectsProcessor(playerId == null ? "" : playerId);
        playerInstances.add(p);
        if (!p.playerId.isEmpty()) instancesByPlayerId.put(p.playerId, p);
        Log.i(TAG, "Player instance created, total: " + playerInstances.size());
        return p;
    }

    // Native engine handle — unique per instance. Written on the playback
    // thread; read under handleLock by the main thread (stem key updates).
    private volatile long nativeHandle = 0;
    private final Object handleLock = new Object();

    // Live stems: engine ids of this player's current and next queue item, and
    // whether the tap still needs the media time of the next buffer.
    private volatile int stemKeyCurrent = 0;
    private volatile int stemKeyNext = 0;
    private boolean stemNeedTime = true;

    private final String playerId;
    // This instance's own track gain; survives a mid-life onReset, which drops
    // the id from the static cache.
    private volatile Float trackGainDb = null;

    private RoomEffectsProcessor() { this(""); }

    private RoomEffectsProcessor(String playerId) { this.playerId = playerId; }

    // ---- BaseAudioProcessor overrides ----

    @Override
    protected AudioFormat onConfigure(AudioFormat inputAudioFormat)
            throws UnhandledAudioFormatException {
        int encoding = inputAudioFormat.encoding;
        if (encoding != C.ENCODING_PCM_16BIT && encoding != C.ENCODING_PCM_FLOAT) {
            throw new UnhandledAudioFormatException(inputAudioFormat);
        }
        if (inputAudioFormat.channelCount != 2) {
            Log.w(TAG, "Non-stereo audio (" + inputAudioFormat.channelCount + "ch), passing through");
            return AudioFormat.NOT_SET;
        }

        Log.i(TAG, "Configured: " + inputAudioFormat.sampleRate + "Hz, " +
            inputAudioFormat.channelCount + "ch, encoding=" + encoding);
        return inputAudioFormat;
    }

    @Override
    public void queueInput(ByteBuffer inputBuffer) {
        if (!inputBuffer.hasRemaining()) return;

        int remaining = inputBuffer.remaining();
        int encoding = inputAudioFormat.encoding;
        int bytesPerSample = (encoding == C.ENCODING_PCM_FLOAT) ? 4 : 2;
        int numFrames = remaining / (bytesPerSample * 2); // stereo = 2 channels

        if (numFrames <= 0) {
            inputBuffer.position(inputBuffer.limit());
            return;
        }

        ByteBuffer outputBuffer = replaceOutputBuffer(remaining);
        outputBuffer.put(inputBuffer);
        outputBuffer.flip();

        // Process through this instance's native DSP engine
        if (nativeHandle != 0) {
            if (encoding == C.ENCODING_PCM_FLOAT) {
                nativeProcessFloat(nativeHandle, outputBuffer, numFrames);
            } else {
                nativeProcessShort(nativeHandle, outputBuffer, numFrames);
            }
        }
    }

    @Override
    protected void onFlush() {
        // Re-register if a prior onReset() removed this instance mid-life.
        // media3 can flush/reset a still-live processor during setAudioSource
        // reconfiguration (not only on player release), so onReset() may drop
        // us from the broadcast list before the player is actually disposed.
        // CopyOnWriteArrayList makes contains()/add() safe here; the native
        // handle is (re)created below so a re-added instance is fully live.
        if (!playerInstances.contains(this)) {
            playerInstances.add(this);
        }
        if (!playerId.isEmpty()) {
            instancesByPlayerId.put(playerId, this);
            Float own = trackGainDb;
            if (own != null) cachedTrackGainDb.putIfAbsent(playerId, own);
        }
        if (inputAudioFormat != AudioFormat.NOT_SET) {
            synchronized (handleLock) {
                if (nativeHandle != 0) {
                    nativeReinit(nativeHandle, inputAudioFormat.sampleRate,
                        inputAudioFormat.channelCount);
                } else {
                    nativeHandle = nativeCreate(inputAudioFormat.sampleRate,
                        inputAudioFormat.channelCount);
                }
                // Apply current cached params to this instance's native handle
                applyCachedParams();
                // A flush means a seek or a new source: the stem tap must learn
                // where it is again from the next buffer's media time.
                nativeStemFlush(nativeHandle);
                nativeStemSetKeys(nativeHandle, stemKeyCurrent, stemKeyNext);
            }
            stemNeedTime = true;
        }
    }

    @Override
    protected void onReset() {
        synchronized (handleLock) {
            if (nativeHandle != 0) {
                nativeDestroy(nativeHandle);
                nativeHandle = 0;
            }
        }
        // Prune this instance so the static list doesn't grow unbounded across
        // crossfade/stop-start cycles (just_audio disposes and recreates the
        // platform player, which reset()s each processor). Without this every
        // cycle leaked a stale processor and every broadcast* fanned out over
        // an ever-growing list. If media3 later flushes this same instance
        // (mid-life reset), onFlush() re-adds it.
        playerInstances.remove(this);
        if (!playerId.isEmpty()) {
            instancesByPlayerId.remove(playerId, this);
            // Pruned so ids of disposed players don't accumulate; onFlush
            // restores it from trackGainDb if this instance comes back.
            cachedTrackGainDb.remove(playerId);
        }
    }

    // ---- StemSinkListener (patched just_audio) ----

    @Override
    public void onSinkStreamChange() {
        // Playback thread. The next buffers belong to another queue item.
        long h = nativeHandle;
        if (h != 0) nativeStemStreamChange(h);
        stemNeedTime = true;
    }

    @Override
    public void onSinkBuffer(long mediaTimeUs) {
        // Playback thread, before the buffer enters this processor. Only the
        // first buffer after a flush or stream change matters; frames are
        // counted natively from there.
        if (!stemNeedTime) return;
        long h = nativeHandle;
        if (h == 0) return;
        nativeStemBufferTime(h, mediaTimeUs);
        stemNeedTime = false;
    }

    @Override
    public void onTrackKeys(String currentUri, String nextUri) {
        // Main thread.
        int current = StemEngineBridge.registerTrack(currentUri);
        int next = StemEngineBridge.registerTrack(nextUri);
        stemKeyCurrent = current;
        stemKeyNext = next;
        synchronized (handleLock) {
            if (nativeHandle != 0) nativeStemSetKeys(nativeHandle, current, next);
        }
    }

    /** Apply all cached params to this instance's native handle. */
    private void applyCachedParams() {
        if (nativeHandle == 0) return;
        nativeSetReverbEnabled(nativeHandle, cachedReverbEnabled);
        nativeSetRoomSize(nativeHandle, cachedRoomSize);
        nativeSetDecay(nativeHandle, cachedDecay);
        nativeSetDamping(nativeHandle, cachedDamping);
        nativeSetPreDelay(nativeHandle, cachedPreDelay);
        nativeSetDiffusion(nativeHandle, cachedDiffusion);
        nativeSetReverbWetDry(nativeHandle, cachedReverbWetDry);
        nativeSetStereoExpand(nativeHandle, cachedStereoExpand);
        nativeSetCrossfeedEnabled(nativeHandle, cachedCrossfeedEnabled);
        nativeSetCrossfeedParams(nativeHandle, cachedCrossfeedCutoff, cachedCrossfeedFeed);
        // Re-applied on every (re)attach, like every other cached stage: a new
        // player instance starts with a fresh native engine that knows nothing.
        nativeSetSurround3dEnabled(nativeHandle, cachedSurround3dEnabled);
        nativeSetSurround3dParams(nativeHandle, cachedSurround3dIntensity,
                cachedSurround3dSubwoofer);
        nativeSetSurround3dSpeakers(nativeHandle, cachedS3dFrontL, cachedS3dFrontR,
                cachedS3dSideL, cachedS3dSideR, cachedS3dSurroundL, cachedS3dSurroundR);
        // EQ state (bypass own-app EQ when global EQ service is active)
        nativeSetEqEnabled(nativeHandle, cachedEqEnabled && !cachedGlobalEqActive);
        nativeSetPreampGain(nativeHandle, cachedPreampGain);
        // Level stages: replayed before the first buffer so a new engine never
        // plays a buffer at the wrong level.
        nativeSetHeadroomDb(nativeHandle, cachedHeadroomDb);
        nativeSetMasterVolumeDb(nativeHandle, cachedMasterVolumeDb);
        nativeSetMono(nativeHandle, cachedMono);
        nativeSetBalance(nativeHandle, cachedBalance);
        if (!playerId.isEmpty()) {
            // The cache holds a value set since the last reset; it wins over
            // this instance's older own copy and becomes the new one.
            Float cached = cachedTrackGainDb.get(playerId);
            if (cached != null) trackGainDb = cached;
            Float own = trackGainDb;
            nativeSetTrackGainDb(nativeHandle, own != null ? own : 0f);
        }
        nativeSetGraphicAllBands(nativeHandle, cachedGraphicGains);
        nativeSetParametricAllBands(nativeHandle, cachedParametricFreqs,
                cachedParametricGains, cachedParametricQs, 32);
        // MBC state
        nativeSetMbcEnabled(nativeHandle, cachedMbcEnabled);
        nativeSetMbcPreGain(nativeHandle, cachedMbcPreGain);
        nativeSetMbcNoiseGate(nativeHandle, cachedMbcNoiseGate);
        nativeSetMbcKneeWidth(nativeHandle, cachedMbcKneeWidth);
        nativeSetMbcExpanderRatio(nativeHandle, cachedMbcExpanderRatio);
        nativeSetMbcThreshold(nativeHandle, cachedMbcThreshold);
        nativeSetMbcRatio(nativeHandle, cachedMbcRatio);
        nativeSetMbcAttackTime(nativeHandle, cachedMbcAttackTime);
        nativeSetMbcReleaseTime(nativeHandle, cachedMbcReleaseTime);
        nativeSetMbcPostGain(nativeHandle, cachedMbcPostGain);
        // Tone controls
        nativeSetToneEnabled(nativeHandle, cachedToneEnabled);
        nativeSetBassGain(nativeHandle, cachedBassGain);
        nativeSetBassFreq(nativeHandle, cachedBassFreq);
        nativeSetBassQ(nativeHandle, cachedBassQ);
        nativeSetTrebleGain(nativeHandle, cachedTrebleGain);
        nativeSetTrebleFreq(nativeHandle, cachedTrebleFreq);
        nativeSetTrebleQ(nativeHandle, cachedTrebleQ);
        // Limiter
        nativeSetLimiterEnabled(nativeHandle, cachedLimiterEnabled);
        nativeSetLimiterCeiling(nativeHandle, cachedLimiterCeiling);
        nativeSetLimiterRelease(nativeHandle, cachedLimiterRelease);
        nativeSetLimiterKnee(nativeHandle, cachedLimiterKnee);
        // Speaker correction EQ
        nativeSetSpeakerEqEnabled(nativeHandle, cachedSpeakerEqEnabled);
        nativeSetSpeakerPreampDb(nativeHandle, cachedSpeakerPreampDb);
        int spkCount = cachedSpeakerBandCount;
        for (int i = 0; i < spkCount; i++) {
            nativeSetSpeakerEqBand(nativeHandle, i, cachedSpeakerEqFreqs[i],
                    cachedSpeakerEqGains[i], cachedSpeakerEqQs[i],
                    cachedSpeakerEqTypes[i], true);
        }
    }

    // ---- Instance methods (called on specific instance) ----

    public void setReverbEnabled(boolean enabled) {
        if (nativeHandle != 0) nativeSetReverbEnabled(nativeHandle, enabled);
    }

    public void setRoomSize(float v) {
        if (nativeHandle != 0) nativeSetRoomSize(nativeHandle, v);
    }

    public void setDecay(float v) {
        if (nativeHandle != 0) nativeSetDecay(nativeHandle, v);
    }

    public void setDamping(float v) {
        if (nativeHandle != 0) nativeSetDamping(nativeHandle, v);
    }

    public void setPreDelay(float ms) {
        if (nativeHandle != 0) nativeSetPreDelay(nativeHandle, ms);
    }

    public void setDiffusion(float v) {
        if (nativeHandle != 0) nativeSetDiffusion(nativeHandle, v);
    }

    public void setReverbWetDry(float v) {
        if (nativeHandle != 0) nativeSetReverbWetDry(nativeHandle, v);
    }

    /** Stereo Expand amount, 0..1 (0 = off). */
    public void setStereoExpand(float amount) {
        if (nativeHandle != 0) nativeSetStereoExpand(nativeHandle, amount);
    }

    public void setCrossfeedEnabled(boolean enabled) {
        if (nativeHandle != 0) nativeSetCrossfeedEnabled(nativeHandle, enabled);
    }

    public void setCrossfeedParams(float cutoffHz, float feedLevelDb) {
        if (nativeHandle != 0) nativeSetCrossfeedParams(nativeHandle, cutoffHz, feedLevelDb);
    }

    public void setSurround3dEnabled(boolean enabled) {
        if (nativeHandle != 0) nativeSetSurround3dEnabled(nativeHandle, enabled);
    }

    public void setSurround3dParams(float intensity, float subwoofer) {
        if (nativeHandle != 0) nativeSetSurround3dParams(nativeHandle, intensity, subwoofer);
    }

    public void setSurround3dSpeakers(boolean frontL, boolean frontR, boolean sideL,
                                      boolean sideR, boolean surroundL, boolean surroundR) {
        if (nativeHandle != 0) {
            nativeSetSurround3dSpeakers(nativeHandle, frontL, frontR, sideL, sideR,
                    surroundL, surroundR);
        }
    }

    // EQ instance methods
    public void setEqEnabled(boolean enabled) {
        if (nativeHandle != 0) nativeSetEqEnabled(nativeHandle, enabled);
    }

    public void setPreampGain(float dB) {
        if (nativeHandle != 0) nativeSetPreampGain(nativeHandle, dB);
    }

    public void setSpeakerPreampDb(float dB) {
        if (nativeHandle != 0) nativeSetSpeakerPreampDb(nativeHandle, dB);
    }

    public void setHeadroomDb(float dB) {
        if (nativeHandle != 0) nativeSetHeadroomDb(nativeHandle, dB);
    }

    public void setTrackGainDb(float dB) {
        trackGainDb = dB;
        if (nativeHandle != 0) nativeSetTrackGainDb(nativeHandle, dB);
    }

    public void setMasterVolumeDb(float dB) {
        if (nativeHandle != 0) nativeSetMasterVolumeDb(nativeHandle, dB);
    }

    public void setMono(boolean on) {
        if (nativeHandle != 0) nativeSetMono(nativeHandle, on);
    }

    public void setBalance(float balance) {
        if (nativeHandle != 0) nativeSetBalance(nativeHandle, balance);
    }

    public void setGraphicBandGain(int band, float dB) {
        if (nativeHandle != 0) nativeSetGraphicBandGain(nativeHandle, band, dB);
    }

    public void setGraphicAllBands(float[] gains) {
        if (nativeHandle != 0) nativeSetGraphicAllBands(nativeHandle, gains);
    }

    public void setParametricBand(int band, float freq, float gainDb, float q,
                                  int filterType, boolean enabled) {
        if (nativeHandle != 0) nativeSetParametricBand(nativeHandle, band, freq, gainDb,
                q, filterType, enabled);
    }

    public void setParametricAllBands(float[] freqs, float[] gains, float[] qs, int count) {
        if (nativeHandle != 0) nativeSetParametricAllBands(nativeHandle, freqs, gains, qs, count);
    }

    // MBC instance methods
    public void setMbcEnabled(boolean enabled) {
        if (nativeHandle != 0) nativeSetMbcEnabled(nativeHandle, enabled);
    }

    public void setMbcPreGain(float dB) {
        if (nativeHandle != 0) nativeSetMbcPreGain(nativeHandle, dB);
    }

    public void setMbcNoiseGate(float dB) {
        if (nativeHandle != 0) nativeSetMbcNoiseGate(nativeHandle, dB);
    }

    public void setMbcKneeWidth(float dB) {
        if (nativeHandle != 0) nativeSetMbcKneeWidth(nativeHandle, dB);
    }

    public void setMbcExpanderRatio(float ratio) {
        if (nativeHandle != 0) nativeSetMbcExpanderRatio(nativeHandle, ratio);
    }

    public void setMbcThreshold(float dB) {
        if (nativeHandle != 0) nativeSetMbcThreshold(nativeHandle, dB);
    }

    public void setMbcRatio(float ratio) {
        if (nativeHandle != 0) nativeSetMbcRatio(nativeHandle, ratio);
    }

    public void setMbcAttackTime(float ms) {
        if (nativeHandle != 0) nativeSetMbcAttackTime(nativeHandle, ms);
    }

    public void setMbcReleaseTime(float ms) {
        if (nativeHandle != 0) nativeSetMbcReleaseTime(nativeHandle, ms);
    }

    public void setMbcPostGain(float dB) {
        if (nativeHandle != 0) nativeSetMbcPostGain(nativeHandle, dB);
    }

    // Tone control instance methods
    public void setToneEnabled(boolean enabled) {
        if (nativeHandle != 0) nativeSetToneEnabled(nativeHandle, enabled);
    }

    public void setBassGain(float dB) {
        if (nativeHandle != 0) nativeSetBassGain(nativeHandle, dB);
    }

    public void setBassFreq(float hz) {
        if (nativeHandle != 0) nativeSetBassFreq(nativeHandle, hz);
    }

    public void setBassQ(float q) {
        if (nativeHandle != 0) nativeSetBassQ(nativeHandle, q);
    }

    public void setTrebleGain(float dB) {
        if (nativeHandle != 0) nativeSetTrebleGain(nativeHandle, dB);
    }

    public void setTrebleFreq(float hz) {
        if (nativeHandle != 0) nativeSetTrebleFreq(nativeHandle, hz);
    }

    public void setTrebleQ(float q) {
        if (nativeHandle != 0) nativeSetTrebleQ(nativeHandle, q);
    }

    // Limiter instance methods
    public void setLimiterEnabled(boolean enabled) {
        if (nativeHandle != 0) nativeSetLimiterEnabled(nativeHandle, enabled);
    }

    public void setLimiterCeiling(float v) {
        if (nativeHandle != 0) nativeSetLimiterCeiling(nativeHandle, v);
    }

    public void setLimiterRelease(float ms) {
        if (nativeHandle != 0) nativeSetLimiterRelease(nativeHandle, ms);
    }

    public void setLimiterKnee(float dB) {
        if (nativeHandle != 0) nativeSetLimiterKnee(nativeHandle, dB);
    }

    // ---- Static broadcast methods (called from MainActivity via MethodChannel) ----

    public static void broadcastReverbEnabled(boolean enabled) {
        cachedReverbEnabled = enabled;
        for (RoomEffectsProcessor p : playerInstances) p.setReverbEnabled(enabled);
    }

    public static void broadcastRoomSize(float v) {
        cachedRoomSize = v;
        for (RoomEffectsProcessor p : playerInstances) p.setRoomSize(v);
    }

    public static void broadcastDecay(float v) {
        cachedDecay = v;
        for (RoomEffectsProcessor p : playerInstances) p.setDecay(v);
    }

    public static void broadcastDamping(float v) {
        cachedDamping = v;
        for (RoomEffectsProcessor p : playerInstances) p.setDamping(v);
    }

    public static void broadcastPreDelay(float ms) {
        cachedPreDelay = ms;
        for (RoomEffectsProcessor p : playerInstances) p.setPreDelay(ms);
    }

    public static void broadcastDiffusion(float v) {
        cachedDiffusion = v;
        for (RoomEffectsProcessor p : playerInstances) p.setDiffusion(v);
    }

    public static void broadcastReverbWetDry(float v) {
        cachedReverbWetDry = v;
        for (RoomEffectsProcessor p : playerInstances) p.setReverbWetDry(v);
    }

    public static void broadcastStereoExpand(float amount) {
        cachedStereoExpand = amount;
        for (RoomEffectsProcessor p : playerInstances) p.setStereoExpand(amount);
    }

    public static void broadcastCrossfeedEnabled(boolean enabled) {
        cachedCrossfeedEnabled = enabled;
        for (RoomEffectsProcessor p : playerInstances) p.setCrossfeedEnabled(enabled);
    }

    public static void broadcastSurround3dEnabled(boolean enabled) {
        cachedSurround3dEnabled = enabled;
        for (RoomEffectsProcessor p : playerInstances) p.setSurround3dEnabled(enabled);
    }

    public static void broadcastSurround3dParams(float intensity, float subwoofer) {
        cachedSurround3dIntensity = intensity;
        cachedSurround3dSubwoofer = subwoofer;
        for (RoomEffectsProcessor p : playerInstances) p.setSurround3dParams(intensity, subwoofer);
    }

    public static void broadcastSurround3dSpeakers(boolean frontL, boolean frontR, boolean sideL,
                                                   boolean sideR, boolean surroundL,
                                                   boolean surroundR) {
        cachedS3dFrontL = frontL;   cachedS3dFrontR = frontR;
        cachedS3dSideL = sideL;     cachedS3dSideR = sideR;
        cachedS3dSurroundL = surroundL; cachedS3dSurroundR = surroundR;
        for (RoomEffectsProcessor p : playerInstances) {
            p.setSurround3dSpeakers(frontL, frontR, sideL, sideR, surroundL, surroundR);
        }
    }

    public static void broadcastCrossfeedParams(float cutoffHz, float feedLevelDb) {
        cachedCrossfeedCutoff = cutoffHz;
        cachedCrossfeedFeed = feedLevelDb;
        for (RoomEffectsProcessor p : playerInstances) p.setCrossfeedParams(cutoffHz, feedLevelDb);
    }

    // ---- EQ broadcast methods ----

    /**
     * Called by GlobalEqService when it starts/stops.
     * While active, own-app C++ EQ is bypassed so the global DynamicsProcessing
     * handles all audio (including ours) — prevents double-EQ.
     */
    public static void broadcastGlobalEqActive(boolean active) {
        cachedGlobalEqActive = active;
        // Apply/restore EQ bypass on all active player instances
        for (RoomEffectsProcessor p : playerInstances) {
            p.setEqEnabled(cachedEqEnabled && !active);
        }
    }

    public static void broadcastEqEnabled(boolean enabled) {
        cachedEqEnabled = enabled;
        for (RoomEffectsProcessor p : playerInstances) p.setEqEnabled(enabled && !cachedGlobalEqActive);
        syncGlobalEq();
    }

    public static void broadcastPreampGain(float dB) {
        cachedPreampGain = dB;
        for (RoomEffectsProcessor p : playerInstances) p.setPreampGain(dB);
        syncGlobalEq();
    }

    public static void broadcastSpeakerPreampDb(float dB) {
        cachedSpeakerPreampDb = dB;
        for (RoomEffectsProcessor p : playerInstances) p.setSpeakerPreampDb(dB);
    }

    public static void broadcastHeadroomDb(float dB) {
        cachedHeadroomDb = dB;
        for (RoomEffectsProcessor p : playerInstances) p.setHeadroomDb(dB);
    }

    public static void broadcastMasterVolumeDb(float dB) {
        cachedMasterVolumeDb = dB;
        for (RoomEffectsProcessor p : playerInstances) p.setMasterVolumeDb(dB);
    }

    public static void broadcastMono(boolean on) {
        cachedMono = on;
        for (RoomEffectsProcessor p : playerInstances) p.setMono(on);
    }

    public static void broadcastBalance(float balance) {
        cachedBalance = balance;
        for (RoomEffectsProcessor p : playerInstances) p.setBalance(balance);
    }

    /** Track gain of one player; cached by id so a later engine for it starts right. */
    public static void setTrackGainDb(String playerId, float dB) {
        if (playerId == null || playerId.isEmpty()) return;
        cachedTrackGainDb.put(playerId, dB);
        RoomEffectsProcessor p = instancesByPlayerId.get(playerId);
        if (p != null) p.setTrackGainDb(dB);  // also updates the instance's own copy
    }

    public static void broadcastGraphicBandGain(int band, float dB) {
        if (band >= 0 && band < 32) cachedGraphicGains[band] = dB;
        for (RoomEffectsProcessor p : playerInstances) p.setGraphicBandGain(band, dB);
        syncGlobalEq();
    }

    public static void broadcastGraphicAllBands(float[] gains) {
        int count = Math.min(gains.length, 32);
        System.arraycopy(gains, 0, cachedGraphicGains, 0, count);
        for (RoomEffectsProcessor p : playerInstances) p.setGraphicAllBands(gains);
        syncGlobalEq();
    }

    public static void broadcastParametricBand(int band, float freq, float gainDb,
                                               float q, int filterType, boolean enabled) {
        if (band >= 0 && band < 32) {
            cachedParametricFreqs[band] = freq;
            cachedParametricGains[band] = gainDb;
            cachedParametricQs[band] = q;
        }
        for (RoomEffectsProcessor p : playerInstances)
            p.setParametricBand(band, freq, gainDb, q, filterType, enabled);
    }

    public static void broadcastParametricAllBands(float[] freqs, float[] gains,
                                                    float[] qs, int count) {
        int n = Math.min(count, 32);
        System.arraycopy(freqs, 0, cachedParametricFreqs, 0, n);
        System.arraycopy(gains, 0, cachedParametricGains, 0, n);
        System.arraycopy(qs, 0, cachedParametricQs, 0, n);
        for (RoomEffectsProcessor p : playerInstances)
            p.setParametricAllBands(freqs, gains, qs, count);
    }

    public static float getCachedPreampGain() {
        return cachedPreampGain;
    }

    public static boolean isCachedMbcEnabled() {
        return cachedMbcEnabled;
    }

    // ---- Package-private accessors for GlobalEqSessionManager ----

    static boolean isCachedEqEnabled() { return cachedEqEnabled; }
    static float[] getCachedGraphicGains() {
        float[] copy = new float[32];
        System.arraycopy(cachedGraphicGains, 0, copy, 0, 32);
        return copy;
    }
    static boolean isCachedToneEnabled() { return cachedToneEnabled; }
    static float getCachedBassGain() { return cachedBassGain; }
    static float getCachedBassFreq() { return cachedBassFreq; }
    static float getCachedTrebleGain() { return cachedTrebleGain; }
    static float getCachedTrebleFreq() { return cachedTrebleFreq; }
    static boolean isCachedLimiterEnabled() { return cachedLimiterEnabled; }
    static float getCachedLimiterCeiling() { return cachedLimiterCeiling; }
    static float getCachedLimiterRelease() { return cachedLimiterRelease; }

    /** Sync global EQ sessions when EQ-related params change. */
    private static void syncGlobalEq() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            GlobalEqSessionManager.syncAllSessions();
        }
    }

    // ---- MBC broadcast methods ----

    public static void broadcastMbcEnabled(boolean enabled) {
        cachedMbcEnabled = enabled;
        for (RoomEffectsProcessor p : playerInstances) p.setMbcEnabled(enabled);
    }

    public static void broadcastMbcPreGain(float dB) {
        cachedMbcPreGain = dB;
        for (RoomEffectsProcessor p : playerInstances) p.setMbcPreGain(dB);
    }

    public static void broadcastMbcNoiseGate(float dB) {
        cachedMbcNoiseGate = dB;
        for (RoomEffectsProcessor p : playerInstances) p.setMbcNoiseGate(dB);
    }

    public static void broadcastMbcKneeWidth(float dB) {
        cachedMbcKneeWidth = dB;
        for (RoomEffectsProcessor p : playerInstances) p.setMbcKneeWidth(dB);
    }

    public static void broadcastMbcExpanderRatio(float ratio) {
        cachedMbcExpanderRatio = ratio;
        for (RoomEffectsProcessor p : playerInstances) p.setMbcExpanderRatio(ratio);
    }

    public static void broadcastMbcThreshold(float dB) {
        cachedMbcThreshold = dB;
        for (RoomEffectsProcessor p : playerInstances) p.setMbcThreshold(dB);
    }

    public static void broadcastMbcRatio(float ratio) {
        cachedMbcRatio = ratio;
        for (RoomEffectsProcessor p : playerInstances) p.setMbcRatio(ratio);
    }

    public static void broadcastMbcAttackTime(float ms) {
        cachedMbcAttackTime = ms;
        for (RoomEffectsProcessor p : playerInstances) p.setMbcAttackTime(ms);
    }

    public static void broadcastMbcReleaseTime(float ms) {
        cachedMbcReleaseTime = ms;
        for (RoomEffectsProcessor p : playerInstances) p.setMbcReleaseTime(ms);
    }

    public static void broadcastMbcPostGain(float dB) {
        cachedMbcPostGain = dB;
        for (RoomEffectsProcessor p : playerInstances) p.setMbcPostGain(dB);
    }

    // ---- Tone control broadcast methods ----

    public static void broadcastToneEnabled(boolean enabled) {
        cachedToneEnabled = enabled;
        for (RoomEffectsProcessor p : playerInstances) p.setToneEnabled(enabled);
        syncGlobalEq();
    }

    public static void broadcastBassGain(float dB) {
        cachedBassGain = dB;
        for (RoomEffectsProcessor p : playerInstances) p.setBassGain(dB);
        syncGlobalEq();
    }

    public static void broadcastBassFreq(float hz) {
        cachedBassFreq = hz;
        for (RoomEffectsProcessor p : playerInstances) p.setBassFreq(hz);
        syncGlobalEq();
    }

    public static void broadcastBassQ(float q) {
        cachedBassQ = q;
        for (RoomEffectsProcessor p : playerInstances) p.setBassQ(q);
    }

    public static void broadcastTrebleGain(float dB) {
        cachedTrebleGain = dB;
        for (RoomEffectsProcessor p : playerInstances) p.setTrebleGain(dB);
        syncGlobalEq();
    }

    public static void broadcastTrebleFreq(float hz) {
        cachedTrebleFreq = hz;
        for (RoomEffectsProcessor p : playerInstances) p.setTrebleFreq(hz);
        syncGlobalEq();
    }

    public static void broadcastTrebleQ(float q) {
        cachedTrebleQ = q;
        for (RoomEffectsProcessor p : playerInstances) p.setTrebleQ(q);
    }

    // ---- Speaker correction EQ instance methods ----

    public void setSpeakerEqEnabled(boolean enabled) {
        if (nativeHandle != 0) nativeSetSpeakerEqEnabled(nativeHandle, enabled);
    }

    public void setSpeakerEqBand(int band, float freq, float gainDb, float q,
                                  int filterType, boolean enabled) {
        if (nativeHandle != 0) nativeSetSpeakerEqBand(nativeHandle, band, freq, gainDb,
                q, filterType, enabled);
    }

    public void clearSpeakerEq() {
        if (nativeHandle != 0) nativeClearSpeakerEq(nativeHandle);
    }

    // ---- Speaker correction EQ broadcast methods ----

    public static void broadcastSpeakerEqEnabled(boolean enabled) {
        cachedSpeakerEqEnabled = enabled;
        for (RoomEffectsProcessor p : playerInstances) p.setSpeakerEqEnabled(enabled);
    }

    public static void broadcastSpeakerEqBands(float[] freqs, float[] gains,
                                                 float[] qs, int[] types, int count) {
        int n = Math.min(count, 32);
        cachedSpeakerBandCount = n;
        System.arraycopy(freqs, 0, cachedSpeakerEqFreqs, 0, n);
        System.arraycopy(gains, 0, cachedSpeakerEqGains, 0, n);
        System.arraycopy(qs, 0, cachedSpeakerEqQs, 0, n);
        System.arraycopy(types, 0, cachedSpeakerEqTypes, 0, n);
        for (RoomEffectsProcessor p : playerInstances) {
            for (int i = 0; i < n; i++) {
                p.setSpeakerEqBand(i, freqs[i], gains[i], qs[i], types[i], true);
            }
        }
    }

    public static void broadcastClearSpeakerEq() {
        cachedSpeakerBandCount = 0;
        for (int i = 0; i < 32; i++) {
            cachedSpeakerEqFreqs[i] = 0f;
            cachedSpeakerEqGains[i] = 0f;
            cachedSpeakerEqQs[i] = 0f;
            cachedSpeakerEqTypes[i] = 0;
        }
        for (RoomEffectsProcessor p : playerInstances) p.clearSpeakerEq();
    }

    // ---- Limiter broadcast methods ----

    public static void broadcastLimiterEnabled(boolean enabled) {
        cachedLimiterEnabled = enabled;
        for (RoomEffectsProcessor p : playerInstances) p.setLimiterEnabled(enabled);
        syncGlobalEq();
    }

    public static void broadcastLimiterCeiling(float v) {
        cachedLimiterCeiling = v;
        for (RoomEffectsProcessor p : playerInstances) p.setLimiterCeiling(v);
        syncGlobalEq();
    }

    public static void broadcastLimiterRelease(float ms) {
        cachedLimiterRelease = ms;
        for (RoomEffectsProcessor p : playerInstances) p.setLimiterRelease(ms);
        syncGlobalEq();
    }

    public static void broadcastLimiterKnee(float dB) {
        cachedLimiterKnee = dB;
        for (RoomEffectsProcessor p : playerInstances) p.setLimiterKnee(dB);
    }

    // ---- Native methods ----

    private native long nativeCreate(int sampleRate, int channels);
    private native void nativeDestroy(long handle);
    private native void nativeReset(long handle);
    private native void nativeReinit(long handle, int sampleRate, int channels);

    private native void nativeProcessFloat(long handle, ByteBuffer buffer, int numFrames);
    private native void nativeProcessShort(long handle, ByteBuffer buffer, int numFrames);

    private native void nativeSetReverbEnabled(long handle, boolean enabled);
    private native void nativeSetRoomSize(long handle, float v);
    private native void nativeSetDecay(long handle, float v);
    private native void nativeSetDamping(long handle, float v);
    private native void nativeSetPreDelay(long handle, float ms);
    private native void nativeSetDiffusion(long handle, float v);
    private native void nativeSetReverbWetDry(long handle, float v);

    private native void nativeSetStereoExpand(long handle, float amount);

    private native void nativeSetCrossfeedEnabled(long handle, boolean enabled);
    private native void nativeSetCrossfeedParams(long handle, float cutoffHz, float feedLevelDb);

    private native void nativeSetSurround3dEnabled(long handle, boolean enabled);
    private native void nativeSetSurround3dParams(long handle, float intensity, float subwoofer);
    private native void nativeSetSurround3dSpeakers(long handle, boolean frontL, boolean frontR,
                                                    boolean sideL, boolean sideR,
                                                    boolean surroundL, boolean surroundR);

    private native void nativeSetEqEnabled(long handle, boolean enabled);
    private native void nativeSetPreampGain(long handle, float dB);
    private native void nativeSetHeadroomDb(long handle, float dB);
    private native void nativeSetSpeakerPreampDb(long handle, float dB);
    private native void nativeSetTrackGainDb(long handle, float dB);
    private native void nativeSetMasterVolumeDb(long handle, float dB);
    private native void nativeSetMono(long handle, boolean on);
    private native void nativeSetBalance(long handle, float balance);
    private native void nativeSetGraphicBandGain(long handle, int band, float dB);
    private native void nativeSetGraphicAllBands(long handle, float[] gains);
    private native void nativeSetParametricBand(long handle, int band, float freq,
                                                float gainDb, float q, int filterType,
                                                boolean enabled);
    private native void nativeSetParametricAllBands(long handle, float[] freqs, float[] gains,
                                                     float[] qs, int count);

    private native void nativeSetMbcEnabled(long handle, boolean enabled);
    private native void nativeSetMbcPreGain(long handle, float dB);
    private native void nativeSetMbcNoiseGate(long handle, float dB);
    private native void nativeSetMbcKneeWidth(long handle, float dB);
    private native void nativeSetMbcExpanderRatio(long handle, float ratio);
    private native void nativeSetMbcThreshold(long handle, float dB);
    private native void nativeSetMbcRatio(long handle, float ratio);
    private native void nativeSetMbcAttackTime(long handle, float ms);
    private native void nativeSetMbcReleaseTime(long handle, float ms);
    private native void nativeSetMbcPostGain(long handle, float dB);

    // Tone control natives
    private native void nativeSetToneEnabled(long handle, boolean enabled);
    private native void nativeSetBassGain(long handle, float dB);
    private native void nativeSetBassFreq(long handle, float hz);
    private native void nativeSetBassQ(long handle, float q);
    private native void nativeSetTrebleGain(long handle, float dB);
    private native void nativeSetTrebleFreq(long handle, float hz);
    private native void nativeSetTrebleQ(long handle, float q);

    // Limiter natives
    private native void nativeSetLimiterEnabled(long handle, boolean enabled);
    private native void nativeSetLimiterCeiling(long handle, float v);
    private native void nativeSetLimiterRelease(long handle, float ms);
    private native void nativeSetLimiterKnee(long handle, float dB);

    // Speaker correction EQ natives
    private native void nativeSetSpeakerEqEnabled(long handle, boolean enabled);
    private native void nativeSetSpeakerEqBand(long handle, int band, float freq,
                                                float gainDb, float q, int filterType,
                                                boolean enabled);
    private native void nativeClearSpeakerEq(long handle);

    // Live stems: this player's tap (cpp/stems/stem_tap.h)
    private native void nativeStemFlush(long handle);
    private native void nativeStemStreamChange(long handle);
    private native void nativeStemBufferTime(long handle, long mediaTimeUs);
    private native void nativeStemSetKeys(long handle, int current, int next);
}
