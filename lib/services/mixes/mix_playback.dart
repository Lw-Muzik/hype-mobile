/// Playing a mix whose tracks live in three different places.
///
/// # Start on the first thing that can play, then grow
///
/// A mix may open with a YouTube track that needs resolving and a drive track
/// that needs a link minted. Resolving all twenty-five before the first note
/// would make tapping a card feel broken; resolving them in order and waiting
/// would stall on the first failure.
///
/// So: walk the list until something plays, play it, and append the rest behind
/// it as they resolve. The same shape the YouTube playlist path already uses —
/// the queue grows while the user is listening, rather than before they are.
///
/// Anything that will not resolve is dropped silently. A mix that is two tracks
/// shorter is a better outcome than an error over music the user did not ask
/// for by name.
library;

import 'dart:async';

import 'package:on_audio_query/on_audio_query.dart';

import '../../controllers/app_controller.dart';
import '../../models/cloud_file.dart';
import '../connect/remote/connect_play_router.dart';
import '../ytmusic/yt_playback.dart';
import '../ytmusic/yt_repository.dart';
import 'daily_mixes.dart';
import 'mix_track_ref.dart';

/// Anything that is a list of references worth playing in order.
///
/// A generated mix is one; a saved playlist is another. Playback does not need
/// to know which, and giving it the concrete mix type would have forced the
/// playlist page to impersonate one.
abstract class ResolvedMixSource {
  List<MixTrackRef> get tracks;
}

/// Mints a playable link for a drive file, or null when it cannot.
typedef CloudLinkResolver = Future<String?> Function(CloudFile file);

class MixPlayback {
  const MixPlayback._();

  /// How many references to resolve at once when filling in behind the first
  /// track. Matches the concurrency the YouTube paths already use.
  static const _batch = 4;

  /// Plays [mix], starting as soon as anything in it can be played.
  ///
  /// Returns once the first track is loaded; the rest arrive behind it. The
  /// load is awaited *after* the queue fill has been started, so a caller that
  /// orders a later action behind this one (Hype Connect does) cannot have it
  /// reach the player before the track does. The in-app callers navigate before
  /// they await, so waiting here costs them nothing.
  ///
  /// [startAt] starts the first track part-way in. It is the position of
  /// `mix.tracks.first`, so it applies only if that track is the one that
  /// plays — when it will not resolve and a later one plays instead, the
  /// position would belong to a different song.
  static Future<void> play(
    AppController controller,
    ResolvedMixSource mix, {
    required CloudLinkResolver resolveCloud,
    Duration? startAt,
  }) async {
    if (mix.tracks.isEmpty) return;
    // Another device is the player: it plays the mix (Hype Connect).
    final routed = ConnectPlayRouter.mix(
      mix.tracks,
      here: () =>
          play(controller, mix, resolveCloud: resolveCloud, startAt: startAt),
    );
    if (routed != null) return routed;

    for (var i = 0; i < mix.tracks.length; i++) {
      final song = await _resolve(mix.tracks[i], resolveCloud);
      if (song == null) continue;

      // A mix is a running order — it was built as one — so it queues rather
      // than seeding a station.
      final load = controller.playSongFromList(
        [song],
        0,
        initialPosition: i == 0 ? startAt : null,
      );
      unawaited(
        _fillBehind(
          controller,
          mix.tracks.sublist(i + 1),
          resolveCloud,
          generation: controller.queueGeneration,
        ),
      );
      await load;
      return;
    }
  }

  /// Resolves the remainder a few at a time and appends what works.
  static Future<void> _fillBehind(
    AppController controller,
    List<MixTrackRef> rest,
    CloudLinkResolver resolveCloud, {
    required int generation,
  }) async {
    for (var i = 0; i < rest.length; i += _batch) {
      // The user may have started something else; appending to a queue they
      // have left would graft this mix onto it.
      if (controller.queueGeneration != generation) return;
      final slice = rest.skip(i).take(_batch).toList();
      final resolved = await Future.wait([
        for (final ref in slice) _resolve(ref, resolveCloud),
      ]);
      final songs = [
        for (final song in resolved)
          if (song != null) song,
      ];
      if (songs.isEmpty || controller.queueGeneration != generation) continue;
      await controller.appendToQueue(songs);
    }
  }

  /// One reference, made playable, or null.
  static Future<SongModel?> _resolve(
    MixTrackRef ref,
    CloudLinkResolver resolveCloud,
  ) async {
    try {
      switch (ref.source) {
        case MixSource.local:
          return ref.song;

        case MixSource.cloud:
          final file = ref.file;
          if (file == null) return null;
          final url = await resolveCloud(file);
          return url == null ? null : file.toSongModel(url);

        case MixSource.youtube:
          final track = ref.track;
          if (track == null) return null;

          if (ref.isVideo) {
            // Goes through the existing video path, which writes the DASH
            // manifest and registers it — a video's `data` is an identity, and
            // what the player opens lives in the registry.
            final models = await YtPlayback.resolveVideoModels([track]);
            return models.isEmpty ? null : models.first;
          }

          final targets = await YtMusicRepository.instance.audioTargets([
            track.videoId,
          ]);
          final target = targets[track.videoId];
          if (target == null) return null;
          // The cover has to be on disk before the track reaches the player,
          // or the artwork widget memoises a future that resolved to null.
          await YtPlayback.cacheArtwork(track);
          return YtPlayback.songModelOf(track, target);
      }
    } catch (_) {
      return null;
    }
  }
}
