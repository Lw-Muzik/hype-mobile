/// An artist from the library.
///
/// The same page as the YouTube Music artist (`discover/artist_page.dart`): the
/// portrait round over itself blurred, the name over it, Play / Shuffle and —
/// where YouTube has Radio — Play next; then their top songs five at a time and
/// their albums as a shelf. YouTube's other shelves have nothing local to show
/// and are left out.
library;

import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:provider/provider.dart';

import '../Routes/routes.dart';
import '../controllers/app_controller.dart';
import '../data/library_repository.dart';
import 'album_songs.dart';
import 'discover/widgets/local_media.dart';
import 'discover/widgets/media_widgets.dart';
import 'discover/widgets/yt_hero.dart';
import 'discover/widgets/yt_widgets.dart';

class ArtistSongs extends StatefulWidget {
  final int? artistId;

  /// A song whose cover stands in when there is no artist id to look art up
  /// by — a artist reached from the player, for a file the media library
  /// never gave one.
  final int? coverSongId;
  final String coverPath;
  final int songs;
  final int albums;
  final String artist;

  const ArtistSongs({
    super.key,
    required this.artistId,
    this.coverSongId,
    this.coverPath = '',
    required this.artist,
    required this.songs,
    required this.albums,
  });

  @override
  State<ArtistSongs> createState() => _ArtistSongsState();
}

int _plays(SongModel s) => (s.getMap['play_count'] as num?)?.toInt() ?? 0;

/// One album by this artist, as the shelf shows it.
class _LocalAlbum {
  _LocalAlbum(this.name, this.songs);
  final String name;
  final List<SongModel> songs;
  SongModel get first => songs.first;
}

class _ArtistSongsState extends State<ArtistSongs> {
  late final Stream<List<SongModel>> _songsStream = context
      .read<LibraryRepository>()
      .watchArtistSongs(widget.artist);

  /// Most played first; with nothing played yet, the library's own order.
  List<SongModel> _top(List<SongModel> songs) {
    final played = songs.where((s) => _plays(s) > 0).toList()
      ..sort((a, b) => _plays(b).compareTo(_plays(a)));
    return played.isEmpty ? songs : played;
  }

  List<_LocalAlbum> _albums(List<SongModel> songs) {
    final byName = <String, List<SongModel>>{};
    for (final s in songs) {
      final name = (s.album ?? '').trim();
      byName.putIfAbsent(name.isEmpty ? 'Unknown Album' : name, () => []).add(s);
    }
    return [for (final e in byName.entries) _LocalAlbum(e.key, e.value)];
  }

  List<LocalArtSource> _portrait(List<SongModel> songs) => [
    if (widget.artistId != null)
      LocalArtSource(
        id: widget.artistId!,
        type: ArtworkType.ARTIST,
        other: widget.artist,
      ),
    if (songs.isNotEmpty)
      LocalArtSource.song(_top(songs).first)
    else if (widget.coverSongId != null)
      LocalArtSource(id: widget.coverSongId!, data: widget.coverPath),
  ];

