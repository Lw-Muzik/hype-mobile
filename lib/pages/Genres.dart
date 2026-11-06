import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/extensions/index.dart';
import 'package:eq_app/pages/genre_songs.dart';

import '/exports/exports.dart';
import '/data/library_repository.dart';

import '../widgets/library_list_row.dart';
import 'package:eq_app/navigation/zoom/persisted_zoom_list.dart';
import 'package:eq_app/navigation/zoom/zoom_steps.dart';

import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/motion/morph.dart';

/// Pinch-zoom ladder, zoomed-out first: three grids, then the list.
const List<ZoomStep> _genresZoomSteps = [
  ZoomStep.grid(maxTileExtent: 100.0, childAspectRatio: 1.0, spacing: 8),
  ZoomStep.grid(maxTileExtent: 150.0, childAspectRatio: 1.0, spacing: 8),
  ZoomStep.grid(maxTileExtent: 200.0, childAspectRatio: 1.0, spacing: 8),
  ZoomStep.list(rowExtent: kLibraryRowExtent),
];

class Genres extends StatefulWidget {
  const Genres({super.key});

  @override
  State<Genres> createState() => _GenresState();
}

class _GenresState extends State<Genres> {
  late final Stream<List<GenreModel>> _genresStream;

  @override
  void initState() {
    super.initState();
    _genresStream = context.read<LibraryRepository>().watchGenres();
  }

  Color _genreColor(String name) {
    final hash = name.hashCode;
    final hue = (hash % 360).abs().toDouble();
    return HSLColor.fromAHSL(1.0, hue, 0.5, 0.35).toColor();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<GenreModel>>(
      stream: _genresStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator.adaptive());
        } else if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 48,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 12),
                Text(
                  "Failed to load genres",
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
          );
        } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.category,
                  size: 64,
                  color: Theme.of(context).colorScheme.onSurface
                      .withValues(alpha: 0.3),
                ),
                const SizedBox(height: 12),
                Text(
                  "No genres found",
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
          );
        }

        final genres = snapshot.data!;
        return Padding(
          padding: const EdgeInsets.all(8.0),
          child: PersistedZoomList(
            zoomKey: 'genres',
            steps: _genresZoomSteps,
            fallbackStep: 2,
            itemCount: genres.length,
            itemBuilder: (context, index, step) {
              if (step is GridZoomStep) {
                final genre = genres[index];
                final baseColor = _genreColor(genre.genre);
                return MorphTag(
                  tag: itemTag(
                    LibraryPageKey('genre', {
                      'genreId': genre.id,
                      'genre': genre.genre,
                      'songs': genre.numOfSongs,
                    }),
                  ),
                  child: InkWell(
                    onTap: () => AppNav.openPage(
                      context,
                      GenreSongs(
                        genreId: genre.id,
                        genre: genre.genre,
                        songs: genre.numOfSongs,
                      ),
                      key: LibraryPageKey('genre', {
                        'genreId': genre.id,
                        'genre': genre.genre,
                        'songs': genre.numOfSongs,
                      }),
                      morphFrom: itemTag(
                        LibraryPageKey('genre', {
                          'genreId': genre.id,
                          'genre': genre.genre,
                          'songs': genre.numOfSongs,
                        }),
                      ),
                    ),
                    child: Hero(
                      tag: 'genre_${genre.id}',
                      child: Card(
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                baseColor,
                                baseColor.withValues(alpha: 0.7),
                              ],
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(
                                Icons.music_note,
                                size: 36,
                                color: Colors.white70,
                              ),
                              const SizedBox(height: 8),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                child: Text(
                                  genre.genre,
                                  maxLines: 2,
                                  textAlign: TextAlign.center,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(color: Colors.white),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  genre.numOfSongs.nSongs,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: Colors.white70),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              } else {
                final genre = genres[index];
                return MorphTag(
                  tag: itemTag(
                    LibraryPageKey('genre', {
                      'genreId': genre.id,
                      'genre': genre.genre,
                      'songs': genre.numOfSongs,
                    }),
                  ),
                  child: LibraryListRow(
                    title: genre.genre,
                    subtitle: '${genre.numOfSongs} songs',
                    artworkId: null,
                    fallbackIcon: Icons.library_music_rounded,
                    onTap: () => AppNav.openPage(
                      context,
                      GenreSongs(
                        genreId: genre.id,
                        genre: genre.genre,
                        songs: genre.numOfSongs,
                      ),
                      key: LibraryPageKey('genre', {
                        'genreId': genre.id,
                        'genre': genre.genre,
                        'songs': genre.numOfSongs,
                      }),
                      morphFrom: itemTag(
                        LibraryPageKey('genre', {
                          'genreId': genre.id,
                          'genre': genre.genre,
                          'songs': genre.numOfSongs,
                        }),
                      ),
                    ),
                  ),
                );
              }
            },
          ),
        );
      },
    );
  }
}
