/// Turning the library database into mixes that can be played.
///
/// The arithmetic lives in `daily_mixes.dart` and knows nothing about SQLite,
/// artwork or `SongModel`. This is the layer that feeds it: it reads the
/// library and its listening history, hands both to the engine, and maps the
/// keys that come back to the tracks the player takes.
///
/// Mixes are cached for the daypart they were built in. Rebuilding on every
/// rebuild of a widget would be three queries and a clustering pass to produce
/// — by design — exactly the same answer.
library;

import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../../data/library_repository.dart';
import '../../models/cloud_file.dart';
import '../lyrics/lrclib_resolver.dart'
    show cleanTitle, normalizeArtist, primaryArtist;
import '../ytmusic/yt_models.dart';
import 'daily_mixes.dart';
import 'mix_playback.dart';
import 'mix_track_ref.dart';

/// Drive files the user has, or an empty list when no drive is linked.
typedef CloudLibrary = List<CloudFile> Function();

/// YouTube tracks that go with a taste — its genre or its artist.
///
/// Called once per mix and only for tastes the local library already has, so
/// streaming can add variety *inside* something the user likes and can never
/// invent a taste they do not.
typedef YouTubeForTaste = Future<List<YtTrack>> Function(String descriptor);

/// YouTube Music's "radio" for one of the user's own songs — the related
/// tracks it would play next. Empty when the song can't be found there.
typedef YouTubeRadio = Future<List<YtTrack>> Function(MixSeed seed);

/// A song the user plays, as a starting point for YouTube radio: a file on the
/// phone (found on YouTube by title and artist) or a streamed song they played
/// (whose video id is already known).
class MixSeed {
  const MixSeed({
    required this.key,
    required this.title,
    this.artist,
    this.videoId,
    required this.score,
    required this.ref,
  });

  /// The engine's key for this track.
  final String key;
  final String title;
  final String? artist;

  /// Set for a streamed song: its radio needs no search.
  final String? videoId;

  /// How much it is played: completed plays count double, skips not at all.
  final int score;

  /// The track itself, for a mix that opens with it.
  final MixTrackRef ref;
}

/// One identity for a recording across sources: "Blinding Lights (Official
/// Video)" by "The Weeknd - Topic" is the same song as the file on the phone.
String trackIdentity(String title, String? artist) =>
    '${cleanTitle(title).toLowerCase()}|'
    '${primaryArtist(normalizeArtist(artist ?? '')).toLowerCase()}';

/// A mix, as far as it can be prepared without spending a request per track.
class ResolvedMix implements ResolvedMixSource {
  const ResolvedMix({
    required this.name,
    required this.descriptor,
    required this.tracks,
    this.seededBySong = false,
  });

  final String name;
  final String descriptor;

  /// A radio of one song ("glory radio"): its descriptor is a song title, not
  /// a taste, so it is no search term for playlists.
  final bool seededBySong;
  @override
  final List<MixTrackRef> tracks;

  int get length => tracks.length;

  /// Whether anything here comes from a drive or from YouTube.
  bool get hasRemote => tracks.any((t) => t.source != MixSource.local);
}

class DailyMixService {
  DailyMixService(
    this._repo, {
    CloudLibrary? cloudLibrary,
    YouTubeForTaste? youTube,
    YouTubeRadio? youTubeRadio,
    int? variation,
  }) : _cloudLibrary = cloudLibrary,
       _youTube = youTube,
       _youTubeRadio = youTubeRadio,
       _variation = variation ?? _freshVariation();

  final LibraryRepository _repo;
  final CloudLibrary? _cloudLibrary;
  final YouTubeForTaste? _youTube;
  final YouTubeRadio? _youTubeRadio;

  /// How many of a mix's most-played songs seed its YouTube radio.
  static const radioSeeds = 2;

  /// How many of a mix's favourites a session's radio seeds are drawn from.
  static const radioSeedPool = 8;

  /// Below this many radio tracks, the taste's name is searched as well.
  static const radioEnough = 12;

  /// Home should never be bare: with fewer mixes than this, the user's
  /// favourite songs each get a radio mix of their own.
  static const minMixes = 3;

  List<ResolvedMix>? _cached;
  String? _cachedFor;

  /// This session's mixes. A service is made once per app launch, so each
  /// launch gets new ones; [reshuffle] starts another session mid-launch.
  int _variation;
  int get variation => _variation;

  static final Random _rng = Random();
  static int _freshVariation() => _rng.nextInt(1 << 31);

  /// New mixes from the same library — for a return to the app after a while,
  /// or a pull to refresh. The next [mixes] call rebuilds.
  void reshuffle() {
    _variation = _freshVariation();
    invalidate();
  }

  /// A stamp that changes exactly when the mixes should.
  static String stampFor(DateTime now) =>
      '${now.year}-${now.month}-${now.day}-${Daypart.of(now).index}';

