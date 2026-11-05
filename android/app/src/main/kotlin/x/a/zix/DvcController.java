package x.a.zix;

import android.content.Context;
import android.database.ContentObserver;
import android.media.AudioManager;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;

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
    private static int savedSystemVolume = -1;
    private static boolean dvcActive = false;
    private static ContentObserver volumeObserver;
    private static Handler handler;
    private static boolean suppressObserver = false;
    private static Runnable pendingRaise;
    /** Longer than the AudioTrack buffer the processed audio sits in. */
    private static final long RAISE_DELAY_MS = 800;

    // EventChannel sink for forwarding volume-button events to Flutter
    private static EventChannel.EventSink eventSink;

    public static void init(Context context) {
        audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        if (handler == null) handler = new Handler(Looper.getMainLooper());
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

        savedSystemVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC);

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

    private static void raiseSystemVolumeToMax() {
        if (audioManager == null) return;
        int maxVol = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
        suppressObserver = true;
        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, maxVol, 0);
        suppressObserver = false;
    }

    private static void cancelPendingRaise() {
        if (pendingRaise != null && handler != null) {
            handler.removeCallbacks(pendingRaise);
        }
        pendingRaise = null;
    }

    /**
     * Disable DVC: unregister observer and restore the saved system volume.
     */
    public static void disable(Context context) {
        if (!dvcActive) return;

        cancelPendingRaise();
        unregisterVolumeObserver(context);

        if (savedSystemVolume >= 0 && audioManager != null) {
            suppressObserver = true;
            audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, savedSystemVolume, 0);
            suppressObserver = false;
        }

        dvcActive = false;
        savedSystemVolume = -1;
        SystemVolumeObserver.refresh();
    }

    /** Put the system music stream back at maximum if something moved it. */
    private static void holdSystemVolumeAtMax() {
        if (!dvcActive || audioManager == null || pendingRaise != null) return;
        int maxVol = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
        if (audioManager.getStreamVolume(AudioManager.STREAM_MUSIC) != maxVol) {
            suppressObserver = true;
            audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, maxVol, 0);
            suppressObserver = false;
        }
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

    public static int getSavedVolume() {
        return savedSystemVolume;
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
                if (suppressObserver || !dvcActive || audioManager == null) return;
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
