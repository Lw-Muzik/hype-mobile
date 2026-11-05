/// A station made entirely out of the user's own files.
///
/// No network, no account, no service to ask. The seed's metadata is compared
/// against candidates pulled from the library database and the winners are
/// drawn weighted-random — see `track_similarity.dart` for the arithmetic and
/// why it is weighted rather than ranked.
///
/// This works on a plane, and that is most of the point.
library;

import 'dart:math';

import 'package:on_audio_query/on_audio_query.dart';

import '../../data/library_repository.dart';
import 'station_source.dart';
import 'track_similarity.dart';

class LibraryStation implements StationSource {
  LibraryStation({
    required LibraryRepository repo,
    required SongModel seed,
    Random? random,
  }) : _repo = repo,
       _seed = seed,
       _random = random ?? Random();

  final LibraryRepository _repo;
  final Random _random;

  SongModel _seed;

  /// Tracks the station has reached but whose models it still holds, so
  /// [advanceSeed] can move to one without going back to the database.
  final Map<String, SongModel> _known = {};

  @override
  String get seedKey => keyOf(_seed);

  @override
  String get kind => 'library';

  /// The queue's own id, as a string. Matches what `RadioQueue` records.
  static String keyOf(SongModel song) => song.id.toString();

  @override
  bool advanceSeed(String key) {
    final next = _known[key];
    if (next == null || key == seedKey) return false;
    _seed = next;
    return true;
  }

  @override
  Future<StationBatch> fetch({
    required Set<String> exclude,
    required int limit,
  }) async {
    final candidates = await _repo.stationCandidates(
      artist: _seed.artist,
      genre: _seed.genre,
      album: _seed.album,
    );
    if (candidates.isEmpty) return StationBatch.empty;

    final byKey = {for (final song in candidates) keyOf(song): song};
    final drawn = drawStation(
      seed: _traitsOf(_seed),
      candidates: [for (final song in candidates) _traitsOf(song)],
      exclude: exclude,
      limit: limit,
      random: _random,
    );
    if (drawn.isEmpty) return StationBatch.empty;

    final tracks = [
      for (final traits in drawn)
        if (byKey[traits.key] case final song?) song,
    ];
    for (final song in tracks) {
      _known[keyOf(song)] = song;
    }

    return StationBatch(
      tracks: tracks,
      consumed: {for (final traits in drawn) traits.key},
      // A local library does not run out the way a remote query does: there is
      // always more to draw until the exclude set has swallowed everything, and
      // that shows up as an empty draw rather than as an exhausted cursor.
      hasMore: true,
    );
  }

  /// A library row's metadata, in the shape the scorer wants.
  ///
  /// `date_added` is MediaStore's, which is already in Unix seconds.
  static TrackTraits _traitsOf(SongModel song) {
    final map = song.getMap;
    return TrackTraits(
      key: keyOf(song),
      artist: song.artist,
      album: song.album,
      genre: map['genre'] as String?,
      addedAtSec: (map['date_added'] as num?)?.toInt(),
      playCount: (map['play_count'] as num?)?.toInt() ?? 0,
    );
  }
}
