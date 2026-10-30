/// One playlist or album, opened into its tracks.
///
/// Listing rather than playing is the point — see `yt_open.dart`. "Play"
/// starts at the top and therefore queues the whole list; tapping a track starts
/// from that track, because a queue that grows behind the music can only extend
/// forwards without interrupting it.
///
/// # The header
///
/// The cover is the page: drawn large, and again behind everything, blurred
/// into the ground — a still image, so `ImageFiltered` rather than a live
/// backdrop. Under it the title, who made it (each artist a link to their
/// page, the first with their portrait), what it is and how long, and the
/// three things to do with it: shuffle, play, download.
///
/// An album lists its tracks by number, the way its sleeve does; a playlist
/// shows each track's own art. Whichever track is playing is marked, so
/// arriving here from the player ("Go to album") shows where the song sits.
library;

import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/app_config.dart';
import '../../controllers/app_controller.dart';
import '../../models/track_extras.dart';
import '../../Routes/routes.dart';
import '../../services/ytmusic/parse/yt_json.dart';
import '../../services/ytmusic/parse/yt_tracks.dart';
import '../../services/ytmusic/yt_models.dart';
import '../../services/ytmusic/yt_playback.dart';
import '../../services/ytmusic/yt_repository.dart';
import '../../themes/ember.dart';
import 'artist_page.dart';
import 'widgets/media_widgets.dart';
import 'widgets/yt_hero.dart';
import 'widgets/yt_widgets.dart';
import 'yt_open.dart';

class YtOpenedListPage extends StatefulWidget {
  final ExploreItem item;

  /// A track to bring into view once the list arrives — the song the player
  /// was on when "Go to album" was chosen.
  final String? highlightVideoId;

  const YtOpenedListPage({
    super.key,
    required this.item,
    this.highlightVideoId,
  });

  @override
  State<YtOpenedListPage> createState() => _YtOpenedListPageState();
}

class _YtOpenedListPageState extends State<YtOpenedListPage> {
  YtTrackList? _list;
  bool _loading = true;
  String? _error;
  final _scroll = ScrollController();

  bool get _isAlbum => widget.item.kind == ExploreKind.album;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await YtMusicRepository.instance.openList(widget.item);
      if (!mounted) return;
      setState(() {
        _list = list;
        _loading = false;
      });
      // Resolve the top of the list while the user is still reading it, so the
      // tap that follows costs nothing.
      YtMusicRepository.instance.prefetchAudio([
        for (final track in list.tracks) track.videoId,
      ]);
      _revealHighlight(list.tracks);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is YtException ? e.message : 'Could not open that.';
      });
    }
  }

  /// Scrolls the highlighted track into view when it sits below the fold.
  void _revealHighlight(List<YtTrack> tracks) {
    final id = widget.highlightVideoId;
    if (id == null) return;
    final index = _indexOf(tracks, id);
    if (index < 6) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = mediaListHeroHeight(context) + 64 + index * _rowHeight - 160;
      _scroll.animateTo(
        math.min(target, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOutCubic,
      );
    });
  }

  /// An album lists its own upload of a song, which can be another video
  /// than the one the player has — so the title stands in when the id
  /// doesn't match.
  int _indexOf(List<YtTrack> tracks, String videoId, {String? title}) {
    final byId = tracks.indexWhere((t) => t.videoId == videoId);
    if (byId >= 0 || title == null) return byId;
    final wanted = title.toLowerCase();
    return tracks.indexWhere((t) => t.title.toLowerCase() == wanted);
  }

  static const _rowHeight = 60.0;

  @override
  Widget build(BuildContext context) {
    final list = _list;
    final tracks = list?.tracks ?? const <YtTrack>[];
    final title = list?.title ?? widget.item.title;
    // Only what is playing, so the page rebuilds when the song changes and
    // not on everything else the controller reports.
    final current = context
        .select<AppController, ({String? id, String? title})>((c) {
          final index = c.songId;
          if (index < 0 || index >= c.songs.length) {
            return (id: null, title: null);
          }
          final song = c.songs[index];
          return (id: song.ytVideoId, title: song.title);
        });
    final currentIndex = current.id == null
        ? -1
        : _indexOf(tracks, current.id!, title: _isAlbum ? current.title : null);
    final player = context.read<AppController>().handler.player;

    return MediaPageScaffold(
      controller: _scroll,
      title: title,
      heroHeight: mediaListHeroHeight,
      background: _Hero(
        item: widget.item,
        list: list,
        isAlbum: _isAlbum,
        onPlay: tracks.isEmpty
            ? null
            : () => YtPlayback.play(context, tracks, 0),
        onShuffle: tracks.isEmpty
            ? null
            : () => YtPlayback.play(context, [...tracks]..shuffle(), 0),
        onDownload: tracks.isEmpty
            ? null
            : () => startPlaylistDownload(context, tracks),
      ),
      slivers: [
          if (_loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: YtTrackSkeleton(),
            )
          else if (_error case final String message)
            SliverFillRemaining(
              hasScrollBody: false,
              child: YtMessage(
                icon: Icons.error_outline_rounded,
                title: "That didn't open",
                body: message,
                onRetry: _load,
              ),
            )
          else if (tracks.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: YtMessage(
                icon: Icons.inbox_rounded,
                title: 'No tracks here',
                body: 'YouTube lists nothing playable in this one.',
                onRetry: _load,
              ),
            )
          else ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              sliver: SliverFixedExtentList(
                itemExtent: _rowHeight,
                delegate: SliverChildBuilderDelegate(
                  childCount: tracks.length,
                  (context, index) => _isAlbum
                      ? _albumRow(
                          context,
                          tracks,
                          index,
                          albumArtist: list?.artist,
                          current: index == currentIndex,
                          playing: player.playingStream,
                        )
                      : MediaHighlight(
                          current: index == currentIndex,
                          child: YtTrackRow(
                            track: tracks[index],
                            position: index + 1,
                            onTap: () =>
                                YtPlayback.play(context, tracks, index),
                            onMore: () =>
                                showTrackActions(context, tracks[index]),
                          ),
                        ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 110),
                child: Text(
                  list?.stats ?? _countLabel(tracks.length),
                  style: TextStyle(color: Ember.textTertiary, fontSize: 12.5),
                ),
              ),
            ),
          ],
      ],
    );
  }

  static String _countLabel(int n) => n == 1 ? '1 song' : '$n songs';
}