  /// The mixes for [now], built once per daypart.
  ///
  /// [force] reshuffles and rebuilds — for a pull-to-refresh, where the user
  /// has asked for something new and getting the same list back would read as
  /// the gesture having failed.
  Future<List<ResolvedMix>> mixes({DateTime? now, bool force = false}) async {
    final moment = now ?? DateTime.now();
    if (force) reshuffle();
    final stamp = stampFor(moment);
    final cached = _cached;
    if (cached != null && _cachedFor == stamp) return cached;

    final songs = await _repo.allSongs();
    final streamed = await _repo.streamedTracks();
    if (songs.isEmpty && streamed.isEmpty) {
      _cached = const [];
      _cachedFor = stamp;
      return const [];
    }

    // Two small aggregate queries rather than one per track.
    final stats = await _repo.playStats();
    final hours = await _repo.playHours();
    final streamedStats = await _repo.playStatsFor({
      for (final t in streamed) t.songId: t.durationMs,
    });

    final byKey = {for (final song in songs) song.id.toString(): song};
    final refs = <String, MixTrackRef>{};
    final seeds = <String, MixSeed>{};
    final local = <MixCandidate>[];
    for (final song in songs) {
      final candidate = _candidateOf(song, stats, hours);
      local.add(candidate);
      seeds[candidate.key] = MixSeed(
        key: candidate.key,
        title: song.title,
        artist: song.artist,
        score: _score(candidate.plays, candidate.skips, candidate.playCount),
        ref: MixTrackRef.local(song),
      );
    }
    // Streamed songs the user played are part of their listening: they can
    // found a taste and seed radio like a file on the phone can.
    final historyKeys = <String>{};
    for (final t in streamed) {
      final stat = streamedStats[t.songId];
      if (stat == null || stat.plays == stat.skips) continue;
      final key = t.key;
      final track = YtTrack(
        videoId: t.videoId,
        title: t.title,
        artist: t.artist,
        thumbnail: t.thumbnail,
        durationSecs: t.durationMs > 0 ? t.durationMs / 1000 : null,
        playlistId: '',
        playlistTitle: '',
      );
      final ref = MixTrackRef.youtube(track, asVideo: false);
      historyKeys.add(key);
      refs[key] = ref;
      local.add(
        MixCandidate(
          key: key,
          source: MixSource.youtube,
          history: true,
          artist: t.artist,
          plays: stat.plays,
          skips: stat.skips,
        ),
      );
      seeds[key] = MixSeed(
        key: key,
        title: t.title,
        artist: t.artist,
        videoId: t.videoId,
        score: _score(stat.plays, stat.skips, 0),
        ref: ref,
      );
    }
    // What the user already has or plays — never worth fetching again.
    final owned = {
      for (final seed in seeds.values) trackIdentity(seed.title, seed.artist),
    };

    // Pass one decides the tastes, from the user's own listening alone. Remote
    // tracks are then fetched for those tastes and only those — which is what
    // stops a drive full of one genre inventing a mix the library has no
    // grounds for.
    final canSupplement =
        (_cloudLibrary?.call().isNotEmpty ?? false) ||
        _youTube != null ||
        _youTubeRadio != null;
    final shape = buildDailyMixes(
      library: local,
      now: moment,
      canSupplement: canSupplement,
      variation: _variation,
    );

    // Fetched for every taste at once: each is a handful of requests, and
    // doing them in turn made Home wait for all of them end to end.
    final fetched = await Future.wait([
      for (final mix in shape)
        _remoteFor(mix, seeds: seeds, owned: owned, ownKeys: historyKeys),
    ]);
    final supplements = <String, List<MixCandidate>>{};
    var supplemented = false;
    for (var i = 0; i < shape.length; i++) {
      final pool = supplements[shape[i].descriptor] ??= [];
      for (final entry in fetched[i].entries) {
        // A track two tastes both turned up belongs to the first.
        if (refs.containsKey(entry.key)) continue;
        refs[entry.key] = entry.value.$2;
        pool.add(entry.value.$1);
        supplemented = true;
      }
    }

    // Pass two fills those same tastes, each from its own supplement.
    final built = !supplemented
        ? shape
        : buildDailyMixes(
            library: local,
            now: moment,
            canSupplement: canSupplement,
            supplements: supplements,
            variation: _variation,
          );

    final resolved = <ResolvedMix>[];
    for (final mix in built) {
      final tracks = <MixTrackRef>[
        for (final key in mix.trackKeys)
          if (byKey[key] case final song?)
            MixTrackRef.local(song)
          else if (refs[key] case final ref?)
            ref,
      ];
      // A mix whose tracks all vanished between the query and here is not worth
      // a card.
      if (tracks.isEmpty) continue;
      resolved.add(
        ResolvedMix(name: mix.name, descriptor: mix.descriptor, tracks: tracks),
      );
    }

    if (resolved.length < minMixes) {
      resolved.addAll(
        await _radioMixes(
          count: minMixes - resolved.length,
          taken: resolved,
          seeds: seeds,
          owned: owned,
          ownKeys: historyKeys,
        ),
      );
    }

    _cached = resolved;
    _cachedFor = stamp;
    return resolved;
  }

