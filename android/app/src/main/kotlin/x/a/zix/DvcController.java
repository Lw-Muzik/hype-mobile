package x.a.zix;

import android.content.Context;
import android.content.SharedPreferences;
import android.database.ContentObserver;
import android.media.AudioDeviceCallback;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;

import org.json.JSONException;
import org.json.JSONObject;

import io.flutter.plugin.common.EventChannel;

/**
 * Direct Volume Control.
 *
 * While enabled, system STREAM_MUSIC volume is held at maximum so the full
 * digital range reaches the output, and hardware volume keys are forwarded to
 * Dart as "up"/"down" events. The audible level itself is the engine master
 * volume (see RoomEffectsProcessor.broadcastMasterVolumeDb), which every
 * player applies inside its own engine, so a crossfade keeps both players at
 * the same level. Turning DVC off restores the saved system volume.
 *
 * A {@link ContentObserver} watches for external volume changes and re-forces
 * the maximum, so the key presses are handled by the DVC level instead.
 */
public class DvcController {

    private static AudioManager audioManager;
    private static Context appContext;
    private static final String PREFS = "dvc_saved_volumes";
    private static final String KEY = "state";
    private static volatile boolean dvcActive = false;
    private static ContentObserver volumeObserver;
    private static Handler handler;
    /** The index we last set ourselves; an observer callback that finds the
     *  stream at this value is our own echo (callbacks are posted, so a flag
     *  cleared right after the call would not cover them). */
    private static int expectedIndex = -1;
    private static boolean callbackRegistered = false;
    private static Runnable pendingRaise;
    /** Longer than the AudioTrack buffer the processed audio sits in. */
    private static final long RAISE_DELAY_MS = 800;

    // EventChannel sink for forwarding volume-button events to Flutter
    private static EventChannel.EventSink eventSink;

    public static void init(Context context) {
        audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        appContext = context.getApplicationContext();
        if (handler == null) handler = new Handler(Looper.getMainLooper());
        registerDeviceCallback();
    }

    /**
     * R4: a pending restore is applied natively the moment its output becomes
     * the active one, not when Dart next reads the route.
     */
    private static void registerDeviceCallback() {
        if (callbackRegistered || audioManager == null
                || android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.M) return;
        callbackRegistered = true;
        audioManager.registerAudioDeviceCallback(new AudioDeviceCallback() {
            @Override
            public void onAudioDevicesAdded(AudioDeviceInfo[] added) { onRouteChanged(); }

            @Override
            public void onAudioDevicesRemoved(AudioDeviceInfo[] removed) { onRouteChanged(); }
        }, handler);
    }

    private static void onRouteChanged() {
        restorePendingNow();
        // Music can follow the device a moment later: look again.
        handler.postDelayed(new Runnable() {
            @Override
            public void run() { restorePendingNow(); }
        }, 500);
    }

    private static void restorePendingNow() {
        if (appContext != null && !dvcActive) restoreIfActive(appContext);
    }

    /**
     * Set up the EventChannel that sends "up"/"down" events to Dart when
     * hardware volume buttons are pressed while DVC is active.
     */
    public static void setupEventChannel(EventChannel channel) {
        channel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink sink) {
                eventSink = sink;
            }

