/// The landing surface: what this person should hear right now.
///
/// # Every shelf can be absent
///
/// A new install has no listening history, may have no playlists, and may have
/// nothing to jump back into. Each shelf here renders **nothing at all** when it
/// has nothing — not a placeholder, not "no recent tracks yet". A first run is
/// then a short page rather than a page full of apologies, and it grows into
/// itself as the library gets used.
///
/// # Nothing here waits on the network
///
/// Mixes, playlists, recents and rediscovery all come from the local database.
/// The page is complete and useful with the phone in aeroplane mode.
library;

import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/Themes/app_fonts.dart';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../data/library_repository.dart';
import '../../models/cloud_file.dart';
import '../../services/mixes/daily_mix_service.dart';
import '../../services/lyrics/lrclib_resolver.dart'
    show cleanTitle, normalizeArtist, primaryArtist;
import '../../services/mixes/daily_mixes.dart';
import '../../services/mixes/mix_playback.dart';
import '../../services/ytmusic/yt_models.dart';
import '../../services/ytmusic/yt_repository.dart';
import '../../services/radio/library_station.dart';
import '../../themes/ember.dart';
import '../discover/widgets/yt_widgets.dart';
import '../discover/yt_open.dart';
import 'mix_playlist_page.dart';
import 'widgets/shelf.dart';
import 'package:eq_app/navigation/library/library_tags.dart';

class HomeSurface extends StatefulWidget {
  const HomeSurface({super.key});

  @override
  State<HomeSurface> createState() => _HomeSurfaceState();
}

class _HomeSurfaceState extends State<HomeSurface> with WidgetsBindingObserver {
  DailyMixService? _mixService;

