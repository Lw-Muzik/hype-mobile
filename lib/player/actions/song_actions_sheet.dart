/// What can be done with the playing song — a long press on the player's
/// cover away.
///
/// # What it offers depends on where the song comes from
///
/// A YouTube Music stream can be downloaded, and its album and artists are
/// YouTube Music's pages, found from the track itself. A file on the phone
/// goes to the library's own album and artist, can be identified from its
/// sound and given a better cover. A drive file can be identified and given a
/// cover. Every one of them can go in a playlist and start a radio. Nothing
/// is offered that would only fail: identifying a stream YouTube has already
/// named, finding a cover for a stream that came with one.
///
/// # One panel
///
/// Choosing a playlist, an artist or a cover happens on pages of the same
/// panel, which reshapes around each (see `PageMorph`), so the sheet never
/// stacks a second sheet over itself.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:provider/provider.dart';

import '../../Helpers/Channel.dart';
import '../../Routes/routes.dart';
import '../../config/app_config.dart';
import '../../controllers/app_controller.dart';
import '../../data/library_repository.dart';
import '../../models/cloud_file.dart';
import '../../models/track_extras.dart';
import '../../pages/album_songs.dart';
import '../../pages/artist_songs.dart';
import '../../pages/discover/artist_page.dart';
import '../../pages/discover/opened_list_page.dart';
import '../../pages/discover/yt_open.dart';
import '../../pages/home/mix_playlist_page.dart';
import '../../services/radio/library_station.dart';
import '../../services/radio/station_source.dart';
import '../../services/radio/youtube_station.dart';
import '../../services/ytmusic/parse/yt_track_info.dart';
import '../../services/ytmusic/yt_download.dart';
import '../../services/ytmusic/yt_downloads.dart';
import '../../services/ytmusic/yt_models.dart';
import '../../services/ytmusic/yt_repository.dart';
import '../../themes/ember.dart';
import '../../widgets/artwork_widget.dart';
import 'frosted_sheet.dart';
import 'liquid_fill.dart';
import 'motion.dart';
import 'sheet_parts.dart';
import 'song_action_pages.dart';
import 'vinyl_cover.dart';

/// Opens the song actions for what [controller] is playing, over the player
/// at [context].
Future<void> showSongActions(
  BuildContext context,
  AppController controller,
) async {
  final songs = controller.songs;
  final index = controller.songId;
  if (index < 0 || index >= songs.length) return;
  HapticFeedback.mediumImpact();
  await showFrostedSheet<void>(
    context,
    builder: (_) => SongActionsSheet(
      host: context,
      controller: controller,
      song: songs[index],
    ),
  );
}

/// The song the sheet is about, and where it comes from — which decides what
/// can be done with it.
class SongSubject {
  const SongSubject(this.song);

  final SongModel song;

  String? get videoId => song.ytVideoId;
  bool get isYouTube => videoId != null;
  bool get isVideo => song.isYtVideo;
  bool get isCloud => !isYouTube && song.data.startsWith('http');
  bool get isDevice => !isYouTube && !isCloud;

  String get title => song.title;

  /// Who it's by — null for the placeholders the media library and the
  /// YouTube path write when they don't know.
  String? get artist {
    final value = song.artist?.trim();
    if (value == null || value.isEmpty) return null;
    const unknown = {'<unknown>', 'unknown', 'unknown artist', 'youtube music'};
    return unknown.contains(value.toLowerCase()) ? null : value;
  }

  /// The album a file names. A stream carries its art's URL in that field
  /// instead, which is not an album.
  String? get album {
    final value = song.album?.trim();
    if (value == null || value.isEmpty || value.startsWith('http')) {
      return null;
    }
    const unknown = {'<unknown>', 'unknown', 'unknown album'};
    return unknown.contains(value.toLowerCase()) ? null : value;
  }

  /// A stream's artwork URL (kept in `album`, see above).
  String? get artworkUrl {
    final value = song.album;
    return value != null && value.startsWith('http') ? value : null;
  }

  Duration? get duration {
    final ms = song.duration ?? 0;
    return ms > 0 ? Duration(milliseconds: ms) : null;
  }

  /// The stream as YouTube Music's own model, filled in from [info] where
  /// the queue entry is thin.
  YtTrack ytTrack(YtTrackInfo? info) => YtTrack(
    videoId: videoId!,
    title: title,
    artist: artist ?? info?.artist,
    album: info?.album,
    durationSecs: duration != null
        ? duration!.inMilliseconds / 1000
        : info?.durationSecs,
    thumbnail: artworkUrl ?? info?.thumbnail,
    hasVideo: isVideo,
  );
}

