/// An app-owned playlist, which may hold music from three different places.
///
/// # Why this exists rather than reusing `PlaylistSongs`
///
/// That page reads MediaStore, whose playlists are Android-only and can hold
/// only MediaStore ids. These rows can hold a drive file and a YouTube track as
/// well, which is the entire reason the app owns them — so opening one with the
/// MediaStore view would query it with a row id that means nothing there.
///
/// # Rendering does not wait on resolution
///
/// Every row draws from what was stored beside the entry — title, artist,
/// source. A drive link is minted and a YouTube track resolved only when
/// something is played, so a playlist full of streamed music still reads
/// correctly with the phone offline; it just cannot play those rows.
library;

import 'package:eq_app/navigation/app_nav.dart';
import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../data/library_repository.dart';
import '../../models/cloud_file.dart';
import '../../services/mixes/mix_playback.dart';
import '../../services/mixes/mix_track_ref.dart';
import '../../services/ytmusic/yt_models.dart';
import '../../themes/ember.dart';

import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/motion/morph.dart';

class MixPlaylistPage extends StatefulWidget {
  const MixPlaylistPage({super.key, required this.playlist});

  final PlaylistSummary playlist;

  @override
  State<MixPlaylistPage> createState() => _MixPlaylistPageState();
}

class _MixPlaylistPageState extends State<MixPlaylistPage> {
  List<PlaylistItem> _items = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final items = await context.read<LibraryRepository>().playlistEntries(
      widget.playlist.id,
    );
    if (!mounted) return;
    setState(() {
      _items = items;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();

    return Scaffold(
      backgroundColor: Ember.ground,
      appBar: AppBar(
        backgroundColor: Ember.ground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: MorphTag(
          tag: headerTag(LibraryPageKey('mix', {'id': widget.playlist.id})),
          child: Text(
            widget.playlist.name,
            style: const TextStyle(color: Ember.textPrimary),
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          color: Ember.textPrimary,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: !_loaded
          ? const SizedBox.shrink()
          : _items.isEmpty
          ? Center(
              child: Text(
                'Nothing in here yet',
                style: TextStyle(color: Ember.textTertiary),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 100),
              itemCount: _items.length,
              itemBuilder: (context, index) => _row(controller, index),
            ),
    );
  }

  Widget _row(AppController controller, int index) {
    final item = _items[index];
    return ListTile(
      onTap: () => _playFrom(controller, index),
      leading: SizedBox(
        width: 34,
        child: Icon(_iconFor(item.source), size: 20, color: Ember.accent),
      ),
      title: Text(
        item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Ember.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        item.artist ?? _labelFor(item.source),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Ember.textTertiary, fontSize: 12),
      ),
    );
  }

  static IconData _iconFor(String source) => switch (source) {
    'cloud' => Icons.cloud_outlined,
    'youtube' => Icons.play_circle_outline_rounded,
    _ => Icons.music_note_rounded,
  };

  static String _labelFor(String source) => switch (source) {
    'cloud' => 'From your drive',
    'youtube' => 'From YouTube',
    _ => 'On this device',
  };

  Future<void> _playFrom(AppController controller, int index) async {
    final repo = context.read<LibraryRepository>();
    final refs = await _toRefs(controller, repo, _items.skip(index).toList());
    if (!mounted || refs.isEmpty) return;

    await AppNav.toPlayerWhileStarting(
      context,
      controller,
      () => MixPlayback.play(
        controller,
        ResolvedMixLike(refs),
        resolveCloud: (file) async {
          if (file.provider == CloudProvider.googleDrive) {
            return controller.googleDriveService.getStreamUrl(file.fileId);
          }
          return controller.dropboxService.getTemporaryLink(file.fileId);
        },
      ),
    );
  }

  /// Rebuilds playable references from stored rows.
  ///
  /// A stored entry keeps only what identifies the track — an id, and the title
  /// and artist to draw with. Everything else is looked up here: a local id
  /// against the library, a drive id against the cached file list, and a
  /// YouTube id rebuilt into the track shape the resolver takes.
  Future<List<MixTrackRef>> _toRefs(
    AppController controller,
    LibraryRepository repo,
    List<PlaylistItem> items,
  ) async {
    final localIds = {
      for (final item in items)
        if (item.source == 'local' && item.songId != null) item.songId!,
    };
    final byId = <int, SongModel>{};
    if (localIds.isNotEmpty) {
      for (final song in await repo.allSongs()) {
        if (localIds.contains(song.id)) byId[song.id] = song;
      }
    }

    final cloudById = <String, CloudFile>{};
    for (final provider in CloudProvider.values) {
      for (final file
          in controller.cloudCache.loadFileList(provider) ??
              const <CloudFile>[]) {
        cloudById[file.fileId] = file;
      }
    }

    final refs = <MixTrackRef>[];
    for (final item in items) {
      switch (item.source) {
        case 'cloud':
          final file = cloudById[item.externalId];
          if (file != null) refs.add(MixTrackRef.cloud(file));
        case 'youtube':
          final id = item.externalId;
          if (id == null) continue;
          refs.add(
            MixTrackRef.youtube(
              YtTrack(
                videoId: id,
                title: item.title,
                artist: item.artist,
                playlistId: '',
                playlistTitle: '',
              ),
            ),
          );
        default:
          final song = byId[item.songId];
          if (song != null) refs.add(MixTrackRef.local(song));
      }
    }
    return refs;
  }
}

/// A bare list of references, so [MixPlayback] can play something that is not a
/// generated mix without the playlist page having to pretend to be one.
class ResolvedMixLike implements ResolvedMixSource {
  const ResolvedMixLike(this.tracks);
  @override
  final List<MixTrackRef> tracks;
}