/// The page's header: the cover large and blurred behind, then the facts and
/// the three buttons.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.item,
    required this.list,
    required this.isAlbum,
    required this.onPlay,
    required this.onShuffle,
    required this.onDownload,
  });

  final ExploreItem item;
  final YtTrackList? list;
  final bool isAlbum;
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final cover = list?.thumbnail ?? item.thumbnail;
    return MediaListHero(
      kicker: isAlbum ? _kind(list?.subtitle) ?? 'ALBUM' : 'PLAYLIST',
      title: list?.title ?? item.title,
      credits: _credits(context),
      facts: _facts,
      art: (size) => YtArtwork(url: cover, size: size),
      backdrop: cover == null
          ? null
          : CachedNetworkImage(
              imageUrl: thumbnailAt(cover, 200),
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => const SizedBox.shrink(),
            ),
      actions: [
        if (AppConfig.directBuild)
          YtRoundButton(
            icon: Icons.download_rounded,
            tooltip: 'Download all',
            onTap: onDownload,
          ),
        YtRoundButton(
          icon: Icons.play_arrow_rounded,
          tooltip: 'Play',
          size: 64,
          primary: true,
          onTap: onPlay,
        ),
        YtRoundButton(
          icon: Icons.shuffle_rounded,
          tooltip: 'Shuffle',
          onTap: onShuffle,
        ),
      ],
    );
  }

  /// "Album • 2019" → "ALBUM"; an EP or single says so.
  static String? _kind(String? subtitle) {
    final first = subtitle?.split('•').first.trim();
    return first == null || first.isEmpty ? null : first.toUpperCase();
  }

  /// "2019 • 12 songs • 42 minutes": the year from the subtitle, the rest
  /// as YouTube counts it.
  String? get _facts {
    final parts = <String>[
      ...?list?.subtitle?.split('•').skip(1).map((p) => p.trim()),
      ?list?.stats,
    ].where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? null : parts.join(' • ');
  }

  /// Who made it: each credited artist a link to their page, the first with
  /// their portrait.
  Widget _credits(BuildContext context) {
    final artists = list?.artists ?? const <YtArtistRef>[];
    if (artists.isEmpty) {
      final text = list?.artist ?? item.artist ?? item.subtitle;
      if (text == null) return const SizedBox.shrink();
      return MediaCreditText(text);
    }
    return MediaCredits(
      children: [
        for (var i = 0; i < artists.length; i++)
          _chip(context, artists[i], i == 0 ? list?.artistThumbnail : null),
      ],
    );
  }

  Widget _chip(BuildContext context, YtArtistRef artist, String? portrait) {
    final target = artist.asItem(thumbnail: portrait);
    return MediaCreditChip(
      name: artist.name,
      portrait: portrait == null
          ? null
          : YtArtwork(url: portrait, size: 24, circular: true),
      onTap: target == null
          ? null
          : () => Routes.routeTo(YtArtistPage(item: target), context),
    );
  }
}

/// A track on an album: its number — or, playing, the bars — then its title,
/// any guests, and its length.
Widget _albumRow(
  BuildContext context,
  List<YtTrack> tracks,
  int index, {
  required String? albumArtist,
  required bool current,
  required Stream<bool> playing,
}) {
  final track = tracks[index];
  // The album's own artist goes without saying; guests are worth reading.
  final byline = track.artist != null && track.artist != albumArtist
      ? track.artist
      : null;
  return MediaAlbumRow(
    number: index + 1,
    title: track.title,
    byline: byline,
    duration: mediaClock(track.durationSecs),
    hasVideo: track.hasVideo,
    dimmed: !track.isAvailable,
    current: current,
    playing: playing,
    onTap: () => YtPlayback.play(context, tracks, index),
    onMore: () => showTrackActions(context, track),
  );
}
