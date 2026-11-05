/// One player at a time: the Claim and Yield rules of contract §3.12.
///
/// # The rules
///
/// `activeDeviceId` names the one player that should be making sound. A
/// connected player whose `activeDeviceId` is not itself keeps it true:
///
/// * **Claim.** It sends `select {self}` when
///   (a) its playback goes from not playing to playing, for any reason — the
///       app's own UI, the lock screen, a headset button, a `play`/`resume`
///       command — or
///   (b) it receives `welcome` or `devices` while playing and the active device
///       is null, offline, or not a player.
/// (c) it receives `welcome` while playing and either its playback started
///       while it had no socket (a lock-screen play after the background grace
///       closed the socket), or the active device's entry in `welcome.states`
///       is missing or not playing (a stale selection, e.g. left over from a
///       merge).
///   It is then *claiming* until a `welcome`/`devices` shows itself as active,
///   the hub answers `not_a_player`, or [claimWindow] passes. At most one claim
///   is sent per [claimWindow].
/// * **Yield.** A player that is playing, is not claiming, and receives a
///   `devices` naming **another online player** as active pauses its own
///   playback (pause, not stop). On `welcome` it yields only when (c) does not
///   apply. A claiming player postpones the check until claiming ends, then
///   applies it to the latest list as a `devices` check.
///
/// Two players that start at once both claim; the hub applies the selects in
/// turn, and the loser sees the winner as active when its claiming ends and
/// yields. That is last-select-wins.
///
/// # Shape
///
/// A pure state machine: it reads nothing and touches nothing but the two
/// callbacks it is given, so every rule above is a plain unit test.
library;

import 'dart:async';

import 'package:clock/clock.dart';

import '../connect_protocol.dart';

class ConnectTakeover {
  ConnectTakeover({
    required this.selfId,
    required this.sendSelect,
    required this.pauseLocal,
    this.claimWindow = const Duration(seconds: 3),
  });

  /// This install's device id.
  final String selfId;

  /// Sends `select {deviceId}`; false when no session is up (nothing was sent,
  /// so nothing counts as a claim).
  final bool Function(String deviceId) sendSelect;

  /// Pauses local playback — pause, not stop.
  final void Function() pauseLocal;

  /// How long a claim waits for the hub, and the minimum gap between claims.
  final Duration claimWindow;

  bool _connected = false;
  bool _listed = false;
  bool _playing = false;
  bool _startedOffline = false;
  List<DeviceInfo> _devices = const [];
  String? _activeId;

  bool _claiming = false;
  DateTime? _lastClaimAt;
  Timer? _claimTimer;

  /// Whether a claim is waiting for the hub's answer.
  bool get claiming => _claiming;

  /// Whether the hub has said, on this connection, which device is the active
  /// player. Until it has, [otherPlayerActive] being false means "not heard
  /// yet", not "nobody else is playing".
  bool get hubHasAnswered => _connected && _listed;

  /// Whether another online player is the active device, so this one is not
  /// the one that should be making sound. The automatic resumes (start,
  /// reopen, wired, Bluetooth, focus gain) stay quiet while this holds.
  bool get otherPlayerActive {
    if (!_connected) return false;
    final active = _activeId;
    if (active == null || active == selfId) return false;
    final device = _deviceById(active);
    return device != null && device.online && device.isPlayer;
  }

  // -- Inputs ----------------------------------------------------------------

  /// The socket reached `welcome` (call [onList] with its contents too).
  void onConnected() {
    _connected = true;
  }

  /// The socket went away. Whatever list we held is stale from here on.
  void onDisconnected() {
    _connected = false;
    _listed = false;
    _devices = const [];
    _activeId = null;
    _endClaim();
  }

  /// A `welcome` ([isWelcome], with [activeIsPlaying] from `welcome.states`:
  /// null when the active device has no entry) or `devices` frame.
  void onList(
    List<DeviceInfo> devices,
    String? activeDeviceId, {
    bool isWelcome = false,
    bool? activeIsPlaying,
  }) {
    _devices = devices;
    _activeId = activeDeviceId;
    _listed = true;
    if (!_connected) return;

    if (_claiming) {
      if (activeDeviceId == selfId) _endClaim();
      return; // Otherwise the check waits for the claim to end.
    }
    if (!_playing) return;
    _evaluate(
      allowClaim: true,
      isWelcome: isWelcome,
      activeIsPlaying: activeIsPlaying,
    );
  }

  /// The `error` frame with [code]. Only `not_a_player` concerns a claim.
  void onError(String code) {
    if (code != 'not_a_player' || !_claiming) return;
    _endClaim();
    if (_playing) _evaluate(allowClaim: false);
  }

  /// This phone's music started or stopped playing.
  void onLocalPlaying(bool playing) {
    final started = playing && !_playing;
    _playing = playing;
    if (!playing) _startedOffline = false;
    if (started && !_connected) _startedOffline = true;
    if (!started || !_connected) return;
    if (_activeId == selfId) return;
    _claim();
  }

  void dispose() {
    _claimTimer?.cancel();
    _claimTimer = null;
  }

  // -- Rules -----------------------------------------------------------------

  void _evaluate({
    required bool allowClaim,
    bool isWelcome = false,
    bool? activeIsPlaying,
  }) {
    final active = _activeId;
    if (active == selfId) {
      _startedOffline = false;
      return;
    }
    final device = active == null ? null : _deviceById(active);
    final activeIsOnlinePlayer =
        device != null && device.online && device.isPlayer;
    if (activeIsOnlinePlayer) {
      // Rule (c): on welcome, an offline start or a stale/idle selection wins.
      final claimInstead =
          isWelcome && (_startedOffline || activeIsPlaying != true);
      if (!claimInstead) {
        pauseLocal(); // Yield.
        return;
      }
    }
    if (allowClaim) _claim(); // Rule (b).
  }

  DeviceInfo? _deviceById(String id) {
    for (final device in _devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  void _claim() {
    final now = clock.now();
    final last = _lastClaimAt;
    if (last != null && now.difference(last) < claimWindow) return;
    if (!sendSelect(selfId)) return;
    _startedOffline = false;
    _lastClaimAt = now;
    _claiming = true;
    _claimTimer?.cancel();
    _claimTimer = Timer(claimWindow, _onClaimTimeout);
  }

  void _onClaimTimeout() {
    _claimTimer = null;
    if (!_claiming) return;
    _claiming = false;
    // Apply the postponed yield to the latest list; never re-claim from a
    // timer, or a silent hub would be sent a select every few seconds forever.
    if (_playing && _connected) _evaluate(allowClaim: false);
  }

  void _endClaim() {
    _claiming = false;
    _claimTimer?.cancel();
    _claimTimer = null;
  }
}
