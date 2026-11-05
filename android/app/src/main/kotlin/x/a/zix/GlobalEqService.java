package x.a.zix;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.media.AudioManager;
import android.media.AudioPlaybackConfiguration;
import android.media.session.MediaController;
import android.media.session.MediaSessionManager;
import android.media.session.PlaybackState;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;

import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;
import androidx.core.app.NotificationCompat;

import io.flutter.plugin.common.EventChannel;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * Foreground service that attaches a global DynamicsProcessing EQ to the audio
 * output mix (sessionId = 0), applying the current EQ profile to ALL audio apps.
 *
 * Tracks which apps are currently playing audio using a tiered approach:
 *   - API 34+: AudioPlaybackConfiguration.getClientUid() (public API)
 *   - API 28-33: MediaSessionManager.getActiveSessions() (public API)
 *   - Both: AudioPlaybackCallback for real-time change notifications
 */
@RequiresApi(api = Build.VERSION_CODES.P)
public class GlobalEqService extends Service {
    private static final String TAG = "GlobalEqService";
    private static final String CHANNEL_ID = "global_eq_channel";
    private static final int NOTIFICATION_ID = 9002;
    private static final String ACTION_STOP = "x.a.zix.STOP_GLOBAL_EQ";

    private AudioManager audioManager;
    private AudioManager.AudioPlaybackCallback playbackCallback;
    private MediaSessionManager mediaSessionManager;
    private MediaSessionManager.OnActiveSessionsChangedListener sessionListener;
    private PowerManager.WakeLock wakeLock;
    private final Handler handler = new Handler(Looper.getMainLooper());

    // The running instance (main thread only) and the preset shown in its
    // notification. The preset is kept even while the service is stopped, so
    // the notification is right from the moment the service starts.
    private static GlobalEqService instance;

    // Tells Dart when the notification's Stop ends the service (Dart did not
    // ask for it, so it would otherwise keep believing system-wide mode is on).
    // Main thread only.
    private static EventChannel.EventSink stoppedSink;

    // True after the notification's Stop (a person asked for it), until the
    // service is created again or Dart starts/stops it itself. Lets Dart tell
    // that apart from a start that failed. Also written to Dart's own setting
    // so a Stop with no Dart isolate alive is still remembered.
    static volatile boolean stoppedByUser = false;
    private static final String FLUTTER_PREFS = "FlutterSharedPreferences";
    private static final String FLUTTER_ENABLED_KEY = "flutter.globalEqEnabled";

    public static void setupEventChannel(EventChannel channel) {
        channel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink sink) {
                stoppedSink = sink;
            }

