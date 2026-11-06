/// Getting YouTube tracks into the player.
///
/// # Why the queue grows instead of being built
///
/// A YouTube track's URL only exists once it has been resolved, one request per
/// track. Resolving a fifty-track playlist before the first note would be five
/// to ten seconds of spinner. So the tapped track is resolved alone, playback
/// starts on it, and the rest arrive behind it — appended to the live queue,
/// never reloaded into it, because reloading would restart the song the user is
/// already listening to.
///
/// # What "play" means here
///
/// Tapping a track plays **from that track to the end of the list**, which is
/// what appending can express without ever disturbing what is already playing.
/// The tracks above it are reachable by "Play all", which starts at the top and
/// therefore queues everything.
library;

import 'package:eq_app/navigation/app_nav.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:provider/provider.dart';

import '../radio/radio_queue.dart';
import '../radio/youtube_station.dart';
import '../connect/connect_protocol.dart' show EnqueueMode;
import '../connect/remote/connect_play_router.dart';
import '../../controllers/app_controller.dart';
import '../../models/track_extras.dart';
import '../video/video_registry.dart';
import 'parse/yt_json.dart';
import 'yt_models.dart';
import 'yt_repository.dart';

class YtPlayback {
  const YtPlayback._();

  /// How many resolves to have in flight at once while filling the queue.
  ///
  /// Four keeps the queue ahead of playback comfortably without opening a burst
  /// of sockets on a phone radio — which is both slower in practice and the kind
  /// of pattern that earns rate-limiting.
  static const _resolveConcurrency = 4;

  /// Plays [tracks] from [index] onward.
  ///
  /// Returns once playback has started; the rest of the queue fills behind it.
  ///
  /// With [radio] set, the tapped track plays *alone* and an endless station is
  /// built from it instead — what a list of search results wants, where the
  /// items are candidates for one song rather than a running order, and queueing
  /// the other nineteen means following a song with its own remixes, covers and
  /// live versions. Honours the Autoplay preference: with that off the list is
  /// queued as before, because the user has asked the app not to go and find
  /// music by itself, and a queue of the results it already has is not that.
  static Future<void> play(
    BuildContext context,
    List<YtTrack> tracks,
    int index, {
    bool radio = false,
  }) {
    // Another device is the player: play there (Hype Connect remote mode).
    final routed = ConnectPlayRouter.yt(
      tracks,
      index,
      radio: radio,
      here: () => play(context, tracks, index, radio: radio),
    );
    if (routed != null) return routed;
    return playTracks(
      context.read<AppController>(),
      tracks,
      index,
      radio: radio,
      isWanted: () => context.mounted,
      complain: (message) {
        if (context.mounted) _complain(context, message);
      },
      onStarted: () {
        if (context.mounted) AppNav.toPlayer(context);
      },
    );
  }

  /// "Play next": [track] goes right after the song playing now, so it is the
  /// next thing heard and the rest of the queue follows it unchanged. With
  /// nothing playing there is no "after", so it simply starts (the player is
  /// not opened: the user asked for a queue change, not a screen change).
  /// While another device is the player it is queued there.
  ///
  /// Everything taken from [context] is read before the first wait, so it may
  /// be a sheet's context that closes straight after calling this.
  static Future<void> playNext(BuildContext context, YtTrack track) async {
    final routed = ConnectPlayRouter.enqueueYt([track], EnqueueMode.next);
    final messenger = ScaffoldMessenger.maybeOf(context);
    void say(String message) => messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
    if (routed != null) {
      await routed;
      say('Playing next');
      return;
    }
    final controller = context.read<AppController>();
    if (!track.isAvailable) {
      say("That song can't be played.");
      return;
    }
    if (!controller.hasNowPlaying) {
      return playTracks(controller, [track], 0, complain: say);
    }
    final target = await _resolveForPlay(track, say);
    if (target == null) return;
    await cacheArtwork(track);
    await controller.insertNext([songModelOf(track, target)]);
    say('Playing next');
  }

