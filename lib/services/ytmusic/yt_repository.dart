/// The only thing the Discover UI talks to.
///
/// Everything below is a thin front for [YtWorker] plus the three caches that
/// exist for a stated reason. The caching policy is deliberately uneven, and the
/// unevenness is the design:
///
/// * **Categories are cached to disk.** They are the landing screen — first tab
///   on iOS — and they change perhaps monthly. Rendering them from disk means
///   opening the app costs no network at all before something is on screen.
/// * **Category pages are never cached to disk**, only held for the session.
///   Discover's whole value is being current, and a stale copy of YouTube's
///   catalog is just a worse Library. The session LRU exists so pressing back
///   doesn't re-fetch what's still on screen.
/// * **Stream URLs are cached until they expire**, and not one second past —
///   googlevideo states its own deadline and a URL served after it is a stall.
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'parse/yt_track_info.dart';
import 'parse/yt_tracks.dart';
import 'yt_innertube.dart';
import 'yt_models.dart';
import 'yt_worker.dart';

class YtMusicRepository {
  YtMusicRepository._();

  static final YtMusicRepository instance = YtMusicRepository._();

  static const _categoriesKey = 'ytmusic.categories.v1';

  /// How many category pages to keep for the session. Enough that browsing back
  /// and forth between a few genres is instant, small enough that fifty-item
  /// shelves don't accumulate into real memory.
  static const _pageCacheSize = 8;

  final _pages = <String, List<ExploreShelf>>{};
  final _audio = <String, StreamTarget>{};
  final _video = <String, StreamTarget>{};

  /// In-flight resolves, so two taps on the same track make one request.
  final _resolving = <String, Future<StreamTarget>>{};

  // -------------------------------------------------------------------------
  // Categories
  // -------------------------------------------------------------------------

