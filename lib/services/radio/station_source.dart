/// Where a station's next tracks come from.
///
/// # The seam
///
/// A station is two jobs wearing one name. One is bookkeeping: which station is
/// playing, what it has already handed over, how close the queue is to running
/// out, whether the user has switched Autoplay off. That job is identical
/// whether the music is on YouTube, on the phone, or in a Google Drive folder,
/// and it is where every bug this class has ever had actually lived.
///
/// The other job is answering "what goes with this?", and that one is entirely
/// different per source: YouTube has an endpoint, a local library has metadata
/// and arithmetic, a cloud drive has thinner metadata and the same arithmetic.
///
/// [StationSource] is the second job. `RadioQueue` is the first.
///
/// # Why a new source object per station
///
/// A YouTube continuation token belongs to a *query*, not to a seed: sending
/// the previous station's token with the new station's seed returns the next
/// page of the previous station, and that once poisoned every later top-up
/// until the app was restarted.
///
/// Keeping the cursor inside the source object makes that structurally
/// impossible — a new station is a new object, so there is no field for a stale
/// cursor to survive in. Callers must therefore build a fresh source per
/// station and never reuse one.
library;

import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';

/// What a station needs from the thing it is filling.
///
/// Narrower than `AppController` on purpose. `RadioQueue`'s rules — station
/// identity, single-flight, de-duplication, headroom — are the part most worth
/// testing and the part that was untestable for exactly this reason: reaching
/// them meant constructing a controller that loads preferences, opens a
/// database and owns two audio players. Two members is a seam; a god object is
/// not.
abstract class StationSink {
  /// The queue as it stands, in playing order.
  List<SongModel> get songs;

  /// Adds [extra] to the end of the queue without disturbing what is playing.
  Future<void> appendToQueue(List<SongModel> extra);
}

/// One page of a station's answer.
@immutable
class StationBatch {
  /// Playable queue entries, in the order they should be heard.
  final List<SongModel> tracks;

  /// Every key this page used up — including tracks that were selected but
  /// failed to become playable.
  ///
  /// Separate from [tracks] on purpose. A track that will not resolve should
  /// not be offered again on the next fill, or a station with one dead entry
  /// spends every top-up rediscovering it.
  final Set<String> consumed;

  /// Whether this source has more to give for the seed it currently holds.
  ///
  /// False is not "the station is over" — it is "this seed is spent", which is
  /// the signal for `RadioQueue` to walk the seed forward.
  final bool hasMore;

  const StationBatch({
    required this.tracks,
    required this.consumed,
    required this.hasMore,
  });

  static const empty = StationBatch(tracks: [], consumed: {}, hasMore: false);
}

/// One station's supply of related music.
abstract class StationSource {
  /// What the station is currently seeded on. Used for de-duplication and to
  /// recognise when a seed has stopped moving.
  String get seedKey;

  /// For logs and tests. Not shown to the user.
  String get kind;

  /// Up to [limit] tracks related to the current seed, excluding [exclude].
  ///
  /// Implementations must not throw for the ordinary failures — an empty page,
  /// a dead network, a library with nothing in it. Return [StationBatch.empty]
  /// instead; radio is a courtesy and a station that cannot fill should end
  /// quietly rather than raise.
  Future<StationBatch> fetch({
    required Set<String> exclude,
    required int limit,
  });

  /// Moves the seed to [key], a track this station itself offered.
  ///
  /// Returns false when the source cannot or should not move — already there,
  /// or the key means nothing to it. A source that has no notion of a moving
  /// seed may always return false; its station simply ends when its seed is
  /// spent.
  bool advanceSeed(String key);
}
