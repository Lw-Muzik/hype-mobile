/// An album from the library, opened into its tracks.
///
/// The same page as the YouTube Music album (`discover/opened_list_page.dart`),
/// built from the same pieces: the cover large and blurred behind everything,
/// the artist as a link to their page, what it is and how long, then Play,
/// Shuffle and — where YouTube offers Download, since these songs are already on
/// the phone — Play next. Tracks are numbered the way the sleeve numbers them.
library;

import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../data/library_repository.dart';
import '../themes/ember.dart';
import 'artist_songs.dart';
import 'discover/widgets/local_media.dart';
import 'discover/widgets/media_widgets.dart';
import 'discover/widgets/yt_hero.dart';
import 'discover/widgets/yt_widgets.dart';
import '../Routes/routes.dart';

class AlbumSongs extends StatefulWidget {
  final int? albumId;

  /// A song whose cover stands in when there is no album id to look art up
  /// by — a album reached from the player, for a file the media library
  /// never gave one.
  final int? coverSongId;
  final String coverPath;
  final String album;
  final int songs;
  const AlbumSongs({
    super.key,
    required this.albumId,
    this.coverSongId,
    this.coverPath = '',
    required this.album,
    required this.songs,
  });

  @override
  State<AlbumSongs> createState() => _AlbumSongsState();
}

class _AlbumSongsState extends State<AlbumSongs> {
  // Built once here (not in build()) so rebuilds don't re-issue the query.
  late final Stream<List<SongModel>> _songsStream = context
      .read<LibraryRepository>()
      .watchAlbumSongs(widget.album);

  List<LocalArtSource> _cover(List<SongModel> songs) => [
    if (widget.albumId case final id?)
      LocalArtSource(
        id: id,
        type: ArtworkType.ALBUM,
        other: widget.album,
      ),
    if (widget.coverSongId case final id?)
      LocalArtSource(id: id, data: widget.coverPath),
    for (final song in songs.take(3)) LocalArtSource.song(song),
  ];

  /// The album's artist: the one name all its tracks share.
  String? _artist(List<SongModel> songs) {
    final names = {
      for (final s in songs)
        ?localByline(s, album: false),
    };
    return names.length == 1 ? names.first : null;
  }

  /// Track numbers as the files carry them (Android packs the disc into the
  /// thousands) when they make sense; otherwise the order of the list.
  List<int> _numbers(List<SongModel> songs) {
    final tracks = [for (final s in songs) (s.track ?? 0) % 1000];
    final usable =
        tracks.every((t) => t > 0) && tracks.toSet().length == tracks.length;
    return usable ? tracks : [for (var i = 0; i < songs.length; i++) i + 1];
  }

  Future<void> _openArtist(String artist, SongModel sample) async {
    final songs = await context
        .read<LibraryRepository>()
        .watchArtistSongs(artist)
        .first;
    if (!mounted) return;
    Routes.routeTo(
      ArtistSongs(
        artistId: sample.artistId,
        artist: artist,
        songs: songs.length,
        albums: {for (final s in songs) s.album}.length,
        coverSongId: sample.id,
        coverPath: sample.data,
      ),
      context,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.read<AppController>();
    final currentId = currentLocalSongId(context);
    return StreamBuilder<List<SongModel>>(
      stream: _songsStream,
      builder: (context, snapshot) {
        final songs = snapshot.data ?? const <SongModel>[];
        final loading = !snapshot.hasData;
        final artist = _artist(songs);
        final numbers = _numbers(songs);
        final cover = _cover(songs);
        final enabled = songs.isNotEmpty;
        return MediaPageScaffold(
          title: widget.album,
          heroHeight: mediaListHeroHeight,
          bottomBar: const LocalMiniPlayerBar(),
          background: MediaListHero(
            kicker: 'ALBUM',
            title: widget.album,
            credits: songs.isEmpty
                ? null
                : artist != null
                ? MediaCredits(
                    children: [
                      MediaCreditChip(
                        name: artist,
                        portrait: LocalArtwork(
                          size: 24,
                          circular: true,
                          placeholder: Icons.person_rounded,
                          sources: [
                            if (songs.first.artistId != null)
                              LocalArtSource(
                                id: songs.first.artistId!,
                                type: ArtworkType.ARTIST,
                                other: artist,
                              ),
                            LocalArtSource.song(songs.first),
                          ],
                        ),
                        onTap: () => _openArtist(artist, songs.first),
                      ),
                    ],
                  )
                : const MediaCreditText('Various artists'),
            facts: songs.isEmpty ? null : localFacts(songs),
            art: (size) => LocalArtwork(
              sources: cover,
              size: size,
              placeholder: Icons.album_rounded,
            ),
            backdrop: LocalArtwork(sources: cover),
            actions: [
              YtRoundButton(
                icon: Icons.playlist_play_rounded,
                tooltip: 'Play next',
                onTap: enabled ? () => playLocalNext(context, songs) : null,
              ),
              YtRoundButton(
                icon: Icons.play_arrow_rounded,
                tooltip: 'Play',
                size: 64,
                primary: true,
                onTap: enabled
                    ? () => controller.playSongFromList(songs, 0)
                    : null,
              ),
              YtRoundButton(
                icon: Icons.shuffle_rounded,
                tooltip: 'Shuffle',
                onTap: enabled
                    ? () => controller.playSongFromList(
                        [...songs]..shuffle(),
                        0,
                      )
                    : null,
              ),
            ],
          ),
          slivers: [
            if (loading)
              const SliverFillRemaining(
                child: YtTrackSkeleton(),
              )
            else if (songs.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: YtMessage(
                  icon: Icons.inbox_rounded,
                  title: 'No songs found',
                  body: 'Nothing in your library is on this album.',
                ),
              )
            else ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                sliver: SliverFixedExtentList(
                  itemExtent: MediaTrackRow.height,
                  delegate: SliverChildBuilderDelegate(
                    childCount: songs.length,
                    (context, index) {
                      final song = songs[index];
                      return MediaAlbumRow(
                        number: numbers[index],
                        title: song.title,
                        // The album's own artist goes without saying.
                        byline: artist == null
                            ? localByline(song, album: false)
                            : null,
                        duration: localClock(song),
                        current: song.id == currentId,
                        playing: controller.handler.player.playingStream,
                        onTap: () => controller.playSongFromList(songs, index),
                        onLongPress: () => showLocalSongOptions(context, song),
                        onMore: () => showLocalSongOptions(context, song),
                      );
                    },
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 18, 24, 32),
                  child: Text(
                    localFacts(songs),
                    style: TextStyle(
                      color: Ember.textTertiary,
                      fontSize: 12.5,
                    ),
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
