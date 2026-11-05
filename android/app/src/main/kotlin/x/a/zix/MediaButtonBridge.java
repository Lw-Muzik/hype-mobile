package x.a.zix;

import android.content.ComponentName;
import android.content.Context;
import android.content.pm.PackageManager;
import android.view.InputDevice;
import android.view.KeyEvent;

import java.util.HashMap;
import java.util.Map;

/**
 * Headset and Bluetooth media keys, from audio_service's media-session
 * callback to Dart. Native only forwards: every decision (double press, long
 * press, Strict, the Bluetooth grace window) is made in Dart.
 *
 * <p>Imports only android.* and java.* so it type-checks on its own; the
 * Flutter and audio_service wiring is in {@link MediaButtonChannel}.
 */
final class MediaButtonBridge {
    /** Where key events go; the Dart side of the EventChannel. */
    interface Sink {
        void send(Map<String, Object> event);
    }

    private static final int KEYCODE_HEADSETHOOK = 79;
    private static final int KEYCODE_MEDIA_PLAY_PAUSE = 85;
    private static final int KEYCODE_MEDIA_STOP = 86;
    private static final int KEYCODE_MEDIA_NEXT = 87;
    private static final int KEYCODE_MEDIA_PREVIOUS = 88;
    private static final int KEYCODE_MEDIA_PLAY = 126;
    private static final int KEYCODE_MEDIA_PAUSE = 127;

    private static volatile Sink sSink;
    private static volatile boolean sRespond = true;
    private static volatile boolean sPlaying;
    private static volatile boolean sLongPressProxy;
    private static volatile boolean sWiredLongPress;
    private static volatile boolean sBluetoothLongPress;
    /** What the voice-search proxy component was last set to; null until first set. */
    private static Boolean sProxyEnabled;

    private MediaButtonBridge() {}

    static void setSink(Sink s) {
        sSink = s;
    }

    /**
     * What Dart last said: whether headset keys are answered at all, whether
     * Hype is playing (for the long-press voice proxy) and whether that proxy
     * is wanted.
     */
    static void setPolicy(Context c, boolean respond, boolean playing, boolean longPressProxy,
            boolean wiredLongPress, boolean bluetoothLongPress) {
        sRespond = respond;
        sPlaying = playing;
        sLongPressProxy = longPressProxy;
        sWiredLongPress = wiredLongPress;
        sBluetoothLongPress = bluetoothLongPress;
        setProxyEnabled(c, longPressProxy);
    }

    /**
     * Whether a hold of the button on the output in use now is wanted as a long
     * press. When it is not (say Bluetooth is set to Long press and wired is
     * not), the proxy hands the voice-search request on to the other app.
     */
    static boolean wantsLongPress(Context c) {
        final boolean bluetooth = "bluetooth".equals(AudioOutputDetector.getAudioOutputType(c));
        return bluetooth ? sBluetoothLongPress : sWiredLongPress;
    }

    /**
     * Turns the voice-search proxy activity on or off. It is off in the
     * manifest, so Hype is not offered as a voice-search app unless the
     * listener's settings call for it.
     */
    private static synchronized void setProxyEnabled(Context c, boolean enabled) {
        if (c == null || (sProxyEnabled != null && sProxyEnabled == enabled)) return;
        try {
            c.getPackageManager().setComponentEnabledSetting(
                    new ComponentName(c, VoiceSearchProxyActivity.class),
                    enabled
                            ? PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                            : PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP);
            sProxyEnabled = enabled;
        } catch (RuntimeException e) {
            // Retried at the next policy push.
            sProxyEnabled = null;
        }
    }

    /**
     * The system asked for voice search while Hype plays and the button that
     * did it is held down: tell Dart, which decides what a long press is.
     */
    /** Hands a long press to Dart; false when nobody can act on it. */
    static boolean onVoiceLongPress(Context c) {
        final Sink sink = sSink;
        if (sink == null || !sRespond) return false;
        Map<String, Object> m = new HashMap<>();
        m.put("longPress", true);
        m.put("btOutput", "bluetooth".equals(AudioOutputDetector.getAudioOutputType(c)));
        sink.send(m);
        return true;
    }

    static boolean isPlaying() {
        return sPlaying;
    }

    static boolean longPressProxy() {
        return sLongPressProxy;
    }

    private static boolean isHandledKey(int keyCode) {
        switch (keyCode) {
            case KEYCODE_HEADSETHOOK:
            case KEYCODE_MEDIA_PLAY_PAUSE:
            case KEYCODE_MEDIA_STOP:
            case KEYCODE_MEDIA_NEXT:
            case KEYCODE_MEDIA_PREVIOUS:
            case KEYCODE_MEDIA_PLAY:
            case KEYCODE_MEDIA_PAUSE:
                return true;
            default:
                return false;
        }
    }

    /**
     * Offered every media key that is not one of audio_service's own
     * notification buttons. Returns true when the event is dealt with (sent to
     * Dart, or swallowed because Respond to buttons is off); false leaves it to
     * audio_service.
     */
    static boolean onMediaButton(Context c, KeyEvent e) {
        if (e == null || !isHandledKey(e.getKeyCode())) return false;
        if (!sRespond) return true;
        final Sink sink = sSink;
        if (sink == null) return false;
        final int action = e.getAction();
        if (action != KeyEvent.ACTION_DOWN && action != KeyEvent.ACTION_UP) return true;

        Map<String, Object> m = new HashMap<>();
        m.put("keyCode", e.getKeyCode());
        m.put("down", action == KeyEvent.ACTION_DOWN);
        m.put("repeat", e.getRepeatCount());
        m.put("deviceId", e.getDeviceId());
        InputDevice device = e.getDevice();
        m.put("deviceName", device != null ? device.getName() : null);
        m.put("btOutput", "bluetooth".equals(AudioOutputDetector.getAudioOutputType(c)));
        sink.send(m);
        return true;
    }
}
