/// Mixes built for one person, out of the music they already own.
///
/// # What actually makes a mix feel personal
///
/// Not the recommendations — a phone has nobody to ask. Three things:
///
/// * **Clustering.** A library is not one taste, it is several. Building one
///   list out of all of them produces something that is nobody's mix. So the
///   library is split into the groups it naturally falls into and each gets its
///   own, and a group too small or too vague to be a taste gets **no mix at
///   all** rather than a thin one.
/// * **Rediscovery.** A mix of the twenty tracks someone plays most is a mix
///   they could have made themselves. Roughly two fifths of each one is music
///   they own and have barely heard.
/// * **Time.** The same mix every day is the complaint this feature exists to
///   answer. The draw is seeded with the date, *the part of the day* and a
///   per-session `variation`, so a mix is stable while you are looking at it,
///   different the next time the app is opened, this evening, and tomorrow —
///   and once there is listening history, weighted towards what this person
///   actually reaches for at this hour.
///
/// Everything here is plain values in and plain values out: no database, no
/// clock, no random source of its own. `now` and the candidate list are
/// arguments, which is what makes "the same day gives the same mix" a testable
/// claim rather than a hope.
library;

import 'dart:math';

import 'package:flutter/foundation.dart';

/// The parts of a day, as someone listening would describe them.
enum Daypart {
  earlyMorning('early morning', 5, 8),
  morning('morning', 8, 12),
  afternoon('afternoon', 12, 17),
  evening('evening', 17, 21),
  lateNight('late night', 21, 5);

  const Daypart(this.label, this.startHour, this.endHour);

  final String label;
  final int startHour;
  final int endHour;

  static Daypart of(DateTime time) {
    final hour = time.hour;
    for (final part in values) {
      if (part == lateNight) continue;
      if (hour >= part.startHour && hour < part.endHour) return part;
    }
    return lateNight;
  }

  /// Hours this daypart covers, for matching against listening history.
  Set<int> get hours {
    if (this == lateNight) {
      return {for (var h = 21; h < 24; h++) h, for (var h = 0; h < 5; h++) h};
    }
    return {for (var h = startHour; h < endHour; h++) h};
  }
}

/// Where a candidate came from.
enum MixSource { local, cloud, youtube }

/// One track, as the mix engine needs to see it.
@immutable
class MixCandidate {
  const MixCandidate({
    required this.key,
    this.source = MixSource.local,
    this.artist,
    this.genre,
    this.addedAtSec,
    this.playCount = 0,
    this.plays = 0,
    this.skips = 0,
    this.hours = const {},
    this.history = false,
  });

  final String key;
  final MixSource source;

  /// A streamed song the user has played themselves. It is part of their
  /// listening, so it counts as theirs — it can found a taste and fills the
  /// "own music" share of a mix — unlike streamed tracks fetched to add variety.
  final bool history;

  /// Whether this is the user's own music: on the phone, or played by them.
  bool get isOwn => source == MixSource.local || history;
  final String? artist;
  final String? genre;
  final int? addedAtSec;

  /// The library's own counter, which exists even with no event history.
  final int playCount;

  /// Plays and early abandonments drawn from the event log.
  final int plays;
  final int skips;

  /// Hours of the day this track has been played in.
  final Set<int> hours;

  /// Whether this has earned a place on its own record.
  ///
  /// Needs more than one play: skipping something once is not a verdict.
  bool get isProven {
    if (plays >= 2) return skips / plays < 0.5;
    // No event history yet — fall back to the counter a v1 install already had.
    return plays == 0 && playCount >= 2;
  }

  /// Whether this is something the user owns and has barely heard.
  bool get isNovel => plays == 0 && playCount == 0;
}

/// A finished mix.
@immutable
class DailyMix {
  const DailyMix({
    required this.name,
    required this.descriptor,
    required this.daypart,
    required this.trackKeys,
  });

  /// What the card says: "afrobeat dusk", "late night guitar".
  final String name;

  /// The cluster this was built from — a genre, or an artist when the library
  /// has no usable genres.
  final String descriptor;

  final Daypart daypart;
  final List<String> trackKeys;

  int get length => trackKeys.length;
}

/// Tuning, named so the balance can be read rather than inferred.
class MixRules {
  const MixRules._();

  /// Below this a purely local group is not a taste, it is a handful of files.
  /// Emitting a mix for it produces a card that runs out in four minutes.
  static const minClusterSize = 8;