  /// Completed plays count double; the library's own counter counts once.
  static int _score(int plays, int skips, int playCount) =>
      (plays - skips) * 2 + playCount;

  /// Mixes seeded from the user's favourite songs — for a listener whose plays
  /// don't yet form tastes (a few songs by many artists, or nothing on the
  /// phone at all). Each opens with the favourite, then its YouTube radio.
  Future<List<ResolvedMix>> _radioMixes({
    required int count,
    required List<ResolvedMix> taken,
    required Map<String, MixSeed> seeds,
    required Set<String> owned,
    required Set<String> ownKeys,
  }) async {
    final radio = _youTubeRadio;
    if (radio == null || count <= 0) return const [];

    final takenNames = {for (final m in taken) m.descriptor.toLowerCase()};
    final played = [
      for (final seed in seeds.values)
        if (seed.score > 0) seed,
    ]..sort((a, b) => b.score.compareTo(a.score));
    final random = Random(Object.hash(_variation, 'radio-mixes'));
    final keyed = [
      for (final s in played.take(radioSeedPool * 2))
        (s, pow(random.nextDouble(), 1 / s.score).toDouble()),
    ]..sort((a, b) => b.$2.compareTo(a.$2));

    // One per artist, and none for a taste that already has its mix. When the
    // artists run out — someone who has played four songs by one artist —
    // the favourites themselves each get a radio ("glory radio").
    final chosen = <(MixSeed, bool)>[];
    final names = <String>{...takenNames};
    for (final (seed, _) in keyed) {
      if (chosen.length == count) break;
      if (_radioName(seed).isEmpty) continue;
      if (!names.add(_radioDescriptor(seed).toLowerCase())) continue;
      chosen.add((seed, false));
    }
    final titles = <String>{};
    for (final (seed, _) in keyed) {
      if (chosen.length >= count) break;
      if (chosen.any((c) => c.$1.key == seed.key)) continue;
      final title = cleanTitle(seed.title).toLowerCase();
      if (title.isEmpty || !titles.add(title)) continue;
      chosen.add((seed, true));
    }

    final built = await Future.wait([
      for (final (seed, bySong) in chosen)
        () async {
          final List<YtTrack> related;
          try {
            related = await radio(seed);
          } catch (_) {
            return null;
          }
          final seen = {...owned};
          final tracks = <MixTrackRef>[seed.ref];
          for (final t in related) {
            if (!t.isAvailable || ownKeys.contains('yt:${t.videoId}')) continue;
            if (!seen.add(trackIdentity(t.title, t.artist))) continue;
            tracks.add(MixTrackRef.youtube(t, asVideo: false));
            if (tracks.length == MixRules.tracksPerMix) break;
          }
          // The favourite alone is not a mix.
          if (tracks.length < MixRules.minClusterSize) return null;
          final title = cleanTitle(seed.title);
          return ResolvedMix(
            name: bySong ? '${title.toLowerCase()} radio' : _radioName(seed),
            descriptor: bySong ? title : _radioDescriptor(seed),
            tracks: tracks,
            seededBySong: bySong,
          );
        }(),
    ]);
    return [for (final mix in built) ?mix];
  }

  static String _radioDescriptor(MixSeed seed) {
    final artist = primaryArtist(normalizeArtist(seed.artist ?? ''));
    return artist.isNotEmpty ? artist : cleanTitle(seed.title);
  }

  /// "burna boy mix", or "last last radio" when the artist isn't known.
  static String _radioName(MixSeed seed) {
    final artist = primaryArtist(normalizeArtist(seed.artist ?? ''));
    if (artist.isNotEmpty) return '${artist.toLowerCase()} mix';
    final title = cleanTitle(seed.title);
    return title.isEmpty ? '' : '${title.toLowerCase()} radio';
  }

