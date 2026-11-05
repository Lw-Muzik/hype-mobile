package x.a.zix;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;

import com.ryanheise.audioservice.AudioService;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodChannel;

/**
 * Registers the headset-button channels on whichever engine runs the Dart main
 * isolate, and hands audio_service's raw media keys to {@link MediaButtonBridge}.
 *
 * <p>Like {@link ConnectChannel}, {@link #attach} is called from MainActivity
 * and from ConnectChannel (the engine Hype Connect starts with no activity),
 * and is idempotent per engine.
 *
 * <ul>
 * <li>{@code eq_app/media_buttons}: EventChannel of key events.
 * <li>{@code eq_app/media_buttons_ctl}: MethodChannel with {@code attached},
 *     {@code setButtonPolicy} and {@code buttonFeedback}.
 * </ul>
 */
final class MediaButtonChannel {
    static final String EVENTS = "eq_app/media_buttons";
    static final String CONTROL = "eq_app/media_buttons_ctl";

    private static BinaryMessenger sMessenger;
    private static EventChannel sEvents;
    private static MethodChannel sControl;

    private MediaButtonChannel() {}

    static synchronized void attach(@NonNull FlutterEngine engine, @NonNull Context context) {
        final Context app = context.getApplicationContext();
        // A static on AudioService, so it is set whether or not the engine is new.
        AudioService.setMediaButtonInterceptor(e -> MediaButtonBridge.onMediaButton(app, e));

        BinaryMessenger messenger = engine.getDartExecutor().getBinaryMessenger();
        if (sMessenger == messenger) return;
        if (sEvents != null) sEvents.setStreamHandler(null);
        if (sControl != null) sControl.setMethodCallHandler(null);
        // Whoever listened on the old engine is gone with it.
        MediaButtonBridge.setSink(null);
        sMessenger = messenger;

        sEvents = new EventChannel(messenger, EVENTS);
        sEvents.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                final Handler main = new Handler(Looper.getMainLooper());
                MediaButtonBridge.setSink(event -> main.post(() -> events.success(event)));
            }

            @Override
            public void onCancel(Object arguments) {
                MediaButtonBridge.setSink(null);
            }
        });

        sControl = new MethodChannel(messenger, CONTROL);
        sControl.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "attached":
                    result.success(true);
                    break;
                case "setButtonPolicy":
                    final boolean proxy = Boolean.TRUE.equals(call.argument("longPressProxy"));
                    // Per output; an older Dart side without them means both.
                    final Object wired = call.argument("wiredLongPress");
                    final Object bluetooth = call.argument("bluetoothLongPress");
                    MediaButtonBridge.setPolicy(
                            app,
                            !Boolean.FALSE.equals(call.argument("respond")),
                            Boolean.TRUE.equals(call.argument("playing")),
                            proxy,
                            wired != null ? Boolean.TRUE.equals(wired) : proxy,
                            bluetooth != null ? Boolean.TRUE.equals(bluetooth) : proxy);
                    result.success(null);
                    break;
                case "buttonFeedback": {
                    Number beeps = call.argument("beeps");
                    Number toneVolume = call.argument("toneVolume");
                    ButtonFeedbackPlayer.play(
                            app,
                            beeps != null ? beeps.intValue() : 0,
                            toneVolume != null ? toneVolume.intValue() : 60,
                            Boolean.TRUE.equals(call.argument("vibrate")));
                    result.success(null);
                    break;
                }
                default:
                    result.notImplemented();
            }
        });
    }
}
