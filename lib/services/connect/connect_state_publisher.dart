/// Telling the hub what this phone is playing.
///
/// # When a frame is worth sending
///
/// Controllers draw their progress bar by extrapolating from the last frame
/// (`position + time since it arrived`), so a frame only has to be sent when
/// that extrapolation would be wrong:
///
/// * something besides the position changed — the track, play or pause, the
///   volume, shuffle, repeat, the queue; or
/// * the position is not where the last frame said it would be by now (a seek,
///   or a stall), by more than [positionTolerance]; or
/// * it has been [heartbeat] since the last frame while playing, so a controller
///   that joined late, or a hub that restarted, hears from us anyway.
///
/// Ordinary playback sends nothing between heartbeats, which matters on a phone
/// whose radio would otherwise wake three times a second for a progress bar.
///
/// # Coalescing
///
/// A track change fires the controller, the player and the queue within a few
/// milliseconds of each other. Changes are gathered for [debounce] and the
/// state is read once, afterwards, so the hub sees one frame describing where
/// things ended up rather than three describing where they passed through.
///
/// # `seq`
///
/// Receivers drop a frame whose `seq` is not newer than what they hold, so it
/// must never go backwards — including across an app restart, when the hub still
/// remembers the old session's last value. It starts from the larger of the
/// clock in epoch seconds (which fits the 32-bit range the hub validates until
/// 2038) and one past the last value this install persisted, which covers a
/// wrong clock and a long burst of frames.
library;

import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';

import 'connect_protocol.dart';
import 'connect_tracks.dart';

/// One upcoming queue entry as the source sees it.
@immutable
class UpcomingSong {
  const UpcomingSong(this.uid, this.song);

  /// From [queueUids], so that it is what a `jump` will be matched against.
  final String uid;
  final SongModel song;
}

/// What the player looks like at one instant.
@immutable
class ConnectSnapshot {
  const ConnectSnapshot({
    required this.track,
    required this.playing,
    required this.position,
    required this.duration,
    required this.volume,
    required this.shuffle,
    required this.repeat,
    required this.upcoming,
    this.video = false,
  });

  final SongModel? track;
  final bool playing;
  final Duration position;
  final Duration? duration;

  /// Null when the volume cannot be read meaningfully right now — mid
  /// crossfade, when each player's volume is a point on a ramp rather than the
  /// user's setting. The publisher then repeats the last value it knew.
  final double? volume;
  final bool shuffle;
  final ConnectRepeat repeat;

  /// Everything after the playing track, in playing order. May be longer than
  /// the 50 a frame carries; the publisher cuts it.
  final List<UpcomingSong> upcoming;

  /// Whether the player is showing the current track's picture (v1.3).
  final bool video;
}

/// Where the publisher reads the player from.
abstract interface class ConnectStateSource {
  /// Fires whenever anything that might change a frame may have changed. Cheap
  /// and frequent is fine: the publisher coalesces.
  Stream<void> get changes;

  ConnectSnapshot read();
}

/// Remembers the last `seq` this install used.
abstract interface class ConnectSeqStore {
  int? read();
  void write(int seq);
}

class ConnectStatePublisher {
  ConnectStatePublisher({
    required this._source,
    required this._send,
    required this._deviceId,
    required this._seqStore,
    this.debounce = const Duration(milliseconds: 300),
    this.heartbeat = const Duration(seconds: 15),
    this.positionTolerance = const Duration(seconds: 2),
  });

  final ConnectStateSource _source;

  /// Sends a frame; false when no session is up.
  final bool Function(StateFrame frame) _send;
  final String _deviceId;
  final ConnectSeqStore _seqStore;

  final Duration debounce;
  final Duration heartbeat;
  final Duration positionTolerance;

  StreamSubscription<void>? _subscription;
  Timer? _debounceTimer;
  Timer? _heartbeatTimer;

  int? _nextSeq;
  double _lastVolume = 1;

