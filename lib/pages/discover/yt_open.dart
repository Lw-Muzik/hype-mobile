/// What tapping something in Discover does.
///
/// Kept in one place because every screen shows the same five kinds of thing and
/// they must behave identically wherever they appear: a playlist opens the same
/// way from a genre shelf, a search result and an artist page.
///
/// The rule, taken from desktop: **opening a tile lists its tracks rather than
/// playing them.** Browsing is how you find out what something is, and a hundred
/// tracks starting unannounced on a single tap answers a question the user
/// hadn't asked yet. Rows — songs and videos — are the exception: they name one
/// thing to play, so they play.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../Routes/routes.dart';
import '../../config/app_config.dart';
import '../../controllers/library_controller.dart';
import '../../services/ytmusic/yt_download.dart';
import '../../services/ytmusic/yt_downloads.dart';
import '../../services/ytmusic/yt_models.dart';
import '../../services/ytmusic/yt_playback.dart';
import 'artist_page.dart';
import 'opened_list_page.dart';

/// Opens [item], using [siblings] as the queue when it turns out to be a track.
///
/// [radio] asks for a station seeded from the tapped song instead of a queue of
/// its [siblings] — see [YtPlayback.play], which also decides what the Autoplay
/// preference has to say about it.
void openExploreItem(
  BuildContext context,
  ExploreItem item, {
  List<ExploreItem> siblings = const [],
  bool radio = false,
}) {
  switch (item.kind) {
    case ExploreKind.playlist:
    case ExploreKind.album:
      Routes.routeTo(YtOpenedListPage(item: item), context);
    case ExploreKind.artist:
      Routes.routeTo(YtArtistPage(item: item), context);
    case ExploreKind.video:
      // A video plays with the videos it was listed alongside, exactly as a
      // song plays with its siblings. Picking the third result in the Videos
      // tab used to give one video and then a station of audio.
      final videos = [
        for (final sibling in siblings)
          if (sibling.kind == ExploreKind.video) sibling.asTrack(),
      ];
      YtPlayback.watch(context, item.asTrack(), siblings: videos);
    case ExploreKind.song:
      // A song plays with whatever it was listed alongside, so tapping the
      // third song on a shelf continues into the fourth rather than stopping.
      final queue = [
        for (final sibling in siblings)
          if (sibling.kind == ExploreKind.song) sibling,
      ];
      final index = queue.indexWhere((s) => s.id == item.id);
      final tracks = queue.isEmpty
          ? [item.asTrack()]
          : [for (final song in queue) song.asTrack()];
      YtPlayback.play(context, tracks, index < 0 ? 0 : index, radio: radio);
  }
}