enum SheetPage { main, playlists, artists, identify, artwork }

class SongActionsSheet extends StatefulWidget {
  const SongActionsSheet({
    super.key,
    required this.host,
    required this.controller,
    required this.song,
  });

  /// The player under the sheet: where pages open and notices show once the
  /// sheet has gone.
  final BuildContext host;
  final AppController controller;
  final SongModel song;

  @override
  State<SongActionsSheet> createState() => _SongActionsSheetState();
}

class _SongActionsSheetState extends State<SongActionsSheet> {
  late final SongSubject _subject = SongSubject(widget.song);

  SheetPage _page = SheetPage.main;
  bool _forward = true;

  /// What YouTube Music says about a stream: its album, every artist with
  /// their channel. Asked for as the sheet opens.
  YtTrackInfo? _info;
  bool _infoLoading = false;

  /// Where a stream already is on the phone, if it is.
  String? _localCopy;

  /// An artist credited without a link, being looked up by name.
  String? _findingArtist;

  /// A short message shown in the panel itself while it stays open.
  String? _notice;
  Timer? _noticeTimer;

  @override
  void initState() {
    super.initState();
    if (_subject.isYouTube) {
      _loadInfo();
      _checkLocalCopy();
      YtDownloads.instance.changes.addListener(_onDownloadsChanged);
    }
  }

