package x.a.zix;

import android.media.audiofx.DynamicsProcessing;
import android.os.Build;
import android.util.Log;

import androidx.annotation.RequiresApi;

import java.util.concurrent.ConcurrentHashMap;

/**
 * Manages DynamicsProcessing instances attached to external apps' audio sessions.
 * Each external session gets its own DynamicsProcessing configured from RoomEffectsProcessor's
 * cached EQ/tone/limiter state.
 *
 * The in-app C++ DSP pipeline is completely independent — this only affects external audio.
 */
@RequiresApi(api = Build.VERSION_CODES.P)
public class GlobalEqSessionManager {
    private static final String TAG = "GlobalEqSessionManager";

    // Single global DynamicsProcessing attached to the output mix (sessionId = 0).
    // Per-session attachment to external apps requires system-level permissions on
    // Android 10+ and is not available to normal apps. sessionId = 0 is the
    // standard approach used by third-party EQ apps.
    private static volatile DynamicsProcessing globalDp = null;
    // Pre-EQ band count of the live instance. A DynamicsProcessing config is
    // fixed at creation, so a different graphic band count needs a new instance.
    private static volatile int globalBandCount = 0;
    private static volatile boolean enabled = false;

    // The values the smooth-gains scales are divided by to give a factor (the
    // scale with smoothing off; see smooth_gains.h).
    private static final float EQ_SCALE_OFF_DB = 15f;
    private static final float BASS_SCALE_OFF_DB = 22.5f;

    private GlobalEqSessionManager() {}

    public static boolean isEnabled() {
        return enabled;
    }

    public static void setEnabled(boolean on) {
        enabled = on;
        if (!on) releaseAll();
    }

    /**
     * Create and attach the global DynamicsProcessing to the output mix (sessionId = 0).
     * Affects all audio output from all apps on the device.
     */
    public static synchronized void attachGlobal() {
        if (!enabled || globalDp != null) return;
        try {
            int count = RoomEffectsProcessor.getCachedGraphicCount();
            globalDp = createConfiguredInstance(0, count); // 0 = global output mix
            globalBandCount = count;
            globalDp.setEnabled(true);
            Log.i(TAG, "Global DynamicsProcessing attached to output mix, " + count + " bands");
        } catch (Exception e) {
            Log.e(TAG, "Failed to attach global DynamicsProcessing: " + e.getMessage());
            // createConfiguredInstance releases its own on failure; this covers setEnabled.
            if (globalDp != null) {
                try { globalDp.release(); } catch (Exception ignored) {}
            }
            globalDp = null;
            globalBandCount = 0;
        }
    }

    /** Release the global DynamicsProcessing (called when service stops). */
    public static synchronized void releaseAll() {
        releaseInstance();
        Log.i(TAG, "Global EQ released");
    }

    private static void releaseInstance() {
        if (globalDp != null) {
            try {
                globalDp.setEnabled(false);
                globalDp.release();
            } catch (Exception ignored) {}
            globalDp = null;
        }
        globalBandCount = 0;
    }

    /**
     * Re-apply current EQ state to the global effect.
     * Called whenever the user changes EQ/tone/limiter settings.
     */
    public static synchronized void syncAllSessions() {
        if (!enabled) return;
        if (globalDp == null) {
            // A rebuild or attach that failed earlier: try again on every change.
            attachGlobal();
            return;
        }
        try {
            int count = RoomEffectsProcessor.getCachedGraphicCount();
            if (count != globalBandCount) {
                // The band count is fixed at creation: rebuild (may drop out briefly).
                releaseInstance();
                attachGlobal();
                return;
            }
            applyState(globalDp, count);
        } catch (Exception e) {
            Log.w(TAG, "Error syncing global EQ: " + e.getMessage());
        }
    }

    // Kept for backward-compatibility — no-ops since we use global sessionId=0.
    public static void attachSession(int sessionId, String pkg) {}
    public static void detachSession(int sessionId) {}

    /** Create a DynamicsProcessing instance configured from cached state. */
    private static DynamicsProcessing createConfiguredInstance(int sessionId, int bandCount) {
        // Build config: Pre-EQ with `bandCount` bands, no MBC, no Post-EQ, limiter enabled
        DynamicsProcessing.Config.Builder builder = new DynamicsProcessing.Config.Builder(
                DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION,
                /* channelCount */ 2,
                /* preEqInUse */ true,
                /* preEqBandCount */ bandCount,
                /* mbcInUse */ false,
                /* mbcBandCount */ 0,
                /* postEqInUse */ false,
                /* postEqBandCount */ 0,
                /* limiterInUse */ true
        );

        // Priority: higher = takes precedence over other audio effects on this session.
        // Use max priority so Hype EQ overrides system/OEM equalizers.
        DynamicsProcessing dp = new DynamicsProcessing(Integer.MAX_VALUE, sessionId, builder.build());
        try {
            applyState(dp, bandCount);
        } catch (RuntimeException e) {
            // Do not leak the effect (a held effect slot) when configuring it fails.
            try { dp.release(); } catch (Exception ignored) {}
            throw e;
        }
        return dp;
    }