            @Override
            public void onCancel(Object arguments) {
                eventSink = null;
            }
        });
    }

    /**
     * Enable DVC: save current system volume, set STREAM_MUSIC to max,
     * and register the volume observer.
     */
    public static void enable(Context context) {
        if (audioManager == null) init(context);
        if (dvcActive) return;

        // The active output's original is saved before it may be raised; a
        // saved original is never overwritten (DvcSavedVolumes.enable).
        ensureSavedOriginal();
        setDisabling(loadMap(), false);

        dvcActive = true;

        // The master volume is applied inside the player's AudioProcessor,
        // upstream of the AudioTrack buffer, so at least RAISE_DELAY_MS of
        // audio processed at unity gain is still queued when DVC turns on.
        // Raising the system stream at once would play that audio at full
        // device volume. When audio is playing, wait for the buffer to drain.
        // Side effect (accepted): DVC volume-key changes are heard about
        // one buffer (~0.25 s) late, because the same buffer sits between
        // the processor and the speaker.
        if (audioManager.isMusicActive()) {
            cancelPendingRaise();
            pendingRaise = new Runnable() {
                @Override
                public void run() {
                    pendingRaise = null;
                    if (dvcActive) raiseSystemVolumeToMax();
                }
            };
            handler.postDelayed(pendingRaise, RAISE_DELAY_MS);
        } else {
            raiseSystemVolumeToMax();
        }

        registerVolumeObserver(context);
        SystemVolumeObserver.refresh();
    }

    private static int currentIndex() {
        return audioManager.getStreamVolume(AudioManager.STREAM_MUSIC);
    }

    private static int maxIndex() {
        return audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
    }

    /** Sets the music stream and remembers the value as our own echo. */
    private static void setOurs(int index) {
        expectedIndex = index;
        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, index, 0);
    }

    /**
     * Makes sure the active output has a saved original, mirroring
     * DvcSavedVolumes.enable: a missing one is saved (never as the maximum:
     * half instead); an existing one is refreshed if the listener moved the
     * volume off maximum. Returns false when the output has no usable key, in
     * which case it must not be raised.
     */
    private static boolean ensureSavedOriginal() {
        if (audioManager == null || appContext == null) return false;
        String key = AudioOutputDetector.getActiveDeviceKey(appContext);
        if (key == null || key.isEmpty()) return false;
        JSONObject map = loadMap();
        int idx = currentIndex();
        int max = maxIndex();
        try {
            if (!map.has(key)) {
                map.put(key, idx >= max ? Math.round(max * 0.5f) : idx);
                storeMap(map);
            } else if (idx != max) {
                map.put(key, idx);
                storeMap(map);
            }
        } catch (JSONException e) {
            return false;
        }
        return true;
    }

    private static void raiseSystemVolumeToMax() {
        if (audioManager == null) return;
        // The output may have changed since enable: never raise one whose
        // original is not saved.
        if (!ensureSavedOriginal()) return;
        setOurs(maxIndex());
    }

    private static void cancelPendingRaise() {
        if (pendingRaise != null && handler != null) {
            handler.removeCallbacks(pendingRaise);
        }
        pendingRaise = null;
    }

    /**
     * Disable DVC. A route-driven release ({@code release} true) writes nothing
     * to the system volume and forgets nothing. A real disable hands back every
     * output's saved original: the active output's now, the others when each
     * becomes active (see {@code DvcSavedVolumes} in Dart, mirrored here and
     * persisted so a process restart keeps the entries).
     */
    public static void disable(Context context, boolean release) {
        if (!dvcActive && release) return;
        boolean wasActive = dvcActive;
        cancelPendingRaise();
        unregisterVolumeObserver(context);
        dvcActive = false;
        expectedIndex = -1;
        if (!release) {
            setDisabling(loadMap(), true);
            restoreIfActive(context);
        }
        if (wasActive) SystemVolumeObserver.refresh();
    }

    /** Applies a pending restore once its output is the active one again. */
    public static void applyPendingRestore(Context context) {
        if (dvcActive) return;
        restoreIfActive(context);
    }

    /**
     * Mirrors DvcSavedVolumes.deviceActive: the active output's entry is
     * written back only if the output is still at maximum (our own raise); if
     * the listener moved it, the entry is dropped without writing.
     */
    private static void restoreIfActive(Context context) {
        if (appContext == null) appContext = context.getApplicationContext();
        if (audioManager == null) init(context);
        if (!isDisabling()) return;
        JSONObject map = loadMap();
        String key = AudioOutputDetector.getActiveDeviceKey(context);
        if (key != null && map.has(key)) {
            int idx = map.optInt(key, -1);
            map.remove(key);
            if (idx >= 0 && currentIndex() == maxIndex()) {
                audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, idx, 0);
            }
            writeState(map, map.length() > 0);
        } else if (map.length() == 0) {
            writeState(map, false);
        }
    }

    // -- Persisted per-output originals --

    private static SharedPreferences prefs() {
        return appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private static JSONObject loadMap() {
        try {
            String t = prefs().getString(KEY, null);
            if (t != null) return new JSONObject(t).optJSONObject("saved") != null
                    ? new JSONObject(t).getJSONObject("saved") : new JSONObject();
        } catch (Exception ignored) {}
        return new JSONObject();
    }

    private static boolean isDisabling() {
        try {
            String t = prefs().getString(KEY, null);
            return t != null && new JSONObject(t).optBoolean("disabling", false);
        } catch (Exception e) {
            return false;
        }
    }

    private static void storeMap(JSONObject map) {
        writeState(map, isDisabling());
    }

    private static void setDisabling(JSONObject map, boolean disabling) {
        writeState(map, disabling);
    }

    private static void writeState(JSONObject map, boolean disabling) {
        if (appContext == null) return;
        try {
            JSONObject o = new JSONObject();
            o.put("saved", map);
            o.put("disabling", disabling);
            prefs().edit().putString(KEY, o.toString()).apply();
        } catch (JSONException ignored) {}
    }

    /** Put the system music stream back at maximum if something moved it. */
    private static void holdSystemVolumeAtMax() {
        if (!dvcActive || audioManager == null || pendingRaise != null) return;
        if (!ensureSavedOriginal()) return;
        int maxVol = maxIndex();
        if (currentIndex() != maxVol) setOurs(maxVol);
    }

    /**
     * Forward a hardware volume-button press as a DVC gain adjustment.
     * Called from MainActivity.onKeyDown.
     *
     * @param direction "up" or "down"
     * @return true if the event was consumed (DVC is active)
     */
    public static boolean onVolumeButton(String direction) {
        if (!dvcActive) return false;

        // Send event to Flutter (Dart side adjusts the DVC level)
        if (eventSink != null) {
            eventSink.success(direction);
        }
        return true;
    }

    public static boolean isActive() {
        return dvcActive;
    }

    /**
     * The real attenuation (dB) Android applies at music step [index] on the
     * active output (API 28+), or null where it cannot be read. Used to seed
     * the DVC level so it matches what the listener heard.
     */
    public static Double getStreamDb(Context context, int index) {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.P) return null;
        if (audioManager == null) init(context);
        try {
            float db = audioManager.getStreamVolumeDb(AudioManager.STREAM_MUSIC, index,
                    AudioOutputDetector.getActiveDeviceType(context));
            return Double.valueOf(db);
        } catch (RuntimeException e) {
            return null;
        }
    }

    public static int getMaxVolume() {
        if (audioManager == null) return 15;
        return audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
    }

    public static int getCurrentSystemVolume() {
        if (audioManager == null) return 0;
        return audioManager.getStreamVolume(AudioManager.STREAM_MUSIC);
    }

    // -- Volume observer --

    private static void registerVolumeObserver(Context context) {
        if (volumeObserver != null) return;
        volumeObserver = new ContentObserver(handler) {
            @Override
            public void onChange(boolean selfChange) {
                if (!dvcActive || audioManager == null) return;
                if (currentIndex() == expectedIndex) return; // our own echo
                holdSystemVolumeAtMax();
            }
        };
        context.getContentResolver().registerContentObserver(
                Settings.System.CONTENT_URI, true, volumeObserver);
    }

    private static void unregisterVolumeObserver(Context context) {
        if (volumeObserver != null) {
            try {
                context.getContentResolver().unregisterContentObserver(volumeObserver);
            } catch (Exception ignored) {}
            volumeObserver = null;
        }
    }
}
