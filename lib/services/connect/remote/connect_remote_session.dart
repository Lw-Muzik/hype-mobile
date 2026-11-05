/// This phone as a remote control for another player (contract §3.12).
///
/// # What it keeps
///
/// * the device list and who is active, from `welcome` and `devices`;
/// * the latest [StampedState] of every other device, from `welcome.states` and
///   `state` frames. A frame whose `seq` is not newer than what is held for that
///   device is dropped; a device that goes offline is forgotten, and a `welcome`
///   replaces everything (the hub forgot our session, so it is the truth);
/// * the commands in flight, each waiting for its `ack`.
///
/// # Remote mode
///
/// [remoteTarget] is the active device when that is somebody else, online, and
/// a player. While it is non-null the app plays *there*: its player UI shows
/// [nowPlaying] and its controls go through [cmd]. When the target stops being
/// a target because it went offline (and nobody else took over), [events]
/// carries a [RemoteWentOffline] so the app can say so.
///
/// # Progress
///
/// Contract §3.6: `positionMs + (playing ? hubNow - at : 0)`, clamped to the
/// duration, where `hubNow` comes from the hub clock.
///
/// # Optimistic controls
///
/// A tap on pause or a seek should look done at once, not after a round trip
/// and a state frame. The tap leaves an overlay (the playing flag, or a
/// position) that holds until a state arrives for that device (it is
/// only accepted with a newer `seq`), or [overlayTtl] passes — whichever is first — and then the device's
/// own report wins again.
///
/// A **volume** overlay follows different rules. Volume is stepped quickly
/// (hardware keys repeat while held, a slider is dragged) and the echo of an
/// earlier step arrives while the next is already on screen, so "any newer
/// state drops it" would jitter the display back to a stale value. It is
/// dropped only by a state whose volume is within 0.01 of it (the device caught
/// up) or when [overlayTtl] passes since the last change.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../connect_protocol.dart';

/// What the remote device is playing, as of a moment.
@immutable
class RemoteNowPlaying {
  const RemoteNowPlaying({
    required this.device,
    required this.track,
    required this.playing,
    required this.positionMs,
    required this.durationMs,
    required this.volume,
    required this.shuffle,
    required this.repeat,
    required this.queue,
  });

  final DeviceInfo device;
  final TrackRef? track;
  final bool playing;

  /// Interpolated for the instant [ConnectRemoteSession.nowPlaying] was read.
  final int positionMs;
  final int? durationMs;
  final double volume;
  final bool shuffle;
  final ConnectRepeat repeat;
  final List<QueueEntry> queue;
}

sealed class RemoteEvent {
  const RemoteEvent();
}

/// The device this phone was remote-controlling disappeared.
final class RemoteWentOffline extends RemoteEvent {
  const RemoteWentOffline(this.deviceName);
  final String deviceName;
}

class _Overlay {
  _Overlay({required this.atMs});

  bool? playing;
  int? positionMs;

  /// Held separately from the transport guesses; see the library docs.
  double? volume;

  /// Hub time when the position was set.
  int atMs;
}

class ConnectRemoteSession extends ChangeNotifier {
  ConnectRemoteSession({
    required this.selfId,
    required this._send,
    required this._hubNowMs,
    this.cmdTimeout = const Duration(seconds: 11),
    this.overlayTtl = const Duration(seconds: 3),
  });

  final String selfId;
  final bool Function(ConnectFrame frame) _send;
  final int Function() _hubNowMs;

  /// The hub gives up on a player after 10 s; this is a second behind it.
  final Duration cmdTimeout;
  final Duration overlayTtl;

  List<DeviceInfo> _devices = const [];
  String? _activeId;
  final Map<String, StampedState> _states = {};
  final Map<String, _Overlay> _overlays = {};
  final Map<String, Timer> _overlayTimers = {};
  final Map<String, Timer> _volumeTimers = {};

  /// One step of [nudgeVolume]: a hardware key press.
  static const double volumeStep = 0.05;

  /// A volume command is sent at once if the last one went at least this long
  /// ago; otherwise the newest value goes once the gap has passed.
  static const Duration volumeGap = Duration(milliseconds: 120);

  DateTime? _volumeSentAt;
  Timer? _volumeTrailing;
  double? _volumePending;