    /**
     * Apply the cached EQ/tone/limiter state to a DynamicsProcessing. It carries
     * what DynamicsProcessing can: N pre-EQ bands (the graphic EQ plus the tone
     * shelves, with the smooth-gains scaling), the input gain (preamp +
     * headroom) and the limiter. Hype's own engine runs those stages neutral
     * while this is active (see RoomEffectsProcessor.broadcastGlobalEqActive).
     */
    private static void applyState(DynamicsProcessing dp, int bandCount) {
        boolean eqEnabled = RoomEffectsProcessor.isCachedEqEnabled();
        float preamp = RoomEffectsProcessor.getCachedPreampGain();
        float headroom = RoomEffectsProcessor.getCachedHeadroomDb();
        float systemVolumeDb = RoomEffectsProcessor.getCachedSystemVolumeDb();
        boolean smoothGains = RoomEffectsProcessor.isCachedSmoothGains();
        float[] graphicGains = RoomEffectsProcessor.getCachedGraphicGains();
        float[] centres = RoomEffectsProcessor.getCachedGraphicCentres();
        float[] cutoffs = RoomEffectsProcessor.getCachedGraphicCutoffs();
        boolean toneEnabled = RoomEffectsProcessor.isCachedToneEnabled();
        float bassGain = RoomEffectsProcessor.getCachedBassGain();
        float bassFreq = RoomEffectsProcessor.getCachedBassFreq();
        float trebleGain = RoomEffectsProcessor.getCachedTrebleGain();
        float trebleFreq = RoomEffectsProcessor.getCachedTrebleFreq();
        boolean limiterEnabled = RoomEffectsProcessor.isCachedLimiterEnabled();

        // Input gain = the preamp (while the EQ is on) + headroom.
        float appliedPreamp = eqEnabled ? preamp : 0f;
        dp.setInputGainAllChannelsTo(appliedPreamp + headroom);

        // Smooth gains: T is the level the EQ is reached at, and the engine's own
        // rule (smooth_gains.h) turns it into the two scales, in dB. A factor is
        // the scale over its value with smoothing off, so it is 1 with smoothing
        // off; if the native rule is unavailable the gains play unscaled.
        float eqFactor = 1f;
        float bassFactor = 1f;
        float[] scales = RoomEffectsProcessor.nativeSmoothScales(
                appliedPreamp + systemVolumeDb + headroom, smoothGains);
        if (scales != null && scales.length >= 2) {
            eqFactor = scales[0] / EQ_SCALE_OFF_DB;
            bassFactor = scales[1] / BASS_SCALE_OFF_DB;
        }

        // Pre-EQ bands. The tone shelves are folded into the bands and run
        // whether or not the EQ is on, like Hype's own tone knobs.
        boolean bandsInUse = eqEnabled || toneEnabled;
        for (int ch = 0; ch < 2; ch++) {
            DynamicsProcessing.Eq preEq = dp.getPreEqByChannelIndex(ch);
            preEq.setEnabled(bandsInUse);

            for (int i = 0; i < bandCount; i++) {
                DynamicsProcessing.EqBand band = preEq.getBand(i);
                band.setCutoffFrequency(cutoffs[i]);

                float gain = eqEnabled ? graphicGains[i] * eqFactor : 0f;
                if (toneEnabled) {
                    if (centres[i] <= bassFreq) {
                        gain += bassGain * bassFactor;
                    }
                    if (centres[i] >= trebleFreq) {
                        gain += trebleGain * eqFactor;
                    }
                }

                band.setGain(gain);
                preEq.setBand(i, band);
            }

            dp.setPreEqByChannelIndex(ch, preEq);
        }

        // Limiter: 0 dBFS threshold, 5.3 ms attack, 341 ms release, ratio 20.
        for (int ch = 0; ch < 2; ch++) {
            DynamicsProcessing.Limiter limiter = dp.getLimiterByChannelIndex(ch);
            limiter.setEnabled(limiterEnabled);
            limiter.setThreshold(0f);
            limiter.setPostGain(0f);
            limiter.setAttackTime(5.3f);
            limiter.setReleaseTime(341f);
            limiter.setRatio(20f);
            dp.setLimiterByChannelIndex(ch, limiter);
        }
    }
}