  /// Drive and YouTube tracks for one taste.
  ///
  /// YouTube is asked first for the radio of the songs the user actually plays
  /// in this mix — what they listen to, not just what the taste is called. The
  /// taste's name is searched only when that comes up short (a cold start with
  /// no plays yet, or songs YouTube doesn't know). Anything the user already
  /// owns is skipped: streaming a song that is on the phone is pure waste.
  ///
  /// Returns key -> (candidate for the engine, reference for playback).
  ///
  /// **Silent on failure.** A mix is something the app offers unasked; being
  /// offline, or signed out, or rate-limited must cost the variety and nothing
  /// else. The local mix is already correct.
  Future<Map<String, (MixCandidate, MixTrackRef)>> _remoteFor(
    DailyMix mix, {
    required Map<String, MixSeed> seeds,
    required Set<String> owned,
    required Set<String> ownKeys,
  }) async {
    final descriptor = mix.descriptor;
    final out = <String, (MixCandidate, MixTrackRef)>{};
    final wanted = descriptor.toLowerCase();

    final cloud = _cloudLibrary?.call() ?? const <CloudFile>[];
    for (final file in cloud) {
      final artist = file.trackArtist?.toLowerCase();
      final album = file.albumName?.toLowerCase();
      if (artist != wanted && album != wanted) continue;
      final key = 'cloud:${file.fileId}';
      out[key] = (
        MixCandidate(
          key: key,
          source: MixSource.cloud,
          artist: file.trackArtist,
          genre: descriptor,
        ),
        MixTrackRef.cloud(file),
      );
    }

    final seen = {...owned};
    void addYouTube(YtTrack track, {required bool asVideo}) {
      final key = 'yt:${track.videoId}';
      // Already in the mix as something the user played.
      if (out.containsKey(key) || ownKeys.contains(key)) return;
      if (!seen.add(trackIdentity(track.title, track.artist))) return;
      out[key] = (
        MixCandidate(
          key: key,
          source: MixSource.youtube,
          artist: track.artist,
          genre: descriptor,
        ),
        // Marked as video only when YouTube says there is real footage;
        // MixTrackRef.youtube enforces that too.
        MixTrackRef.youtube(track, asVideo: asVideo),
      );
    }

    var fromRadio = 0;
    final radio = _youTubeRadio;
    if (radio != null) {
      final picked = seedsFor(
        mix,
        seeds: seeds,
        random: Random(Object.hash(_variation, mix.descriptor)),
      );
      Future<List<YtTrack>> safely(MixSeed seed) async {
        try {
          return await radio(seed);
        } catch (_) {
          return const <YtTrack>[];
        }
      }

      final batches = await Future.wait([
        for (final seed in picked) safely(seed),
      ]);
      final before = out.length;
      // Interleaved so two seeds share the mix rather than the first one
      // crowding the second out.
      final longest = batches.fold<int>(
        0,
        (n, b) => b.length > n ? b.length : n,
      );
      for (var i = 0; i < longest; i++) {
        for (final batch in batches) {
          // Radio items carry a video flag for most songs; a mix of songs
          // plays them as audio.
          if (i < batch.length && batch[i].isAvailable) {
            addYouTube(batch[i], asVideo: false);
          }
        }
      }
      fromRadio = out.length - before;
    }

    final youTube = _youTube;
    if (youTube != null && fromRadio < radioEnough) {
      try {
        for (final track in await youTube(descriptor)) {
          addYouTube(track, asVideo: track.hasVideo);
        }
      } catch (_) {
        // See the note above: variety is the only thing lost.
      }
    }
    return out;
  }

  /// The songs in [mix] the user plays — what its radio is seeded from.
  ///
  /// Drawn from the most-played few, weighted by plays, so each session's radio
  /// starts from a different favourite rather than the same two every time.
  /// Without [random], simply the top ones. Nothing played yet means no seeds,
  /// and the taste's name is searched.
  @visibleForTesting
  static List<MixSeed> seedsFor(
    DailyMix mix, {
    required Map<String, MixSeed> seeds,
    Random? random,
  }) {
    final played = [
      for (final key in mix.trackKeys)
        if (seeds[key] case final seed? when seed.score > 0) seed,
    ]..sort((a, b) => b.score.compareTo(a.score));
    if (random == null) return played.take(radioSeeds).toList();

    // Weighted sampling without replacement among the favourites.
    final pool = played.take(radioSeedPool).toList();
    final keyed = [
      for (final s in pool)
        (s, pow(random.nextDouble(), 1 / s.score).toDouble()),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final k in keyed.take(radioSeeds)) k.$1];
  }

  /// Drops the cache. For after a library scan, which can change what tastes
  /// the library even contains.
  void invalidate() {
    _cached = null;
    _cachedFor = null;
  }

  static MixCandidate _candidateOf(
    SongModel song,
    Map<int, PlayStats> stats,
    Map<int, Set<int>> hours,
  ) {
    final map = song.getMap;
    final stat = stats[song.id];
    return MixCandidate(
      key: song.id.toString(),
      artist: song.artist,
      genre: map['genre'] as String?,
      addedAtSec: (map['date_added'] as num?)?.toInt(),
      playCount: (map['play_count'] as num?)?.toInt() ?? 0,
      plays: stat?.plays ?? 0,
      skips: stat?.skips ?? 0,
      hours: hours[song.id] ?? const {},
    );
  }
}
