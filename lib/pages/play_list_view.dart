/// The Library's Playlists tab.
///
/// # Two kinds, the app's own first
///
/// The app's playlists — what "Add to playlist" in the player fills, what a
/// saved mix becomes — can hold a YouTube track or a drive file beside the
/// phone's own files, and work on iOS. They come first, and follow every
/// change as it happens (see `LibraryRepository.playlistRevision`): a song
/// added from the player is here when you arrive.
///
/// Below them, on Android, the playlists the phone's media library keeps —
/// made by other apps, or by this one before it had its own — which hold
/// only files on the phone. `queryPlaylists` is not supported on iOS.
library;

import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library_page_key.dart';

import 'dart:io';

import 'package:eq_app/Helpers/index.dart';
import 'package:eq_app/controllers/app_controller.dart';
import 'package:eq_app/extensions/index.dart';
import 'package:eq_app/pages/playlist_songs.dart';

import '/exports/exports.dart';
import '../data/library_repository.dart';
import '../themes/ember.dart';
import 'home/mix_playlist_page.dart';

import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/motion/morph.dart';

class PlayListView extends StatefulWidget {
  const PlayListView({super.key});

  @override
  State<PlayListView> createState() => _PlayListViewState();
}

class _PlayListViewState extends State<PlayListView> {
  List<PlaylistSummary>? _own;
  List<PlaylistModel> _device = const [];
  LibraryRepository? _repo;
  final TextEditingController _name = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_repo != null) return;
    _repo = context.read<LibraryRepository>()
      ..playlistRevision.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _repo?.playlistRevision.removeListener(_load);
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final own = await _repo!.playlists();
    var device = const <PlaylistModel>[];
    if (Platform.isAndroid) {
      try {
        device = await OnAudioQuery().queryPlaylists();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _own = own;
      _device = device;
    });
  }

  Future<void> _create() async {
    _name.clear();
    final name = await showAdaptiveDialog<String>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: const Text('New playlist'),
        content: Material(
          type: MaterialType.transparency,
          child: TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Playlist name'),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _name.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return;
    await _repo!.createPlaylist(
      trimmed,
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  Future<void> _delete(PlaylistSummary playlist) async {
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: const Text('Delete this playlist?'),
        content: Text(
          '"${playlist.name}" will be removed. The songs in it stay where '
          'they are.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _repo!.deletePlaylist(playlist.id);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.read<AppController>();
    final own = _own;
    if (own == null) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }
    final empty = own.isEmpty && _device.isEmpty;
    return Stack(
      children: [
        if (empty)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.queue_music_rounded,
                  size: 64,
                  color: Ember.textTertiary,
                ),
                const SizedBox(height: 12),
                Text(
                  'No playlists yet',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Tap + to start one, or add a song from the player',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          )
        else
          ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 96),
            children: [
              if (own.isNotEmpty) ...[
                _heading(context, 'YOUR PLAYLISTS'),
                for (final playlist in own)
                  MorphTag(
                    tag: itemTag(LibraryPageKey('mix', {'id': playlist.id})),
                    child: _Tile(
                      title: playlist.name,
                      subtitle: playlist.trackCount.nSongs,
                      cover: _OwnCover(playlist: playlist),
                      onTap: () => AppNav.openPage(
                        context,
                        MixPlaylistPage(playlist: playlist),
                        key: LibraryPageKey('mix', {'id': playlist.id}),
                        morphFrom: itemTag(
                          LibraryPageKey('mix', {'id': playlist.id}),
                        ),
                      ),
                      onLongPress: () => _delete(playlist),
                    ),
                  ),
              ],
              if (_device.isNotEmpty) ...[
                _heading(context, 'ON THIS DEVICE'),
                for (final playlist in _device)
                  MorphTag(
                    tag: itemTag(
                      LibraryPageKey('playlist', {
                        'playlistId': playlist.id,
                        'playlist': playlist.playlist,
                        'songs': playlist.numOfSongs,
                      }),
                    ),
                    child: _Tile(
                      title: playlist.playlist,
                      subtitle: playlist.numOfSongs.nSongs,
                      cover: Hero(
                        tag: 'playlist_${playlist.id}',
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: Ember.surfaceHigh,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.playlist_play_rounded,
                            color: Ember.textSecondary,
                            size: 26,
                          ),
                        ),
                      ),
                      onTap: () => AppNav.openPage(
                        context,
                        PlaylistSongs(
                          playlistId: playlist.id,
                          playlist: playlist.playlist,
                          songs: playlist.numOfSongs,
                        ),
                        key: LibraryPageKey('playlist', {
                          'playlistId': playlist.id,
                          'playlist': playlist.playlist,
                          'songs': playlist.numOfSongs,
                        }),
                        morphFrom: itemTag(
                          LibraryPageKey('playlist', {
                            'playlistId': playlist.id,
                            'playlist': playlist.playlist,
                            'songs': playlist.numOfSongs,
                          }),
                        ),
                      ),
                      onLongPress: () => showDeletePlaylist(
                        controller,
                        playlist.playlist,
                        playlist.id,
                        context,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        Positioned(
          bottom: 50,
          right: 40,
          child: FloatingActionButton(
            onPressed: _create,
            tooltip: 'New playlist',
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }

  Widget _heading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(Ember.gutter, 16, Ember.gutter, 8),
    child: Text(text, style: Ember.shelfTitle(context)),
  );
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.onTap,
    required this.onLongPress,
  });

  final String title;
  final String subtitle;
  final Widget cover;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: Ember.surface,
        borderRadius: BorderRadius.circular(Ember.radiusTile),
        child: InkWell(
          borderRadius: BorderRadius.circular(Ember.radiusTile),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                cover,
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Ember.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: Ember.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: Ember.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An app playlist's cover: its own, or a tile in a colour of its own.
class _OwnCover extends StatelessWidget {
  const _OwnCover({required this.playlist});

  final PlaylistSummary playlist;

  @override
  Widget build(BuildContext context) {
    final path = playlist.coverPath;
    final tint = Ember.accentFor(playlist.name);
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox.square(
        dimension: 48,
        child: path != null && File(path).existsSync()
            ? Image.file(File(path), fit: BoxFit.cover)
            : DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.lerp(tint, Colors.white, 0.18)!,
                      Color.lerp(tint, Colors.black, 0.35)!,
                    ],
                  ),
                ),
                child: const Icon(
                  Icons.queue_music_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ),
      ),
    );
  }
}
