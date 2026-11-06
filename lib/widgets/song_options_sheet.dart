import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:provider/provider.dart';

import '/helpers/channel.dart';
import '/controllers/library_controller.dart';
import '/data/library_repository.dart';
import '/models/recognition_result.dart';
import '/services/track_identify.dart';
import '/pages/album_songs.dart';
import '/pages/artist_songs.dart';
import 'playlist_widget.dart';

/// Bottom sheet with song actions: Identify track, Add to playlist, etc.
class SongOptionsSheet extends StatefulWidget {
  final SongModel song;
  const SongOptionsSheet({super.key, required this.song});

  @override
  State<SongOptionsSheet> createState() => _SongOptionsSheetState();
}

class _SongOptionsSheetState extends State<SongOptionsSheet> {
  bool _identifying = false;
  bool _applying = false;
  RecognitionResult? _result;
  String? _error;

  bool get _hasArtist {
    final a = widget.song.artist;
    return a != null && a.trim().isNotEmpty && a != '<unknown>';
  }

  bool get _hasAlbum {
    final a = widget.song.album;
    return a != null && a.trim().isNotEmpty;
  }

  /// Deletes the track's file, then the row.
  ///
  /// # Order matters
  ///
  /// The file goes first and the library row only follows if it actually went.
  /// On Android 11+ the delete can be refused — the system asks the user, and
  /// they can say no — and on iOS a track owned by the Music app lives outside
  /// this sandbox and cannot be touched at all. Dropping the row first would
  /// make a refused delete look like a success until the next scan put the
  /// track back, which is the sort of thing that reads as data loss.
  Future<void> _confirmDelete() async {
    final messenger = ScaffoldMessenger.of(context);
    final library = context.read<LibraryController>();
    final path = widget.song.data;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog.adaptive(
        title: const Text('Delete this track?'),
        content: Text(
          '"${widget.song.title}" will be removed from this device. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    Navigator.pop(context);

    final deleted = await Channel.deleteAudio(path);
    if (deleted) await library.rescan();
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          deleted
              ? 'Deleted "${widget.song.title}"'
              : 'Could not delete that track',
        ),
      ),
    );
  }

  Future<void> _goToArtist() async {
    final artist = widget.song.artist!;
    final repo = context.read<LibraryRepository>();
    final nav = Navigator.of(context);
    final songs = await repo.watchArtistSongs(artist).first;
    if (!mounted) return;
    nav.pop();
    AppNav.openPage(
      context,
      ArtistSongs(
        artistId: widget.song.artistId,
        artist: artist,
        songs: songs.length,
        albums: 0,
      ),
      key: LibraryPageKey('artist', {
        'artistId': widget.song.artistId,
        'artist': artist,
        'songs': songs.length,
        'albums': 0,
      }),
    );
  }

  Future<void> _goToAlbum() async {
    final album = widget.song.album!;
    final repo = context.read<LibraryRepository>();
    final nav = Navigator.of(context);
    final songs = await repo.watchAlbumSongs(album).first;
    if (!mounted) return;
    nav.pop();
    AppNav.openPage(
      context,
      AlbumSongs(
        albumId: widget.song.albumId,
        album: album,
        songs: songs.length,
      ),
      key: LibraryPageKey('album', {
        'albumId': widget.song.albumId,
        'album': album,
        'songs': songs.length,
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Song info header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                QueryArtworkWidget(
                  id: widget.song.id,
                  type: ArtworkType.AUDIO,
                  artworkHeight: 48,
                  artworkWidth: 48,
                  artworkBorder: BorderRadius.circular(8),
                  nullArtworkWidget: Container(
                    height: 48,
                    width: 48,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.music_note,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.song.title,
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        widget.song.artist ?? 'Unknown artist',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(),

          // Identify track
          if (_applying) ...[
            const ListTile(
              leading: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator.adaptive(strokeWidth: 2),
              ),
              title: Text("Saving tags..."),
              subtitle: Text("Writing metadata and artwork"),
            ),
          ] else if (_result != null) ...[
            _buildResultTile(theme),
          ] else if (_identifying) ...[
            const ListTile(
              leading: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator.adaptive(strokeWidth: 2),
              ),
              title: Text("Identifying track..."),
              subtitle: Text("Fingerprinting and searching databases"),
            ),
          ] else ...[
            ListTile(
              leading: const Icon(Icons.fingerprint),
              title: const Text("Identify track"),
              subtitle: _error != null
                  ? Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    )
                  : const Text("Recognize song using audio fingerprint"),
              onTap: _identifyTrack,
            ),
          ],

          const Divider(height: 1, indent: 16, endIndent: 16),

          // Add to playlist
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: const Text("Add to playlist"),
            onTap: () {
              Navigator.pop(context);
              showModalBottomSheet(
                useRootNavigator: true,
                context: context,
                builder: (_) => BottomSheet(
                  onClosing: () {},
                  builder: (_) => PlaylistWidget(
                    audioId: widget.song.id,
                    song: widget.song.title,
                  ),
                ),
              );
            },
          ),

          // Delete from device
          ListTile(
            leading: Icon(
              Icons.delete_outline_rounded,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              'Delete from device',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            subtitle: const Text('Removes the file, not just the listing'),
            onTap: _confirmDelete,
          ),

          // Go to artist
          if (_hasArtist)
            ListTile(
              leading: const Icon(Icons.person_outline_rounded),
              title: const Text("Go to artist"),
              subtitle: Text(
                widget.song.artist!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: _goToArtist,
            ),

          // Go to album
          if (_hasAlbum)
            ListTile(
              leading: const Icon(Icons.album_outlined),
              title: const Text("Go to album"),
              subtitle: Text(
                widget.song.album!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: _goToAlbum,
            ),

          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _identifyTrack() async {
    setState(() {
      _identifying = true;
      _error = null;
    });
    final outcome = await identifyTrack(widget.song);
    if (!mounted) return;
    setState(() {
      _identifying = false;
      _result = outcome.result;
      _error = outcome.error;
    });
  }

  Widget _buildResultTile(ThemeData theme) {
    final r = _result!;
    return Column(
      children: [
        ListTile(
          leading: Icon(Icons.check_circle, color: theme.colorScheme.primary),
          title: Text(r.title ?? 'Unknown'),
          subtitle: Text(
            [
              if (r.artist != null) r.artist!,
              if (r.album != null) r.album!,
              if (r.year != null) r.year!,
            ].join(' - '),
          ),
          trailing: Text(
            '${(r.score * 100).round()}%',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: _applyTags,
                  child: const Text("Apply tags"),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Dismiss"),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Future<void> _applyTags() async {
    final result = _result;
    if (result == null) return;
    setState(() => _applying = true);
    final error = await applyIdentification(widget.song, result);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (error != null) {
      setState(() => _applying = false);
      messenger.showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    Navigator.pop(context);
    messenger.showSnackBar(
      const SnackBar(content: Text("Tags and artwork updated")),
    );
  }
}
