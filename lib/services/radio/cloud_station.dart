/// A station drawn from a connected drive.
///
/// The same arithmetic as the local library, over thinner metadata: a cloud
/// file has a title, an artist and sometimes an album, but no genre column and
/// no play count. The scorer copes — a missing field simply never matches — so
/// a drive station leans harder on artist and album than a local one does.
///
/// Unlike the library, a cloud track is not playable until it has a stream URL,
/// and for Dropbox that is a request per file. Resolution is therefore part of
/// the fetch, concurrent, and anything that fails is dropped rather than
/// retried — the queue grows by less, which is the right failure for a
/// courtesy.
library;

import 'dart:math';

import 'package:on_audio_query/on_audio_query.dart';

import '../../models/cloud_file.dart';
import 'station_source.dart';
import 'track_similarity.dart';

/// Turns a file into something the player can open, or null when it cannot.
typedef CloudStreamResolver = Future<String?> Function(CloudFile file);

class CloudStation implements StationSource {
  CloudStation({
    required List<CloudFile> files,
    required CloudFile seed,
    required CloudStreamResolver resolve,
    Random? random,
  }) : _files = files,
       _seed = seed,
       _resolve = resolve,
       _random = random ?? Random();

  final List<CloudFile> _files;
  final CloudStreamResolver _resolve;
  final Random _random;

  CloudFile _seed;

  @override
  String get seedKey => _seed.fileId;

  @override
  String get kind => 'cloud';

  @override
  bool advanceSeed(String key) {
    if (key == _seed.fileId) return false;
    for (final file in _files) {
      if (file.fileId == key) {
        _seed = file;
        return true;
      }
    }
    return false;
  }

  @override
  Future<StationBatch> fetch({
    required Set<String> exclude,
    required int limit,
  }) async {
    if (_files.isEmpty) return StationBatch.empty;

    final byKey = {for (final file in _files) file.fileId: file};
    final drawn = drawStation(
      seed: _traitsOf(_seed),
      candidates: [for (final file in _files) _traitsOf(file)],
      exclude: exclude,
      limit: limit,
      random: _random,
    );
    if (drawn.isEmpty) return StationBatch.empty;

    final picked = [
      for (final traits in drawn)
        if (byKey[traits.key] case final file?) file,
    ];

    // Concurrent because Dropbox needs a request per file and doing them in
    // turn would make a top-up take as long as the tracks it is adding.
    final urls = await Future.wait([for (final file in picked) _safely(file)]);

    final tracks = <SongModel>[];
    for (var i = 0; i < picked.length; i++) {
      final url = urls[i];
      if (url != null) tracks.add(picked[i].toSongModel(url));
    }

    return StationBatch(
      tracks: tracks,
      // Every file drawn, not merely every one that resolved — a file whose
      // link cannot be minted should not be rediscovered on the next fill.
      consumed: {for (final traits in drawn) traits.key},
      hasMore: true,
    );
  }

  Future<String?> _safely(CloudFile file) async {
    try {
      return await _resolve(file);
    } catch (_) {
      return null;
    }
  }

  /// A drive file's metadata, in the shape the scorer wants.
  ///
  /// Read from the [CloudFile] rather than from `toSongModel`, whose `album`
  /// field carries the thumbnail URL when there is one — an existing convention
  /// that would otherwise make every file with artwork look like it shared an
  /// album with every other.
  static TrackTraits _traitsOf(CloudFile file) => TrackTraits(
    key: file.fileId,
    artist: file.trackArtist,
    album: file.albumName,
    // Drives have no genre column and no play count. A missing field never
    // matches, so these terms simply drop out of the scoring.
    genre: null,
    addedAtSec: file.modifiedDate == null
        ? null
        : file.modifiedDate!.millisecondsSinceEpoch ~/ 1000,
  );
}