  /// [play] without a screen to speak to.
  ///
  /// Everything [play] does to the interface goes through a callback, so a
  /// caller with no `BuildContext` — Hype Connect, acting on a command from
  /// another device — can start the same playback without opening the player
  /// or showing a snack bar. [play] is this with the callbacks wired to the
  /// widget tree, so the two cannot drift apart.
  ///
  /// * [isWanted] is asked after each wait (the resolve, the cover); once it is
  ///   false nothing more is started. [play] answers it with `context.mounted`.
  /// * [complain] receives the sentence a user would be shown when nothing
  ///   could be played.
  /// * [onStarted] runs the moment the first track has been handed to the
  ///   player, before the queue fills — the in-app caller opens the player
  ///   screen there.
  /// * [startAt] starts the first track part-way in. It belongs to
  ///   `tracks[index]`, so it applies only when that track is the one that
  ///   plays: if it is unavailable and the next one plays instead, the position
  ///   would land in a song nobody asked to resume.
  ///
  /// The returned future completes once the first track is loaded (not once it
  /// has played) — last, after the queue fill and any station have been
  /// started, so a caller can order later actions behind it.
  static Future<void> playTracks(
    AppController controller,
    List<YtTrack> tracks,
    int index, {
    bool radio = false,
    Duration? startAt,
    bool Function()? isWanted,
    void Function(String message)? complain,
    void Function()? onStarted,
  }) async {
    bool wanted() => isWanted?.call() ?? true;
    if (tracks.isEmpty || index < 0 || index >= tracks.length) return;
    final playable = [
      for (final track in tracks.skip(index))
        if (track.isAvailable) track,
    ];
    if (playable.isEmpty) {
      complain?.call('Nothing in this list can be played.');
      return;
    }

    final first = playable.first;
    // The cover is fetched next to the resolve, not after it: they are
    // independent requests and waiting for them in turn would show a spinner
    // for the sum of the two.
    final artwork = cacheArtwork(first);
    final target = await _resolveForPlay(first, complain);
    if (target == null || !wanted()) return;
    await artwork;
    if (!wanted()) return;

    final load = controller.playSongFromList(
      [songModelOf(first, target)],
      0,
      initialPosition: identical(first, tracks[index]) ? startAt : null,
    );
    onStarted?.call();

    // Attached before the fill starts, not after: the fill takes the station it
    // is filling on the way in and stops if it stops being the current one, so
    // this station has to exist by then or the fill belongs to the last one.
    RadioQueue.instance.attach(YouTubeStation(seed: first.videoId));
    if (radio && RadioQueue.instance.enabled) {
      // Not `force`: this station is the app's idea, not one the user named, so
      // Autoplay governs it — which the `enabled` check above has already said
      // yes to. Reaching `fill` directly rather than waiting for the queue to
      // run low is the whole point: a queue of one has no "near the end".
      unawaited(RadioQueue.instance.fill(controller));
    } else {
      // Everything after the first track arrives behind the music.
      unawaited(_fillQueue(controller, playable.skip(1).toList()));
    }
    await load;
  }

