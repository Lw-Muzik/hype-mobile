/// Turning a controller's commands into what this phone's player does.
///
/// # Accept, acknowledge, then play
///
/// A player acknowledges a command once it has *accepted* it, not once audio
/// starts (contract §3.4): the hub gives up after ten seconds, and resolving a
/// YouTube track can take longer than that on a phone radio. So the executor
/// does the quick part — reading the refs, looking local ones up, deciding
/// what will play — answers, and leaves the slow part running. The state that
/// follows is what tells the controller how it went.
///
/// # Nothing remote touches the screen
///
/// The in-app paths that play YouTube open the player screen and report
/// failures in a snack bar; a phone on the table being driven from a laptop
/// must do neither. Everything here goes through [ConnectPlayer], which has no
/// way to reach a `BuildContext` — so "never navigate" is a property of the
/// types rather than a promise kept by care.
///
/// # What can play here
///
/// A `yt` ref always can, as far as anything short of resolving it can tell. A
/// `local` ref can only if this phone is the device that owns it and the song
/// is still in its library. `other` refs never appear in commands, and are
/// skipped if they do.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../ytmusic/yt_models.dart';
import 'connect_protocol.dart';
import 'connect_tracks.dart';

/// A track this phone has found a way to play.
sealed class Playable {
  const Playable();
}

final class YtPlayable extends Playable {
  const YtPlayable(this.track);
  final YtTrack track;
}

final class LocalPlayable extends Playable {
  const LocalPlayable(this.song);
  final SongModel song;
}

/// How a `play` is carried out — chosen here, executed by the player.
///
/// Each kind is one of the app's existing ways of starting music, so a remote
/// play behaves exactly as the same tap in the app would.
sealed class PlayPlan {
  const PlayPlan();
}

/// Every item is a song on this phone: the whole list becomes the queue and
/// playback starts at [index] — what tapping a song in a library list does.
final class LocalListPlan extends PlayPlan {
  const LocalListPlan(this.songs, this.index, {this.startAt});
  final List<SongModel> songs;
  final int index;
  final Duration? startAt;
}

/// Every item from the start on is YouTube: the first plays as soon as it
/// resolves and the rest are appended behind it. With [radio], the first plays
/// and the app's own radio follows — what tapping a search result does.
final class YtListPlan extends PlayPlan {
  const YtListPlan(this.tracks, {this.radio = false, this.startAt});
  final List<YtTrack> tracks;
  final bool radio;
  final Duration? startAt;
}

/// A mix of both: played the way the app plays a mix — start on the first
/// thing that plays, grow the queue behind it.
final class MixedListPlan extends PlayPlan {
  const MixedListPlan(this.items, {this.startAt});
  final List<Playable> items;
  final Duration? startAt;
}

/// `radio` on a song of this phone's: it plays alone and a station drawn from
/// the library follows — what tapping a library search result does.
final class LocalStationPlan extends PlayPlan {
  const LocalStationPlan(this.seed);
  final SongModel seed;
}

/// Chooses how to play [resolved] — the command's items, each resolved to a
/// [Playable] or null — starting at [index].
///
/// Returns null when nothing from [index] on can play, which the executor
/// reports as `nothing_playable`. Items *before* [index] never start playback:
/// the user asked for the one at [index], and skipping backwards to reach
/// something playable would play a song they did not pick.
///
/// [position] applies only when the item at [index] is itself playable. When it
/// has been skipped, the position belonged to a different song.
@visibleForTesting
PlayPlan? planPlay(
  List<Playable?> resolved,
  int index, {
  Duration? position,
  bool radio = false,
}) {
  if (index < 0 || index >= resolved.length) return null;
  final from = [for (final item in resolved.skip(index)) ?item];
  if (from.isEmpty) return null;
  final startAt = resolved[index] == null ? null : position;

  if (radio) {
    return switch (from.first) {
      LocalPlayable(:final song) => LocalStationPlan(song),
      YtPlayable() => YtListPlan(
        [
          for (final item in from)
            if (item is YtPlayable) item.track,
        ],
        radio: true,
        startAt: startAt,
      ),
    };
  }

  if (from.every((item) => item is YtPlayable)) {
    return YtListPlan([
      for (final item in from) (item as YtPlayable).track,
    ], startAt: startAt);
  }

  final playable = [for (final item in resolved) ?item];
  if (playable.every((item) => item is LocalPlayable)) {
    final songs = [for (final item in playable) (item as LocalPlayable).song];
    // Where the first playable item at or after [index] sits once the
    // unplayable ones are gone.
    final start = playable.indexOf(from.first);
    return LocalListPlan(songs, start, startAt: startAt);
  }

  return MixedListPlan(from, startAt: startAt);
}

