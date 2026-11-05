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

    /**
     * Whether the "Disable absolute volume" developer option is on
     * ({@code Settings.Global bluetooth_disable_absolute_volume == 1}).
     * An unset option means absolute volume is in use (false). Null when the
     * setting cannot be read, which callers treat as unknown.
     */
    public static Boolean isBtAbsoluteVolumeDisabled(Context context) {
        if (context == null) return null;
        try {
            return Settings.Global.getInt(
                    context.getContentResolver(),
                    "bluetooth_disable_absolute_volume", 0) == 1;
        } catch (RuntimeException e) {
            return null;
        }
    }
}
