// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../audio/headset/button_presses.dart';
import '../audio/headset/headset_settings.dart';
import '../player/remote_commands.dart';

/// A long press is not acted on twice if both the 600 ms timer and the
/// system's voice-search request report it, which they can for one hold. Only
/// a press from the other path counts as a duplicate: two holds that each end
/// in the same path's long press both act.
const kLongPressDedupe = Duration(milliseconds: 1500);

/// Headset and Bluetooth media keys on Android.
///
/// The platform forwards raw key events; this times them with the clock, runs
/// them through the [PressRecognizer] and hands the resulting command to
/// [execute] (the remote gate), then gives feedback for the ones that were
/// carried out. One deadline timer serves the whole press sequence.
class MediaButtonService {
  MediaButtonService({
    required Stream<Map<Object?, Object?>> events,
    required Future<bool> Function(RemoteCommand c, {required bool bluetooth})
    execute,
    required HeadsetSettings Function() settings,
    required bool Function() playing,
    required Stream<bool> playingStream,
    required Future<void> Function(ButtonFeedback f, int toneVolume) feedback,
    required int Function() toneVolume,
    required Future<void> Function({
      required bool respond,
      required bool playing,
      required bool longPressProxy,
      required bool wiredLongPress,
      required bool bluetoothLongPress,
    })
    pushPolicy,
  }) : _events = events,
       _execute = execute,
       _settings = settings,
       _playing = playing,
       _playingStream = playingStream,
       _feedback = feedback,
       _toneVolume = toneVolume,
       _pushPolicy = pushPolicy;

  final Stream<Map<Object?, Object?>> _events;
  final Future<bool> Function(RemoteCommand c, {required bool bluetooth})
  _execute;
  final HeadsetSettings Function() _settings;
  final bool Function() _playing;
  final Stream<bool> _playingStream;
  final Future<void> Function(ButtonFeedback f, int toneVolume) _feedback;
  final int Function() _toneVolume;
  final Future<void> Function({
    required bool respond,
    required bool playing,
    required bool longPressProxy,
    required bool wiredLongPress,
    required bool bluetoothLongPress,
  })
  _pushPolicy;

  PressRecognizer _recognizer = PressRecognizer();
  StreamSubscription<Map<Object?, Object?>>? _eventsSub;
  StreamSubscription<bool>? _playingSub;
  Timer? _timer;
  bool _started = false;
  bool _disposed = false;

  /// When, and by which path, the last long press was acted on, for
  /// [kLongPressDedupe]. Cleared by the next hook key-down.
  int? _lastLongMs;
  _LongPath? _lastLongPath;

  /// The hold that just produced a long press is still down: its release
  /// must not also toggle.
  bool _swallowHookRelease = false;

  int _nowMs() => clock.now().millisecondsSinceEpoch;

  /// Starts listening and tells the platform the policy in force. A platform
  /// without the handler (the stream errors, the push fails) is logged, not
  /// thrown.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _eventsSub = _events.listen(
      _onPlatformEvent,
      onError: (Object e) => debugPrint('Media button events: $e'),
    );
    _playingSub = _playingStream.listen(
      (playing) => unawaited(_push(playing)),
      onError: (Object e) => debugPrint('Playing stream: $e'),
    );
    unawaited(pushPolicy());
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    unawaited(_eventsSub?.cancel());
    unawaited(_playingSub?.cancel());
    _eventsSub = null;
    _playingSub = null;
  }

  /// Sends the current Respond to buttons, playing state and the voice-proxy
  /// wish (overall, and for wired and Bluetooth) to the platform. Call when the settings change.
  Future<void> pushPolicy() => _push(_playing());

  Future<void> _push(bool playing) async {
    if (_disposed) return;
    final s = _settings();
    try {
      await _pushPolicy(
        respond: s.respondToButtons,
        playing: playing,
        longPressProxy: voiceProxyEnabled(s),
        wiredLongPress: longPressWanted(s, ButtonSource.wired),
        bluetoothLongPress: longPressWanted(s, ButtonSource.bluetooth),
      );
    } catch (e) {
      debugPrint('Pushing the button policy failed: $e');
    }
  }

  void _onPlatformEvent(Map<Object?, Object?> raw) {
    if (_disposed) return;
    if (raw['connected'] == true) {
      // The platform handler is there now (it may not have been at start()).
      unawaited(pushPolicy());
      return;
    }
    final s = _settings();
    if (!s.respondToButtons) {
      // The platform swallows the keys too; drop anything half-recognised.
      _timer?.cancel();
      _timer = null;
      _recognizer = PressRecognizer();
      return;
    }
    final now = _nowMs();
    final e = buttonEventFromPlatform(raw, atMs: now);
    if (e == null) return;

    final isHook =
        !e.longPress &&
        (e.keyCode == MediaKey.headsetHook || e.keyCode == MediaKey.playPause);
    if (isHook && e.down) {
      _swallowHookRelease = false;
      _lastLongMs = null;
      _lastLongPath = null;
    }

    final mode = e.source == ButtonSource.bluetooth
        ? s.bluetoothButtons
        : s.wiredButtons;
    // A hold that reached 600 ms before this event is the timer's.
    final late = _recognizer.onDeadline(now, playing: _playing());
    var out = _recognizer.onEvent(e, mode: mode, playing: _playing());
    if (isHook && !e.down && _swallowHookRelease) {
      // The release of a hold that already acted as a long press.
      _swallowHookRelease = false;
      out = [for (final p in out) if (p.long) p];
    }
    _reschedule();
    unawaited(_emit(late, _LongPath.timer));
    unawaited(_emit(out, e.longPress ? _LongPath.voice : _LongPath.timer));
  }

  void _reschedule() {
    _timer?.cancel();
    _timer = null;
    final d = _recognizer.deadlineMs;
    if (d == null || _disposed) return;
    final wait = d - _nowMs();
    _timer = Timer(Duration(milliseconds: wait < 0 ? 0 : wait), _onDeadline);
  }

  void _onDeadline() {
    _timer = null;
    if (_disposed) return;
    final out = _recognizer.onDeadline(_nowMs(), playing: _playing());
    _reschedule();
    unawaited(_emit(out, _LongPath.timer));
  }

  Future<void> _emit(List<RecognizedPress> presses, _LongPath path) async {
    for (final p in presses) {
      if (_disposed) return;
      if (p.long) {
        final now = _nowMs();
        final last = _lastLongMs;
        if (last != null &&
            _lastLongPath != path &&
            now - last < kLongPressDedupe.inMilliseconds) {
          continue; // the same hold, already acted on by the other path
        }
        _lastLongMs = now;
        _lastLongPath = path;
        _swallowHookRelease = true;
      }
      try {
        final done = await _execute(
          p.command,
          bluetooth: p.source == ButtonSource.bluetooth,
        );
        if (!done || _disposed) continue;
        final f = feedbackFor(p, _settings());
        if (!f.isNone) await _feedback(f, _toneVolume());
      } catch (e) {
        debugPrint('Media button ${p.command.name} failed: $e');
      }
    }
  }
}

/// What reported a long press: the 600 ms timer or the system's voice request.
enum _LongPath { timer, voice }
