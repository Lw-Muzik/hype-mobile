/// What the library pages add to the shared `media_widgets.dart`: artwork from
/// the phone's own files, and the handful of rules about local songs the album,
/// artist and playlist pages all need.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:provider/provider.dart';

import '../../../controllers/app_controller.dart';
import '../../../services/artwork_service.dart';
import '../../../widgets/bottom_player.dart';
import '../../../widgets/song_options_sheet.dart';
import 'media_widgets.dart';

/// One place artwork might be found: a song's own cover, an album's, an
/// artist's.
class LocalArtSource {
  const LocalArtSource({
    required this.id,
    this.data = '',
    this.type = ArtworkType.AUDIO,
    this.other = '',
  });

  /// A song's cover.
  factory LocalArtSource.song(SongModel song) =>
      LocalArtSource(id: song.id, data: song.data);

  final int id;
  final String data;
  final ArtworkType type;
  final String other;
}

/// Artwork from the library, decoded at the size it is drawn — the same
/// discipline as `YtArtwork`. Tries each of [sources] in turn, so an artist
/// with no portrait of their own shows the cover of one of their songs; when
/// none has a picture, the same empty square YouTube art falls back to.
///
/// With no [size] it fills whatever it is given (a backdrop), decoding at
/// [fillDecodeWidth].
class LocalArtwork extends StatefulWidget {
  const LocalArtwork({
    super.key,
    required this.sources,
    this.size,
    this.circular = false,
    this.placeholder = Icons.music_note_rounded,
    this.fillDecodeWidth = 200,
  });

  final List<LocalArtSource> sources;
  final double? size;
  final bool circular;
  final IconData placeholder;
  final int fillDecodeWidth;

  @override
  State<LocalArtwork> createState() => _LocalArtworkState();
}

class _LocalArtworkState extends State<LocalArtwork> {
  Future<ImageProvider?>? _image;
  int? _decode;
  StreamSubscription<int>? _replaced;

  @override
  void initState() {
    super.initState();
    // "Find artwork" swaps a song's cover everywhere it shows.
    _replaced = ArtworkService.instance.changes.listen((id) {
      if (mounted && widget.sources.any((s) => s.id == id)) {
        setState(() => _image = null);
      }
    });
  }

  @override
  void didUpdateWidget(covariant LocalArtwork old) {
    super.didUpdateWidget(old);
    if (old.sources.length != widget.sources.length ||
        !_sameSources(old.sources, widget.sources)) {
      _image = null;
    }
  }

  static bool _sameSources(List<LocalArtSource> a, List<LocalArtSource> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          a[i].type != b[i].type ||
          a[i].other != b[i].other ||
          a[i].data != b[i].data) {
        return false;
      }
    }
    return true;
  }

  @override
  void dispose() {
    _replaced?.cancel();
    super.dispose();
  }

  Future<ImageProvider?> _resolve(int decode) async {
    for (final s in widget.sources) {
      String? path;
      try {
        path = await ArtworkService.instance.pathFor(
          id: s.id,
          data: s.data,
          type: s.type,
          other: s.other,
        );
      } catch (_) {
        // A source the media store can't answer for: try the next one.
      }
      if (path != null) {
        return ResizeImage(
          FileImage(File(path)),
          width: decode,
          policy: ResizeImagePolicy.fit,
        );
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final decode = size == null
        ? widget.fillDecodeWidth
        : (size * MediaQuery.devicePixelRatioOf(context)).round();
    if (_image == null || _decode != decode) {
      _decode = decode;
      _image = _resolve(decode);
    }
    final radius = mediaArtRadius(size ?? 0, circular: widget.circular);
    return FutureBuilder<ImageProvider?>(
      future: _image,
      builder: (context, snap) {
        final image = snap.data;
        if (image == null) {
          return size == null
              ? const SizedBox.shrink()
              : MediaArtFallback(
                  size: size,
                  circular: widget.circular,
                  icon: widget.placeholder,
                );
        }
        final picture = Image(
          image: image,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        );
        return size == null
            ? picture
            : ClipRRect(borderRadius: radius, child: picture);
      },
    );
  }
}

/// The song playing now, as its id (-1 for none). Selecting just this lets a
/// page rebuild when the song changes rather than on everything the controller
/// reports.
int currentLocalSongId(BuildContext context) =>
    context.select<AppController, int>((c) {
      final index = c.songId;
      if (index < 0 || index >= c.songs.length) return -1;
      return c.songs[index].id;
    });

/// "Artist • Album" for a row, leaving out whichever the page already says.
String? localByline(SongModel song, {bool artist = true, bool album = true}) {
  final a = artist ? _clean(song.artist) : null;
  final b = album ? _clean(song.album) : null;
  if (a != null && b != null && a != b) return '$a • $b';
  return a ?? b;
}

String? _clean(String? s) {
  final t = s?.trim();
  if (t == null || t.isEmpty || t == '<unknown>') return null;
  return t;
}

/// "12 songs • 42 minutes".
String localFacts(List<SongModel> songs) {
  final n = songs.length;
  final ms = songs.fold<int>(0, (sum, s) => sum + (s.duration ?? 0));
  final count = n == 1 ? '1 song' : '$n songs';
  return ms <= 0 ? count : '$count • ${mediaTotalLength(ms / 1000)}';
}

String? localClock(SongModel song) {
  final ms = song.duration;
  return ms == null ? null : mediaClock(ms / 1000);
}

/// The overflow / long-press menu every library list opens.
void showLocalSongOptions(BuildContext context, SongModel song) {
  showModalBottomSheet(
    context: context,
    builder: (_) => SongOptionsSheet(song: song),
  );
}

/// Queues [songs] right after the playing track. With nothing playing there is
/// no "after", so they simply start.
Future<void> playLocalNext(BuildContext context, List<SongModel> songs) async {
  if (songs.isEmpty) return;
  final controller = context.read<AppController>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (!controller.hasNowPlaying) {
    await controller.playSongFromList(songs, 0);
    return;
  }
  await controller.insertNext(songs);
  messenger?.showSnackBar(
    SnackBar(
      content: Text(
        songs.length == 1
            ? 'Playing next'
            : 'Playing ${songs.length} songs next',
      ),
      duration: const Duration(seconds: 2),
    ),
  );
}

/// The mini player, under the page while something is loaded.
class LocalMiniPlayerBar extends StatelessWidget {
  const LocalMiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context) => Consumer<AppController>(
    builder: (context, c, _) =>
        c.hasMiniPlayer ? BottomPlayer(controller: c) : const SizedBox.shrink(),
  );
}
