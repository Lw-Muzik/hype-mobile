/// Moving playback between devices (contract §3.9, §3.12).
///
/// There is no transfer frame: the controller moves playback itself —
/// `play {the source's track + queue, at its position}` to the target, then
/// `pause` to the source, then `select` the target. This phone does it in
/// three shapes, all through [transfer]:
///
/// * **phone -> other** (this phone is the source): the play command carries
///   this phone's own track, queue and position; once the target accepts it,
///   local playback pauses and the target is selected.
/// * **other -> phone** ("Play on this phone"): the other device's state is fed
///   to this phone's own `play` handler *as if the hub had sent it* — the same
///   code path a remote `play` takes — and then the old device is paused. The
///   Claim rule makes this phone the active player once audio starts.
/// * **other -> other**: exactly what the web does.
///
/// Items the target cannot play (another device's `local`, `other`) are
/// counted, not hidden: the result says how many stayed behind.
library;

import 'dart:async';

import '../connect_protocol.dart';
import '../connect_state_publisher.dart';
import '../connect_tracks.dart';
import 'connect_remote_session.dart';

class TransferResult {
  const TransferResult.ok({this.dropped = 0}) : ok = true, message = null;

  const TransferResult.failed(this.message) : ok = false, dropped = 0;

  final bool ok;

  /// How many of the queue could not move.
  final int dropped;

  /// A sentence to show when [ok] is false.
  final String? message;
}

class ConnectTransfer {
  ConnectTransfer({
    required this.session,
    required this.selfId,
    required this.localState,
    required this.pauseLocal,
    required this.playLocal,
    required this.select,
    required this.nameOf,
    this.maxItems = 100,
  });

  final ConnectRemoteSession session;
  final String selfId;
  final ConnectStateSource localState;

  /// Pauses this phone's own playback.
  final Future<void> Function() pauseLocal;

  /// Runs [command] through this phone's own command handler, as if the hub
  /// had delivered it, and returns the ack it would have sent.
  final Future<AckFrame> Function(PlayCommand command) playLocal;

  /// Sends `select`; false when no session is up.
  final bool Function(String? deviceId) select;

  final String Function(String deviceId) nameOf;
  final int maxItems;

  /// The device playback should leave when the user picks [targetId] in the
  /// picker: whoever is the active player now.
  String? sourceFor(String targetId) {
    final remote = session.remoteTarget?.id;
    if (remote != null) return remote;
    // No other device is playing: this phone is the source if it has anything.
    return localState.read().track == null ? null : selfId;
  }

  /// Moves whatever plays now to [targetId] (the picker's tap).
  Future<TransferResult> moveTo(String targetId) async {
    final source = sourceFor(targetId);
    if (source == null) {
      // Nothing to carry: just make the target the place music will play.
      return select(targetId)
          ? const TransferResult.ok()
          : const TransferResult.failed('Not connected right now.');
    }
    return transfer(from: source, to: targetId);
  }

  /// Moves playback from [from] to [to].
  Future<TransferResult> transfer({
    required String from,
    required String to,
  }) async {
    if (from == to) return const TransferResult.ok();
    final payload = _payloadOf(from);
    if (payload == null || payload.track == null) {
      // Nothing playing at the source: only the active device changes.
      return select(to)
          ? const TransferResult.ok()
          : const TransferResult.failed('Not connected right now.');
    }

    final refs = [payload.track!, ...payload.queue];
    final toPhone = to == selfId;
    final sendable = [
      for (final ref in refs)
        if (ref is YtTrackRef || (ref is LocalTrackRef && ref.deviceId == to))
          ref,
    ];
    final dropped = refs.length - sendable.length;
    // Track zero decides: a song the target cannot play at the head of the
    // queue would otherwise hand the listener a different song.
    final headSendable =
        payload.track is YtTrackRef ||
        (payload.track is LocalTrackRef &&
            (payload.track as LocalTrackRef).deviceId == to);
    if (!headSendable) {
      if (!payload.playing) {
        // Paused: there is no music to carry, only the choice of player, and
        // refusing would leave the user no way to switch. The song stays where
        // it is; the picker says so.
        if (!select(to)) {
          return const TransferResult.failed('Not connected right now.');
        }
        return TransferResult.ok(dropped: refs.length);
      }
      return TransferResult.failed(
        "'${_titleOf(payload.track!)}' is only on "
        '${from == selfId ? 'this phone' : nameOf(from)}, '
        'so ${toPhone ? 'this phone' : nameOf(to)} cannot play it.',
      );
    }

    final command = PlayCommand(
      items: sendable,
      index: 0,
      positionMs: payload.positionMs,
    );
    final AckFrame ack;
    if (toPhone) {
      ack = await playLocal(command);
    } else {
      ack = await session.cmd(to, command);
    }
    if (!ack.ok) {
      return TransferResult.failed(
        '${toPhone ? 'This phone' : nameOf(to)} could not take over'
        '${ack.error == AckError.offline ? ': it is offline' : ''}.',
      );
    }

    // The new device has the music; stop the old one, then name the new one.
    if (from == selfId) {
      await pauseLocal();
    } else {
      unawaited(session.cmd(from, const PauseCommand()));
    }
    if (!toPhone) select(to);
    return TransferResult.ok(dropped: dropped);
  }

  _Payload? _payloadOf(String from) {
    if (from == selfId) {
      final snapshot = localState.read();
      final song = snapshot.track;
      if (song == null) return null;
      return _Payload(
        track: trackRefOf(song, deviceId: selfId),
        queue: [
          for (final entry in snapshot.upcoming.take(maxItems))
            trackRefOf(entry.song, deviceId: selfId),
        ],
        positionMs: snapshot.position.inMilliseconds,
        playing: snapshot.playing,
      );
    }
    final stamped = session.stateOf(from);
    if (stamped == null) return null;
    final state = stamped.state;
    return _Payload(
      track: state.track,
      queue: [for (final entry in state.queue.take(maxItems)) entry.track],
      positionMs: session.positionOf(from) ?? state.positionMs,
      playing: state.playing,
    );
  }

  static String _titleOf(TrackRef ref) => switch (ref) {
    YtTrackRef(:final title) => title,
    LocalTrackRef(:final title) => title,
    OtherTrackRef(:final title) => title,
  };
}

class _Payload {
  const _Payload({
    required this.track,
    required this.queue,
    required this.positionMs,
    required this.playing,
  });
  final TrackRef? track;
  final List<TrackRef> queue;
  final int positionMs;
  final bool playing;
}
