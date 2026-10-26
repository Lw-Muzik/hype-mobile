/// A playlist from the device, opened into its tracks.
///
/// The same page as a YouTube Music playlist (`discover/opened_list_page.dart`):
/// the first track's cover large and blurred behind, who it belongs to and how
/// long it runs, Play / Shuffle / Play next (YouTube's Download slot — these
/// songs are already here), and every track with its own art.
library;

import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:provider/provider.dart';

import '../Helpers/index.dart';
import '../Routes/routes.dart';
import '../themes/ember.dart';
import '../controllers/app_controller.dart';
import 'discover/widgets/local_media.dart';
import 'discover/widgets/media_widgets.dart';
import 'discover/widgets/yt_hero.dart';
import 'discover/widgets/yt_widgets.dart';

class PlaylistSongs extends StatefulWidget {
  final int playlistId;
  final String playlist;
  final int songs;
  const PlaylistSongs({
    super.key,
    required this.playlistId,
    required this.playlist,
    required this.songs,
  });

  @override
  State<PlaylistSongs> createState() => _PlaylistSongsState();
}

class _PlaylistSongsState extends State<PlaylistSongs> {
  late Future<List<SongModel>> _songsFuture = _load();

  Future<List<SongModel>> _load() => OnAudioQuery().queryAudiosFrom(
    AudiosFromType.PLAYLIST,
    widget.playlistId,
  );

  /// Long-press (and the overflow): take the track out of the playlist, then
  /// show the list without it.
  Future<void> _edit(SongModel song) async {
    await showModalBottomSheet(
      context: context,
      builder: (context) => BottomSheet(
        onClosing: () {},
        builder: (context) => PlayListEditor(
          audioId: song.id,
          song: song.title,
          playlist: widget.playlistId,
        ),
      ),
    );
    if (mounted) setState(() => _songsFuture = _load());
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.read<AppController>();
    final currentId = currentLocalSongId(context);
    return FutureBuilder<List<SongModel>>(
      future: _songsFuture,
      builder: (context, snapshot) {
        final songs = snapshot.data ?? const <SongModel>[];
        final loading = !snapshot.hasData;
        final enabled = songs.isNotEmpty;
        final cover = [for (final s in songs.take(3)) LocalArtSource.song(s)];
        return MediaPageScaffold(
          title: widget.playlist,
          heroHeight: mediaListHeroHeight,
          bottomBar: const LocalMiniPlayerBar(),
          background: MediaListHero(
            kicker: 'PLAYLIST',
            title: widget.playlist,
            credits: const MediaCreditText('On this device'),
            facts: songs.isEmpty ? null : localFacts(songs),
            art: (size) => LocalArtwork(
              sources: cover,
              size: size,
              placeholder: Icons.queue_music_rounded,
            ),
            backdrop: cover.isEmpty ? null : LocalArtwork(sources: cover),
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
                  body: 'This playlist has nothing in it.',
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
                      return MediaHighlight(
                        current: song.id == currentId,
                        child: MediaTrackRow(
                          art: LocalArtwork(
                            size: 44,
                            sources: [LocalArtSource.song(song)],
                          ),
                          title: song.title,
                          byline: localByline(song),
                          duration: localClock(song),
                          position: index + 1,
                          onTap: () =>
                              controller.playSongFromList(songs, index),
                          onLongPress: () => _edit(song),
                          onMore: () => _edit(song),
                        ),
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

class PlayListEditor extends StatefulWidget {
  final int audioId;
  final String song;
  final int playlist;
  const PlayListEditor({
    super.key,
    required this.audioId,
    required this.song,
    required this.playlist,
  });

  @override
  State<PlayListEditor> createState() => _PlayListEditorState();
}

class _PlayListEditorState extends State<PlayListEditor> {
  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, controller, c) {
        return SizedBox(
          height: 150,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.delete),
                title: const Text("Remove from playlist"),
                onTap: () {
                  controller.audioQuery
                      .removeFromPlaylist(widget.playlist, widget.audioId)
                      .then((value) {
                        if (value) {
                          Routes.pop(context);
                          showMessage(
                            context: context,
                            type: 'success',
                            msg: "${widget.song} removed successfully",
                          );
                        }
                      });
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
