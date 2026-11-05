package x.a.zix;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.database.ContentObserver;
import android.media.AudioDeviceCallback;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;

import io.flutter.plugin.common.EventChannel;

/**
 * Feeds the music stream's output level (dB) to every audio engine so the
 * "smooth equalizer/tone gains" follow the volume keys without a Dart round
 * trip. Idempotent: started from the activity and from the global-EQ service.
 */
public final class SystemVolumeObserver {

    private static final float FLOOR_DB = -96f;
    private static final float MIN_STEP_DB = 0.01f;

    private static final Object LOCK = new Object();
    private static Context appContext;
    private static AudioManager audioManager;
    private static boolean started;
    private static float lastPushedDb = Float.NaN;
    private static float lastFeedFraction = Float.NaN;
    private static EventChannel.EventSink feedSink;
    private static final Handler FEED_HANDLER = new Handler(Looper.getMainLooper());

    private SystemVolumeObserver() {}

    public static void start(Context context) {
        if (context == null) return;
        synchronized (LOCK) {
            if (started) return;
            Context app = context.getApplicationContext();
            appContext = app != null ? app : context;
            audioManager = (AudioManager) appContext.getSystemService(Context.AUDIO_SERVICE);
            if (audioManager == null) return;
            started = true;
        }

        Handler main = new Handler(Looper.getMainLooper());
        appContext.getContentResolver().registerContentObserver(
                Settings.System.CONTENT_URI, true, new ContentObserver(main) {
                    @Override
                    public void onChange(boolean selfChange) {
                        refresh();
                    }
                });
        // Bluetooth absolute-volume presses may write no Settings.System row;
        // this broadcast still fires for them.
        BroadcastReceiver volumeReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context c, Intent intent) {
                refresh();
            }
        };
        IntentFilter filter = new IntentFilter("android.media.VOLUME_CHANGED_ACTION");
        if (Build.VERSION.SDK_INT >= 33) {
            appContext.registerReceiver(volumeReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            appContext.registerReceiver(volumeReceiver, filter);
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioManager.registerAudioDeviceCallback(new AudioDeviceCallback() {
                @Override
                public void onAudioDevicesAdded(AudioDeviceInfo[] added) {
                    refresh();
                }

                @Override
                public void onAudioDevicesRemoved(AudioDeviceInfo[] removed) {
                    refresh();
                }
            }, main);
        }
        refresh();
    }

    /** Dart-facing feed: the music stream as 0...1, on change (EventChannel eq_app/system_volume). */
    public static void setupEventChannel(EventChannel channel) {
        channel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                synchronized (LOCK) {
                    feedSink = events;
                    lastFeedFraction = Float.NaN;
                }
                refresh();
            }

            @Override
            public void onCancel(Object arguments) {
                synchronized (LOCK) {
                    feedSink = null;
                }
            }
        });
    }

    private static EventChannel.EventSink keysSink;

    /** Level changes made by Hype's own handling of the volume keys (eq_app/volume_keys). */
    public static void setupKeysChannel(EventChannel channel) {
        channel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                synchronized (LOCK) {
                    keysSink = events;
                }
            }

            @Override
            public void onCancel(Object arguments) {
                synchronized (LOCK) {
                    keysSink = null;
                }
            }
        });
    }

    /** Tells Dart a volume key moved the level to [fraction] (0...1). */
    public static void emitKeyVolume(float fraction) {
        final EventChannel.EventSink sink;
        synchronized (LOCK) {
            sink = keysSink;
        }
        if (sink == null) return;
        FEED_HANDLER.post(() -> {
            try {
                sink.success((double) fraction);
            } catch (RuntimeException ignored) {
                // The Dart side went away.
            }
        });
    }

    /** The music stream's index over its maximum, 0...1. */
    public static float currentFraction(AudioManager am) {
        if (am == null) return 1f;
        int max = Math.max(1, am.getStreamMaxVolume(AudioManager.STREAM_MUSIC));
        return Math.max(0f, Math.min(1f, am.getStreamVolume(AudioManager.STREAM_MUSIC) / (float) max));
    }

    private static void pushFeed(AudioManager am) {
        final EventChannel.EventSink sink;
        final float fraction = currentFraction(am);
        synchronized (LOCK) {
            sink = feedSink;
            if (sink == null || fraction == lastFeedFraction) return;
            lastFeedFraction = fraction;
        }
        FEED_HANDLER.post(() -> {
            try {
                sink.success((double) fraction);
            } catch (RuntimeException ignored) {
                // The Dart side went away between the check and the post.
            }
        });
    }

    /** Re-reads the volume and pushes it if it moved by more than 0.01 dB. */
    public static void refresh() {
        final AudioManager am;
        synchronized (LOCK) {
            if (!started) return;
            am = audioManager;
        }
        pushFeed(am);
        final float db = currentMusicDb(am);
        synchronized (LOCK) {
            if (!Float.isNaN(lastPushedDb) && Math.abs(db - lastPushedDb) <= MIN_STEP_DB) return;
            lastPushedDb = db;
        }
        RoomEffectsProcessor.broadcastSystemVolumeDb(db);
    }

    /** Music-stream level in dB (-96...0); 0 while digital volume control owns the volume. */
    public static float currentMusicDb(AudioManager am) {
        if (DvcController.isActive()) return 0f;
        if (am == null) return 0f;
        int index = am.getStreamVolume(AudioManager.STREAM_MUSIC);
        if (index <= 0) return FLOOR_DB;
        int max = Math.max(1, am.getStreamMaxVolume(AudioManager.STREAM_MUSIC));

        float db;
        boolean have = false;
        db = 0f;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                db = am.getStreamVolumeDb(AudioManager.STREAM_MUSIC, index, outputDeviceType());
                have = !Float.isNaN(db);
            } catch (RuntimeException e) {
                have = false;
            }
        }
        if (!have) db = (float) (20.0 * Math.log10((double) index / max));
        if (Float.isNaN(db)) db = 0f;
        return Math.max(FLOOR_DB, Math.min(0f, db));
    }

    private static int outputDeviceType() {
        String kind = AudioOutputDetector.getAudioOutputType(appContext);
        if ("bluetooth".equals(kind)) return AudioDeviceInfo.TYPE_BLUETOOTH_A2DP;
        if ("wired_headphone".equals(kind)) return AudioDeviceInfo.TYPE_WIRED_HEADPHONES;
        if ("usb_audio".equals(kind)) return AudioDeviceInfo.TYPE_USB_HEADSET;
        return AudioDeviceInfo.TYPE_BUILTIN_SPEAKER;
    }
}
