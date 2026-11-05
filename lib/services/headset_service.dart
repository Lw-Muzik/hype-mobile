// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../audio/focus/playback_target.dart';
import '../audio/headset/headset_policy.dart';
import '../audio/headset/headset_settings.dart';
import '../audio/headset/output_kind.dart';

/// How long after a device appears Hype waits before resuming, so the route
/// has switched and the first notes do not come out of the speaker.
const kResumeOnConnectDelay = Duration(milliseconds: 500);

/// Reacts to outputs coming and going: Resume on wired/Bluetooth, Pause on
/// disconnect, Pause on USB DAC, and the start of the Bluetooth grace window.
/// The decisions are the pure ones in `headset_policy.dart`.
class HeadsetService {
  HeadsetService({
    required PlaybackTarget target,
    required void Function(int nowMs) onBluetoothConnected,
    required HeadsetSettings Function() settings,
    required bool Function() canResume,
    required bool Function() waitingForFocus,
    required bool isIos,
    required Stream<AudioDevicesChangedEvent> devicesChanged,
    required Stream<void> becomingNoisy,
    // ignore: experimental_member_use
    required Future<Set<AudioDevice>> Function() currentDevices,
    int Function()? nowMs,

    /// Drops a resume that is waiting on audio focus (see
    /// `AudioFocusService.cancelHold`).
    void Function()? onCancelHold,
  }) : _target = target,
       _onBluetoothConnected = onBluetoothConnected,
       _settings = settings,
       _canResume = canResume,
       _waitingForFocus = waitingForFocus,
       _isIos = isIos,
       _devicesChanged = devicesChanged,
       _becomingNoisy = becomingNoisy,
       _currentDevices = currentDevices,
       _onCancelHold = onCancelHold,
       _nowMs = nowMs ?? (() => clock.now().millisecondsSinceEpoch);

  /// The real thing, on the platform's audio session.
  static HeadsetService forPlatform({
    required PlaybackTarget target,
    required void Function(int nowMs) onBluetoothConnected,
    required HeadsetSettings Function() settings,
    required bool Function() canResume,
    required bool Function() waitingForFocus,
    void Function()? onCancelHold,
  }) {
    final session = AudioSession.instance;
    return HeadsetService(
      target: target,
      onBluetoothConnected: onBluetoothConnected,
      settings: settings,
      canResume: canResume,
      waitingForFocus: waitingForFocus,
      onCancelHold: onCancelHold,
      isIos: defaultTargetPlatform == TargetPlatform.iOS,
      devicesChanged: Stream.fromFuture(session)
          .asyncExpand((s) => s.devicesChangedEventStream),
      becomingNoisy: Stream.fromFuture(session)
          .asyncExpand((s) => s.becomingNoisyEventStream),
      currentDevices: () async =>
          (await session).getDevices(includeInputs: false),
    );
  }

  final PlaybackTarget _target;
  final void Function(int nowMs) _onBluetoothConnected;
  final HeadsetSettings Function() _settings;
  final bool Function() _canResume;
  final bool Function() _waitingForFocus;
  final bool _isIos;
  final Stream<AudioDevicesChangedEvent> _devicesChanged;
  final Stream<void> _becomingNoisy;
  // ignore: experimental_member_use
  final Future<Set<AudioDevice>> Function() _currentDevices;
  final void Function()? _onCancelHold;
  final int Function() _nowMs;

  /// The output devices already present; only a new id is a connection.
  final _knownOutputIds = <String>{};

  StreamSubscription<AudioDevicesChangedEvent>? _devicesSub;
  StreamSubscription<void>? _noisySub;
  Timer? _resumeTimer;
  bool _started = false;
  bool _disposed = false;