  @override
  void dispose() {
    YtDownloads.instance.changes.removeListener(_onDownloadsChanged);
    _noticeTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadInfo() async {
    setState(() => _infoLoading = true);
    YtTrackInfo? info;
    try {
      info = await YtMusicRepository.instance
          .trackInfo(_subject.videoId!)
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      // Offline or refused: the rows that needed it fall back to what the
      // queue entry knows, or step aside.
    }
    if (!mounted) return;
    setState(() {
      _info = info;
      _infoLoading = false;
    });
  }

  void _onDownloadsChanged() {
    if (!mounted) return;
    setState(() {});
    _checkLocalCopy();
  }

  Future<void> _checkLocalCopy() async {
    final path = await YtDownloads.instance.localCopy(
      _subject.videoId!,
      title: _subject.title,
      artist: _subject.artist,
    );
    if (mounted && path != _localCopy) setState(() => _localCopy = path);
  }

  void _open(SheetPage page) => setState(() {
    _forward = page != SheetPage.main;
    _page = page;
  });

  void _back() => _open(SheetPage.main);

  /// A message in the panel, for things said while it stays open.
  void _say(String message) {
    _noticeTimer?.cancel();
    setState(() => _notice = message);
    _noticeTimer = Timer(const Duration(milliseconds: 2400), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  /// A message on the player, for things said as the sheet closes.
  void _snack(String message, {SnackBarAction? action}) {
    if (!widget.host.mounted) return;
    ScaffoldMessenger.of(widget.host).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(message),
        action: action,
      ),
    );
  }

  /// Closes the sheet and opens [page] over the player — back returns there.
  void _navigate(Widget page) {
    final host = widget.host;
    Navigator.of(context).pop();
    if (host.mounted) Routes.routeTo(page, host);
  }

  // ---------------------------------------------------------------------------
  // Layout
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final inset = MediaQuery.viewPaddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard > 0 ? keyboard : inset),
      child: GlassPanel(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetHandle(),
            _noticeBar(),
            Flexible(
              child: SingleChildScrollView(
                child: PageMorph(
                  pageKey: _page,
                  forward: _forward,
                  child: switch (_page) {
                    SheetPage.main => _mainPage(),
                    SheetPage.playlists => _playlistsPage(),
                    SheetPage.artists => ArtistPickerPage(
                      artists: _ytArtists,
                      busy: _findingArtist,
                      onBack: _back,
                      onPick: _openYtArtist,
                    ),
                    SheetPage.identify => IdentifyPage(
                      song: widget.song,
                      onBack: _back,
                      onApplied: () {
                        _back();
                        _say('Tags and artwork updated');
                      },
                    ),
                    SheetPage.artwork => ArtworkPickerPage(
                      song: widget.song,
                      title: _subject.title,
                      artist: _subject.artist,
                      onBack: _back,
                      onChosen: () {
                        _back();
                        _say('Artwork updated');
                      },
                    ),
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _noticeBar() {
    return AnimatedSize(
      duration: const Duration(milliseconds: 320),
      curve: const SpringCurve(dampingRatio: 0.7),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: _notice == null
            ? const SizedBox(width: double.infinity)
            : Padding(
                key: ValueKey(_notice),
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 2),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Ember.accentWash,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Ember.accent.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.check_rounded,
                        size: 16,
                        color: Ember.accent,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          _notice!,
                          style: const TextStyle(
                            color: Ember.accent,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _mainPage() {
    final actions = _quickActions();
    final rows = _rows();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Cascade(index: 0, child: _header()),
        Cascade(
          index: 1,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(child: actions[i]),
                ],
              ],
            ),
          ),
        ),
        if (rows.isNotEmpty)
          Cascade(index: 2, child: ActionGroup(children: rows)),
        const SizedBox(height: 12),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Header
  // ---------------------------------------------------------------------------

  Widget _header() {
    final s = _subject;
    final song = widget.song;
    final cover = ArtworkWidget(
      songId: song.id,
      path: song.data,
      width: 68,
      height: 68,
      size: 500,
      quality: 100,
      borderRadius: BorderRadius.zero,
    );
    final artist = s.isYouTube ? (_info?.artist ?? s.artist) : s.artist;
    final player = widget.controller.handler.player;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 18),
      child: Row(
        children: [
          StreamBuilder<bool>(
            stream: player.playingStream,
            initialData: player.playing,
            builder: (context, playing) => VinylCover(
              cover: cover,
              spinning: (playing.data ?? false) && _stillPlaying,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Ember.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  artist ?? 'Unknown artist',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: glassWhite(0.72),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (_meta case final meta?) ...[
                  const SizedBox(height: 2),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    child: Text(
                      meta,
                      key: ValueKey(meta),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: glassWhite(0.45), fontSize: 12.5),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                _sourceChip(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Whether the sheet's song is still the one the player is on.
  bool get _stillPlaying {
    final songs = widget.controller.songs;
    final index = widget.controller.songId;
    return index >= 0 &&
        index < songs.length &&
        songs[index].id == widget.song.id;
  }

  /// "Album • 2019 • 3:12", from what is known.
  String? get _meta {
    final s = _subject;
    final parts = <String>[
      if (s.isYouTube) ...[
        ?_info?.album,
        if (_info?.year case final year?) '$year',
      ] else
        ?s.album,
      if (s.duration ?? _infoDuration case final d?) _clock(d),
    ];
    return parts.isEmpty ? null : parts.join(' • ');
  }

  /// A queue entry from a shelf can arrive without its length; YouTube
  /// Music's own details have it.
  Duration? get _infoDuration {
    final seconds = _info?.durationSecs;
    return seconds == null || seconds <= 0
        ? null
        : Duration(milliseconds: (seconds * 1000).round());
  }

  static String _clock(Duration d) {
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
      return '${d.inHours}:$minutes:$seconds';
    }
    return '${d.inMinutes}:$seconds';
  }

  Widget _sourceChip() {
    final s = _subject;
    if (s.isYouTube) {
      // Store builds don't name or colour the stream as YouTube's.
      if (!AppConfig.directBuild) {
        return SourceChip(
          icon: s.isVideo ? Icons.smart_display_rounded : Icons.wifi_rounded,
          label: s.isVideo ? 'Music video' : 'Streaming',
        );
      }
      return SourceChip(
        icon: s.isVideo
            ? Icons.smart_display_rounded
            : Icons.play_circle_fill_rounded,
        iconColor: const Color(0xFFFF2D3B),
        label: s.isVideo ? 'Music video' : 'YouTube Music',
      );
    }
    if (s.isCloud) {
      return const SourceChip(icon: Icons.cloud_rounded, label: 'Your drive');
    }
    return const SourceChip(
      icon: Icons.smartphone_rounded,
      label: 'On this device',
    );
  }

  // ---------------------------------------------------------------------------
  // Quick actions
  // ---------------------------------------------------------------------------

  List<Widget> _quickActions() {
    final s = _subject;
    return [
      if (s.isYouTube && AppConfig.directBuild) _downloadAction(),
      QuickAction(
        icon: Icons.playlist_add_rounded,
        label: 'Playlist',
        onTap: _playlistItem() == null
            ? null
            : () => _open(SheetPage.playlists),
      ),
      QuickAction(
        icon: Icons.radio_rounded,
        label: 'Radio',
        onTap: _startRadio,
      ),
      if (!s.isCloud)
        QuickAction(
          icon: Icons.ios_share_rounded,
          label: 'Share',
          onTap: _share,
        ),
    ];
  }

  Widget _downloadAction() {
    final videoId = _subject.videoId!;
    final progress = YtDownloads.instance.progressOf(videoId);
    if (progress != null) {
      return ValueListenableBuilder<double?>(
        valueListenable: progress,
        builder: (context, value, _) => QuickAction(
          icon: Icons.downloading_rounded,
          label: value == null ? 'Starting…' : '${(value * 100).round()}%',
          onTap: () => _say('Downloading — it carries on if you close this'),
          background: LiquidFill(
            level: value,
            color: Ember.accent.withValues(alpha: 0.28),
            child: const SizedBox.expand(),
          ),
        ),
      );
    }
    if (_localCopy != null) {
      return QuickAction(
        icon: Icons.download_done_rounded,
        label: 'Downloaded',
        active: true,
        onTap: () => _say('Already in your library'),
      );
    }
    return QuickAction(
      icon: Icons.download_rounded,
      label: 'Download',
      onTap: _download,
    );
  }

  void _download() {
    final track = _subject.ytTrack(_info);
    // The snack bar on the player reports how it ended, sheet open or not.
    startDownload(widget.host, track, showProgress: false);
    YtDownloads.instance.download(track).then((result) {
      if (result is YtDownloadSaved && mounted) {
        setState(() => _localCopy = result.path);
      }
    });
    setState(() {});
  }

  /// The song as a playlist keeps it, or null when it can't be kept — a
  /// drive file this phone has no listing of any more.
  PlaylistItem? _playlistItem() {
    final s = _subject;
    if (s.isYouTube) {
      return PlaylistItem(
        source: 'youtube',
        externalId: s.videoId,
        title: s.title,
        artist: s.artist ?? _info?.artist,
      );
    }
    if (s.isCloud) {
      final file = _cloudFile();
      if (file == null) return null;
      return PlaylistItem(
        source: 'cloud',
        externalId: file.fileId,
        title: s.title,
        artist: s.artist,
      );
    }
    return PlaylistItem(
      source: 'local',
      songId: widget.song.id,
      title: s.title,
      artist: s.artist,
    );
  }

  /// The drive file behind a cloud entry: its queue id is the file id's hash.
  CloudFile? _cloudFile() {
    for (final provider in CloudProvider.values) {
      final files = widget.controller.cloudCache.loadFileList(provider);
      for (final file in files ?? const <CloudFile>[]) {
        if (file.fileId.hashCode.abs() == widget.song.id) return file;
      }
    }
    return null;
  }

  Widget _playlistsPage() {
    final item = _playlistItem()!;
    return PlaylistPickerPage(
      item: item,
      onBack: _back,
      onAdded: (playlist, {required already}) {
        Navigator.of(context).pop();
        final host = widget.host;
        _snack(
          already ? 'Already in ${playlist.name}' : 'Added to ${playlist.name}',
          action: SnackBarAction(
            label: 'View',
            onPressed: () {
              if (host.mounted) {
                Routes.scaleTo(MixPlaylistPage(playlist: playlist), host);
              }
            },
          ),
        );
      },
    );
  }

  Future<void> _startRadio() async {
    final s = _subject;
    final controller = widget.controller;
    final StationSource source = s.isYouTube
        ? YouTubeStation(seed: s.videoId!)
        : LibraryStation(
            repo: context.read<LibraryRepository>(),
            seed: widget.song,
          );
    final playing = _stillPlaying;
    Navigator.of(context).pop();
    _snack('Radio on: more like "${s.title}" is up next');
    if (playing) {
      await controller.continueAsStation(source);
    } else {
      await controller.playStation(widget.song, source);
    }
  }

  Future<void> _share() async {
    final s = _subject;
    Navigator.of(context).pop();
    final bool shared;
    if (s.isYouTube) {
      final by = s.artist ?? _info?.artist;
      final name = '${s.title}${by == null ? '' : ' — $by'}';
      shared = await Channel.shareText(
        AppConfig.directBuild
            ? '$name\nhttps://music.youtube.com/watch?v=${s.videoId}'
            // Store builds don't hand out YouTube links.
            : '$name\nPlaying on HypeMuzik: https://hypemuzik.com',
      );
    } else {
      shared = await Channel.shareAudio(widget.song.data);
    }
    if (!shared) _snack("This song can't be shared from here");
  }

  // ---------------------------------------------------------------------------
  // Going places
  // ---------------------------------------------------------------------------

  List<Widget> _rows() {
    final s = _subject;
    final rows = <Widget>[];
    if (s.isYouTube) {
      final album = _info?.album;
      if (_infoLoading || (album != null && _info?.albumId != null)) {
        rows.add(
          ActionRow(
            icon: Icons.album_rounded,
            title: 'Go to album',
            subtitle: album ?? 'Finding the album…',
            busy: _infoLoading,
            onTap: _openYtAlbum,
          ),
        );
      }
      final artists = _ytArtists;
      if (_infoLoading || artists.isNotEmpty) {
        rows.add(
          ActionRow(
            icon: Icons.person_rounded,
            title: artists.length > 1 ? 'Go to artists' : 'Go to artist',
            subtitle: artists.isEmpty
                ? 'Finding the artist…'
                : artists.map((a) => a.name).join(', '),
            busy: _infoLoading || _findingArtist != null,
            onTap: _openYtArtists,
          ),
        );
      }
      return rows;
    }
    if (s.isDevice) {
      if (s.album != null) {
        rows.add(
          ActionRow(
            icon: Icons.album_rounded,
            title: 'Go to album',
            subtitle: s.album,
            onTap: _openLocalAlbum,
          ),
        );
      }
      if (s.artist != null) {
        rows.add(
          ActionRow(
            icon: Icons.person_rounded,
            title: 'Go to artist',
            subtitle: s.artist,
            onTap: _openLocalArtist,
          ),
        );
      }
    }
    rows.add(
      ActionRow(
        icon: Icons.fingerprint_rounded,
        title: 'Identify track',
        subtitle: 'Name it from its sound',
        onTap: () => _open(SheetPage.identify),
      ),
    );
    rows.add(
      ActionRow(
        icon: Icons.image_search_rounded,
        title: 'Find artwork',
        subtitle: 'Choose a better cover',
        onTap: () => _open(SheetPage.artwork),
      ),
    );
    return rows;
  }

  /// A stream's artists: YouTube Music's credits, each with their channel;
  /// failing those, the queue entry's artist, to be found by name.
  List<YtArtistRef> get _ytArtists {
    final credited = _info?.artists ?? const <YtArtistRef>[];
    if (credited.isNotEmpty) return credited;
    final name = _subject.artist;
    return name == null || _infoLoading ? const [] : [YtArtistRef(name)];
  }

  void _openYtAlbum() {
    final info = _info;
    final albumId = info?.albumId;
    if (info == null || albumId == null) return;
    _navigate(
      YtOpenedListPage(
        item: ExploreItem(
          id: albumId,
          kind: ExploreKind.album,
          title: info.album ?? '',
          thumbnail: info.isSong ? info.thumbnail : null,
          artist: info.artist,
        ),
        highlightVideoId: _subject.videoId,
      ),
    );
  }

  Future<void> _openYtArtists() async {
    final artists = _ytArtists;
    if (artists.length > 1) {
      _open(SheetPage.artists);
    } else if (artists.length == 1) {
      await _openYtArtist(artists.single);
    }
  }

  Future<void> _openYtArtist(YtArtistRef artist) async {
    var item = artist.asItem();
    if (item == null) {
      setState(() => _findingArtist = artist.name);
      item = await _searchArtist(artist.name);
      if (!mounted) return;
      setState(() => _findingArtist = null);
      if (item == null) {
        _say(AppConfig.directBuild
            ? "Couldn't find ${artist.name} on YouTube Music"
            : "Couldn't find ${artist.name}");
        return;
      }
    }
    _navigate(YtArtistPage(item: item));
  }

  /// An artist YouTube credited without linking: the search result named
  /// exactly that, else the first.
  static Future<ExploreItem?> _searchArtist(String name) async {
    try {
      final shelves = await YtMusicRepository.instance
          .search(name, SearchFilter.artists)
          .timeout(const Duration(seconds: 15));
      final found = [
        for (final shelf in shelves)
          for (final item in shelf.items)
            if (item.kind == ExploreKind.artist) item,
      ];
      if (found.isEmpty) return null;
      final wanted = name.toLowerCase();
      return found.firstWhere(
        (item) => item.title.toLowerCase() == wanted,
        orElse: () => found.first,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _openLocalAlbum() async {
    final album = _subject.album!;
    final songs = await context
        .read<LibraryRepository>()
        .watchAlbumSongs(album)
        .first;
    if (!mounted) return;
    _navigate(
      AlbumSongs(
        albumId: widget.song.albumId,
        album: album,
        songs: songs.length,
        coverSongId: widget.song.id,
        coverPath: widget.song.data,
      ),
    );
  }

  Future<void> _openLocalArtist() async {
    final artist = _subject.artist!;
    final songs = await context
        .read<LibraryRepository>()
        .watchArtistSongs(artist)
        .first;
    if (!mounted) return;
    _navigate(
      ArtistSongs(
        artistId: widget.song.artistId,
        artist: artist,
        songs: songs.length,
        albums: {for (final song in songs) song.album}.length,
        coverSongId: widget.song.id,
        coverPath: widget.song.data,
      ),
    );
  }
}
