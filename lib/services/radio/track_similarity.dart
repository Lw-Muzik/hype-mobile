/// How a station decides what belongs next to a track it already has.
///
/// # Why this is arithmetic and not a service
///
/// YouTube answers "what goes with this?" with a network call. A file on the
/// user's disk has nobody to ask. What it does have is metadata — artist,
/// genre, album, when it was added, how often it has been played — and that is
/// enough to build a station that is recognisably *about* the seed rather than
/// a shuffle wearing its name.
///
/// The whole thing is plain values in and plain values out: no database, no
/// network, no singletons. That is deliberate. A station's taste is the part
/// most worth testing and the part least worth mocking a database for.
library;

import 'dart:math';

import 'package:flutter/foundation.dart';

/// The facts a station needs about one track.
///
/// Deliberately not a `SongModel`. This layer is shared by the local library
/// (which has genre) and cloud drives (which do not), and neither should have
/// to pretend to be the other's row shape.
@immutable
class TrackTraits {
  /// How this track is identified for de-duplication. Stable within a source.
  final String key;

  final String? artist;
  final String? album;
  final String? genre;

  /// Unix seconds the track was added to the library, when known.
  final int? addedAtSec;

  final int playCount;

  const TrackTraits({
    required this.key,
    this.artist,
    this.album,
    this.genre,
    this.addedAtSec,
    this.playCount = 0,
  });
}

/// Weights, named so the balance between them can be read rather than inferred.
///
/// Artist dominates because it is the strongest thing a personal library knows:
/// two tracks by the same artist are related whatever else disagrees. Genre is
/// next but is trusted less — tag quality in a scanned library is uneven, and
/// "Rock" spans more ground than any one artist does. Album is worth less than
/// genre on purpose: a station that walks through one album is a queue, not a
/// station.
class SimilarityWeights {
  const SimilarityWeights._();

  static const sameArtist = 4.0;
  static const sameGenre = 2.5;
  static const sameAlbum = 1.5;

  /// For tracks added around the same time as the seed.
  ///
  /// There is no release-year column, and this is the better signal anyway:
  /// music that arrived together usually arrived for a reason — one rip, one
  /// download session, one phase.
  static const nearbyAddition = 1.0;
  static const addedWithin = Duration(days: 30);

  /// Most a well-played track can earn from its play count alone.
  static const familiarity = 0.5;

  /// Plays at which [familiarity] is fully earned. Beyond this, more plays say
  /// nothing new — the difference between forty plays and four hundred is not
  /// four hundred divided by forty.
  static const familiarityCeiling = 10;

  /// Every candidate keeps a little weight even when it matches nothing.
  ///
  /// Without it a library whose tags are sparse would produce a station of one
  /// artist and then stop. With it, unrelated music is reachable but rare —
  /// which is also what keeps a station from being the same twenty-five tracks
  /// every time.
  static const floor = 0.1;
}

/// How strongly [candidate] belongs on a station seeded by [seed].
///
/// Zero means "nothing in common", never "exclude" — exclusion is the caller's
/// job and is done by key, which is a stronger statement than a low score.
double similarity(TrackTraits seed, TrackTraits candidate) {
  var score = 0.0;

  if (_matches(seed.artist, candidate.artist)) {
    score += SimilarityWeights.sameArtist;
  }
  if (_matches(seed.genre, candidate.genre)) {
    score += SimilarityWeights.sameGenre;
  }
  if (_matches(seed.album, candidate.album)) {
    score += SimilarityWeights.sameAlbum;
  }

  final seedAdded = seed.addedAtSec;
  final candidateAdded = candidate.addedAtSec;
  if (seedAdded != null && candidateAdded != null) {
    final apart = (seedAdded - candidateAdded).abs();
    if (apart <= SimilarityWeights.addedWithin.inSeconds) {
      score += SimilarityWeights.nearbyAddition;
    }
  }

  if (candidate.playCount > 0) {
    final capped = min(
      candidate.playCount,
      SimilarityWeights.familiarityCeiling,
    );
    score +=
        SimilarityWeights.familiarity *
        (capped / SimilarityWeights.familiarityCeiling);
  }

  return score;
}

/// Case- and whitespace-insensitive, and an unknown value matches nothing.
///
/// "Unknown Artist" appearing on nine hundred untagged files would otherwise be
/// the strongest signal in the library, and every station would be a station of
/// everything that was never tagged.
bool _matches(String? a, String? b) {
  if (a == null || b == null) return false;
  final left = a.trim().toLowerCase();
  final right = b.trim().toLowerCase();
  if (left.isEmpty || right.isEmpty) return false;
  if (_unknown.contains(left) || _unknown.contains(right)) return false;
  return left == right;
}

const _unknown = {'unknown', 'unknown artist', 'unknown album', '<unknown>'};

/// Draws up to [limit] tracks for a station seeded by [seed].
///
/// Weighted-random rather than top-scoring. Taking the best N is what makes a
/// "station" that is the same list every time it is started, which is the
/// complaint this whole feature exists to answer; weighting keeps it *about*
/// the seed while leaving it free to be different tomorrow.
///
/// [exclude] holds keys the station has already handed over. Anything in it is
/// dropped outright — a stronger statement than a score penalty, and the same
/// rule the YouTube station applies to its own offered set.
///
/// [random] is injected so a test can pin the draw. Callers pass `Random()`.
List<TrackTraits> drawStation({
  required TrackTraits seed,
  required List<TrackTraits> candidates,
  required Set<String> exclude,
  required int limit,
  required Random random,
}) {
  if (limit <= 0) return const [];

  final pool = <TrackTraits>[];
  final weights = <double>[];
  for (final candidate in candidates) {
    if (candidate.key == seed.key) continue;
    if (exclude.contains(candidate.key)) continue;
    pool.add(candidate);
    weights.add(similarity(seed, candidate) + SimilarityWeights.floor);
  }

  final drawn = <TrackTraits>[];
  var total = weights.fold<double>(0, (sum, w) => sum + w);

  while (drawn.length < limit && pool.isNotEmpty) {
    var target = random.nextDouble() * total;
    var index = pool.length - 1;
    for (var i = 0; i < pool.length; i++) {
      target -= weights[i];
      if (target <= 0) {
        index = i;
        break;
      }
    }
    drawn.add(pool.removeAt(index));
    // Recomputed from the removed weight rather than re-summing the pool: a
    // 40,000-track library would otherwise re-add forty thousand doubles per
    // track drawn.
    total -= weights.removeAt(index);
    // Floating-point drift over hundreds of draws can leave `total` slightly
    // wrong; re-summing when it goes non-positive keeps selection honest
    // without paying for it every iteration.
    if (total <= 0) {
      total = weights.fold<double>(0, (sum, w) => sum + w);
      if (total <= 0) break;
    }
  }

  return drawn;
}