/// The actions on a track: radio, watch it and, in the direct build, download it.
///
/// Shown from the overflow on a row rather than on a long press, because a long
/// press inside a scrolling list is a gesture people trigger by accident.
Future<void> showTrackActions(BuildContext context, YtTrack track) async {
  final theme = Theme.of(context);
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: theme.colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
            child: Text(
              track.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.radio_rounded),
            title: const Text('Start radio'),
            subtitle: const Text('An endless station built from this song'),
            onTap: () {
              Navigator.pop(sheetContext);
              YtPlayback.startRadio(context, track);
            },
          ),
          if (track.hasVideo)
            ListTile(
              leading: const Icon(Icons.play_circle_outline_rounded),
              title: const Text('Watch video'),
              onTap: () {
                Navigator.pop(sheetContext);
                YtPlayback.watch(context, track);
              },
            ),
          if (AppConfig.directBuild)
            ListTile(
              leading: const Icon(Icons.download_rounded),
              title: const Text('Download'),
              subtitle: const Text('Saves to your music library'),
              onTap: () {
                Navigator.pop(sheetContext);
                startDownload(context, track);
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Downloads [track], reporting progress and the outcome in one snack bar.
///
/// Deliberately fire-and-forget from the caller's point of view: a download is
/// something you set going and keep browsing, not something you wait on. One
/// already running is not started twice — see [YtDownloads].
///
/// [showProgress] false leaves the progress to whatever started it (the
/// player's song actions draw it in their download button) and reports only
/// how it ended.
void startDownload(
  BuildContext context,
  YtTrack track, {
  bool showProgress = true,
}) {
  // Store builds hide every download button; this stops any caller added later.
  if (!AppConfig.directBuild) return;
  final messenger = ScaffoldMessenger.of(context);
  if (YtDownloads.instance.isRunning(track.videoId)) {
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('Already downloading ${track.title}'),
      ),
    );
    return;
  }
  final progress = ValueNotifier<double?>(null);

  if (showProgress) {
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(minutes: 10),
        behavior: SnackBarBehavior.floating,
        content: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (context, value, _) => Row(
            children: [
              SizedBox(
                width: 60,
                child: LinearProgressIndicator(
                  value: value,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  'Downloading ${track.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Captured before the await: the widget that started this may well be gone
  // by the time the download finishes, and reading a provider off a dead
  // context throws.
  final library = context.read<LibraryController>();

  YtDownloads.instance
      .download(track, onProgress: (value) => progress.value = value)
      .then((result) async {
        // A saved track that the Library does not list has not, as far as the user
        // is concerned, been saved. Android's MediaStore insert and iOS's write
        // into Documents/Music both need a scan before the row exists.
        if (result is YtDownloadSaved) await library.rescan();
        if (showProgress) messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(switch (result) {
              YtDownloadSaved(inLibrary: true) => 'Saved to your music library',
              YtDownloadSaved(inLibrary: false) => 'Saved to this app',
              YtDownloadFailed(:final message) => message,
            }),
          ),
        );
        // Deliberately not disposed. Hiding a snack bar is animated, so its builder
        // is still listening well past this point, and disposing underneath it
        // throws. Nothing else holds the notifier once that widget is gone, so it
        // is collected on its own — which is the cheaper of the two mistakes.
      });
}

/// Downloads every track in a list.
///
/// Shows one snack bar for the whole run rather than one per track: fifty
/// stacked notifications would bury the app, and the only thing worth saying
/// while it works is which track and how far through.
///
/// The summary distinguishes "all saved" from "some saved" and names the count,
/// because a playlist where three videos are unavailable is the normal case
/// rather than an error, and reporting it as a flat success would be a lie.
void startPlaylistDownload(BuildContext context, List<YtTrack> tracks) {
  if (!AppConfig.directBuild || tracks.isEmpty) return;

  final messenger = ScaffoldMessenger.of(context);
  final library = context.read<LibraryController>();
  final progress = ValueNotifier<double>(0);
  final label = ValueNotifier<String>('Starting…');
  var cancelled = false;

  messenger.showSnackBar(
    SnackBar(
      duration: const Duration(days: 1),
      behavior: SnackBarBehavior.floating,
      content: Row(
        children: [
          SizedBox(
            width: 60,
            child: ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (context, value, _) => LinearProgressIndicator(
                value: value,
                minHeight: 4,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: ValueListenableBuilder<String>(
              valueListenable: label,
              builder: (context, value, _) =>
                  Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
      ),
      action: SnackBarAction(label: 'Stop', onPressed: () => cancelled = true),
    ),
  );

  YtDownloader.downloadAll(
    tracks,
    isCancelled: () => cancelled,
    onTrack: (index, total, title) {
      label.value = '${index + 1} of $total · $title';
      progress.value = index / total;
    },
    onProgress: (_) {},
  ).then((results) async {
    // In order, one per track until a stop: each saved one is remembered so
    // the player knows it is downloaded.
    for (var i = 0; i < results.length; i++) {
      if (results[i] case YtDownloadSaved(:final path)) {
        await YtDownloads.instance.remember(tracks[i].videoId, path);
      }
    }
    final saved = results.whereType<YtDownloadSaved>().length;
    if (saved > 0) await library.rescan();
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(switch ((saved, results.length)) {
          (0, _) => 'Nothing could be downloaded',
          final s when s.$1 == tracks.length => 'Saved all ${s.$1} tracks',
          final s =>
            'Saved ${s.$1} of ${tracks.length} '
                '(${tracks.length - s.$1} unavailable)',
        }),
      ),
    );
  });
}