  /// Plays [track] as video.
  ///
  /// # Watching is playing
  ///
  /// A video is not a screen this app navigates to, it is a track it plays. It
  /// enters the queue like any other, on the same player, inside the same
  /// background service — which is what gives it the equaliser, the lock-screen
  /// controls, the queue the user can reach and pick from, and a radio that
  /// takes over when it ends. None of those are video features. They are
  /// consequences of a video being an ordinary member of the queue instead of a
  /// second player standing beside it.
  ///
  /// The player screen is where it appears, because that is where playback
  /// lives.
  ///
  /// # When there is no video to show
  ///
  /// YouTube serves most music videos as separate audio and video streams that
  /// only a DASH manifest can recombine, and iOS cannot open DASH. Rather than
  /// refusing, the track plays as audio and says so — the user asked to hear
  /// this song, and the picture was the part the platform could not provide.
  static Future<void> watch(
    BuildContext context,
    YtTrack track, {

    /// The rest of the list [track] was tapped in.
    ///
    /// Queued behind it as videos, the way tapping a song queues the songs
    /// beside it. Without this, picking something in the Videos tab played one
    /// video and then a station of audio — one video, from a tab of videos.
    List<YtTrack> siblings = const [],
  }) async {
    final routed = ConnectPlayRouter.yt(
      [track, ...siblings],
      0,
      here: () => watch(context, track, siblings: siblings),
    );
    if (routed != null) return routed;
    final artwork = cacheArtwork(track);
    final StreamTarget target;
    try {
      target = await YtMusicRepository.instance
          .videoTarget(track.videoId)
          .timeout(const Duration(seconds: 25));
    } on TimeoutException {
      if (context.mounted) {
        _complain(context, 'YouTube took too long to answer.');
      }
      return;
    } catch (e) {
      // A dead target is worth forgetting so a retry re-resolves rather than
      // replaying the same expired URL.
      YtMusicRepository.instance.forget(track.videoId);
      if (!context.mounted) return;
      _complain(
        context,
        e is YtException ? e.message : 'That video would not play.',
      );
      return;
    }
    if (!context.mounted) return;

    if (target.format == YtStreamFormat.dash && Platform.isIOS) {
      _complain(
        context,
        'YouTube only offers this one as separate video and audio streams, '
        'which iOS cannot combine. Playing the audio.',
      );
      await play(context, [track], 0);
      return;
    }

    final songId = _songIdOf(track);
    // Set before the track is queued: `playSongFromList` clears the registry
    // when something that is not a YouTube stream takes over, and the mode has
    // to be in place for the queue that is about to be built, not after it.
    VideoRegistry.instance.videoMode = true;
    final video = await VideoRegistry.instance.adopt(
      songId: songId,
      videoId: track.videoId,
      target: target,
    );
    if (!context.mounted) return;
    if (video == null) {
      // The manifest could not be staged. The song is still worth playing.
      VideoRegistry.instance.videoMode = false;
      _complain(context, 'Could not prepare that video. Playing the audio.');
      await play(context, [track], 0);
      return;
    }
    await artwork;
    if (!context.mounted) return;

    final controller = context.read<AppController>();
    controller.playSongFromList([
      videoModelOf(track, expiresAt: target.expiresAt),
    ], 0);
    AppNav.toPlayer(context);

    // Attached before the radio is asked to fill, for the same reason
    // [play] does it in that order: a fill takes the station it is filling on
    // the way in, so this one has to exist before it starts.
    //
    // Unlike a tapped search result this is not gated on Autoplay: a queue of
    // exactly one video has nothing to follow it, and stopping dead after a
    // three-minute video is the behaviour being fixed. The preference governs
    // stations the app invents, and `fill` still honours it.
    RadioQueue.instance.attach(YouTubeStation(seed: track.videoId));

    // The rest of the tapped list first, as videos. Only when there is no list
    // — a single "Watch video" from a track's overflow — does the station take
    // over immediately.
    final rest = [
      for (final sibling in siblings)
        if (sibling.videoId != track.videoId && sibling.isAvailable) sibling,
    ];
    if (rest.isEmpty) {
      unawaited(RadioQueue.instance.fill(controller));
    } else {
      unawaited(_fillVideoQueue(controller, rest));
    }
  }

  /// Resolves [rest] as videos and appends them, a few at a time.
  ///
  /// Smaller batches than the audio path uses: a video target is heavier to
  /// resolve and each one writes a manifest to disk, so running far ahead of the
  /// user spends effort on videos they will most likely skip.
  static Future<void> _fillVideoQueue(
    AppController controller,
    List<YtTrack> rest,
  ) async {
    const batchSize = 6;
    // The queue these videos belong to; see [_fillQueue].
    final station = RadioQueue.instance.station;
    for (var i = 0; i < rest.length; i += batchSize) {
      final batch = rest.skip(i).take(batchSize).toList();
      final models = await resolveVideoModels(batch);
      // The user may have started something else by now; appending to a queue
      // they have left would graft this list onto it.
      if (models.isEmpty || !RadioQueue.instance.isStation(station)) return;
      await controller.appendToQueue(models);
    }
    if (!RadioQueue.instance.isStation(station)) return;
    await RadioQueue.instance.onIndexChanged(controller, controller.songId);
  }