  /// The categories last seen, or null if this device has never loaded them.
  ///
  /// Reads one small string off disk — no network, no isolate. This is what the
  /// landing screen paints before anything else has happened.
  Future<List<ExploreSection>?> cachedCategories() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_categoriesKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final sections = <ExploreSection>[];
      for (final entry in decoded) {
        final section = ExploreSection.fromJson(entry);
        if (section != null) sections.add(section);
      }
      return sections.isEmpty ? null : sections;
    } catch (_) {
      // A cache that won't read is a cache miss, never an error worth showing.
      return null;
    }
  }

  /// The categories, fresh from YouTube, written through to the disk cache.
  Future<List<ExploreSection>> categories() async {
    final sections = await YtWorker.instance.run<List<ExploreSection>>(
      YtOp.categories,
    );
    if (sections.isNotEmpty) unawaited(_writeCategories(sections));
    return sections;
  }

  Future<void> _writeCategories(List<ExploreSection> sections) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _categoriesKey,
        jsonEncode([for (final s in sections) s.toJson()]),
      );
    } catch (_) {
      // Failing to cache costs one instant paint next launch. Nothing more.
    }
  }

  // -------------------------------------------------------------------------
  // Browsing
  // -------------------------------------------------------------------------

  /// One category's shelves.
  Future<List<ExploreShelf>> categoryPage(ExploreCategory category) async {
    final cached = _pages.remove(category.params);
    if (cached != null) {
      // Re-inserting moves it to the most-recent end.
      _pages[category.params] = cached;
      return cached;
    }
    final shelves = await YtWorker.instance.run<List<ExploreShelf>>(
      YtOp.categoryPage,
      {'params': category.params},
    );
    if (shelves.isNotEmpty) {
      _pages[category.params] = shelves;
      while (_pages.length > _pageCacheSize) {
        _pages.remove(_pages.keys.first);
      }
    }
    return shelves;
  }

  /// One artist's page: who they are, then their shelves — top songs,
  /// albums, singles, videos.
  Future<YtArtistPageData> artistPage(String browseId) => YtWorker.instance
      .run<YtArtistPageData>(YtOp.artistPage, {'browseId': browseId});

  /// Search results for one filter.
  ///
  /// Every filter is its own request — that's how YT Music's own search works,
  /// and the unfiltered query answers with a different, shallower set (a top
  /// result and a handful of each kind) rather than with everything.
  Future<List<ExploreShelf>> search(String query, SearchFilter filter) =>
      YtWorker.instance.run<List<ExploreShelf>>(YtOp.search, {
        'query': query,
        'params': filter.params,
      });

  /// YouTube Music's own curated playlists for [query] ("Presenting Burna
  /// Boy", "Afrobeats Now") — the *featured* filter, as opposed to the
  /// community playlists [SearchFilter.playlists] returns, which are anyone's
  /// uploads. Kept out of [SearchFilter] so it doesn't become a search tab.
  Future<List<ExploreShelf>> featuredPlaylists(String query) =>
      YtWorker.instance.run<List<ExploreShelf>>(YtOp.search, {
        'query': query,
        'params': _featuredPlaylistsParams,
      });

  static const _featuredPlaylistsParams = 'EgeKAQQoADgBagwQDhAKEAMQBRAJEAQ%3D';

  /// Type-ahead completions. Never throws: a failed suggestion request must
  /// leave the field alone, not replace what the user is typing with an error.
  Future<List<String>> suggestions(String query) async {
    try {
      return await YtWorker.instance.run<List<String>>(YtOp.suggestions, {
        'query': query,
      });
    } catch (_) {
      return const [];
    }
  }

  // -------------------------------------------------------------------------
  // Opening things into tracks
  // -------------------------------------------------------------------------

  /// The tracks behind one item, ready to queue.
  ///
  /// Nothing is cached: this is YouTube's live catalog and its whole value is
  /// being current, so every open is a fresh read.
  Future<List<YtTrack>> tracksOf(ExploreItem item) async {
    switch (item.kind) {
      case ExploreKind.playlist:
        final list = await _trackList(item, TrackListKind.playlist);
        return list.tracks;
      case ExploreKind.album:
        final list = await _trackList(item, TrackListKind.album);
        return list.tracks;
      // A row already said everything a track needs, so playing one costs no
      // request at all — the id it carries is the video id.
      case ExploreKind.song:
      case ExploreKind.video:
        return [item.asTrack()];
      // An artist isn't a track list; their top songs are the closest thing to
      // one, and they're what YouTube's own play button uses.
      case ExploreKind.artist:
        return _artistTracks(item);
    }
  }

  /// One playlist or album, with its header — what the opened screen shows.
  Future<YtTrackList> openList(ExploreItem item) => _trackList(
    item,
    item.kind == ExploreKind.album
        ? TrackListKind.album
        : TrackListKind.playlist,
  );

  Future<YtTrackList> _trackList(ExploreItem item, TrackListKind kind) =>
      YtWorker.instance.run<YtTrackList>(YtOp.trackList, {
        'id': item.id,
        'kind': kind.index,
        'title': item.title,
      });

  /// An artist's playable rows, in the order their page lists them.
  ///
  /// Only the rows: the carousels on an artist page are albums and singles to
  /// *open*, not tracks, and opening each to flatten it would be dozens of
  /// requests for one play button.
  ///
  /// An artist whose page holds no rows is an empty queue rather than an error —
  /// there is nothing wrong with the page, it simply lists no songs.
  Future<List<YtTrack>> _artistTracks(ExploreItem item) async {
    final shelves = (await artistPage(item.id)).shelves;
    return [
      for (final shelf in shelves)
        for (final entry in shelf.items)
          if (entry.isPlayable)
            entry
                .asTrack(playlistId: item.id, playlistTitle: item.title)
                // On an artist's own page, an unlinked credit is them.
                .copyWith(artist: entry.artist ?? item.title),
    ];
  }

  // -------------------------------------------------------------------------
  // Radio
  // -------------------------------------------------------------------------

  /// The endless "up next" YouTube derives from one song.
  Future<RadioBatch> radio(String videoId) =>
      YtWorker.instance.run<RadioBatch>(YtOp.radio, {'videoId': videoId});

  /// The next page of a radio. Needs the seed as well as the token: the wire
  /// format re-posts the full body, so the token alone is not a request.
  Future<RadioBatch> radioContinue(String videoId, String token) =>
      YtWorker.instance.run<RadioBatch>(YtOp.radioContinue, {
        'videoId': videoId,
        'token': token,
      });

  // -------------------------------------------------------------------------
  // Details, for tagging a download
  // -------------------------------------------------------------------------

  /// What YouTube Music knows about one track — every credited artist, the
  /// album and its link, year, art and lyrics link — or null when it can't
  /// say. Never cached: it is asked once per download.
  Future<YtTrackInfo?> trackInfo(String videoId) =>
      YtWorker.instance.run<YtTrackInfo?>(YtOp.trackInfo, {'videoId': videoId});

  /// The lyrics behind a [YtTrackInfo.lyricsId], or null.
  Future<YtLyrics?> lyrics(String browseId) =>
      YtWorker.instance.run<YtLyrics?>(YtOp.lyrics, {'browseId': browseId});

  /// An album's page by its `MPREb…` id: its artist, cover and track order.
  Future<YtTrackList> album(String browseId, {String title = ''}) => _trackList(
    ExploreItem(id: browseId, kind: ExploreKind.album, title: title),
    TrackListKind.album,
  );

  // -------------------------------------------------------------------------
  // Streams
  // -------------------------------------------------------------------------

  /// A directly-playable audio target for a video id.
  Future<StreamTarget> audioTarget(String videoId) =>
      _resolve(videoId, _audio, YtOp.resolveAudio);

  /// A directly-playable video target — the adaptive HLS manifest.
  Future<StreamTarget> videoTarget(String videoId) =>
      _resolve(videoId, _video, YtOp.resolveVideo);

  Future<StreamTarget> _resolve(
    String videoId,
    Map<String, StreamTarget> cache,
    YtOp op,
  ) {
    final hit = cache[videoId];
    if (hit != null && hit.isFresh) return Future.value(hit);
    cache.remove(videoId);

    final key = '${op.name}:$videoId';
    final inFlight = _resolving[key];
    if (inFlight != null) return inFlight;

    final future = YtWorker.instance
        .run<StreamTarget>(op, {'videoId': videoId})
        .then((target) {
          cache[videoId] = target;
          return target;
        })
        .whenComplete(() {
          // A BLOCK body, deliberately. `whenComplete(() => _resolving.remove(key))`
          // reads as identical but is a deadlock: `Map.remove` returns the value it
          // removed — which here is this very future — and `whenComplete` waits on
          // any Future its callback returns. The future ends up awaiting itself and
          // never completes, while the `then` above still runs. The symptom is a
          // spinner that never goes away over a request that already succeeded.
          _resolving.remove(key);
        });

    _resolving[key] = future;
    return future;
  }

  /// Resolves several tracks' audio, a few at a time.
  ///
  /// Bounded because a fifty-track playlist would otherwise open fifty sockets
  /// at once, which on a phone radio is slower than doing it in handfuls as well
  /// as being the kind of burst that earns rate-limiting.
  Future<Map<String, StreamTarget>> audioTargets(
    List<String> videoIds, {
    int concurrency = 4,
  }) async {
    final resolved = <String, StreamTarget>{};
    for (var i = 0; i < videoIds.length; i += concurrency) {
      final batch = videoIds.skip(i).take(concurrency);
      await Future.wait([
        for (final id in batch)
          audioTarget(id).then(
            (target) => resolved[id] = target,
            // One track that won't resolve costs itself, not the batch.
            onError: (_) {},
          ),
      ]);
    }
    return resolved;
  }

  /// Resolves several tracks' *video*, a few at a time.
  ///
  /// Bounded for the same reasons as [audioTargets], and used with a smaller
  /// list: a video target is heavier to resolve and its manifest has to be
  /// written to disk, so queueing a great many ahead of the user spends effort
  /// on videos they will most likely skip past.
  Future<Map<String, StreamTarget>> videoTargets(
    List<String> videoIds, {
    int concurrency = 3,
  }) async {
    final resolved = <String, StreamTarget>{};
    for (var i = 0; i < videoIds.length; i += concurrency) {
      final batch = videoIds.skip(i).take(concurrency);
      await Future.wait([
        for (final id in batch)
          videoTarget(id).then(
            (target) => resolved[id] = target,
            // One video that won't resolve costs itself, not the batch.
            onError: (_) {},
          ),
      ]);
    }
    return resolved;
  }

  /// Whether [videoId] can be played right now with no request at all.
  ///
  /// The play path uses this to decide whether it needs to show the user
  /// anything: a resolve it doesn't have to make is a spinner it shouldn't show.
  bool isResolved(String videoId) => _audio[videoId]?.isFresh ?? false;

  /// Resolves the tracks most likely to be tapped, quietly, ahead of the tap.
  ///
  /// This is what makes playing feel instant, and it does two jobs at once:
  ///
  /// 1. **It warms the connection.** Browsing talks to `music.youtube.com`;
  ///    resolving talks to `youtubei.googleapis.com`. So the first play of a
  ///    session always pays a TLS handshake to a host nothing has spoken to yet
  ///    — measured at 0.74 s against 0.14 s on a warm connection. Prefetching
  ///    moves that cost to while the user is still reading the screen.
  /// 2. **It caches the URLs**, so the tap itself costs nothing.
  ///
  /// Deliberately small and fire-and-forget: this is speculative work, so it
  /// must never delay the screen that asked for it, and it must not spend a
  /// phone's data resolving fifty tracks nobody plays. Failures are silent —
  /// a prefetch that misses just means the tap pays for itself as before.
  void prefetchAudio(List<String> videoIds, {int limit = 4}) {
    final wanted = <String>[];
    for (final id in videoIds) {
      if (wanted.length >= limit) break;
      if (id.isEmpty ||
          isResolved(id) ||
          _resolving.containsKey('${YtOp.resolveAudio.name}:$id')) {
        continue;
      }
      wanted.add(id);
    }
    if (wanted.isEmpty) return;
    unawaited(audioTargets(wanted, concurrency: 2));
  }

  /// Forgets a track's resolved URLs — used when playback rejects one, so the
  /// retry asks YouTube again instead of replaying the same dead URL.
  void forget(String videoId) {
    _audio.remove(videoId);
    _video.remove(videoId);
  }

  /// Starts a new InnerTube session, and forgets every URL the old one minted.
  ///
  /// Called when playback proves the session is one of the gated ones: its urls
  /// answer `OK` at resolve time and 403 the moment a player opens them, so the
  /// only evidence arrives from ExoPlayer, and the only cure is a new session.
  ///
  /// Every cached target has to go with it. They were minted by the burned
  /// session and are gated to a track; keeping them would serve the same dead
  /// urls to the very retry that exists to escape them. The browse and search
  /// caches stay: pages are not gated, and they are what makes Discover instant.
  Future<void> resetSession() async {
    _audio.clear();
    _video.clear();
    await YtWorker.instance.run<void>(YtOp.resetSession);
  }

  /// Drops everything held for the session. The disk-cached categories stay:
  /// they are what makes the next cold open instant.
  void clearSession() {
    _pages.clear();
    _audio.clear();
    _video.clear();
  }
}

/// Re-exported so callers can catch the one exception type this layer throws.
typedef YtException = YtNetworkException;
