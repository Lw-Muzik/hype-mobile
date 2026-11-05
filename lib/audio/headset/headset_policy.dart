import 'headset_settings.dart';
import 'output_kind.dart';

/// What the player should do in response to an output-device change.
enum HeadsetAction { pause, resume, restartPlayback, startBluetoothGrace }

/// Actions for outputs that just connected.
///
/// Resume needs a paused player with something to resume, and never fires
/// while Hype waits for audio focus. A USB audio device appearing in the same
/// event suppresses Resume on wired (USB-C headsets report as both); a USB
/// DAC pauses playback on Android.
List<HeadsetAction> onOutputsConnected(
  Set<AudioOutputKind> kinds,
  HeadsetSettings s, {
  required bool playing,
  required bool canResume,
  required bool waitingForFocus,
  required bool isIos,
}) {
  final out = <HeadsetAction>[];
  final bluetooth = kinds.contains(AudioOutputKind.bluetooth);
  final wired = kinds.contains(AudioOutputKind.wired);
  final usb = kinds.contains(AudioOutputKind.usb);

  if (bluetooth) out.add(HeadsetAction.startBluetoothGrace);

  final mayResume = !playing && canResume && !waitingForFocus;
  // A USB-C headset reports as USB and wired together on Android, where USB
  // (a DAC) has its own rule, so it does not count as wired there. iOS hides
  // the USB rows and reports a USB-C headset as USB only: there it is wired.
  final wiredForResume = isIos ? (wired || usb) : (wired && !usb);
  final resume =
      mayResume &&
      ((bluetooth && s.resumeOnBluetooth) ||
          (wiredForResume && s.resumeOnWired));
  if (resume) out.add(HeadsetAction.resume);

  if (usb && !isIos && playing && s.pauseOnUsbDac) {
    out.add(HeadsetAction.pause);
  }
  return out;
}

/// Actions when the output is about to get loud (headset unplugged,
/// Bluetooth dropped).
///
/// With Pause on disconnect off, iOS still stops the player itself when the
/// route goes away, so Hype restarts it on the new route.
List<HeadsetAction> onBecomingNoisy(
  HeadsetSettings s, {
  required bool playing,
  required bool isIos,
}) {
  if (!playing) return const [];
  if (s.pauseOnDisconnect) return const [HeadsetAction.pause];
  return isIos ? const [HeadsetAction.restartPlayback] : const [];
}