/// This phone's songs, as the executor and the `library` rpc read them.
abstract interface class ConnectLibrary {
  /// The songs among [ids] that are still on this phone, by id.
  Future<Map<int, SongModel>> songsByIds(Iterable<int> ids);

  /// One page of the library, optionally filtered, and how many songs match.
  Future<({int total, List<SongModel> songs})> page({
    required int offset,
    required int limit,
    String? query,
  });
}

/// The player, as remote commands may touch it.
///
/// Every method returns once the action is under way — never a future that
/// lives as long as playback does (`just_audio`'s `play()` is one of those).
abstract interface class ConnectPlayer {
  /// Whether this phone is a player right now. False in equalizer-only mode,
  /// where the app has no queue and no screen to show one on.
  bool get available;

  /// Whether there is a queue to pause, skip through or append to.
  bool get hasQueue;

  Future<void> play(PlayPlan plan);

  /// Adds [items] after the playing track ([EnqueueMode.next]) or at the end.
  Future<void> enqueue(List<Playable> items, EnqueueMode mode);

  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> next();
  Future<void> prev();
  Future<void> seek(Duration position);

  /// Plays the queue entry whose uid is [uid]. False when none has it.
  Future<bool> jump(String uid);

  /// 0..1.
  Future<void> setVolume(double value);
  Future<void> setShuffle(bool on);
  Future<void> setRepeat(ConnectRepeat mode);
}

class ConnectExecutor {
  ConnectExecutor({
    required this._player,
    required this._library,
    required this._deviceId,
    this.acceptWithin = const Duration(seconds: 3),
  });

  final ConnectPlayer _player;
  final ConnectLibrary _library;
  final String _deviceId;

  /// How long an action may take before it is acknowledged as accepted and
  /// left to finish on its own — comfortably inside the hub's ten seconds.
  final Duration acceptWithin;

  /// Commands are accepted one at a time, in the order they arrived.
  Future<void> _accepting = Future.value();

  /// And carried out one at a time, in the same order — a separate chain,
  /// because carrying out a `play` can take far longer than accepting it.
  ///
  /// Acceptance alone is not enough. A `play` is acknowledged before its first
  /// track has resolved, so a `pause` right behind it would otherwise reach the
  /// player first, find nothing to pause, and the music would then start
  /// regardless. Every action waits for the actions before it.
  Future<void> _running = Future.value();

  Future<AckFrame> execute(CmdFrame frame) {
    final done = Completer<AckFrame>();
    _accepting = _accepting.then((_) async {
      AckFrame ack;
      try {
        ack = await _execute(frame.id, frame.cmd);
      } catch (e, st) {
        debugPrint('Hype Connect: ${frame.cmd.type} failed: $e\n$st');
        ack = AckFrame.failed(frame.id, AckError.failed);
      }
      done.complete(ack);
    });
    return done.future;
  }

