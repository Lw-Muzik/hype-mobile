package x.a.zix;

import android.content.Context;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.os.Build;
import android.provider.Settings;

public class AudioOutputDetector {

    @SuppressWarnings("deprecation")
    public static String getAudioOutputType(Context context) {
        if (context == null) return "speaker";

        AudioManager am = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        if (am == null) return "speaker";

        // These methods check actual audio routing, not just connected devices.
        // They're deprecated but remain the most reliable way to detect the
        // active output across all API levels.
        if (am.isBluetoothA2dpOn() || am.isBluetoothScoOn()) return "bluetooth";
        if (am.isWiredHeadsetOn()) return "wired_headphone";

        // For USB and BLE (no deprecated helper exists), scan connected devices.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            AudioDeviceInfo[] devices = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS);
            for (AudioDeviceInfo device : devices) {
                int type = device.getType();
                if (type == AudioDeviceInfo.TYPE_USB_DEVICE
                        || type == AudioDeviceInfo.TYPE_USB_ACCESSORY
                        || type == AudioDeviceInfo.TYPE_USB_HEADSET) {
                    return "usb_audio";
                }
                // BLE audio (API 31+)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    if (type == AudioDeviceInfo.TYPE_BLE_HEADSET
                            || type == AudioDeviceInfo.TYPE_BLE_SPEAKER) {
                        return "bluetooth";
                    }
                }
            }
        }

        return "speaker";
    }

    /** The {@link AudioDeviceInfo} type matching the active output. */
    public static int getActiveDeviceType(Context context) {
        String type = getAudioOutputType(context);
        switch (type) {
            case "bluetooth": return AudioDeviceInfo.TYPE_BLUETOOTH_A2DP;
            case "wired_headphone": return AudioDeviceInfo.TYPE_WIRED_HEADPHONES;
            case "usb_audio": return AudioDeviceInfo.TYPE_USB_HEADSET;
            default: return AudioDeviceInfo.TYPE_BUILTIN_SPEAKER;
        }
    }

    /** The class of an output device: "bluetooth", "wired_headphone", "usb_audio", "speaker", or null. */
    private static String classOf(AudioDeviceInfo d) {
        int t = d.getType();
        if (t == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP || t == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                || t == AudioDeviceInfo.TYPE_HEARING_AID) return "bluetooth";
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
                && (t == AudioDeviceInfo.TYPE_BLE_HEADSET || t == AudioDeviceInfo.TYPE_BLE_SPEAKER
                    || t == AudioDeviceInfo.TYPE_BLE_BROADCAST)) return "bluetooth";
        if (t == AudioDeviceInfo.TYPE_WIRED_HEADSET || t == AudioDeviceInfo.TYPE_WIRED_HEADPHONES)
            return "wired_headphone";
        if (t == AudioDeviceInfo.TYPE_USB_DEVICE || t == AudioDeviceInfo.TYPE_USB_HEADSET
                || t == AudioDeviceInfo.TYPE_USB_ACCESSORY) return "usb_audio";
        if (t == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER) return "speaker";
        return null;
    }

    /**
     * The output the music stream is actually routed to (API 33+: the routed
     * device list for media; before that the connected output the platform
     * prefers, in the same order as {@link #getAudioOutputType}). Null if none
     * can be told.
     */
    @SuppressWarnings("deprecation")
    public static AudioDeviceInfo getActiveOutputDevice(Context context) {
        if (context == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null;
        AudioManager am = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        if (am == null) return null;
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                java.util.List<AudioDeviceInfo> routed = am.getAudioDevicesForAttributes(
                        new android.media.AudioAttributes.Builder()
                                .setUsage(android.media.AudioAttributes.USAGE_MEDIA).build());
                for (AudioDeviceInfo d : routed) if (classOf(d) != null) return d;
            }
            String want = getAudioOutputType(context);
            for (AudioDeviceInfo d : am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
                if (want.equals(classOf(d))) return d;
            }
        } catch (RuntimeException ignored) {}
        return null;
    }

    private static boolean usable(CharSequence name) {
        if (name == null) return false;
        String n = name.toString().trim();
        return !n.isEmpty() && !"null".equalsIgnoreCase(n);
    }

    /**
     * Identity of the output music plays on: its class, and a stable id when
     * there is one (Bluetooth address on API 28+, else a real product name;
     * USB and wired: a real product name). LE and classic links of one headset
     * share the address, so they share a key. Without an id the key is the
     * class alone, which the Dart side treats as "may have changed".
     */
    public static String getActiveDeviceKey(Context context) {
        AudioDeviceInfo d = getActiveOutputDevice(context);
        if (d == null) return getAudioOutputType(context);
        String cls = classOf(d);
        if ("speaker".equals(cls)) return "speaker";
        String id = null;
        if ("bluetooth".equals(cls) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
                && usable(d.getAddress()) && !"00:00:00:00:00:00".equals(d.getAddress())) {
            id = d.getAddress();
        } else if (usable(d.getProductName())) {
            id = d.getProductName().toString().trim();
        }
        return id == null ? cls : cls + ":" + id;
    }

    /**
     * Whether Bluetooth absolute volume is disabled: the developer option's
     * system property {@code persist.bluetooth.disableabsvol} first, then the
     * {@code Settings.Global bluetooth_disable_absolute_volume} fallback. Unset
     * everywhere means absolute volume is in use (false). Null when neither
     * can be read, which callers treat as unknown.
     */
    public static Boolean isBtAbsoluteVolumeDisabled(Context context) {
        boolean readable = false;
        try {
            Class<?> sp = Class.forName("android.os.SystemProperties");
            String v = (String) sp.getMethod("get", String.class, String.class)
                    .invoke(null, "persist.bluetooth.disableabsvol", "");
            readable = true;
            if ("true".equals(v) || "1".equals(v)) return Boolean.TRUE;
            if ("false".equals(v) || "0".equals(v)) return Boolean.FALSE;
        } catch (Throwable ignored) {}
        if (context == null) return readable ? Boolean.FALSE : null;
        try {
            return Settings.Global.getInt(
                    context.getContentResolver(),
                    "bluetooth_disable_absolute_volume", 0) == 1;
        } catch (RuntimeException e) {
            return readable ? Boolean.FALSE : null;
        }
    }
}
