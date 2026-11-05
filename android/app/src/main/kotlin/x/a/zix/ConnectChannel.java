package x.a.zix;

import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.PowerManager;
import android.provider.Settings;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.ryanheise.audioservice.AudioServicePlugin;

import java.util.Map;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;

/**
 * The {@code x.a.zix/connect_service} channel between Dart's HypeConnect and
 * {@link ConnectService}.
 *
 * <p>It has to exist on whichever engine runs the Dart main isolate, and that
 * is not always the one MainActivity configures: after a reboot the service
 * creates audio_service's cached engine itself, with no activity. So {@link
 * #attach} is called from both places and is idempotent per engine, and the
 * handler uses only the application context.
 */
final class ConnectChannel {
    private static final String TAG = "ConnectChannel";
    static final String NAME = "x.a.zix/connect_service";

    private static MethodChannel sChannel;
    private static BinaryMessenger sMessenger;
    /** The notification was tapped and Dart has not picked that up yet. */
    private static boolean sPendingOpen;

    private ConnectChannel() {}

    /**
     * The engine that runs the Dart main isolate: audio_service's cached one
     * (MainActivity extends AudioServiceFragmentActivity). Creates it, and so
     * starts {@code main()}, if nothing has yet.
     */
    static FlutterEngine ensureEngine(Context context) {
        // The channel handler is registered on this same (main) thread before
        // the Dart isolate can post its first message, so none is missed.
        FlutterEngine engine = AudioServicePlugin.getFlutterEngine(context.getApplicationContext());
        attach(engine, context);
        return engine;
    }

    static synchronized void attach(@NonNull FlutterEngine engine, @NonNull Context context) {
        // The headset-button channels live on the same engines (see MediaButtonChannel).
        MediaButtonChannel.attach(engine, context);
        BinaryMessenger messenger = engine.getDartExecutor().getBinaryMessenger();
        if (sChannel != null && sMessenger == messenger) return;
        if (sChannel != null) sChannel.setMethodCallHandler(null);
        final Context app = context.getApplicationContext();
        sMessenger = messenger;
        sChannel = new MethodChannel(messenger, NAME);
        sChannel.setMethodCallHandler((call, result) -> {
            try {
                switch (call.method) {
                    case "isRunning":
                        result.success(ConnectService.isRunning());
                        break;
                    case "start":
                        result.success(ConnectService.start(app));
                        break;
                    case "update":
                        ConnectService.update(ConnectService.Content.fromMap((Map<?, ?>) call.arguments));
                        result.success(null);
                        break;
                    case "stop":
                        ConnectService.stop(app);
                        result.success(null);
                        break;
                    case "setBootEnabled":
                        ConnectService.setWanted(app, Boolean.TRUE.equals(call.arguments));
                        result.success(null);
                        break;
                    case "isIgnoringBatteryOptimizations": {
                        PowerManager pm = (PowerManager) app.getSystemService(Context.POWER_SERVICE);
                        result.success(pm != null && pm.isIgnoringBatteryOptimizations(app.getPackageName()));
                        break;
                    }
                    case "openBatterySettings":
                        openBatterySettings(app);
                        result.success(null);
                        break;
                    case "getVolume":
                        result.success(ConnectVolume.get(app));
                        break;
                    case "setVolume":
                        ConnectVolume.set(app, ((Number) call.arguments).doubleValue());
                        result.success(null);
                        break;
                    case "watchVolume":
                        ConnectVolume.watch(app, Boolean.TRUE.equals(call.arguments));
                        result.success(null);
                        break;
                    case "setRemoteVolumeKeys":
                        ConnectVolume.sRemoteKeys = Boolean.TRUE.equals(call.arguments);
                        result.success(null);
                        break;
                    case "takeOpenRequest": {
                        boolean pending;
                        synchronized (ConnectChannel.class) {
                            pending = sPendingOpen;
                            sPendingOpen = false;
                        }
                        result.success(pending);
                        break;
                    }
                    default:
                        result.notImplemented();
                }
            } catch (Exception e) {
                Log.w(TAG, call.method + " failed", e);
                result.error("connect_service", e.getMessage(), null);
            }
        });
    }

    /** A notification button was tapped: tell Dart which. */
    static void sendAction(String id) {
        MethodChannel channel;
        synchronized (ConnectChannel.class) {
            channel = sChannel;
        }
        if (channel == null) {
            Log.w(TAG, "button '" + id + "' tapped but Dart is not attached");
            return;
        }
        channel.invokeMethod("action", id);
    }

    /** The media volume changed (0..1): tell Dart if it is listening. */
    static void sendVolumeChanged(double value) {
        invokeDart("volumeChanged", value);
    }

    /**
     * A hardware volume key was pressed while this phone is a remote: Dart
     * steps the other device's volume. Returns whether Dart was there to hear
     * it; when it was not, the key falls through to the system as usual.
     */
    static boolean sendVolumeKey(String direction) {
        return invokeDart("volumeKey", direction);
    }

    private static boolean invokeDart(String method, Object argument) {
        MethodChannel channel;
        synchronized (ConnectChannel.class) {
            channel = sChannel;
        }
        if (channel == null) return false;
        channel.invokeMethod(method, argument);
        return true;
    }

    /**
     * Call with every intent an activity is launched or re-launched with. A
     * tap on the notification carries {@link ConnectService#EXTRA_OPEN_CONNECT};
     * Dart is told if it is listening and can always ask later.
     */
    static void handleLaunchIntent(@Nullable Intent intent) {
        if (intent == null || !intent.getBooleanExtra(ConnectService.EXTRA_OPEN_CONNECT, false)) return;
        // Consumed: a rotation or a recreate must not open the page again.
        intent.removeExtra(ConnectService.EXTRA_OPEN_CONNECT);
        MethodChannel channel;
        synchronized (ConnectChannel.class) {
            sPendingOpen = true;
            channel = sChannel;
        }
        if (channel != null) channel.invokeMethod("openRequested", null);
    }

    private static void openBatterySettings(Context app) {
        // The list of apps with their battery-optimisation state. Not the
        // REQUEST_IGNORE_BATTERY_OPTIMIZATIONS dialog, which Play restricts.
        Intent intent = new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            app.startActivity(intent);
        } catch (RuntimeException e) {
            // A few ROMs lack that page; the app's own settings page is the
            // nearest thing that always exists.
            Intent details = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:" + app.getPackageName()))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            app.startActivity(details);
        }
    }
}