  Future<AckFrame> _execute(String id, Command cmd) async {
    if (cmd is UnknownCommand) return AckFrame.failed(id, AckError.unsupported);
    if (!_player.available) return AckFrame.failed(id, AckError.unsupported);

    switch (cmd) {
      case PlayCommand():
        if (cmd.items.isEmpty) {
          return AckFrame.failed(id, AckError.nothingPlayable);
        }
        if (cmd.index < 0 || cmd.index >= cmd.items.length) {
          return AckFrame.failed(id, AckError.failed);
        }
        final plan = planPlay(
          await resolve(cmd.items),
          cmd.index,
          position: switch (cmd.positionMs) {
            null => null,
            final ms => Duration(milliseconds: ms < 0 ? 0 : ms),
          },
          radio: cmd.radio ?? false,
        );
        if (plan == null) return AckFrame.failed(id, AckError.nothingPlayable);
        _schedule(() => _player.play(plan)).ignore();
        return AckFrame.ok(id);

      case EnqueueCommand():
        final playable = [for (final item in await resolve(cmd.items)) ?item];
        if (playable.isEmpty) {
          return AckFrame.failed(id, AckError.nothingPlayable);
        }
        // Queueing onto nothing is asking for music: it plays.
        if (!_player.hasQueue) {
          final plan = planPlay(playable, 0)!;
          _schedule(() => _player.play(plan)).ignore();
        } else {
          _schedule(() => _player.enqueue(playable, cmd.mode)).ignore();
        }
        return AckFrame.ok(id);

      case ResumeCommand():
        if (!_player.hasQueue) {
          return AckFrame.failed(id, AckError.nothingPlayable);
        }
        return _accept(id, _player.resume);
      case PauseCommand():
        return _accept(id, _player.pause);
      case StopCommand():
        return _accept(id, _player.stop);
      case NextCommand():
        return _accept(id, _player.next);
      case PrevCommand():
        return _accept(id, _player.prev);
      case SeekCommand():
        final ms = cmd.positionMs < 0 ? 0 : cmd.positionMs;
        return _accept(id, () => _player.seek(Duration(milliseconds: ms)));
      case JumpCommand():
        // An unknown uid is answered rather than ignored: the controller's view
        // of the queue is stale, and saying so lets it refresh.
        return _accept(id, () async {
          if (!await _player.jump(cmd.uid)) throw _UnknownUid(cmd.uid);
        });
      case VolumeCommand():
        if (!cmd.value.isFinite) return AckFrame.failed(id, AckError.failed);
        final value = cmd.value.clamp(0.0, 1.0);
        return _accept(id, () => _player.setVolume(value));
      case ShuffleCommand():
        return _accept(id, () => _player.setShuffle(cmd.on));
      case RepeatCommand():
        return _accept(id, () => _player.setRepeat(cmd.mode));
      case UnknownCommand():
        return AckFrame.failed(id, AckError.unsupported);
    }
  }

  /// Each ref as something this phone can play, or null where it cannot.
  ///
  /// Local refs are looked up together, in one query, and only those owned by
  /// this phone are looked up at all: another device's song id means nothing
  /// here even when the same number happens to exist.
  @visibleForTesting
  Future<List<Playable?>> resolve(List<TrackRef> refs) async {
    final wanted = <int>{
      for (final ref in refs)
        if (ref is LocalTrackRef && ref.deviceId == _deviceId)
          ?int.tryParse(ref.id),
    };
    final songs = wanted.isEmpty
        ? const <int, SongModel>{}
        : await _library.songsByIds(wanted);
    return [
      for (final ref in refs)
        switch (ref) {
          YtTrackRef() => YtPlayable(ytTrackOf(ref)),
          LocalTrackRef(:final deviceId, :final id) =>
            deviceId == _deviceId
                ? switch (int.tryParse(id)) {
                    final songId? when songs[songId] != null => LocalPlayable(
                      songs[songId]!,
                    ),
                    _ => null,
                  }
                : null,
          OtherTrackRef() => null,
        },
    ];
  }

  /// Queues [action] behind every earlier one and acknowledges how it went —
  /// or, if it has not finished within [acceptWithin] (it is waiting behind a
  /// slow `play`, or is slow itself), that it was accepted.
  Future<AckFrame> _accept(String id, Future<void> Function() action) async {
    final running = _schedule(action);
    try {
      await running.timeout(acceptWithin);
      return AckFrame.ok(id);
    } on TimeoutException {
      return AckFrame.ok(id);
    } on _UnknownUid {
      return AckFrame.failed(id, AckError.failed);
    } catch (e) {
      debugPrint('Hype Connect: command failed: $e');
      return AckFrame.failed(id, AckError.failed);
    }
  }

  /// Runs [action] once every earlier action has finished, failed or not.
  Future<void> _schedule(Future<void> Function() action) {
    final run = _running.then((_) => action());
    _running = run.then<void>(
      (_) {},
      onError: (Object e, StackTrace st) {
        if (e is! _UnknownUid) {
          debugPrint('Hype Connect: action failed: $e\n$st');
        }
      },
    );
    return run;
  }
}

class _UnknownUid implements Exception {
  const _UnknownUid(this.uid);
  final String uid;
}
