import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../audio/headset/headset_settings.dart';
import 'remote_commands.dart';

/// Stands in front of the audio handler for everything that reaches Hype from
/// outside the app: headset and Bluetooth keys, the notification, the lock
/// screen, a car. Each command is resolved against Strict and the Bluetooth
/// grace window ([resolveRemoteCommand]) before it does anything.
///
/// The app's own buttons talk to the handler directly and never come here.
///
/// Every override cannot tell where its command came from, so it is treated as
/// Bluetooth — the one source the grace window is about. A caller that does
/// know (the media-key service) uses [execute] and says so.
class RemoteCommandGate extends CompositeAudioHandler {
  RemoteCommandGate(BaseAudioHandler super.inner, {int Function()? nowMs})
    : _nowMs = nowMs ?? (() => clock.now().millisecondsSinceEpoch);

  final int Function() _nowMs;

  /// The settings in force. Pushed by the app controller.
  HeadsetSettings settings = const HeadsetSettings();

  /// When a Bluetooth output last appeared, for the grace window; null if none
  /// has since Hype started.
  int? bluetoothConnectedAtMs;

  /// A remote asked for a repeat mode; the app applies it.
  ValueChanged<LoopMode>? onRemoteRepeat;

  /// A remote asked for shuffle on or off; the app applies it.
  ValueChanged<bool>? onRemoteShuffle;

  bool _inGrace({required bool bluetooth}) =>
      bluetooth &&
      inBluetoothGrace(
        nowMs: _nowMs(),
        bluetoothConnectedAtMs: bluetoothConnectedAtMs,
        graceSeconds: settings.ignoreBluetoothCommandsS,
      );

  /// What [c] becomes, or null to drop it.
  ///
  /// Stop is the exception to Strict: it always stops, never toggles and is
  /// never "redundant". It is how the listener closes the notification, and
  /// with the service kept in the foreground while paused a stop ignored on a
  /// paused player would leave the notification undismissable. Only the
  /// Bluetooth grace window can drop it.
  RemoteCommand? _resolve(RemoteCommand c, {required bool bluetooth}) {
    if (c == RemoteCommand.stop) {
      return _inGrace(bluetooth: bluetooth) ? null : RemoteCommand.stop;
    }
    return resolveRemoteCommand(
      c,
      playing: playbackState.value.playing,
      strict: settings.strictCommands,
      inBluetoothGrace: _inGrace(bluetooth: bluetooth),
    );
  }

  Future<void> _dispatch(RemoteCommand? c) async {
    switch (c) {
      case RemoteCommand.play:
        await super.play();
      case RemoteCommand.pause:
        await super.pause();
      case RemoteCommand.stop:
        await super.stop();
      case RemoteCommand.next:
        await super.skipToNext();
      case RemoteCommand.previous:
        await super.skipToPrevious();
      case RemoteCommand.toggle:
      case null:
        break;
    }
  }

  /// Runs [c] if it passes the gate; false when it was ignored. [bluetooth]
  /// says whether the grace window applies to it — a wired key is never held
  /// back by it.
  ///
  /// Answers as soon as the command is resolved, without waiting for it to
  /// finish: a play completes only when playback next pauses (it is the
  /// player's own `play()`), so awaiting it would stall the caller.
  Future<bool> execute(RemoteCommand c, {required bool bluetooth}) async {
    final resolved = _resolve(c, bluetooth: bluetooth);
    if (resolved == null) return false;
    unawaited(
      _dispatch(resolved).catchError((Object e) {
        debugPrint('Remote command $resolved failed: $e');
      }),
    );
    return true;
  }

  @override
  Future<void> play() async {
    final r = _resolve(RemoteCommand.play, bluetooth: true);
    if (r == RemoteCommand.play) return super.play();
    await _dispatch(r);
  }

  @override
  Future<void> pause() async {
    final r = _resolve(RemoteCommand.pause, bluetooth: true);
    if (r == RemoteCommand.pause) return super.pause();
    await _dispatch(r);
  }

  @override
  Future<void> stop() async {
    final r = _resolve(RemoteCommand.stop, bluetooth: true);
    if (r == RemoteCommand.stop) return super.stop();
    await _dispatch(r);
  }

  @override
  Future<void> skipToNext() async {
    final r = _resolve(RemoteCommand.next, bluetooth: true);
    if (r == RemoteCommand.next) return super.skipToNext();
    await _dispatch(r);
  }

  @override
  Future<void> skipToPrevious() async {
    final r = _resolve(RemoteCommand.previous, bluetooth: true);
    if (r == RemoteCommand.previous) return super.skipToPrevious();
    await _dispatch(r);
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    final c = switch (button) {
      MediaButton.media => RemoteCommand.toggle,
      MediaButton.next => RemoteCommand.next,
      MediaButton.previous => RemoteCommand.previous,
    };
    final r = _resolve(c, bluetooth: true);
    // Next and previous resolve to themselves and go through the inner
    // handler's own click; a toggle has become a play or a pause.
    if (r != null && r == c) return super.click(button);
    await _dispatch(r);
  }

  // The rest of what a remote can send is held back by the Bluetooth grace
  // window too: a reconnecting car or headset replays whatever it last did.

  @override
  Future<void> seek(Duration position) async {
    if (_inGrace(bluetooth: true)) return;
    await super.seek(position);
  }

  @override
  Future<void> fastForward() async {
    if (_inGrace(bluetooth: true)) return;
    await super.fastForward();
  }

  @override
  Future<void> rewind() async {
    if (_inGrace(bluetooth: true)) return;
    await super.rewind();
  }

  @override
  Future<void> seekForward(bool begin) async {
    if (_inGrace(bluetooth: true)) return;
    await super.seekForward(begin);
  }

  @override
  Future<void> seekBackward(bool begin) async {
    if (_inGrace(bluetooth: true)) return;
    await super.seekBackward(begin);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (_inGrace(bluetooth: true)) return;
    await super.skipToQueueItem(index);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    if (settings.ignoreRepeatShuffle || _inGrace(bluetooth: true)) return;
    await super.setRepeatMode(repeatMode);
    onRemoteRepeat?.call(loopModeFromRemote(repeatMode));
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    if (settings.ignoreRepeatShuffle || _inGrace(bluetooth: true)) return;
    await super.setShuffleMode(shuffleMode);
    onRemoteShuffle?.call(shuffleFromRemote(shuffleMode));
  }
}
