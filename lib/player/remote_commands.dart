import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

/// A transport command that reaches Hype from outside the app (headset,
/// Bluetooth, notification, lock screen).
enum RemoteCommand { play, pause, toggle, stop, next, previous }

/// What to do with [c], or null to ignore it.
///
/// Commands inside the Bluetooth grace window are always dropped. With
/// [strict] on, a command that would not change anything (play while playing,
/// pause or stop while paused) is dropped; with it off, those flip the state.
RemoteCommand? resolveRemoteCommand(
  RemoteCommand c, {
  required bool playing,
  required bool strict,
  required bool inBluetoothGrace,
}) {
  if (inBluetoothGrace) return null;
  switch (c) {
    case RemoteCommand.play:
      if (!playing) return RemoteCommand.play;
      return strict ? null : RemoteCommand.pause;
    case RemoteCommand.pause:
      if (playing) return RemoteCommand.pause;
      return strict ? null : RemoteCommand.play;
    case RemoteCommand.stop:
      if (playing) return RemoteCommand.stop;
      return strict ? null : RemoteCommand.play;
    case RemoteCommand.toggle:
      return playing ? RemoteCommand.pause : RemoteCommand.play;
    case RemoteCommand.next:
    case RemoteCommand.previous:
      return c;
  }
}

/// Whether commands are still being ignored after a Bluetooth output
/// appeared. False when [graceSeconds] is 0 or no connect was seen.
bool inBluetoothGrace({
  required int nowMs,
  required int? bluetoothConnectedAtMs,
  required int graceSeconds,
}) {
  if (graceSeconds <= 0 || bluetoothConnectedAtMs == null) return false;
  return nowMs - bluetoothConnectedAtMs < graceSeconds * 1000;
}

/// Remote repeat "group" has no equivalent here and means repeat-all.
LoopMode loopModeFromRemote(AudioServiceRepeatMode m) {
  switch (m) {
    case AudioServiceRepeatMode.none:
      return LoopMode.off;
    case AudioServiceRepeatMode.one:
      return LoopMode.one;
    case AudioServiceRepeatMode.all:
    case AudioServiceRepeatMode.group:
      return LoopMode.all;
  }
}

AudioServiceRepeatMode remoteRepeatModeOf(LoopMode m) {
  switch (m) {
    case LoopMode.off:
      return AudioServiceRepeatMode.none;
    case LoopMode.one:
      return AudioServiceRepeatMode.one;
    case LoopMode.all:
      return AudioServiceRepeatMode.all;
  }
}

/// Remote shuffle "group" means shuffle on.
bool shuffleFromRemote(AudioServiceShuffleMode m) =>
    m != AudioServiceShuffleMode.none;
