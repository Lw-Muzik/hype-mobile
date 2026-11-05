// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/services.dart';

import '../audio/advanced/advanced_settings.dart';

/// The system music volume as a fraction 0…1, from Android's
/// `SystemVolumeObserver` and iOS's `outputVolume` observer. Native only
/// emits when the level changed.
class VolumeFeed {
  VolumeFeed._();

  static const EventChannel _channel = EventChannel('eq_app/system_volume');

  static Stream<double> get stream => _channel
      .receiveBroadcastStream()
      .map((e) => (e as num).toDouble().clamp(0.0, 1.0))
      .handleError((Object _) {});
}

/// Pause/resume on volume: pauses when the volume reaches 0, and resumes only
/// what it paused, once the volume is raised and Hype's UI or notification is
/// visible. A pause or play by anyone else clears the mark.
class PauseOnVolume {
  PauseOnVolume({
    required Stream<double> volume,
    required Stream<bool> playingChanges,
    required bool Function() isPlaying,
    required bool Function() enabled,
    required bool Function() visible,
    required Future<void> Function() pause,
    required Future<void> Function() play,
  }) : _volume = volume,
       _playingChanges = playingChanges,
       _isPlaying = isPlaying,
       _enabled = enabled,
       _visible = visible,
       _pause = pause,
       _play = play;

  final Stream<double> _volume;
  final Stream<bool> _playingChanges;
  final bool Function() _isPlaying;
  final bool Function() _enabled;
  final bool Function() _visible;
  final Future<void> Function() _pause;
  final Future<void> Function() _play;

  StreamSubscription<double>? _volumeSub;
  StreamSubscription<bool>? _playingSub;
  double _previous = 1;
  bool _pausedByVolume = false;

  /// The playing state our own pause/play is about to publish; that change is
  /// not the listener's.
  bool? _expected;

  void start({double initial = 1}) {
    _previous = initial;
    _volumeSub ??= _volume.listen(_onVolume);
    _playingSub ??= _playingChanges.listen((playing) {
      if (_expected == playing) {
        _expected = null;
        return;
      }
      _expected = null;
      _pausedByVolume = false;
    });
  }

  void _onVolume(double now) {
    final previous = _previous;
    _previous = now;
    if (!_enabled()) {
      _pausedByVolume = false;
      return;
    }
    final action = volumeAction(
      previous: previous,
      now: now,
      playing: _isPlaying(),
      pausedByVolume: _pausedByVolume,
      uiOrNotificationVisible: _visible(),
    );
    switch (action) {
      case VolumeAction.pause:
        _run(_pause, mark: true);
      case VolumeAction.resume:
        _run(_play, mark: false);
      case null:
        break;
    }
  }

  void _run(Future<void> Function() act, {required bool mark}) {
    _expected = !mark; // pausing publishes false, playing publishes true
    _pausedByVolume = mark;
    // The player's own play() completes only when playback next pauses, so it
    // is never awaited.
    unawaited(act().catchError((Object _) {}));
  }

  void dispose() {
    unawaited(_volumeSub?.cancel());
    unawaited(_playingSub?.cancel());
    _volumeSub = _playingSub = null;
  }
}