  @override
  Widget build(BuildContext context) {
    final controller = context.read<AppController>();
    final currentId = currentLocalSongId(context);
    return StreamBuilder<List<SongModel>>(
      stream: _songsStream,
      builder: (context, snapshot) {
        final songs = snapshot.data ?? const <SongModel>[];
        final loading = !snapshot.hasData;
        final enabled = songs.isNotEmpty;
        final albums = _albums(songs);
        final portrait = _portrait(songs);
        final stats = songs.isEmpty
            ? ''
            : [
                songs.length == 1 ? '1 song' : '${songs.length} songs',
                albums.length == 1 ? '1 album' : '${albums.length} albums',
              ].join(' • ');
        return MediaPageScaffold(
          title: widget.artist,
          heroHeight: mediaArtistHeroHeight,
          bottomBar: const LocalMiniPlayerBar(),
          background: MediaArtistHero(
            name: widget.artist,
            stats: stats,
            washWhenEmpty: true,
            backdrop: LocalArtwork(sources: portrait, fillDecodeWidth: 160),
            portrait: LocalArtwork(
              sources: portrait,
              size: 132,
              circular: true,
              placeholder: Icons.person_rounded,
            ),
          ),
          slivers: [
            if (loading)
              const SliverFillRemaining(
                child: YtSkeleton(),
              )
            else if (songs.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: YtMessage(
                  icon: Icons.inbox_rounded,
                  title: 'No songs found',
                  body: 'Nothing in your library is by this artist.',
                ),
              )
            else ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Row(
                    children: [
                      YtRoundButton(
                        icon: Icons.play_arrow_rounded,
                        tooltip: 'Play',
                        size: 58,
                        primary: true,
                        onTap: () => controller.playSongFromList(songs, 0),
                      ),
                      const SizedBox(width: 14),
                      YtRoundButton(
                        icon: Icons.shuffle_rounded,
                        tooltip: 'Shuffle',
                        onTap: () => controller.playSongFromList(
                          [...songs]..shuffle(),
                          0,
                        ),
                      ),
                      const SizedBox(width: 14),
                      YtRoundButton(
                        icon: Icons.playlist_play_rounded,
                        tooltip: 'Play next',
                        onTap: enabled
                            ? () => playLocalNext(context, songs)
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                sliver: _TopSongs(
                  title: songs.any((s) => _plays(s) > 0)
                      ? 'Top songs'
                      : 'Songs',
                  songs: _top(songs),
                  currentId: currentId,
                  onTap: (song) => controller.playSongFromList(
                    songs,
                    songs.indexWhere((s) => s.id == song.id),
                  ),
                ),
              ),
              if (albums.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 32),
                  sliver: SliverToBoxAdapter(
                    child: MediaShelf(
                      title: 'Albums',
                      count: albums.length,
                      builder: (context, index, width) {
                        final album = albums[index];
                        return MediaTile(
                          width: width,
                          title: album.name,
                          subtitle: album.songs.length == 1
                              ? '1 song'
                              : '${album.songs.length} songs',
                          art: LocalArtwork(
                            size: width,
                            placeholder: Icons.album_rounded,
                            sources: [
                              if (album.first.albumId != null)
                                LocalArtSource(
                                  id: album.first.albumId!,
                                  type: ArtworkType.ALBUM,
                                  other: album.name,
                                ),
                              LocalArtSource.song(album.first),
                            ],
                          ),
                          onTap: () => Routes.routeTo(
                            AlbumSongs(
                              albumId: album.first.albumId,
                              album: album.name,
                              songs: album.songs.length,
                              coverSongId: album.first.id,
                              coverPath: album.first.data,
                            ),
                            context,
                          ),
                        );
                      },
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// The page's song rows, five at a time, built lazily so a long catalogue
/// costs only the rows on screen.
class _TopSongs extends StatefulWidget {
  const _TopSongs({
    required this.title,
    required this.songs,
    required this.currentId,
    required this.onTap,
  });

  final String title;
  final List<SongModel> songs;
  final int currentId;
  final void Function(SongModel song) onTap;

  @override
  State<_TopSongs> createState() => _TopSongsState();
}

class _TopSongsState extends State<_TopSongs> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final songs = widget.songs;
    final shown = _all ? songs.length : songs.length.clamp(0, 5);
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: MediaListTitle(widget.title)),
        SliverFixedExtentList(
          itemExtent: MediaTrackRow.height,
          delegate: SliverChildBuilderDelegate(childCount: shown, (
            context,
            index,
          ) {
            final song = songs[index];
            return MediaHighlight(
              current: song.id == widget.currentId,
              child: MediaTrackRow(
                art: LocalArtwork(
                  size: 44,
                  sources: [LocalArtSource.song(song)],
                ),
                title: song.title,
                byline: localByline(song, artist: false),
                duration: localClock(song),
                position: index + 1,
                onTap: () => widget.onTap(song),
                onLongPress: () => showLocalSongOptions(context, song),
                onMore: () => showLocalSongOptions(context, song),
              ),
            );
          }),
        ),
        if (songs.length > 5)
          SliverToBoxAdapter(
            child: MediaShowAllButton(
              all: _all,
              total: songs.length,
              onPressed: () => setState(() => _all = !_all),
            ),
          ),
      ],
    );
  }
}