  // What the hub was last told.
  String? _sentSignature;
  int _sentPositionMs = 0;
  bool _sentPlaying = false;
  DateTime? _sentAt;

  bool get isRunning => _subscription != null;

  void start() {
    if (isRunning) return;
    _subscription = _source.changes.listen((_) => _changed());
    _heartbeatTimer = Timer.periodic(heartbeat, (_) {
      if (_source.read().playing) _publish(force: true);
    });
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    // A new session starts from nothing: the hub forgets a device's state when
    // it disconnects, so whatever was "last sent" is no longer known to it.
    _sentSignature = null;
  }

  /// Sends the state now, whatever was sent before — a new session has just
  /// started and the hub holds nothing for this device.
  void sendNow() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _publish(force: true);
  }

  void _changed() {
    if (_debounceTimer?.isActive ?? false) return;
    _debounceTimer = Timer(debounce, () {
      _debounceTimer = null;
      _publish(force: false);
    });
  }

  void _publish({required bool force}) {
    final snapshot = _source.read();
    final volume = _volumeOf(snapshot);
    final state = _stateOf(snapshot, volume, seq: 0);
    final signature = _signature(state);
    final now = clock.now();

    if (!force && !_isWorthSending(signature, state, now)) return;

    final seq = _takeSeq(now);
    if (!_send(StateFrame(state.withSeq(seq)))) return;
    _commitSeq(seq);
    _sentSignature = signature;
    _sentPositionMs = state.positionMs;
    _sentPlaying = state.playing;
    _sentAt = now;
  }

  bool _isWorthSending(String signature, PlayerState state, DateTime now) {
    if (signature != _sentSignature) return true;
    final sentAt = _sentAt;
    if (sentAt == null) return true;
    final expected = _sentPositionMs +
        (_sentPlaying ? now.difference(sentAt).inMilliseconds : 0);
    return (state.positionMs - expected).abs() > positionTolerance.inMilliseconds;
  }

  double _volumeOf(ConnectSnapshot snapshot) {
    final raw = snapshot.volume;
    if (raw != null && raw.isFinite) _lastVolume = raw.clamp(0.0, 1.0);
    return _lastVolume;
  }

  PlayerState _stateOf(
    ConnectSnapshot snapshot,
    double volume, {
    required int seq,
  }) {
    final duration = snapshot.duration ??
        (snapshot.track?.duration == null
            ? null
            : Duration(milliseconds: snapshot.track!.duration!));
    final track = snapshot.track;
    return PlayerState(
      seq: seq,
      track: track == null ? null : trackRefOf(track, deviceId: _deviceId),
      playing: snapshot.playing,
      positionMs: snapshot.position.inMilliseconds < 0
          ? 0
          : snapshot.position.inMilliseconds,
      durationMs: duration != null && duration > Duration.zero
          ? duration.inMilliseconds
          : null,
      volume: volume,
      shuffle: snapshot.shuffle,
      repeat: snapshot.repeat,
      video: snapshot.video,
      queue: [
        for (final entry in snapshot.upcoming.take(PlayerState.maxQueue))
          QueueEntry(
            uid: entry.uid,
            track: trackRefOf(entry.song, deviceId: _deviceId),
          ),
      ],
    );
  }

  /// Everything in a frame except the two fields that change as time passes.
  static String _signature(PlayerState state) => jsonEncode(
        state.toJson()
          ..remove('seq')
          ..remove('positionMs'),
      );

  // -------------------------------------------------------------------------

  int _takeSeq(DateTime now) {
    final persisted = _seqStore.read();
    return _nextSeq ??= () {
      final fromClock = now.millisecondsSinceEpoch ~/ 1000;
      final afterLast = persisted == null ? 0 : persisted + 1;
      return fromClock > afterLast ? fromClock : afterLast;
    }();
  }

  void _commitSeq(int used) {
    _nextSeq = used + 1;
    _seqStore.write(used);
  }
}