  /// Resolves [tracks] as videos, registers their manifests and returns the
  /// queue entries for the ones that worked.
  ///
  /// Shared with the station, so a radio running in video mode produces the same
  /// kind of entry as a tapped list does.
  static Future<List<SongModel>> resolveVideoModels(
    List<YtTrack> tracks,
  ) async {
    final targets = await YtMusicRepository.instance.videoTargets([
      for (final track in tracks) track.videoId,
    ]);
    await Future.wait([for (final track in tracks) cacheArtwork(track)]);

    final models = <SongModel>[];
    for (final track in tracks) {
      final target = targets[track.videoId];
      if (target == null) continue;
      // iOS cannot open DASH, and a video that cannot be staged is not one to
      // queue. Skipped rather than substituted with its audio, which would put
      // a track with no picture into a queue of videos.
      if (target.format == YtStreamFormat.dash && Platform.isIOS) continue;
      final source = await VideoRegistry.instance.adopt(
        songId: _songIdOf(track),
        videoId: track.videoId,
        target: target,
      );
      if (source == null) continue;
      models.add(videoModelOf(track, expiresAt: target.expiresAt));
    }
    return models;
  }

  /// One video as the player's own model.
  ///
  /// `_data` is the watch URL rather than anything playable: what to open lives
  /// in [VideoRegistry], because a DASH target is a local manifest and a local
  /// path in this field would read as a downloaded file to every part of the app
  /// that inspects it — the artwork layer, the cloud cache, the radio's check
  /// for whether YouTube is still what's playing.
  static SongModel videoModelOf(YtTrack track, {int? expiresAt}) => SongModel({
    '_id': _songIdOf(track),
    '_data': 'https://music.youtube.com/watch?v=${track.videoId}',
    'title': track.title,
    'artist': track.artist ?? 'YouTube Music',
    'album': track.thumbnail,
    'duration': ((track.durationSecs ?? 0) * 1000).round(),
    '_display_name': '${track.title}.mp4',
    '_display_name_wo_ext': track.title,
    '_size': 0,
    'file_extension': 'mp4',
    'is_music': true,
    // A restored session finds the manifest gone — they are swept at every
    // launch — so a video entry has to say that it *is* one, or it comes
    // back as audio.
    TrackKeys.videoId: track.videoId,
    TrackKeys.isVideo: true,
    TrackKeys.expiresAt: expiresAt,
  });

  /// Starts a station built from one song — YouTube's "Start radio".
  ///
  /// The seed plays immediately and its related tracks arrive behind it, then
  /// keep arriving for as long as the user listens. This is the *explicit*
  /// version of what [RadioQueue] does on its own near the end of a queue,
  /// and unlike that one it is **not gated on the Autoplay preference**: the
  /// setting governs radio the app starts by itself, not radio the user asked
  /// for by name.
  static Future<void> startRadio(BuildContext context, YtTrack seed) async {
    final routed = ConnectPlayRouter.yt(
      [seed],
      0,
      radio: true,
      here: () => startRadio(context, seed),
    );
    if (routed != null) return routed;
    final artwork = cacheArtwork(seed);
    final target = await _resolveForPlay(seed, (message) {
      if (context.mounted) _complain(context, message);
    });
    if (target == null || !context.mounted) return;
    await artwork;
    if (!context.mounted) return;

    final controller = context.read<AppController>();
    controller.playSongFromList([songModelOf(seed, target)], 0);
    AppNav.toPlayer(context);

    RadioQueue.instance.attach(YouTubeStation(seed: seed.videoId));
    unawaited(RadioQueue.instance.fill(controller, force: true));
  }

  /// Resolves the rest of a list and appends it in order.
  ///
  /// Order is preserved by appending a batch at a time: the requests inside a
  /// batch overlap, but the batches themselves land in sequence, so the queue
  /// never reorders itself while the user is watching it.
  static Future<void> _fillQueue(
    AppController controller,
    List<YtTrack> rest,
  ) async {
    // The queue this list belongs to. Resolving takes seconds per batch, and
    // what the user does in them decides whether any of this is still wanted:
    // asking only whether *a* YouTube queue is playing would append this list
    // to whatever they started instead.
    final station = RadioQueue.instance.station;
    for (var i = 0; i < rest.length; i += _resolveConcurrency) {
      final batch = rest.skip(i).take(_resolveConcurrency).toList();
      final targets = await YtMusicRepository.instance.audioTargets([
        for (final track in batch) track.videoId,
      ], concurrency: _resolveConcurrency);
      await Future.wait([for (final track in batch) cacheArtwork(track)]);
      final models = <SongModel>[
        for (final track in batch)
          if (targets[track.videoId] case final target?)
            songModelOf(track, target),
      ];
      // The user may have started something else entirely by now; appending to
      // a queue they've left would graft this playlist onto it.
      if (!RadioQueue.instance.isStation(station)) return;
      await controller.appendToQueue(models);
    }

    // Radio normally tops up as the queue advances, but a queue that is already
    // short has no advance to wait for — play one song and nothing would ever
    // ask for more. Asking here covers it, and still honours both the Autoplay
    // preference and the headroom check.
    if (!RadioQueue.instance.isStation(station)) return;
    await RadioQueue.instance.onIndexChanged(controller, controller.songId);
  }

