import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library_page_key.dart';

import '/extensions/index.dart';
import '/exports/exports.dart';
import '/data/library_repository.dart';

import '../widgets/artwork_widget.dart';
import '../widgets/library_list_row.dart';
import 'package:eq_app/navigation/zoom/persisted_zoom_list.dart';
import 'package:eq_app/navigation/zoom/zoom_steps.dart';
import 'artist_songs.dart';

import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/motion/morph.dart';

/// Pinch-zoom ladder, zoomed-out first: three grids, then the list.
const List<ZoomStep> _artistsZoomSteps = [
  ZoomStep.grid(
    maxTileExtent: 80.0, childAspectRatio: 0.75,
    crossAxisSpacing: 8,
    mainAxisSpacing: 12,
  ),
  ZoomStep.grid(
    maxTileExtent: 140.0, childAspectRatio: 0.75,
    crossAxisSpacing: 8,
    mainAxisSpacing: 12,
  ),
  ZoomStep.grid(
    maxTileExtent: 300.0, childAspectRatio: 0.75,
    crossAxisSpacing: 8,
    mainAxisSpacing: 12,
  ),
  ZoomStep.list(rowExtent: kLibraryRowExtent),
];

class Artists extends StatefulWidget {
  const Artists({super.key});

  @override
  State<Artists> createState() => _ArtistsState();
}

class _ArtistsState extends State<Artists> {
  late final Stream<List<ArtistModel>> _artistsStream;

  @override
  void initState() {
    super.initState();
    _artistsStream = context.read<LibraryRepository>().watchArtists();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: StreamBuilder<List<ArtistModel>>(
        stream: _artistsStream,
        builder: (context, item) {
          if (item.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator.adaptive());
          } else if (item.hasError) {
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
                    "Failed to load artists",
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            );
          } else if (!item.hasData || item.data!.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.person_off,
                    size: 64,
                    color: Theme.of(context).colorScheme.onSurface
                        .withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    "No artists found",
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            );
          }

          final artists = item.data!;
          return PersistedZoomList(
            zoomKey: 'artists',
            steps: _artistsZoomSteps,
            fallbackStep: 1,
            itemCount: artists.length,
            itemBuilder: (context, index, step) {
              if (step is GridZoomStep) {
                final artist = artists[index];
                final artistName = "${artist.getMap['artist'] ?? 'Unknown'}";
                return MorphTag(
                  tag: itemTag(
                    LibraryPageKey('artist', {
                      'artistId': artist.id,
                      'artist': artistName,
                      'songs': artist.numberOfTracks ?? 0,
                      'albums': artist.numberOfAlbums ?? 0,
                    }),
                  ),
                  child: InkWell(
                    onTap: () => AppNav.openPage(
                      context,
                      ArtistSongs(
                        songs: artist.numberOfTracks ?? 0,
                        albums: artist.numberOfAlbums ?? 0,
                        artistId: artist.id,
                        artist: artistName,
                      ),
                      key: LibraryPageKey('artist', {
                        'artistId': artist.id,
                        'artist': artistName,
                        'songs': artist.numberOfTracks ?? 0,
                        'albums': artist.numberOfAlbums ?? 0,
                      }),
                      morphFrom: itemTag(
                        LibraryPageKey('artist', {
                          'artistId': artist.id,
                          'artist': artistName,
                          'songs': artist.numberOfTracks ?? 0,
                          'albums': artist.numberOfAlbums ?? 0,
                        }),
                      ),
                    ),
                    child: Column(
                      children: [
                        Expanded(
                          child: Hero(
                            tag: 'artist_${artist.id}',
                            child: ClipOval(
                              child: SizedBox.expand(
                                child: ArtworkWidget(
                                  borderRadius: BorderRadius.zero,
                                  width: double.infinity,
                                  height: double.infinity,
                                  songId: artist.id,
                                  type: ArtworkType.ARTIST,
                                  other: artistName,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          artistName,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontSize: 12),
                        ),
                        Text(
                          (artist.numberOfTracks ?? 0).nSongs,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                );
              } else {
                final artist = artists[index];
                final artistName = "${artist.getMap['artist'] ?? 'Unknown'}";
                return MorphTag(
                  tag: itemTag(
                    LibraryPageKey('artist', {
                      'artistId': artist.id,
                      'artist': artistName,
                      'songs': artist.numberOfTracks ?? 0,
                      'albums': artist.numberOfAlbums ?? 0,
                    }),
                  ),
                  child: LibraryListRow(
                    title: artistName,
                    subtitle: '${artist.numberOfTracks ?? 0} tracks',
                    artworkId: artist.id,
                    artworkType: ArtworkType.ARTIST,
                    artworkName: artistName,
                    circular: true,
                    fallbackIcon: Icons.person_rounded,
                    onTap: () => AppNav.openPage(
                      context,
                      ArtistSongs(
                        songs: artist.numberOfTracks ?? 0,
                        albums: artist.numberOfAlbums ?? 0,
                        artistId: artist.id,
                        artist: artistName,
                      ),
                      key: LibraryPageKey('artist', {
                        'artistId': artist.id,
                        'artist': artistName,
                        'songs': artist.numberOfTracks ?? 0,
                        'albums': artist.numberOfAlbums ?? 0,
                      }),
                      morphFrom: itemTag(
                        LibraryPageKey('artist', {
                          'artistId': artist.id,
                          'artist': artistName,
                          'songs': artist.numberOfTracks ?? 0,
                          'albums': artist.numberOfAlbums ?? 0,
                        }),
                      ),
                    ),
                  ),
                );
              }
            },
          );
        },
      ),
    );
  }
}