  /// The same threshold when a drive or YouTube can fill the mix out.
  ///
  /// The eight above exists to stop a mix running out, not because seven tracks
  /// is not a taste. When there is somewhere to draw the rest from, three
  /// tracks is enough to *mean* something — and this is what turns a library of
  /// many small artists from three categories into a dozen.
  static const minSeedSize = 3;

  /// A mix of one artist is a discography, not a mix.
  static const minDistinctArtists = 2;

  /// How much two clusters may share before the second is a near-duplicate.
  ///
  /// Genre and artist groupings overlap: everything by one artist is usually
  /// also all of one genre. Offering both is offering the same mix twice with
  /// different names.
  static const maxClusterOverlap = 0.6;

  static const tracksPerMix = 25;
  static const maxMixes = 8;

  /// Share of each mix drawn from music with a listening record. The rest is
  /// rediscovery — see the note at the top of this file.
  static const provenShare = 0.6;

  /// Extra weight for a track usually played at this time of day.
  static const hourBonus = 2.0;

  /// Every candidate keeps some weight, so a mix is never the same list twice.
  static const floor = 0.5;

  /// Most of a mix that may come from somewhere other than the user's own files.
  ///
  /// A drive and YouTube are what stop a small library producing the same forty
  /// tracks for ever. But a mix that is mostly streamed is not *theirs* any
  /// more — it is a recommendation feed wearing their library's name. Local
  /// music keeps the majority, always.
  static const maxRemoteShare = 0.5;
}

/// Builds the mixes for [now], newest-taste first.
///
/// Deterministic: the same library, the same day and the same daypart give the
/// same mixes, which is what lets a card be looked at twice without changing
/// underneath the person looking.
List<DailyMix> buildDailyMixes({
  required List<MixCandidate> library,
  required DateTime now,
  int maxMixes = MixRules.maxMixes,
  int tracksPerMix = MixRules.tracksPerMix,

  /// Whether a drive or YouTube can fill a mix out. Lowers how much local music
  /// a taste needs before it is worth offering — see [MixRules.minSeedSize].
  bool canSupplement = false,

  /// Drive and YouTube tracks fetched for a taste, keyed by its descriptor.
  ///
  /// They join that one mix's pool and are never clustered themselves: the
  /// user's own music decides which tastes exist, and a radio of related
  /// artists must add to "chris brown" rather than found a mix of its own.
  Map<String, List<MixCandidate>> supplements = const {},

  /// Which "session" of mixes this is. A new value — the app opened again, a
  /// pull to refresh — gives different tracks, a different set of tastes when
  /// there are more than fit, and a different running order. The same value
  /// gives the same mixes, so a card doesn't change while it is looked at.
  int variation = 0,
}) {
  if (library.isEmpty) return const [];

  final daypart = Daypart.of(now);
  final minSize = canSupplement
      ? MixRules.minSeedSize
      : MixRules.minClusterSize;
  final clusters = _shuffleByMass(
    _cluster(library, minSize: minSize),
    Random(Object.hash(_day(now), daypart.index, variation, 'order')),
  );
  if (clusters.isEmpty) return const [];

  final mixes = <DailyMix>[];
  for (var i = 0; i < clusters.length && mixes.length < maxMixes; i++) {
    final cluster = clusters[i];
    final random = Random(
      _seedFor(now, daypart, cluster.descriptor, variation),
    );
    final own = {for (final t in cluster.tracks) t.key};
    final pool = [
      ...cluster.tracks,
      for (final t in supplements[cluster.descriptor] ?? const <MixCandidate>[])
        if (own.add(t.key)) t,
    ];
    final keys = _fill(
      pool,
      daypart: daypart,
      limit: tracksPerMix,
      random: random,
    );
    // A cluster that cannot fill even a short mix is one the library only
    // looked like it had — unless something else is expected to fill it.
    if (keys.length < minSize) continue;
    mixes.add(
      DailyMix(
        name: '${cluster.descriptor.toLowerCase()} ${daypart.label}',
        descriptor: cluster.descriptor,
        daypart: daypart,
        trackKeys: keys,
      ),
    );
  }
  return mixes;
}

/// The RNG seed for one mix.
///
/// Date, daypart, taste and session — so the mix is stable while it is on
/// screen, different at a different time of day, different tomorrow, and
/// different every time the app is opened. Keyed by the taste rather than its
/// position, because the shelf order itself changes per session. Deliberately
/// not `Random()`: a mix that reshuffles every time the page rebuilds is a mix
/// nobody can point at.
int _seedFor(DateTime now, Daypart daypart, String descriptor, int variation) =>
    Object.hash(_day(now), daypart.index, descriptor, variation) & 0x7fffffff;