  /// Away at least this long and coming back counts as opening the app again:
  /// the mixes reshuffle. Shorter — answering a message mid-song — and they
  /// stay as they were.
  static const _freshAfter = Duration(minutes: 30);
  DateTime? _backgroundedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _playlistSource?.playlistRevision.removeListener(_reloadPlaylists);
    super.dispose();
  }

  /// The repository whose playlist changes this shelf follows — kept, because
  /// `dispose` can no longer look it up from context.
  LibraryRepository? _playlistSource;

  /// A playlist made or added to anywhere — the player's song actions, a
  /// saved mix — shows on the shelf at once.
  Future<void> _reloadPlaylists() async {
    final playlists = await _repo.playlists();
    if (mounted) setState(() => _playlists = playlists);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _backgroundedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final away = _backgroundedAt;
      _backgroundedAt = null;
      final service = _mixService;
      if (away != null &&
          service != null &&
          DateTime.now().difference(away) >= _freshAfter) {
        service.reshuffle();
        _load();
      }
    }
  }

  List<ResolvedMix> _mixes = const [];
  List<SongModel> _recent = const [];
  List<SongModel> _rediscover = const [];
  List<PlaylistSummary> _playlists = const [];

  /// YouTube Music playlists for the tastes the mixes were built from.
  List<ExploreItem> _forYou = const [];
  bool _loaded = false;

  LibraryRepository get _repo => context.read<LibraryRepository>();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Guarded: didChangeDependencies runs again on any inherited-widget change.
    if (_mixService != null) return;
    _playlistSource = _repo..playlistRevision.addListener(_reloadPlaylists);
    final controller = context.read<AppController>();
    _mixService = DailyMixService(
      _repo,
      // A drive the user has linked; empty when they have not.
      cloudLibrary: () {
        final files = <CloudFile>[];
        for (final provider in CloudProvider.values) {
          final list = controller.cloudCache.loadFileList(provider);
          if (list != null) files.addAll(list);
        }
        return files;
      },
      // Songs that go with a taste the library already has. Fails silently —
      // offline costs the variety and nothing else.
      youTube: (descriptor) async {
        // Songs and music videos both. A mix of one artist's catalogue is
        // better for having the video of the single in it, and the Videos tab
        // is otherwise the only place footage ever appears.
        final results = await Future.wait([
          YtMusicRepository.instance.search(descriptor, SearchFilter.songs),
          YtMusicRepository.instance.search(descriptor, SearchFilter.videos),
        ]);
        return [
          for (final shelf in results.first)
            for (final item in shelf.items)
              if (item.kind == ExploreKind.song) item.asTrack(),
          for (final shelf in results.last)
            for (final item in shelf.items)
              if (item.kind == ExploreKind.video) item.asTrack(),
        ];
      },
      // The related tracks YouTube Music would play after a song the user
      // actually listens to — so the streamed part of a mix follows their
      // plays, not just the name of the taste.
      youTubeRadio: _radioFor,
    );
    _load();
  }

  /// Finds [seed] on YouTube Music and returns its radio, or nothing when the
  /// song isn't there (a wrong match would seed a radio of the wrong music).
  static Future<List<YtTrack>> _radioFor(MixSeed seed) async {
    // A streamed song the user played is already a YouTube video.
    final known = seed.videoId;
    if (known != null) {
      final batch = await YtMusicRepository.instance.radio(known);
      return [
        for (final t in batch.tracks)
          if (t.videoId != known) t,
      ];
    }
    final title = cleanTitle(seed.title);
    final artist = primaryArtist(normalizeArtist(seed.artist ?? ''));
    if (title.isEmpty) return const [];
    final shelves = await YtMusicRepository.instance.search(
      artist.isEmpty ? title : '$title $artist',
      SearchFilter.songs,
    );
    final wanted = title.toLowerCase();
    YtTrack? match;
    for (final shelf in shelves) {
      for (final item in shelf.items) {
        if (item.kind != ExploreKind.song) continue;
        final found = cleanTitle(item.title).toLowerCase();
        if (found == wanted || found.contains(wanted) || wanted.contains(found)) {
          match = item.asTrack();
          break;
        }
      }
      if (match != null) break;
    }
    if (match == null) return const [];
    final batch = await YtMusicRepository.instance.radio(match.videoId);
    // The radio opens with the seed itself, which the user already owns.
    return [
      for (final t in batch.tracks)
        if (t.videoId != match.videoId) t,
    ];
  }

  Future<void> _load({bool force = false}) async {
    final service = _mixService!;
    final mixes = await service.mixes(force: force);
    final recent = await _repo.mostPlayed(limit: 12);
    final rediscover = await _repo.rediscover(limit: 12);
    final playlists = await _repo.playlists();
    if (!mounted) return;
    setState(() {
      _mixes = mixes;
      _recent = recent;
      _rediscover = rediscover;
      _playlists = playlists;
      _loaded = true;
    });

    // Behind the mixes: they're the user's own and should never wait on this.
    final session = service.variation;
    final found = await playlistsForYou(
      tastes: [
        for (final mix in mixes)
          if (!mix.seededBySong) mix.descriptor,
      ],
      related: relatedArtists(mixes),
      search: YtMusicRepository.instance.featuredPlaylists,
      coldStart: moodPlaylists,
      variation: session,
    );
    // A reshuffle since this started owns the shelf now.
    if (!mounted || service.variation != session) return;
    setState(() => _forYou = found);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final daypart = Daypart.of(DateTime.now());

    final shelves = <Widget>[
      _greeting(daypart),
      if (_mixes.isNotEmpty)
        MixShelf(
          title: 'MADE FOR YOU',
          mixes: _mixes,
          onTap: (mix) => _playMix(controller, mix),
          onSave: _saveMixAsPlaylist,
        ),
      if (_forYou.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: YtShelfRow(
            shelf: ExploreShelf(title: 'PLAYLISTS FOR YOU', items: _forYou),
            onOpen: (item) => openExploreItem(context, item),
          ),
        ),
      if (_playlists.isNotEmpty)
        PlaylistShelf(
          title: 'YOUR PLAYLISTS',
          playlists: _playlists,
          onTap: _openPlaylist,
        ),
      if (_recent.isNotEmpty)
        SongShelf(
          title: 'JUMP BACK IN',
          songs: _recent,
          onTap: (song, list) => _play(controller, list, song),
        ),
      if (_rediscover.isNotEmpty)
        SongShelf(
          title: 'REDISCOVER',
          subtitle: 'Yours, and barely played',
          songs: _rediscover,
          onTap: (song, list) => _play(controller, list, song),
        ),
    ];

    // Only the greeting: the library is empty or still scanning. Say so once,
    // rather than stacking four empty shelves.
    final isBare = shelves.length == 1;

    return RefreshIndicator(
      color: Ember.accent,
      backgroundColor: Ember.surface,
      onRefresh: () => _load(force: true),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          ...shelves,
          if (isBare && _loaded) _emptyLibrary(),
        ],
      ),
    );
  }

  Widget _greeting(Daypart daypart) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          Ember.gutter, 8, Ember.gutter, Ember.shelfGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Good ${_greetingWord(daypart)}',
            style: AppFonts.displayStyle(
              color: Ember.textPrimary,
              fontSize: 28,
              letterSpacing: -0.8,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            daypart.label,
            style: TextStyle(color: Ember.textTertiary, fontSize: 13),
          ),
        ],
      ),
    );
  }

  static String _greetingWord(Daypart daypart) => switch (daypart) {
        Daypart.earlyMorning || Daypart.morning => 'morning',
        Daypart.afternoon => 'afternoon',
        Daypart.evening => 'evening',
        Daypart.lateNight => 'evening',
      };

  Widget _emptyLibrary() {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: Ember.gutter, vertical: 48),
      child: Column(
        children: [
          Icon(Icons.library_music_outlined,
              size: 56, color: Ember.textTertiary),
          const SizedBox(height: 16),
          Text(
            'Nothing here yet',
            style: TextStyle(
              color: Ember.textSecondary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Mixes appear once there is music to build them from.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Ember.textTertiary, fontSize: 13),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------

  /// A mix may hold drive and YouTube tracks that are not playable yet, so this
  /// starts on the first one that resolves and grows behind it.
  Future<void> _playMix(AppController controller, ResolvedMix mix) async {
    if (mix.tracks.isEmpty) return;
    await AppNav.toPlayerWhileStarting(
      context,
      controller,
      () => MixPlayback.play(
        controller,
        mix,
        resolveCloud: (file) async {
          if (file.provider == CloudProvider.googleDrive) {
            return controller.googleDriveService.getStreamUrl(file.fileId);
          }
          return controller.dropboxService.getTemporaryLink(file.fileId);
        },
      ),
    );
  }

  /// A shelf is a report, not a running order, so tapping one seeds a station —
  /// the same rule search follows.
  Future<void> _play(
    AppController controller,
    List<SongModel> list,
    SongModel song,
  ) async {
    // The queue first: installing one drops the previous queue's origin, and
    // opening the player records the origin of this page for the new queue.
    final started = controller.playStation(
      song,
      LibraryStation(repo: _repo, seed: song),
    );
    AppNav.toPlayer(context);
    await started;
  }

  /// Opens an **app-owned** playlist.
  ///
  /// Deliberately not `PlaylistSongs`, which reads MediaStore: these rows can
  /// hold a drive file and a YouTube track, and their ids mean nothing there.
  void _openPlaylist(PlaylistSummary playlist) {
    AppNav.openPage(
      context,
      MixPlaylistPage(playlist: playlist),
      key: LibraryPageKey('mix', {'id': playlist.id}),
      morphFrom: itemTag(LibraryPageKey('mix', {'id': playlist.id})),
    );
  }

  /// Keeps a mix, exactly as it stands, as a playlist.
  ///
  /// A mix is rebuilt tomorrow by design — which is the point of it, and also
  /// why there has to be a way to say "not this one, I want to keep it". The
  /// entries carry their source, so a saved mix keeps its drive and YouTube
  /// tracks rather than collapsing to the local ones.
  Future<void> _saveMixAsPlaylist(ResolvedMix mix) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final id = await _repo.createPlaylist(mix.name, now);
    await _repo.addToPlaylist(
      id,
      [
        for (final ref in mix.tracks)
          PlaylistItem(
            source: switch (ref.source) {
              MixSource.cloud => 'cloud',
              MixSource.youtube => 'youtube',
              MixSource.local => 'local',
            },
            songId: ref.song?.id,
            externalId: ref.file?.fileId ?? ref.track?.videoId,
            title: ref.title,
            artist: ref.artist,
          ),
      ],
      now,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved "${mix.name}" to your playlists')),
    );
    await _load();
  }
}

/// YouTube Music playlists for what the user listens to.
///
/// One curated-playlist search per taste: the mixes' own [tastes] first, then
/// a session's pick from [related] (artists that keep turning up in those
/// mixes), so the shelf reaches a little beyond what the mixes already are and
/// changes from one session to the next. Each search keeps only its top
/// [perTaste] results in YouTube's order — further down, an artist's results
/// drift to football and country playlists. Interleaved so no taste fills the
/// shelf. With no tastes yet, [coldStart]: YouTube Music's own mood playlists,
/// curated for the listener's region. Silent on failure.
@visibleForTesting
Future<List<ExploreItem>> playlistsForYou({
  required List<String> tastes,
  List<String> related = const [],
  required Future<List<ExploreShelf>> Function(String query) search,
  required Future<List<ExploreItem>> Function() coldStart,
  required int variation,
  int maxTastes = 4,
  int perTaste = 3,
  int limit = 12,
}) async {
  final random = Random(Object.hash(variation, 'playlists'));
  final queries = <String>[];
  void add(String taste) {
    final q = taste.trim();
    if (q.isEmpty || queries.length >= maxTastes) return;
    if (queries.any((x) => x.toLowerCase() == q.toLowerCase())) return;
    queries.add(q);
  }

  for (final taste in tastes.take(maxTastes - 1)) {
    add(taste);
  }
  // At least one slot goes to a related artist when there are any.
  for (final taste in [...related.take(6)]..shuffle(random)) {
    add(taste);
  }
  for (final taste in tastes) {
    add(taste);
  }

  if (queries.isEmpty) {
    try {
      return ([...await coldStart()]..shuffle(random)).take(limit).toList();
    } catch (_) {
      return const [];
    }
  }

  final results = await Future.wait([
    for (final q in queries)
      () async {
        try {
          final shelves = await search(q);
          return [
            for (final shelf in shelves)
              for (final item in shelf.items)
                if (item.kind == ExploreKind.playlist) item,
          ].take(perTaste).toList();
        } catch (_) {
          return const <ExploreItem>[];
        }
      }(),
  ]);

  final seen = <String>{};
  final out = <ExploreItem>[];
  for (var i = 0; i < perTaste && out.length < limit; i++) {
    for (final r in results) {
      if (i < r.length && seen.add(r[i].id)) out.add(r[i]);
      if (out.length == limit) break;
    }
  }
  return out;
}

/// The artists that turn up most in [mixes] besides the mixes' own tastes —
/// what "Playlists for you" reaches out to.
List<String> relatedArtists(List<ResolvedMix> mixes) {
  final own = {
    for (final m in mixes)
      if (!m.seededBySong) m.descriptor.toLowerCase(),
  };
  final counts = <String, int>{};
  for (final mix in mixes) {
    for (final ref in mix.tracks) {
      final artist = primaryArtist(normalizeArtist(
        ref.track?.artist ?? ref.song?.artist ?? '',
      ));
      if (artist.isEmpty || own.contains(artist.toLowerCase())) continue;
      counts[artist] = (counts[artist] ?? 0) + 1;
    }
  }
  final ranked = counts.keys.toList()
    ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  return ranked;
}

/// Mood playlists YouTube Music curates for the listener's region — for a
/// Home with no tastes to search yet.
Future<List<ExploreItem>> moodPlaylists() async {
  final repo = YtMusicRepository.instance;
  final sections = await repo.cachedCategories() ?? await repo.categories();
  final moods = sections.isEmpty ? const <ExploreCategory>[] : sections.first.categories;
  final pages = await Future.wait([
    for (final mood in moods.take(2)) repo.categoryPage(mood),
  ]);
  return [
    for (final page in pages)
      for (final shelf in page)
        for (final item in shelf.items)
          if (item.kind == ExploreKind.playlist) item,
  ];
}
