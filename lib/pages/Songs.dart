import 'package:eq_app/navigation/app_nav.dart';
import 'dart:io';
import '/exports/exports.dart';

import '/widgets/song_tile.dart';
import '/widgets/song_options_sheet.dart';
import '/widgets/song_sort_button.dart';
import '/widgets/song_list_skeleton.dart';
import '/data/library_repository.dart';
import '/controllers/app_controller.dart';
import '/controllers/library_controller.dart';
import '/services/local_music_scanner.dart';

class AllSongs extends StatefulWidget {
  const AllSongs({super.key});

  @override
  State<AllSongs> createState() => _AllSongsState();
}

class _AllSongsState extends State<AllSongs> {
  bool _importing = false;

  /// Alphabetical fast-scroll only makes sense for A–Z orderings.
  String Function(SongModel)? _fastKey(SongSort sort) {
    switch (sort) {
      case SongSort.title:
        return (s) => s.title;
      case SongSort.artist:
        return (s) => s.artist ?? '';
      case SongSort.album:
        return (s) => s.album ?? '';
      case SongSort.dateAdded:
      case SongSort.duration:
      case SongSort.playCount:
        return null;
    }
  }

  Future<void> _importFiles() async {
    if (_importing) return;
    _importing = true;
    try {
      final count = await LocalMusicScanner.importFiles();
      if (!mounted) return;
      if (count > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Imported $count file${count == 1 ? '' : 's'}'),
          ),
        );
        await context.read<LibraryController>().rescan();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
      }
    } finally {
      _importing = false;
    }
  }

  void _openOptions(SongModel song) {
    showModalBottomSheet(
      useRootNavigator: true,
      context: context,
      builder: (_) => SongOptionsSheet(song: song),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryController>();
    return StreamBuilder<List<SongModel>>(
      stream: library.repo.watchSongs(
        sort: library.songSort,
        dir: library.songDir,
      ),
      builder: (context, snap) {
        final songs = snap.data;

        // Before the first DB emit, or while the first-ever scan is still
        // filling an empty library, show a skeleton instead of a spinner.
        if (songs == null || (songs.isEmpty && library.isScanning)) {
          return const SongListSkeleton();
        }
        if (songs.isEmpty) return _emptyState(context);

        return Column(
          children: [
            _header(context, songs.length, library),
            Expanded(
              child: Consumer<AppController>(
                builder: (context, controller, _) {
                  return SongListView(
                    songs: songs,
                    controller: controller,
                    fastScrollKey: _fastKey(library.songSort),
                    onTap: (song, index) {
                      controller.playSongFromList(songs, index);
                      AppNav.toPlayer(context);
                    },
                    onLongPress: (song, index) => _openOptions(song),
                    onOptions: (song, index) => _openOptions(song),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _header(BuildContext context, int count, LibraryController library) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.music_note, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            library.isScanning ? "$count songs · scanning…" : "$count songs",
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const Spacer(),
          if (Platform.isIOS) ...[
            GestureDetector(
              onTap: () => context.read<LibraryController>().rescan(),
              child: Icon(
                Icons.refresh_rounded,
                size: 20,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: _importFiles,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.add_rounded,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    "Import",
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
          ],
          SongSortButton(
            sort: library.songSort,
            dir: library.songDir,
            onChanged: library.setSongSort,
          ),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.music_off,
            size: 64,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 12),
          Text(
            Platform.isIOS ? "No songs found" : "No songs available.",
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          if (Platform.isIOS) ...[
            const SizedBox(height: 20),
            _ImportButton(onTap: _importFiles),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                "How to add music on iOS:\n\n"
                "1. Tap 'Import' above to pick files\n"
                "2. In Safari: download a song → tap it\n"
                "   → Share → 'Open in Hype Muzik'\n"
                "3. In Files app: browse to On My iPhone\n"
                "   → Hype Muzik → drop files there\n\n"
                "Songs from Apple Music library\n"
                "appear automatically.",
                textAlign: TextAlign.left,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ImportButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ImportButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.folder_open_rounded, size: 20),
      label: const Text("Import Music Files"),
    );
  }
}
