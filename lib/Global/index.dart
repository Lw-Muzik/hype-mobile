import 'dart:io';
import 'dart:ui';

import '../player/actions/song_actions_sheet.dart';
import '/helpers/visualizer_widget.dart';
import '/helpers/index.dart';
import '/exports/exports.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../helpers/audio_handler.dart';
import '../routes/routes.dart';
import '../visualizers/multiwave_visualizer.dart';
import '../controllers/app_controller.dart';
import '../services/streaming_data_guard.dart';
import '../pages/visual_ui.dart';
import '../player/widgets/now_playing.dart';
import '../pages/equalizer.dart';
import '../player/lyrics_view.dart';
import '../widgets/artwork_widget.dart';
import '../widgets/listen_sheet.dart';
import '../services/video/video_registry.dart';
import '../services/ytmusic/yt_audio_source.dart';
import '../services/ytmusic/yt_innertube.dart';
import '../player/now_playing_hero.dart';
import '../Themes/ember.dart';

SystemUiOverlayStyle overlay = const SystemUiOverlayStyle(
  systemNavigationBarDividerColor: Colors.transparent,
  systemNavigationBarContrastEnforced: false,
  systemNavigationBarIconBrightness: Brightness.dark,
  systemNavigationBarColor: Colors.transparent,
);
PreferredSizeWidget kAppBar = AppBar(
  toolbarHeight: 0,
  systemOverlayStyle: overlay,
  forceMaterialTransparency: true,
);

Widget playerVisual(AppController controller) {
  return VisualizerWidget(
    builder: (context, fft, _, rate) {
      return fft.isNotEmpty
          ? CustomPaint(
              painter: MultiWaveVisualizer(
                color: Theme.of(
                  context,
                ).primaryColorLight.withValues(alpha: 0.1),
                waveData: fft,
                // width: MediaQuery.of(context).size.width,
                height: MediaQuery.of(context).size.height,
              ),
              child: const Center(),
            )
          : Container();
    },
    id: 0,
  );
}

Widget playerActionBar(AppController controller, BuildContext context) {
  return Container(
    margin: const EdgeInsets.symmetric(horizontal: 24),
    padding: const EdgeInsets.symmetric(vertical: 8),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // A dot while stems are changing the mix, wherever the user has gone:
        // without it, a song with no vocals is just a broken song.
        ValueListenableBuilder<bool>(
          valueListenable: controller.stemsController.engagedListenable,
          builder: (context, stemsOn, _) => _ActionItem(
            icon: Icons.equalizer_rounded,
            label: 'EQ',
            badge: stemsOn,
            badgeLabel: 'stems on',
            onTap: () =>
                Routes.routeTo(const Equalizer(), context, animate: true),
          ),
        ),
        _ActionItem(
          icon: Icons.lyrics_rounded,
          label: 'Lyrics',
          onTap: () {
            Navigator.of(context).push(
              PageRouteBuilder(
                opaque: false,
                pageBuilder: (_, __, ___) => const LyricsView(),
                transitionsBuilder: (_, anim, __, child) {
                  return SlideTransition(
                    position:
                        Tween<Offset>(
                          begin: const Offset(0, 1),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: anim,
                            curve: Curves.easeOutCubic,
                          ),
                        ),
                    child: child,
                  );
                },
                transitionDuration: const Duration(milliseconds: 350),
              ),
            );
          },
        ),
        _ActionItem(
          icon: Icons.graphic_eq_rounded,
          label: 'Visual',
          onTap: () => Routes.routeTo(const VisualUI(), context),
        ),
        _ActionItem(
          icon: Icons.queue_music_rounded,
          label: 'Queue',
          onTap: () {
            showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              isDismissible: true,
              backgroundColor: Colors.transparent,
              barrierColor: Colors.black54,
              builder: (context) {
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.pop(context),
                  child: GestureDetector(
                    onTap: () {},
                    child: DraggableScrollableSheet(
                      initialChildSize: 0.55,
                      minChildSize: 0.3,
                      maxChildSize: 0.92,
                      expand: false,
                      builder: (context, scrollController) {
                        return NowPlaying(
                          controller: controller,
                          scrollController: scrollController,
                        );
                      },
                    ),
                  ),
                );
              },
            );
          },
        ),
        _ActionItem(
          icon: Icons.hearing_rounded,
          label: 'Listen',
          onTap: () {
            showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              barrierColor: Colors.black54,
              builder: (_) => const ListenSheet(),
            );
          },
        ),
      ],
    ),
  );
}