  /// Puts a track's cover where the app's artwork layer will look for it.
  ///
  /// `ArtworkService.pathFor` handles an `http` track by *reading*
  /// `cloud_art_<id>.png` out of the temp directory — it never fetches. The
  /// fetch lives in `AppController`, and it runs after the player is already
  /// showing the track, by which time `ArtworkWidget` has memoised a future
  /// that resolved to nothing. The result is a cover that stays default for the
  /// whole song.
  ///
  /// Writing the file *before* the track is handed over closes that race: the
  /// widget's first resolve finds it. Failures are silent — a missing cover is
  /// a placeholder, never a reason not to play.
  static Future<void> cacheArtwork(YtTrack track) async {
    final url = track.thumbnail;
    if (url == null || url.isEmpty) return;
    final id = _songIdOf(track);
    try {
      final file = File(
        '${(await getTemporaryDirectory()).path}/cloud_art_$id.png',
      );
      if (file.existsSync() && await file.length() > 0) return;
      // Asked for at a size worth showing full-screen without being the 544 px
      // original for a track that may never be looked at.
      final response = await http.get(Uri.parse(thumbnailAt(url, 512)));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return;
      await file.writeAsBytes(response.bodyBytes);
    } catch (_) {
      // No cover is a placeholder. It is never a reason to fail a play.
    }
  }

  /// The id the player and the artwork layer agree to know this track by.
  static int _songIdOf(YtTrack track) => track.videoId.hashCode.abs();

  /// One track as the player's own model.
  ///
  /// Follows the convention the rest of this app already uses for streamed
  /// tracks: `_data` is the URL to play and the artwork URL rides in `album`,
  /// which is what `loadAudioSource` reads it out of.
  static SongModel songModelOf(YtTrack track, StreamTarget target) =>
      SongModel({
        '_id': _songIdOf(track),
        '_data': target.url,
        'title': track.title,
        'artist': track.artist ?? 'YouTube Music',
        'album': track.thumbnail,
        'duration': ((track.durationSecs ?? 0) * 1000).round(),
        '_display_name': '${track.title}.m4a',
        '_display_name_wo_ext': track.title,
        '_size': 0,
        'file_extension': 'm4a',
        'is_music': true,
        // The URL above is single-use and stops working in about six hours. A
        // queue saved tonight and reopened tomorrow needs the id to build a new
        // one, and the deadline to know that it has to. See `TrackExtras`.
        TrackKeys.videoId: track.videoId,
        TrackKeys.expiresAt: target.expiresAt,
      });

  /// Resolves [track] for playback.
  ///
  /// No overlay, no spinner. A prefetched track resolves in zero time and a cold
  /// one in about 250 ms — putting a modal over that makes an instant action
  /// look like a slow one, and the app's loading language is skeletons anyway.
  ///
  /// The resolve is bounded: a request that cannot finish must become an error
  /// the user can act on, never an interface that waits forever.
  static Future<StreamTarget?> _resolveForPlay(
    YtTrack track,
    void Function(String message)? complain,
  ) async {
    try {
      return await YtMusicRepository.instance
          .audioTarget(track.videoId)
          .timeout(const Duration(seconds: 25));
    } on TimeoutException {
      complain?.call('YouTube took too long to answer.');
      return null;
    } on YtException catch (e) {
      complain?.call(e.message);
      return null;
    } catch (e) {
      complain?.call('Could not play that: $e');
      return null;
    }
  }

  static void _complain(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }
}
