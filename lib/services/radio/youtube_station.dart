/// A station supplied by YouTube's related-tracks endpoint.
///
/// This is the fetching half of the old `YtRadioQueue`, lifted intact. The
/// bookkeeping half now lives in `RadioQueue` and is shared with the local and
/// cloud stations.
///
/// The one real change is where the continuation token lives. It is a field on
/// this object rather than on the singleton, which means a new station is a new
/// object and there is nowhere for the previous station's cursor to survive.
/// That used to be a guard; now it is the shape of the thing.
library;

import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../../services/video/video_registry.dart';
import '../ytmusic/yt_models.dart';
import '../ytmusic/yt_playback.dart';
import '../ytmusic/yt_repository.dart';
import 'station_source.dart';

class YouTubeStation implements StationSource {
  YouTubeStation({required String seed}) : _seed = seed;

  String _seed;

  /// A cursor into one server-side result set.
  ///
  /// Belongs to the *query* that produced it, not to the seed — which is why
  /// pairing it with a different seed silently continues the previous station,
  /// and why it is cleared whenever the seed moves.
  String? _token;

  /// How many pages to walk before accepting that a seed has nothing more.
  ///
  /// Consecutive pages overlap, so a page can be entirely tracks already
  /// queued. That is a reason to turn the page, not to stop — but it has to be
  /// bounded, or a seed that genuinely ended would be asked for ever.
  static const _maxPagesPerFetch = 3;

  /// Videos are resolved a few at a time and each writes a manifest to disk, so
  /// a station showing pictures runs a shorter way ahead than one playing
  /// songs.
  static const _videoModeLimit = 6;

  @override
  String get seedKey => _seed;

  @override
  String get kind => 'youtube';

  @override
  bool advanceSeed(String key) {
    if (key == _seed) return false;
    _seed = key;
    // The cursor belonged to the old seed's query and means nothing to this
    // one. Carrying it over is the bug this class was built to make impossible.
    _token = null;
    return true;
  }

  @override
  Future<StationBatch> fetch({
    required Set<String> exclude,
    required int limit,
  }) async {
    final watching = VideoRegistry.instance.videoMode;
    final take = watching ? _videoModeLimit : limit;

    // Pages overlap, so one can be entirely tracks already queued. That page is
    // not the end of the seed — it is a page to turn.
    for (var page = 0; page < _maxPagesPerFetch; page++) {
      final token = _token;
      final batch = token == null
          ? await YtMusicRepository.instance.radio(_seed)
          : await YtMusicRepository.instance.radioContinue(_seed, token);

      // A radio that stops offering a token has not necessarily ended; the seed
      // still produces a fresh panel, so forgetting the token re-seeds next
      // time rather than ending the music.
      _token = batch.continuation;

      if (batch.tracks.isEmpty) return StationBatch.empty;

      final fresh = _freshTracks(batch.tracks, exclude: exclude, limit: take);

      // Every track on this page is already in the queue. Ask for the next one
      // rather than reporting a seed that has run dry.
      if (fresh.isEmpty) {
        if (_token == null) return StationBatch.empty;
        continue;
      }

      // A station seeded from a video keeps showing pictures. Someone who
      // opened the Videos tab and let it run should not find themselves
      // listening to a radio of songs three tracks later.
      final models = watching
          ? await YtPlayback.resolveVideoModels(fresh)
          : await _resolveAudioModels(fresh);

      return StationBatch(
        tracks: models,
        // Every track selected, not merely every track that resolved. One that
        // will not play should not be rediscovered on the next fill.
        consumed: {for (final track in fresh) track.videoId},
        hasMore: _token != null,
      );
    }
    return StationBatch.empty;
  }

  /// The tracks in [page] not already offered, at most [limit] of them.
  ///
  /// Tracks left behind by the limit are untouched, so a page is used up over
  /// several fills rather than mostly discarded.
  List<YtTrack> _freshTracks(
    List<YtTrack> page, {
    required Set<String> exclude,
    required int limit,
  }) {
    final fresh = <YtTrack>[];
    final taken = <String>{};
    for (final track in page) {
      if (fresh.length >= limit) break;
      if (exclude.contains(track.videoId)) continue;
      if (!taken.add(track.videoId)) continue;
      fresh.add(track);
    }
    return fresh;
  }

  @visibleForTesting
  List<YtTrack> freshTracksForTest(
    List<YtTrack> page, {
    required Set<String> exclude,
    required int limit,
  }) => _freshTracks(page, exclude: exclude, limit: limit);

  /// Resolves [tracks] as audio and returns the entries that worked.
  ///
  /// Whatever fails to resolve is dropped silently: the queue simply grows by
  /// less than it might have, which is the right failure for a courtesy.
  Future<List<SongModel>> _resolveAudioModels(List<YtTrack> tracks) async {
    final targets = await YtMusicRepository.instance.audioTargets([
      for (final track in tracks) track.videoId,
    ]);
    await Future.wait([
      for (final track in tracks) YtPlayback.cacheArtwork(track),
    ]);
    return [
      for (final track in tracks)
        if (targets[track.videoId] case final target?)
          YtPlayback.songModelOf(track, target),
    ];
  }
}