  final Map<String, Completer<AckFrame>> _pending = {};
  final Map<String, Timer> _pendingTimers = {};
  int _counter = 0;

  String? _targetId;
  final _events = StreamController<RemoteEvent>.broadcast(sync: true);

  Stream<RemoteEvent> get events => _events.stream;

  List<DeviceInfo> get devices => _devices;
  String? get activeDeviceId => _activeId;

  /// The device to control, or null when this phone is not in remote mode.
  DeviceInfo? get remoteTarget {
    final id = _targetId;
    return id == null ? null : _deviceById(id);
  }

  bool get isRemote => _targetId != null;

  /// Every other online player: what the device picker lists.
  List<DeviceInfo> get otherPlayers => [
    for (final device in _devices)
      if (device.id != selfId && device.online && device.isPlayer) device,
  ];

  /// The latest known state of [deviceId], uninterpolated.
  StampedState? stateOf(String deviceId) => _states[deviceId];

  /// Whether [deviceId] was last reported playing.
  bool isPlaying(String deviceId) => _states[deviceId]?.state.playing ?? false;

  /// The remote device's player, interpolated to now; null outside remote mode.
  RemoteNowPlaying? nowPlaying() {
    final device = remoteTarget;
    if (device == null) return null;
    return _view(device);
  }

  /// Progress of the target right now, for a ticking progress bar.
  int? positionMs() => nowPlaying()?.positionMs;

  /// Progress of any device we hold a state for, interpolated to now; null with
  /// no state. Used to hand a track over mid-way.
  int? positionOf(String deviceId) {
    if (_states[deviceId] == null) return null;
    return _interpolated(deviceId, overlay: _overlays[deviceId]);
  }

  // -- Inputs ----------------------------------------------------------------

  void onFrame(ConnectFrame frame) {
    switch (frame) {
      case WelcomeFrame():
        _states
          ..clear()
          ..addAll(frame.states);
        _clearOverlays();
        _setDevices(frame.devices, frame.activeDeviceId);
      case DevicesFrame():
        _setDevices(frame.devices, frame.activeDeviceId);
      case StampedStateFrame():
        _onState(frame.deviceId, frame.state);
      case AckFrame():
        _onAck(frame);
      default:
        break;
    }
  }

  /// The socket closed: nothing sent will be answered, and what we knew of the
  /// others is no longer live.
  void onDisconnected() {
    for (final id in _pending.keys.toList()) {
      _complete(id, AckFrame.failed(id, AckError.offline));
    }
    _states.clear();
    _clearOverlays();
    _devices = const [];
    _activeId = null;
    _recomputeTarget();
    notifyListeners();
  }

  void _onState(String deviceId, StampedState state) {
    if (deviceId == selfId) return;
    final held = _states[deviceId];
    if (held != null && state.state.seq <= held.state.seq) return;
    _states[deviceId] = state;
    // The device has spoken since the tap (a state only gets here if its seq is
    // newer than any held): its word beats the guess. Except for the volume,
    // which is only let go once the device reports it (or the TTL passes).
    _dropTransportOverlay(deviceId);
    final guessed = _overlays[deviceId]?.volume;
    if (guessed != null && (state.state.volume - guessed).abs() <= 0.01) {
      _dropVolumeOverlay(deviceId);
    }
    if (deviceId == _targetId) notifyListeners();
  }

  void _setDevices(List<DeviceInfo> devices, String? active) {
    _devices = devices;
    _activeId = active;
    // An offline device's state is history.
    for (final device in devices) {
      if (!device.online) {
        _states.remove(device.id);
        _dropOverlay(device.id);
      }
    }
    _recomputeTarget();
    notifyListeners();
  }

  void _recomputeTarget() {
    final before = _targetId;
    final active = _activeId;
    final device = active == null || active == selfId
        ? null
        : _deviceById(active);
    final next = device != null && device.online && device.isPlayer
        ? device.id
        : null;
    _targetId = next;
    if (before != null && next == null) {
      final gone = _deviceById(before);
      final stillActive = active == before;
      // Gone, rather than handed over to this phone or someone else.
      if (stillActive && (gone == null || !gone.online)) {
        _events.add(RemoteWentOffline(gone?.name ?? 'The other device'));
      }
    }
  }

  // -- Commands --------------------------------------------------------------