class _ActionItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// A small gold dot on the icon: something on that screen is in effect.
  final bool badge;

  /// What the dot means, read out after [label] while it shows.
  final String? badgeLabel;

  const _ActionItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.badge = false,
    this.badgeLabel,
  });

  @override
  Widget build(BuildContext context) {
    final announceBadge = badge && badgeLabel != null;
    return Semantics(
      label: announceBadge ? '$label, $badgeLabel' : null,
      excludeSemantics: announceBadge,
      button: announceBadge ? true : null,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(icon, color: Colors.white70, size: 22),
                    Positioned(
                      right: -3,
                      top: -2,
                      child: AnimatedScale(
                        scale: badge ? 1 : 0,
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOutBack,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            // Solid gold is fine here — it carries no text —
                            // and the dark ring keeps it off the icon.
                            color: Ember.accent,
                            shape: BoxShape.circle,
                            border: Border.all(color: Ember.ground, width: 1.5),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget playerCard(
  Animation<double> animation,
  BuildContext context,
  AppController controller, {
  int? songIndex,
}) {
  final idx = songIndex ?? controller.songId;
  if (idx < 0 || idx >= controller.songs.length) return const SizedBox.shrink();
  final song = controller.songs[idx];

  return Align(
    alignment: const Alignment(0, -0.15),
    child: AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        return Transform.scale(
          scale: animation.value,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 420),
              child: AspectRatio(
                aspectRatio: 1.0,
                // The hero wraps the cover and NOTHING else. Wrapping the card
                // slot instead — the Align, the padding, the constraints — made
                // the flight run from a 42px thumbnail to a full-width box with
                // the artwork sitting somewhere inside it, which is why it read
                // as a jump rather than as the cover moving. Source and
                // destination have to be the same visible object.
                child: _artworkHero(
                  enabled: idx == controller.songId,
                  song: song,
                  child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 30,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: ArtworkWidget(
                      quality: 100,
                      borderRadius: BorderRadius.circular(18),
                      size: 1000,
                      songId: song.id,
                      type: ArtworkType.AUDIO,
                      path: song.data,
                    ),
                  ),
                ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// Ties this cover to the mini player's, or leaves it alone.
///
/// Only the card actually playing may carry the tag: the deck builds the tracks
/// either side too, and two heroes sharing a tag in one route is an assertion
/// failure rather than a worse animation.
Widget _artworkHero({
  required bool enabled,
  required SongModel song,
  required Widget child,
}) {
  if (!enabled) return child;
  // NO custom flightShuttleBuilder, deliberately.
  //
  // A shuttle builds a fresh subtree, and `ArtworkWidget` resolves its image
  // through a Future — showing `assets/audio.jpeg` until that lands. A new one
  // asks for a decode size neither end has cached, so it decodes from scratch
  // and has nothing to show for the whole flight; what appears instead is the
  // deck's own cards through an empty shuttle, which reads as the wrong album
  // flying.
  //
  // Flutter's default shuttle reuses the destination hero's own subtree, whose
  // image is already being resolved for the page it is landing on.
  return Hero(tag: kNowPlayingHeroTag, child: child);
}

/// Folder thumbnail. The representative track is now supplied by the caller
/// (from a single grouped DB query), replacing the old per-card `querySongs()`
/// scan of the entire library that made the Folders tab O(folders × library).
Widget folderArtwork(
  BuildContext context,
  String title, {
  int? sampleId,
  String? sampleData,
  int numSongs = 0,
}) {
  final side = MediaQuery.of(context).size.width;
  return Stack(
    children: [
      if (sampleId != null && sampleData != null)
        ArtworkWidget(
          quality: 50,
          size: 200,
          borderRadius: BorderRadius.circular(10),
          width: side,
          height: side,
          songId: sampleId,
          type: ArtworkType.AUDIO,
          path: sampleData,
        )
      else
        Container(
          width: side,
          height: side,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Icon(
            Icons.folder_rounded,
            size: 48,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.3),
          ),
        ),
      Positioned(
        right: 0,
        left: 0,
        bottom: -10,
        child: Card(
          margin: const EdgeInsets.all(10),
          color: Theme.of(context).primaryColorDark.withValues(alpha: 0.7),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          child: RichText(
            textAlign: TextAlign.center,
            text: TextSpan(
              children: [
                TextSpan(
                  text: "$title \n",
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall!.apply(color: Colors.white),
                ),
                TextSpan(
                  text: "$numSongs Songs",
                  style: Theme.of(context).textTheme.labelSmall!.apply(
                    color: Theme.of(context).primaryColorLight,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

Widget headerWidget(
  AppController controller,
  BuildContext context, {
  List<SongModel>? data,
  Widget? child,
}) {
  return Stack(
    children: [
      child ??
          ArtworkWidget(
            quality: 100,
            size: 3000,
            useSaved: data!.isNotEmpty,
            borderRadius: BorderRadius.zero,
            width: MediaQuery.of(context).size.width,
            height: MediaQuery.of(context).size.height,
            songId: data[data.length > 2 ? data.length - 2 : 0].id,
            type: ArtworkType.AUDIO,
            path: data[data.length > 2 ? data.length - 2 : 0].data,
          ),
      Container(
        width: MediaQuery.of(context).size.width,
        height: MediaQuery.of(context).size.height,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black26,
              Colors.black38,
              Colors.black45,
              Colors.black54,
              Colors.black87,
              Colors.black,
            ],
          ),
        ),
      ),
      if (data != null && data.isNotEmpty)
        Positioned(
          bottom: 160,
          left: 10,
          child: GestureDetector(
            onTap: () {
              List<SongModel> s = data;
              if (s.isNotEmpty) {
                controller.playSongFromList(s, 0);
              }
            },
            child: Card(
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text(
                      "Play All",
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Icon(Icons.play_circle_sharp, size: 35),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}

Future<void> loadAudioSource(
  HypeAudioHandler handler,
  SongModel song, {
  bool replayGain = false,

  /// Where to start the track. For a session restored from the last run, which
  /// has to resume mid-song rather than from the beginning.
  Duration? initialPosition,

  /// Whether to start playing once loaded.
  ///
  /// False when the caller is itself running inside `play()` — starting
  /// playback from in there would recurse through the handler.
  bool autoPlay = true,
}) async {
  // If a crossfade is mid-flight, settle it first (fast — one fade step) so
  // this load lands on the settled active player instead of the outgoing one
  // the fade loop is about to stop.
  await handler.abortCrossfade();

  final isCloud = song.data.startsWith('http');

  // Cancel any previous background cache download (don't waste data on skipped tracks)
  if (isCloud) {
    AppController.instance.cloudCache.cancelActiveDownload();
  }

  // Artwork: cloud tracks store thumbnail URL in album field
  String image;
  if (isCloud && song.album != null && song.album!.startsWith('http')) {
    image =
        await _downloadCloudArtwork(song.album!, song.id) ??
        await fetchArtworkUrl(song.data, song.id);
  } else {
    image = await fetchArtworkUrl(song.data, song.id);
  }

  // Don't pass artwork URLs as album name (discover songs store artwork in album field)
  final albumName = (song.album != null && !song.album!.startsWith('http'))
      ? song.album
      : null;

  MediaItem item = MediaItem(
    id: song.data,
    album: albumName,
    title: song.title,
    artist: song.artist,
    duration: Duration(milliseconds: song.duration ?? 0),
    artUri: image.startsWith('/') ? Uri.file(image) : Uri.parse(image),
  );

  handler.setCurrentMediaItem(item);

  // A video is loaded like any other track — same player, same handler, same
  // notification — but what it opens is the manifest this app wrote for it,
  // which lives beside the queue rather than in `data`. Still subject to the
  // data guard: video is the most expensive thing this app can stream.
  final video = VideoRegistry.instance.sourceFor(song.id);
  if (video != null) {
    final blockReason = StreamingDataGuard.instance.shouldBlockStream();
    if (blockReason != null) {
      debugPrint('Streaming blocked: $blockReason');
      return;
    }
    await handler.player.setAudioSource(
      video.toAudioSource(tag: item),
      initialPosition: initialPosition,
    );
    // Replay gain is read from ID3 tags, which a manifest has none of, so a
    // video always plays at unity — and must say so, or it inherits whatever
    // gain the last local file left behind.
    handler.setTrackGain(handler.player, 1.0);
    if (autoPlay) handler.player.play();
    return;
  }

  if (isCloud) {
    AudioSource source;
    final guard = StreamingDataGuard.instance;

    // YouTube streams — direct URI, no caching. The target is single-use and
    // 403s without the User-Agent of the client that resolved it.
    if (YtInnerTube.isStreamUrl(song.data)) {
      // The data guard applies to all streaming, Discover included.
      final blockReason = guard.shouldBlockStream();
      if (blockReason != null) {
        debugPrint('Streaming blocked: $blockReason');
        return;
      }
      source = ytAudioSource(item.id, tag: item);
    } else {
      // Cloud storage (Google Drive / Dropbox)
      final cache = AppController.instance.cloudCache;
      final auth = AppController.instance.cloudAuth;
      final fileId = song.id.toString();

      if (cache.isCached(fileId)) {
        // Cached — play from disk, zero data usage
        cache.markAccessed(fileId);
        source = AudioSource.file(cache.cacheFile(fileId).path, tag: item);
      } else {
        // Check data guard before streaming
        final blockReason = guard.shouldBlockStream();
        if (blockReason != null) {
          debugPrint('Streaming blocked: $blockReason');
          return;
        }

        // Get auth headers for cloud providers
        final headers = song.data.contains('googleapis.com')
            ? await auth.getGoogleAuthHeaders()
            : <String, String>{};

        // Stream via URI — ExoPlayer uses HTTP range requests internally,
        // only downloads what the buffer needs (~15-50s ahead).
        // This is how Spotify/Tidal work: no full-file download.
        source = AudioSource.uri(
          Uri.parse(item.id),
          headers: headers,
          tag: item,
        );

        // Background cache: download the full file separately for offline use.
        // This runs independently of playback and can be cancelled on skip.
        // On cellular with data saver, skip background caching entirely.
        if (!guard.isDataSaverActive) {
          cache.preCacheTrack(song.data, fileId, headers);
        }
      }

      // Prefetch next cloud track in background
      _prefetchNextTrack();
    }

    await handler.player.setAudioSource(
      source,
      initialPosition: initialPosition,
    );
  } else {
    // Local file: use AudioSource.file for proper path handling (spaces, special chars)
    if (song.data.startsWith('/')) {
      await handler.player.setAudioSource(
        AudioSource.file(song.data, tag: item),
        initialPosition: initialPosition,
      );
    } else {
      await handler.player.setAudioSource(
        AudioSource.uri(Uri.parse(item.id), tag: item),
        initialPosition: initialPosition,
      );
    }
  }

  // Replay gain only for local files (needs ID3 tags)
  if (replayGain && !isCloud) {
    final gain = await HypeAudioHandler.computeReplayGainVolume(song.data);
    handler.setTrackGain(handler.player, gain);
  } else {
    handler.setTrackGain(handler.player, 1.0);
  }

  if (autoPlay) handler.player.play();
}

/// Prefetch the next track in the current queue if conditions allow.
/// On cellular, only prefetches partial data (~512KB ≈ 30s at 128kbps).
/// On WiFi, prefetches the full file for offline use.
void _prefetchNextTrack() async {
  try {
    final ctrl = AppController.instance;
    final guard = StreamingDataGuard.instance;
    if (!guard.shouldPrefetch()) return;

    final songs = ctrl.songs;
    final currentIdx = ctrl.songId;
    if (songs.isEmpty || currentIdx >= songs.length - 1) return;

    final nextSong = songs[currentIdx + 1];
    if (!nextSong.data.startsWith('http')) return;
    // Don't prefetch discover streams (transient URLs)
    if (nextSong.data.contains('nowviba.com')) return;
    // A video's `data` is a watch page, not a media file: caching it would
    // store an HTML document under a song id and then play it. What the player
    // actually opens lives in the registry, and it expires anyway.
    if (VideoRegistry.instance.isVideo(nextSong.id)) return;

    final fileId = nextSong.id.toString();
    final cache = ctrl.cloudCache;
    if (cache.isCached(fileId) || cache.isDownloading(fileId)) return;

    debugPrint('Prefetch: Starting next track ${nextSong.title}');
    final headers = nextSong.data.contains('googleapis.com')
        ? await ctrl.cloudAuth.getGoogleAuthHeaders()
        : <String, String>{};

    // On cellular: only prefetch first 512KB (enough for ~30s at 128kbps)
    // On WiFi: prefetch entire file for offline use
    final maxBytes = guard.isCellular ? 512 * 1024 : 0; // 0 = unlimited
    await cache.preCacheTrack(
      nextSong.data,
      fileId,
      headers,
      maxBytes: maxBytes,
    );
  } catch (e) {
    debugPrint('Prefetch failed: $e');
  }
}

Future<String?> _downloadCloudArtwork(String url, int songId) async {
  try {
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/cloud_art_$songId.png');
    if (file.existsSync()) return file.path;
    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      await file.writeAsBytes(response.bodyBytes);
      return file.path;
    }
  } catch (_) {}
  return null;
}

/// The playing song's actions — the long press on the player's cover. See
/// `SongActionsSheet`.
void showTrackInfo(BuildContext context, AppController controller) {
  showSongActions(context, controller);
}
