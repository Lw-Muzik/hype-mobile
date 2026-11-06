import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/Global/index.dart';
import 'package:eq_app/Routes/routes.dart';
import 'package:eq_app/controllers/app_controller.dart';
import 'package:eq_app/extensions/index.dart';
import 'package:eq_app/widgets/Body.dart';
import '/exports/exports.dart';

import '/widgets/artwork_widget.dart';
import '/widgets/song_options_sheet.dart';
import '/widgets/song_tile.dart';
import '/data/library_repository.dart';
import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/motion/morph.dart';

class GenreSongs extends StatefulWidget {
  final int? genreId;
  final String genre;
  final int songs;
  const GenreSongs({
    super.key,
    required this.genreId,
    required this.genre,
    required this.songs,
  });

  @override
  State<GenreSongs> createState() => _GenreSongsState();
}

class _GenreSongsState extends State<GenreSongs> {
  late final Stream<List<SongModel>> _songsStream = context
      .read<LibraryRepository>()
      .watchGenreSongs(widget.genre);

  @override
  Widget build(BuildContext context) {
    return Body(
      child: NestedScrollView(
        floatHeaderSlivers: true,
        headerSliverBuilder: (context, x) {
          return [
            SliverAppBar(
              expandedHeight: 400,
              leading: IconButton.filledTonal(
                onPressed: () => Routes.pop(context),
                icon: const Icon(Icons.arrow_back),
              ),
              // floating: true,
              // snap: true,
              flexibleSpace: FlexibleSpaceBar(
                expandedTitleScale: 70,
                background: MorphTag(
                  tag: headerTag(
                    LibraryPageKey('genre', {'genreId': widget.genreId}),
                  ),
                  child: Stack(
                    children: [
                      Hero(
                        tag: 'genre_${widget.genreId}',
                        child: headerWidget(
                          context.read<AppController>(),
                          context,
                          child: ArtworkWidget(
                            borderRadius: BorderRadius.zero,
                            size: 5000,
                            quality: 100,
                            width: MediaQuery.of(context).size.width,
                            height: MediaQuery.of(context).size.width,
                            songId: widget.genreId!,
                            other: widget.genre,
                            type: ArtworkType.GENRE,
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 45,
                        left: 20,
                        child: RichText(
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: "${widget.genre}\n",
                                style: Theme.of(context).textTheme.displayMedium,
                              ),
                              TextSpan(
                                text: "${widget.songs}",
                                style: Theme.of(context).textTheme.headlineLarge!
                                    .copyWith(fontWeight: FontWeight.w300),
                              ),
                              TextSpan(
                                text: widget.songs.aTracks,
                                style: Theme.of(context).textTheme.headlineSmall!
                                    .copyWith(fontWeight: FontWeight.w300),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ];
        },
        body: Consumer<AppController>(
          builder: (context, controller, child) {
            return StreamBuilder(
              stream: controller.handler.player.playingStream,
              builder: (context, service) {
                return Scaffold(
                  backgroundColor: Theme.of(
                    context,
                  ).scaffoldBackgroundColor.withValues(alpha: 0.8),
                  body: StreamBuilder<List<SongModel>>(
                    stream: _songsStream,
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return const Center(
                          child: CircularProgressIndicator.adaptive(),
                        );
                      }
                      final songs = snapshot.data!;
                      return SongListView(
                        songs: songs,
                        controller: controller,
                        zoomKey: 'genre_songs',
                        onTap: (song, index) {
                          controller.playSongFromList(songs, index);
                          AppNav.toPlayer(context);
                        },
                        onLongPress: (song, index) {
                          showModalBottomSheet(
                            useRootNavigator: true,
                            context: context,
                            builder: (_) => SongOptionsSheet(song: song),
                          );
                        },
                        onOptions: (song, index) {
                          showModalBottomSheet(
                            useRootNavigator: true,
                            context: context,
                            builder: (_) => SongOptionsSheet(song: song),
                          );
                        },
                      );
                    },
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