  /// Listens, once the devices present now are known: they are not
  /// connections. The subscriptions are made first and paused, so an event that
  /// arrives meanwhile is buffered (not dropped) and judged against them.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final devices = _devicesChanged.listen(
      _onDevices,
      onError: (Object e) => debugPrint('Audio devices stream: $e'),
    )..pause();
    final noisy = _becomingNoisy.listen(
      (_) => _onNoisy(),
      onError: (Object e) => debugPrint('Becoming-noisy stream: $e'),
    )..pause();
    _devicesSub = devices;
    _noisySub = noisy;
    try {
      for (final d in await _currentDevices()) {
        if (d.isOutput) _knownOutputIds.add(d.id);
      }
    } catch (e) {
      debugPrint('Listing the audio devices failed: $e');
    }
    if (_disposed) return;
    devices.resume();
    noisy.resume();
  }

  void dispose() {
    _disposed = true;
    _resumeTimer?.cancel();
    _resumeTimer = null;
    unawaited(_devicesSub?.cancel());
    unawaited(_noisySub?.cancel());
    _devicesSub = _noisySub = null;
  }

  /// Serialises the iOS rescans, which are asynchronous.
  Future<void> _rescanQueue = Future<void>.value();

  void _onDevices(AudioDevicesChangedEvent e) {
    if (_isIos) {
      // audio_session compares a route change with the previous route, and for
      // the first change after launch there is none: the event comes with
      // empty added and removed sets. So on iOS the event only says "the route
      // changed", and the devices are read again and diffed against the known
      // ones.
      _rescanQueue = _rescanQueue.then((_) => _rescan());
      return;
    }
    _apply(e);
  }

  Future<void> _rescan() async {
    if (_disposed) return;
    try {
      final now = [
        for (final d in await _currentDevices())
          if (d.isOutput) d,
      ];
      if (_disposed) return;
      final ids = {for (final d in now) d.id};
      _knownOutputIds.removeWhere((id) => !ids.contains(id));
      _apply(AudioDevicesChangedEvent(devicesAdded: now.toSet()));
    } catch (e) {
      debugPrint('Listing the audio devices failed: $e');
    }
  }

  void _apply(AudioDevicesChangedEvent e) {
    final kinds = newlyConnectedOutputs(e, _knownOutputIds);
    if (kinds.isEmpty) return;
    final actions = onOutputsConnected(
      kinds,
      _settings(),
      playing: _target.playing,
      canResume: _canResume(),
      waitingForFocus: _waitingForFocus(),
      isIos: _isIos,
    );
    for (final a in actions) {
      _perform(a);
    }
  }

  void _onNoisy() {
    // Paused for a call or another app, and the output is about to get loud:
    // what was going to resume would start on the speaker. With Pause on
    // disconnect off the listener asked for the opposite, so the hold stays.
    if (!_target.playing &&
        _waitingForFocus() &&
        _settings().pauseOnDisconnect) {
      _onCancelHold?.call();
      return;
    }
    for (final a in onBecomingNoisy(
      _settings(),
      playing: _target.playing,
      isIos: _isIos,
    )) {
      _perform(a);
    }
  }

  void _perform(HeadsetAction a) {
    switch (a) {
      case HeadsetAction.startBluetoothGrace:
        _onBluetoothConnected(_nowMs());
      case HeadsetAction.pause:
        // The output is about to be, or already is, the speaker: no fade.
        _run(_target.pause(fade: false), 'pause');
      case HeadsetAction.restartPlayback:
        _run(_target.restartPlayback(), 'restart');
      case HeadsetAction.resume:
        _resumeTimer?.cancel();
        _resumeTimer = Timer(kResumeOnConnectDelay, _resumeNow);
    }
  }

  void _resumeNow() {
    _resumeTimer = null;
    // Things change in half a second: the listener may have pressed play, a
    // call may have started, a Connect device may have taken over.
    if (_target.playing || _waitingForFocus() || !_canResume()) return;
    _run(_target.play(), 'resume');
  }

  void _run(Future<void> f, String what) {
    unawaited(
      f.catchError((Object e) {
        debugPrint('Headset $what failed: $e');
      }),
    );
  }
}