int _day(DateTime now) => now.year * 10000 + now.month * 100 + now.day;

/// Puts the tastes in a fresh order for this session, heavier listening more
/// likely first: weighted sampling without replacement (Efraimidis–Spirakis).
///
/// The square root keeps a dominant taste usually-first without letting it
/// pin the shelf — a favourite with twice the plays is not twice as likely to
/// lead — and the +1 means a taste nobody has played yet still gets turns.
List<_Cluster> _shuffleByMass(List<_Cluster> clusters, Random random) {
  final keyed = [
    for (final c in clusters)
      (c, pow(random.nextDouble(), 1 / (sqrt(c.mass) + 1)).toDouble()),
  ]..sort((a, b) => b.$2.compareTo(a.$2));
  return [for (final k in keyed) k.$1];
}

@immutable
class _Cluster {
  const _Cluster({
    required this.descriptor,
    required this.tracks,
    required this.mass,
  });
  final String descriptor;
  final List<MixCandidate> tracks;
  final double mass;
}

/// Splits a library into the tastes it actually contains.
///
/// # Additive, not a fallback chain
///
/// This used to try genre and, failing that, artist. That produced very few
/// categories: a library with no genre tags got artist mixes only, and one with
/// genres got genre mixes only, when both are real ways to describe what
/// someone listens to.
///
/// Now both groupings compete on equal footing and the best of them are taken,
/// with near-duplicates dropped — because everything by one artist is usually
/// also all of one genre, and offering both is offering one mix twice.
List<_Cluster> _cluster(List<MixCandidate> library, {required int minSize}) {
  final byGenre = [
    for (final c in _group(library, (t) => t.genre))
      if (c.tracks.length >= minSize && _hasVariety(c)) c,
  ];
  final byArtist = [
    // No variety rule: an artist cluster has one artist by construction, and
    // requiring several would make this half of the clustering dead code — which
    // it was, until a device with an untagged library showed no mixes at all.
    for (final c in _group(library, (t) => t.artist))
      if (c.tracks.length >= minSize) c,
  ];

  return _distinct(_ranked([...byGenre, ...byArtist]));
}

/// Takes clusters in order of listening mass, skipping any that mostly repeats
/// one already taken.
List<_Cluster> _distinct(List<_Cluster> ranked) {
  final kept = <_Cluster>[];
  final keptKeys = <Set<String>>[];

  for (final cluster in ranked) {
    final keys = {for (final t in cluster.tracks) t.key};
    var duplicate = false;
    for (final taken in keptKeys) {
      final shared = keys.intersection(taken).length;
      // Measured against the smaller of the two: a ten-track artist entirely
      // inside a two-hundred-track genre is a duplicate of it, even though it
      // is five per cent of the genre.
      final smaller = keys.length < taken.length ? keys.length : taken.length;
      if (smaller > 0 && shared / smaller > MixRules.maxClusterOverlap) {
        duplicate = true;
        break;
      }
    }
    if (duplicate) continue;
    kept.add(cluster);
    keptKeys.add(keys);
  }
  return kept;
}

/// Whether a *genre* group has more than one artist in it.
///
/// What stops a single well-tagged album becoming a "mix": twelve tracks, one
/// artist, in order. Applies to genre groupings only — an artist grouping has
/// exactly one artist and would never pass.
bool _hasVariety(_Cluster cluster) {
  final artists = <String>{};
  for (final track in cluster.tracks) {
    final artist = _normalise(track.artist);
    if (artist != null) artists.add(artist);
  }
  return artists.length >= MixRules.minDistinctArtists;
}

List<_Cluster> _ranked(List<_Cluster> clusters) {
  final sorted = [...clusters]..sort((a, b) => b.mass.compareTo(a.mass));
  return sorted;
}

List<_Cluster> _group(
  List<MixCandidate> library,
  String? Function(MixCandidate) field,
) {
  final buckets = <String, List<MixCandidate>>{};
  for (final track in library) {
    final raw = _normalise(field(track));
    if (raw == null) continue;
    (buckets[raw] ??= []).add(track);
  }
  return [
    for (final entry in buckets.entries)
      _Cluster(
        descriptor: entry.key,
        tracks: entry.value,
        // Listening mass, not size: a group of forty nobody plays is a worse
        // mix than a group of twelve somebody loves.
        mass: entry.value.fold<double>(
          0,
          (sum, t) => sum + t.playCount + t.plays * 2,
        ),
      ),
  ];
}

