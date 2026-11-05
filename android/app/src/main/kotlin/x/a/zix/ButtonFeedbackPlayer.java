package x.a.zix;

import android.content.Context;
import android.media.AudioManager;
import android.media.ToneGenerator;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.os.VibratorManager;

/** Beeps and a short buzz for a recognised headset command. Imports only android.*. */
final class ButtonFeedbackPlayer {
    private static final int BEEP_MS = 60;
    private static final int BEEP_GAP_MS = 120;
    private static final int VIBRATE_MS = 40;
    private static final int MAX_BEEPS = 5;

    private ButtonFeedbackPlayer() {}

    /**
     * {@code beeps} short beeps on the music stream at {@code toneVolume}
     * (0...100), then released; {@code vibrate} adds one 40 ms pulse. Must be
     * called on the main thread (the method channel does).
     */
    static void play(Context c, int beeps, int toneVolume, boolean vibrate) {
        if (c == null) return;
        if (beeps > 0) beep(Math.min(beeps, MAX_BEEPS), Math.max(0, Math.min(100, toneVolume)));
        if (vibrate) buzz(c);
    }

    private static void beep(int beeps, int toneVolume) {
        final ToneGenerator tone;
        try {
            tone = new ToneGenerator(AudioManager.STREAM_MUSIC, toneVolume);
        } catch (RuntimeException e) {
            // No free tone generator, or the audio system is busy: no beep.
            return;
        }
        final Handler main = new Handler(Looper.getMainLooper());
        for (int i = 0; i < beeps; i++) {
            main.postDelayed(() -> tone.startTone(ToneGenerator.TONE_PROP_BEEP, BEEP_MS), (long) i * BEEP_GAP_MS);
        }
        // After the last beep has played out.
        main.postDelayed(tone::release, (long) (beeps - 1) * BEEP_GAP_MS + BEEP_MS + 100);
    }

    @SuppressWarnings("deprecation")
    private static void buzz(Context c) {
        Vibrator v;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            VibratorManager vm = (VibratorManager) c.getSystemService(Context.VIBRATOR_MANAGER_SERVICE);
            v = vm != null ? vm.getDefaultVibrator() : null;
        } else {
            v = (Vibrator) c.getSystemService(Context.VIBRATOR_SERVICE);
        }
        if (v == null || !v.hasVibrator()) return;
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v.vibrate(VibrationEffect.createOneShot(VIBRATE_MS, VibrationEffect.DEFAULT_AMPLITUDE));
            } else {
                v.vibrate(VIBRATE_MS);
            }
        } catch (RuntimeException e) {
            // Vibration denied (no permission, or restricted): feedback is optional.
        }
    }
}
