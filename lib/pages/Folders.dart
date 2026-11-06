import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library_page_key.dart';

import '../Helpers/index.dart';
import '/exports/exports.dart';

import '../Global/index.dart';
import '../data/library_repository.dart';
import '../widgets/library_list_row.dart';
import 'package:eq_app/navigation/zoom/persisted_zoom_list.dart';
import 'package:eq_app/navigation/zoom/zoom_steps.dart';
import 'folder_songs.dart';

import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/motion/morph.dart';

/// Pinch-zoom ladder, zoomed-out first: three grids, then the list.
const List<ZoomStep> _foldersZoomSteps = [
  ZoomStep.grid(maxTileExtent: 100.0, childAspectRatio: 1.0, spacing: 8),
  ZoomStep.grid(maxTileExtent: 150.0, childAspectRatio: 1.0, spacing: 8),
  ZoomStep.grid(maxTileExtent: 200.0, childAspectRatio: 1.0, spacing: 8),
  ZoomStep.list(rowExtent: kLibraryRowExtent),
];

class Folders extends StatefulWidget {
  const Folders({super.key});

  @override
  State<Folders> createState() => _FoldersState();
}

class _FoldersState extends State<Folders> {
  late final Stream<List<FolderEntry>> _foldersStream = context
      .read<LibraryRepository>()
      .watchFolders();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<FolderEntry>>(
      stream: _foldersStream,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
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
                  "Failed to load folders",
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
                  Icons.folder_open,
                  size: 64,
                  color: Theme.of(context).colorScheme.onSurface
                      .withValues(alpha: 0.3),
                ),
                const SizedBox(height: 12),
                Text(
                  "No folders found",
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
          );
        }

        final folders = snapshot.data!;
        return Padding(
          padding: const EdgeInsets.all(8.0),
          child: PersistedZoomList(
            zoomKey: 'folders',
            steps: _foldersZoomSteps,
            fallbackStep: 2,
            itemCount: folders.length,
            itemBuilder: (context, index, step) {
              if (step is GridZoomStep) {
                final folder = folders[index];
                final path = folder.path;
                return MorphTag(
                  tag: itemTag(LibraryPageKey('folder', {'path': path})),
                  child: InkWell(
                    onTap: () => AppNav.openPage(
                      context,
                      FolderSongs(path: path),
                      key: LibraryPageKey('folder', {'path': path}),
                      morphFrom: itemTag(
                        LibraryPageKey('folder', {'path': path}),
                      ),
                    ),
                    onLongPress: () {
                      showDeleteWindow("folder", path, context);
                    },
                    child: Hero(
                      tag: 'folder_$path',
                      child: Card(
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: folderArtwork(
                          context,
                          folder.name,
                          sampleId: folder.sampleId,
                          sampleData: folder.sampleData,
                          numSongs: folder.numSongs,
                        ),
                      ),
                    ),
                  ),
                );
              } else {
                final folder = folders[index];
                final path = folder.path;
                return MorphTag(
                  tag: itemTag(LibraryPageKey('folder', {'path': path})),
                  child: LibraryListRow(
                    title: folder.name,
                    subtitle: '${folder.numSongs} Songs',
                    artworkId: folder.sampleId,
                    artworkType: ArtworkType.AUDIO,
                    artworkPath: folder.sampleData ?? '',
                    fallbackIcon: Icons.folder_rounded,
                    onTap: () => AppNav.openPage(
                      context,
                      FolderSongs(path: path),
                      key: LibraryPageKey('folder', {'path': path}),
                      morphFrom: itemTag(
                        LibraryPageKey('folder', {'path': path}),
                      ),
                    ),
                    onLongPress: () {
                      showDeleteWindow("folder", path, context);
                    },
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
