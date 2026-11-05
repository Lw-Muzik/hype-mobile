import 'package:audio_session/audio_session.dart';

/// The kinds of audio output the headset policy tells apart.
enum AudioOutputKind { speaker, wired, bluetooth, usb, other }

// AudioDeviceType is @experimental in audio_session.
// ignore: experimental_member_use
AudioOutputKind outputKindOf(AudioDeviceType t) {
  switch (t) {
    // ignore: experimental_member_use
    case AudioDeviceType.wiredHeadset:
    // ignore: experimental_member_use
    case AudioDeviceType.wiredHeadphones:
    // ignore: experimental_member_use
    case AudioDeviceType.lineAnalog:
      return AudioOutputKind.wired;
    // ignore: experimental_member_use
    case AudioDeviceType.bluetoothA2dp:
    // ignore: experimental_member_use
    case AudioDeviceType.bluetoothLe:
      return AudioOutputKind.bluetooth;
    // ignore: experimental_member_use
    case AudioDeviceType.usbAudio:
      return AudioOutputKind.usb;
    // ignore: experimental_member_use
    case AudioDeviceType.builtInSpeaker:
    // ignore: experimental_member_use
    case AudioDeviceType.builtInEarpiece:
    // ignore: experimental_member_use
    case AudioDeviceType.builtInSpeakerSafe:
      return AudioOutputKind.speaker;
    default:
      return AudioOutputKind.other;
  }
}

/// The kinds of output that just appeared in [e].
///
/// Only outputs count, and only ids not already in [knownOutputIds]. Mutates
/// [knownOutputIds]: removed devices leave it, added ones join it.
Set<AudioOutputKind> newlyConnectedOutputs(
  AudioDevicesChangedEvent e,
  Set<String> knownOutputIds,
) {
  for (final d in e.devicesRemoved) {
    if (d.isOutput) knownOutputIds.remove(d.id);
  }
  final kinds = <AudioOutputKind>{};
  for (final d in e.devicesAdded) {
    if (!d.isOutput) continue;
    if (!knownOutputIds.add(d.id)) continue;
    // ignore: experimental_member_use
    final k = outputKindOf(d.type);
    if (k == AudioOutputKind.wired ||
        k == AudioOutputKind.bluetooth ||
        k == AudioOutputKind.usb) {
      kinds.add(k);
    }
  }
  return kinds;
}