  /// Sends [command] to [to] and completes with its `ack` (or a synthetic
  /// `offline` / `timeout` one — never throws).
  Future<AckFrame> cmd(String to, Command command) {
    final id = 'r${_hubNowMs().toRadixString(36)}-${_counter++}';
    final completer = Completer<AckFrame>();
    if (!_send(CmdFrame(id: id, to: to, cmd: command))) {
      return Future.value(AckFrame.failed(id, AckError.offline));
    }
    _pending[id] = completer;
    _pendingTimers[id] = Timer(cmdTimeout, () {
      _complete(id, AckFrame.failed(id, AckError.timeout));
    });
    return completer.future;
  }

  void _onAck(AckFrame ack) => _complete(ack.id, ack);

  void _complete(String id, AckFrame ack) {
    _pendingTimers.remove(id)?.cancel();
    final completer = _pending.remove(id);
    if (completer != null && !completer.isCompleted) completer.complete(ack);
  }

  /// A command to the current target; offline when there is none.
  Future<AckFrame> cmdTarget(Command command) {
    final id = _targetId;
    if (id == null) {
      return Future.value(AckFrame.failed('none', AckError.offline));
    }
    return cmd(id, command);
  }

  // Optimistic transport ------------------------------------------------------

  Future<AckFrame> pause() {
    _guess(playing: false);
    return cmdTarget(const PauseCommand());
  }

  Future<AckFrame> resume() {
    _guess(playing: true);
    return cmdTarget(const ResumeCommand());
  }

  Future<AckFrame> seek(int positionMs) {
    _guess(positionMs: positionMs);
    return cmdTarget(SeekCommand(positionMs));
  }

  Future<AckFrame> next() => cmdTarget(const NextCommand());
  Future<AckFrame> prev() => cmdTarget(const PrevCommand());
  Future<AckFrame> jump(String uid) => cmdTarget(JumpCommand(uid));
  Future<AckFrame> volume(double value) {
    _guessVolume(value.clamp(0.0, 1.0));
    return cmdTarget(VolumeCommand(value));
  }

  /// One hardware-key step on the remote device: [direction] is +1 or -1.
  /// Returns the level it now stands at, or null outside remote mode or while
  /// the device has not yet said what its volume is.
  ///
  /// At a bound nothing is sent and the current level is returned: a desktop
  /// boosted above 100 % reports 1.0, and an "up" there must not cut its boost
  /// back to 100 %.
  ///
  /// With no reported level there is nothing to step from. The view's stand-in
  /// of 1.0 is fine for drawing a slider, but stepping from it would turn a
  /// "down" on a device playing at 20 % into a jump to 95 %.
  double? nudgeVolume(int direction) {
    final id = _targetId;
    final device = id == null ? null : _deviceById(id);
    if (id == null || device == null) return null;
    if (_states[id] == null && _overlays[id]?.volume == null) return null;
    final current = _view(device).volume;
    final next = ((current + volumeStep * direction.sign) * 100).round() / 100;
    final clamped = next.clamp(0.0, 1.0);
    if (clamped == current) return current;
    _guessVolume(clamped);
    _sendVolumeThrottled(clamped);
    return clamped;
  }

  void _sendVolumeThrottled(double value) {
    final last = _volumeSentAt;
    final now = clock.now();
    if (_volumeTrailing == null &&
        (last == null || now.difference(last) >= volumeGap)) {
      _volumeSentAt = now;
      unawaited(cmdTarget(VolumeCommand(value)));
      return;
    }
    // Last value wins: a held key sends the final level, not every step.
    _volumePending = value;
    if (_volumeTrailing != null) return;
    final wait = last == null ? volumeGap : volumeGap - now.difference(last);
    _volumeTrailing = Timer(wait, () {
      _volumeTrailing = null;
      final pending = _volumePending;
      _volumePending = null;
      if (pending == null) return;
      _volumeSentAt = clock.now();
      unawaited(cmdTarget(VolumeCommand(pending)));
    });
  }

  Future<AckFrame> shuffle(bool on) => cmdTarget(ShuffleCommand(on));
  Future<AckFrame> repeat(ConnectRepeat mode) => cmdTarget(RepeatCommand(mode));