/// Blank and placeholder values are not a taste to cluster on.
///
/// Without this, every untagged file lands in one enormous "Unknown Artist"
/// group and the app offers a mix of everything nobody bothered to tag.
///
/// YouTube's auto-generated artist channels are suffixed `" - Topic"`, and a
/// library assembled from downloads is full of them. Stripping it does two jobs:
/// it stops a mix being called *"chris brown - topic late night"*, and it merges
/// `Chris Brown` with `Chris Brown - Topic` into the one artist they obviously
/// are — which is the difference between two thin clusters and one real one.
String? _normalise(String? value) {
  var trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;

  final lower = trimmed.toLowerCase();
  if (lower.endsWith(_topicSuffix)) {
    trimmed = trimmed.substring(0, trimmed.length - _topicSuffix.length).trim();
    if (trimmed.isEmpty) return null;
  }

  const unknown = {'unknown', 'unknown artist', 'unknown album', '<unknown>'};
  if (unknown.contains(trimmed.toLowerCase())) return null;
  return trimmed;
}

const _topicSuffix = ' - topic';

/// Draws one mix's worth of tracks: mostly proven, substantially novel.
///
/// Both pools top each other up. A library with no listening history has an
/// empty proven pool and the whole mix comes from novelty; a library where
/// everything has been played has no novelty and the whole mix is proven.
/// Neither should produce a short mix.
List<String> _fill(
  List<MixCandidate> cluster, {
  required Daypart daypart,
  required int limit,
  required Random random,
}) {
  final local = [
    for (final t in cluster)
      if (t.isOwn) t,
  ];
  final remote = [
    for (final t in cluster)
      if (!t.isOwn) t,
  ];

  final proven = [
    for (final t in local)
      if (t.isProven) t,
  ];
  final novel = [
    for (final t in local)
      if (t.isNovel) t,
  ];
  // Played a little, or played and skipped — neither earned nor unheard. Kept
  // as the pool that tops the other two up.
  final rest = [
    for (final t in local)
      if (!t.isProven && !t.isNovel) t,
  ];

  // The user's own music takes the majority before anything streamed is drawn.
  final wantLocal = remote.isEmpty
      ? limit
      : (limit * (1 - MixRules.maxRemoteShare)).round();
  final wantProven = (wantLocal * MixRules.provenShare).round();
  final wantNovel = wantLocal - wantProven;

  final picked = <String>{};
  final out = <String>[];

  void draw(List<MixCandidate> pool, int count) {
    final take = _weightedDraw(
      pool.where((t) => !picked.contains(t.key)).toList(),
      daypart: daypart,
      limit: count,
      random: random,
    );
    for (final key in take) {
      if (picked.add(key)) out.add(key);
    }
  }

  draw(proven, wantProven);
  draw(novel, wantNovel);
  // Whatever the local shares could not supply, from the rest of the local pool
  // — a small library should fill up with its own music before reaching out.
  if (out.length < wantLocal) {
    draw([...rest, ...proven, ...novel], wantLocal - out.length);
  }
  draw(remote, limit - out.length);
  // Still short: the library is smaller than a mix. Take anything left.
  if (out.length < limit) {
    draw([...rest, ...proven, ...novel, ...remote], limit - out.length);
  }
  return out;
}

/// Weighted-random without replacement, favouring what this person plays at
/// this time of day.
List<String> _weightedDraw(
  List<MixCandidate> pool, {
  required Daypart daypart,
  required int limit,
  required Random random,
}) {
  if (limit <= 0 || pool.isEmpty) return const [];

  final candidates = [...pool];
  final weights = [for (final track in candidates) _weight(track, daypart)];

  final out = <String>[];
  var total = weights.fold<double>(0, (sum, w) => sum + w);

  while (out.length < limit && candidates.isNotEmpty) {
    var target = random.nextDouble() * total;
    var index = candidates.length - 1;
    for (var i = 0; i < candidates.length; i++) {
      target -= weights[i];
      if (target <= 0) {
        index = i;
        break;
      }
    }
    out.add(candidates.removeAt(index).key);
    total -= weights.removeAt(index);
    if (total <= 0) {
      total = weights.fold<double>(0, (sum, w) => sum + w);
      if (total <= 0) break;
    }
  }
  return out;
}

double _weight(MixCandidate track, Daypart daypart) {
  var weight = MixRules.floor;
  if (track.hours.any(daypart.hours.contains)) weight += MixRules.hourBonus;
  // A little for familiarity, capped — the difference between forty plays and
  // four hundred is not four hundred divided by forty.
  weight += min(track.playCount, 10) / 10;
  return weight;
}