            @Override
            public void onCancel(Object arguments) {
                stoppedSink = null;
            }
        });
    }
    private static String presetLabel;

    /** Sets the preset named in the notification; refreshes it if running. */
    static void updatePreset(String preset) {
        // No preset selected arrives as an empty name: no line at all.
        presetLabel = (preset == null || preset.isEmpty()) ? null : preset;
        GlobalEqService svc = instance;
        if (svc == null) return;
        NotificationManager nm = svc.getSystemService(NotificationManager.class);
        if (nm != null) nm.notify(NOTIFICATION_ID, svc.buildNotification());
    }

    // Currently playing app package names (for UI display only)
    private static final CopyOnWriteArrayList<String> playingApps = new CopyOnWriteArrayList<>();

    /** Returns a snapshot of currently playing app package names. */
    public static List<String> getPlayingApps() {
        return new ArrayList<>(playingApps);
    }

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
        stoppedByUser = false;
        SystemVolumeObserver.start(getApplicationContext());
        createNotificationChannel();
        startForeground(NOTIFICATION_ID, buildNotification());

        audioManager = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
        mediaSessionManager = (MediaSessionManager) getSystemService(Context.MEDIA_SESSION_SERVICE);

        // Wake lock is tied to actual playback (see updateWakeLockForPlayback):
        // held only while audio is playing, released when idle. Previously it
        // was acquired for the whole service lifetime, blocking CPU deep-sleep
        // whenever global EQ was ever enabled — even during silence.
        PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
        if (pm != null) {
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "HypeEQ::GlobalEq");
            wakeLock.setReferenceCounted(false);
        }

        // Attach global DynamicsProcessing to output mix
        GlobalEqSessionManager.setEnabled(true);
        GlobalEqSessionManager.attachGlobal();

        // Bypass C++ EQ in own app to prevent double-processing
        RoomEffectsProcessor.broadcastGlobalEqActive(true);

        // Register for playback change notifications
        registerPlaybackCallback();

        // Register MediaSession listener for API 28-33 package detection
        registerMediaSessionListener();

        // Initial scan
        refreshPlayingApps();
        updateWakeLockForPlayback();

        Log.i(TAG, "GlobalEqService started — global output mix EQ active");
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            stoppedByUser = true;
            getSharedPreferences(FLUTTER_PREFS, MODE_PRIVATE).edit()
                    .putBoolean(FLUTTER_ENABLED_KEY, false).apply();
            if (stoppedSink != null) stoppedSink.success(false);
            stopSelf();
            return START_NOT_STICKY;
        }
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        unregisterPlaybackCallback();
        unregisterMediaSessionListener();
        playingApps.clear();
        GlobalEqSessionManager.setEnabled(false);
        GlobalEqSessionManager.releaseAll();
        // Restore C++ EQ for own app
        RoomEffectsProcessor.broadcastGlobalEqActive(false);
        // Release wake lock
        if (wakeLock != null && wakeLock.isHeld()) {
            wakeLock.release();
            wakeLock = null;
        }
        Log.i(TAG, "GlobalEqService stopped");
        instance = null;
        super.onDestroy();
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        // Service survives app swipe from recents — do NOT stop
        Log.i(TAG, "Task removed but GlobalEqService continues");
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    // ---- Playing apps detection (tiered approach) ----

    /**
     * Refresh the playing apps list using the best available method:
     *  - API 34+: AudioPlaybackConfiguration.getClientUid() (public, catches all audio)
     *  - API 28-33: MediaSessionManager (public, catches media players)
     *  - Fallback: reflection on getClientUid() (may fail on Android 12+)
     */
    private void refreshPlayingApps() {
        Set<String> active = new LinkedHashSet<>();
        String ownPkg = getPackageName();

        // Tier 1: API 34+ — getClientUid() is public but compileSdk may be lower,
        // so use reflection (guaranteed to succeed on API 34+)
        if (Build.VERSION.SDK_INT >= 34) {
            try {
                List<AudioPlaybackConfiguration> configs =
                        audioManager.getActivePlaybackConfigurations();
                if (configs != null) {
                    PackageManager pm = getPackageManager();
                    java.lang.reflect.Method getUid =
                            AudioPlaybackConfiguration.class.getMethod("getClientUid");
                    for (AudioPlaybackConfiguration config : configs) {
                        try {
                            int uid = (int) getUid.invoke(config);
                            String[] packages = pm.getPackagesForUid(uid);
                            if (packages != null) {
                                for (String pkg : packages) {
                                    if (pkg != null && !pkg.equals(ownPkg)) {
                                        active.add(pkg);
                                    }
                                }
                            }
                        } catch (Exception ignored) {}
                    }
                }
            } catch (Exception e) {
                Log.w(TAG, "API 34 playback config scan failed: " + e.getMessage());
            }
        }

        // Tier 2: MediaSessionManager — works on API 28-33, also supplements API 34+
        if (mediaSessionManager != null) {
            try {
                ComponentName listener = getNotificationListenerComponent();
                List<MediaController> controllers = listener != null
                        ? mediaSessionManager.getActiveSessions(listener)
                        : mediaSessionManager.getActiveSessions(null);

                for (MediaController controller : controllers) {
                    String pkg = controller.getPackageName();
                    if (pkg != null && !pkg.equals(ownPkg)) {
                        PlaybackState state = controller.getPlaybackState();
                        if (state != null && state.getState() == PlaybackState.STATE_PLAYING) {
                            active.add(pkg);
                        }
                    }
                }
            } catch (SecurityException e) {
                // NotificationListener not granted — try without component
                try {
                    List<MediaController> controllers =
                            mediaSessionManager.getActiveSessions(null);
                    for (MediaController controller : controllers) {
                        String pkg = controller.getPackageName();
                        if (pkg != null && !pkg.equals(ownPkg)) {
                            PlaybackState state = controller.getPlaybackState();
                            if (state != null && state.getState() == PlaybackState.STATE_PLAYING) {
                                active.add(pkg);
                            }
                        }
                    }
                } catch (Exception ignored) {}
            } catch (Exception e) {
                Log.w(TAG, "MediaSessionManager scan failed: " + e.getMessage());
            }
        }

        // Tier 3: Reflection fallback for API 28-33 (may not work on Android 12+)
        if (active.isEmpty() && Build.VERSION.SDK_INT < 34) {
            try {
                List<AudioPlaybackConfiguration> configs =
                        audioManager.getActivePlaybackConfigurations();
                if (configs != null) {
                    PackageManager pm = getPackageManager();
                    for (AudioPlaybackConfiguration config : configs) {
                        try {
                            java.lang.reflect.Method m =
                                    config.getClass().getMethod("getClientUid");
                            int uid = (int) m.invoke(config);
                            String[] packages = pm.getPackagesForUid(uid);
                            if (packages != null) {
                                for (String pkg : packages) {
                                    if (pkg != null && !pkg.equals(ownPkg)) {
                                        active.add(pkg);
                                    }
                                }
                            }
                        } catch (Exception ignored) {}
                    }
                }
            } catch (Exception e) {
                Log.w(TAG, "Reflection fallback scan failed: " + e.getMessage());
            }
        }

        playingApps.clear();
        playingApps.addAll(active);
    }

    /**
     * Try to find our NotificationListenerService component for MediaSessionManager.
     * Returns null if not declared (MediaSessionManager will use null which returns
     * only sessions this app owns, but some ROMs allow null to return all).
     */
    @Nullable
    private ComponentName getNotificationListenerComponent() {
        try {
            // Look for a NotificationListenerService in our package
            ComponentName component = new ComponentName(this,
                    Class.forName(getPackageName() + ".MediaNotificationListener"));
            return component;
        } catch (ClassNotFoundException e) {
            return null;
        }
    }

    // ---- AudioPlaybackCallback (triggers refresh on any change) ----

    private void registerPlaybackCallback() {
        if (audioManager == null) return;

        playbackCallback = new AudioManager.AudioPlaybackCallback() {
            @Override
            public void onPlaybackConfigChanged(List<AudioPlaybackConfiguration> configs) {
                // Any active playback config means audio is flowing → hold the
                // wake lock; none means idle → release it.
                setWakeLockHeld(configs != null && !configs.isEmpty());
                refreshPlayingApps();
            }
        };
        audioManager.registerAudioPlaybackCallback(playbackCallback, handler);
    }

    /**
     * Hold the PARTIAL_WAKE_LOCK only while audio is actively playing on the
     * device. Uses the same AudioManager playback configs the service already
     * tracks, covering our own app and every other audio app. All calls occur
     * on the main looper (onCreate + callbacks registered with {@code handler}).
     */
    private void updateWakeLockForPlayback() {
        boolean playing = false;
        if (audioManager != null) {
            try {
                List<AudioPlaybackConfiguration> configs =
                        audioManager.getActivePlaybackConfigurations();
                playing = configs != null && !configs.isEmpty();
            } catch (Exception ignored) {}
        }
        setWakeLockHeld(playing);
    }

    private void setWakeLockHeld(boolean held) {
        if (wakeLock == null) return;
        try {
            if (held) {
                if (!wakeLock.isHeld()) wakeLock.acquire();
            } else if (wakeLock.isHeld()) {
                wakeLock.release();
            }
        } catch (Exception ignored) {}
    }

    private void unregisterPlaybackCallback() {
        if (audioManager != null && playbackCallback != null) {
            try {
                audioManager.unregisterAudioPlaybackCallback(playbackCallback);
            } catch (Exception ignored) {}
            playbackCallback = null;
        }
    }

    // ---- MediaSessionManager listener (catches session changes) ----

    private void registerMediaSessionListener() {
        if (mediaSessionManager == null) return;

        sessionListener = controllers -> {
            updateWakeLockForPlayback();
            refreshPlayingApps();
        };

        try {
            ComponentName listener = getNotificationListenerComponent();
            mediaSessionManager.addOnActiveSessionsChangedListener(
                    sessionListener, listener, handler);
        } catch (SecurityException e) {
            // Try without notification listener component
            try {
                mediaSessionManager.addOnActiveSessionsChangedListener(
                        sessionListener, null, handler);
            } catch (Exception ignored) {}
        } catch (Exception e) {
            Log.w(TAG, "Failed to register media session listener: " + e.getMessage());
        }
    }

    private void unregisterMediaSessionListener() {
        if (mediaSessionManager != null && sessionListener != null) {
            try {
                mediaSessionManager.removeOnActiveSessionsChangedListener(sessionListener);
            } catch (Exception ignored) {}
            sessionListener = null;
        }
    }

    // ---- Notification ----

    private void createNotificationChannel() {
        NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                "Global Equalizer",
                NotificationManager.IMPORTANCE_LOW
        );
        channel.setDescription("Shows when Hype EQ is applied to all apps");
        channel.setShowBadge(false);

        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm != null) nm.createNotificationChannel(channel);
    }

    private Notification buildNotification() {
        // "Turn Off" action
        Intent stopIntent = new Intent(this, GlobalEqService.class);
        stopIntent.setAction(ACTION_STOP);
        PendingIntent stopPi = PendingIntent.getService(
                this, 0, stopIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        // Tap notification → open app
        Intent launchIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent launchPi = launchIntent != null
                ? PendingIntent.getActivity(this, 0, launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE)
                : null;

        return new NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("Hype EQ Active")
                .setContentText(presetLabel != null
                        ? "Applied to all apps · Preset: " + presetLabel
                        : "Equalizer applied to all apps")
                .setSmallIcon(R.drawable.ic_stat_eq)
                .setOngoing(true)
                .setContentIntent(launchPi)
                .addAction(R.drawable.ic_stat_eq, "Turn Off", stopPi)
                .build();
    }
}