  void _guess({bool? playing, int? positionMs}) {
    final id = _targetId;
    if (id == null) return;
    final overlay =
        _overlays[id] ?? (_overlays[id] = _Overlay(atMs: _hubNowMs()));
    if (playing != null) {
      // Rebase the position to now so flipping the flag does not make it jump.
      overlay.positionMs = _interpolated(id, overlay: overlay);
      overlay.atMs = _hubNowMs();
      overlay.playing = playing;
    }
    if (positionMs != null) {
      overlay.positionMs = positionMs;
      overlay.atMs = _hubNowMs();
    }
    _overlayTimers[id]?.cancel();
    _overlayTimers[id] = Timer(overlayTtl, () {
      _dropTransportOverlay(id);
      notifyListeners();
    });
    notifyListeners();
  }

  void _guessVolume(double value) {
    final id = _targetId;
    if (id == null) return;
    final overlay =
        _overlays[id] ?? (_overlays[id] = _Overlay(atMs: _hubNowMs()));
    overlay.volume = value;
    _volumeTimers[id]?.cancel();
    _volumeTimers[id] = Timer(overlayTtl, () {
      _dropVolumeOverlay(id);
      notifyListeners();
    });
    notifyListeners();
  }

  /// Drops everything for [id]: the device went away or the session reset.
  void _dropOverlay(String id) {
    _overlays.remove(id);
    _overlayTimers.remove(id)?.cancel();
    _volumeTimers.remove(id)?.cancel();
  }

  void _dropTransportOverlay(String id) {
    _overlayTimers.remove(id)?.cancel();
    final overlay = _overlays[id];
    if (overlay == null) return;
    overlay.playing = null;
    overlay.positionMs = null;
    if (overlay.volume == null) _overlays.remove(id);
  }

  void _dropVolumeOverlay(String id) {
    _volumeTimers.remove(id)?.cancel();
    final overlay = _overlays[id];
    if (overlay == null) return;
    overlay.volume = null;
    if (overlay.playing == null && overlay.positionMs == null) {
      _overlays.remove(id);
    }
  }

  void _clearOverlays() {
    for (final timer in [..._overlayTimers.values, ..._volumeTimers.values]) {
      timer.cancel();
    }
    _overlayTimers.clear();
    _volumeTimers.clear();
    _overlays.clear();
  }

  // -- Reading ---------------------------------------------------------------

  DeviceInfo? _deviceById(String id) {
    for (final device in _devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  RemoteNowPlaying _view(DeviceInfo device) {
    final stamped = _states[device.id];
    final state = stamped?.state;
    final overlay = _overlays[device.id];
    final playing = overlay?.playing ?? state?.playing ?? false;
    return RemoteNowPlaying(
      device: device,
      track: state?.track,
      playing: playing,
      positionMs: _interpolated(device.id, overlay: overlay, playing: playing),
      durationMs: state?.durationMs,
      volume: overlay?.volume ?? state?.volume ?? 1,
      shuffle: state?.shuffle ?? false,
      repeat: state?.repeat ?? ConnectRepeat.off,
      queue: state?.queue ?? const [],
    );
  }

  /// §3.6, with an optimistic overlay when a tap is still waiting for the
  /// device to confirm it.
  int _interpolated(String id, {required _Overlay? overlay, bool? playing}) {
    final stamped = _states[id];
    final state = stamped?.state;
    final duration = state?.durationMs;
    int position;
    if (overlay?.positionMs != null) {
      final isPlaying = playing ?? overlay?.playing ?? state?.playing ?? false;
      position =
          overlay!.positionMs! + (isPlaying ? _hubNowMs() - overlay.atMs : 0);
    } else if (state != null && stamped != null) {
      final isPlaying = playing ?? state.playing;
      position = state.positionMs + (isPlaying ? _hubNowMs() - stamped.at : 0);
    } else {
      position = 0;
    }
    if (position < 0) position = 0;
    if (duration != null && duration > 0 && position > duration) {
      position = duration;
    }
    return position;
  }

  @override
  void dispose() {
    for (final timer in [
      ..._pendingTimers.values,
      ..._overlayTimers.values,
      ..._volumeTimers.values,
    ]) {
      timer.cancel();
    }
    _volumeTrailing?.cancel();
    unawaited(_events.close());
    super.dispose();
  }
}
