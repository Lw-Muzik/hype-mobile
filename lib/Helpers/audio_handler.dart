import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio/video.dart';
import 'package:id3tag/id3tag.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../player/fade_cancellation.dart';
import '../player/output_gain.dart';
import 'index.dart';

class HypeAudioHandler extends BaseAudioHandler {
  /// Data-conscious streaming configuration (Spotify-style drip-feed):
  /// - Android: drip-feed buffer (min == max at 30s) prevents bursty over-download.
  ///   ExoPlayer downloads in ~1MB chunks; 30s is enough for smooth playback
  ///   while keeping data usage proportional to actual listening time.
  ///   Fast start at 2s, quick rebuffer at 4s.
  /// - iOS: auto-wait to minimize stalling, 30s forward buffer,
  ///   preferredPeakBitRate limits bandwidth on cellular.
  static final _streamingLoadConfig = AudioLoadConfiguration(
    androidLoadControl: const AndroidLoadControl(
      minBufferDuration: Duration(seconds: 30),
      maxBufferDuration: Duration(seconds: 30),
      bufferForPlaybackDuration: Duration(seconds: 2),
      bufferForPlaybackAfterRebufferDuration: Duration(seconds: 4),
      prioritizeTimeOverSizeThresholds: true,
    ),
    darwinLoadControl: const DarwinLoadControl(
      automaticallyWaitsToMinimizeStalling: true,
      preferredForwardBufferDuration: Duration(seconds: 30),
    ),
  );

  // `useProxyForRequestHeaders: false` — send request headers natively rather
  // than through just_audio's local HTTP proxy.
  //
  // By default, *any* source carrying headers is rewritten to
  // `http://127.0.0.1:<port>/<original path and query>` and served by a
  // cleartext proxy inside the app. That is a poor fit for YouTube: a
  // googlevideo URL carries a thousand-character query string, and the proxy
  // sits between the player and the CDN for every Range request and every seek.
  // With this off, ExoPlayer uses `setDefaultRequestProperties` and AVPlayer
  // uses `AVURLAssetHTTPHeaderFieldsKey`, so the player talks to the CDN
  // directly — no extra hop, native Range and seek, and no dependence on
  // cleartext traffic being permitted.
  final AudioPlayer _playerA = AudioPlayer(
    audioLoadConfiguration: _streamingLoadConfig,
    useProxyForRequestHeaders: false,
  );
  final AudioPlayer _playerB = AudioPlayer(
    audioLoadConfiguration: _streamingLoadConfig,
    useProxyForRequestHeaders: false,
  );
  late AudioPlayer _activePlayer;
  late AudioPlayer _inactivePlayer;

  StreamSubscription<PlaybackEvent>? _playbackSub;
  bool _isCrossfading = false;

  /// Set while a crossfade is in flight; completed when it settles (normal
  /// completion, abort, or failure). Lets control paths await a fast settle.
  Completer<void>? _fadeDone;

  /// The current crossfade's cancel flag, or null when none is running.
  ///
  /// Deliberately not a plain bool. A crossfade spends most of its life in an
  /// await — loading the next track off the network, fetching its artwork,
  /// sleeping between volume steps — and a flag that is only *read* is noticed
  /// whenever that await happens to finish. Waking the fade is what makes a
  /// press of next act now rather than whenever the network comes back.
  FadeCancellation? _cancellation;

  /// Every volume either player is given: its track gain times the listener
  /// volume. See [OutputGain] — nothing writes a player's volume directly.
  late final OutputGain<AudioPlayer> _gain = OutputGain(
    (player, volume) => unawaited(player.setVolume(volume)),
  );

  /// Sets [player]'s track gain: ReplayGain, a crossfade step, unity for a
  /// video. Applied under the listener volume, which it never overwrites.
  void setTrackGain(AudioPlayer player, double gain) =>
      _gain.setTrack(player, gain);

  /// [player]'s track gain, before the listener volume.
  double trackGainOf(AudioPlayer player) => _gain.trackOf(player);

  /// How loud the listener wants it, 0..1 — where a Hype Connect remote's
  /// volume lands on iOS. Survives loads and crossfades; 1 until set.
  double get listenerVolume => _gain.listener;

  /// Sets [listenerVolume] on both players, so a change mid-crossfade reaches
  /// the outgoing track as well as the incoming one.
  void setListenerVolume(double volume) =>
      _gain.setListener(volume, [_playerA, _playerB]);

  /// The primary player used for playback controls (play/pause/stop/seek).
  AudioPlayer get player => _activePlayer;

  /// Video surfaces, one per player, created the first time one is asked for.
  ///
  /// Keyed by player rather than held as a single field because there are two
  /// of them for crossfading, and a surface belongs to the engine that draws
  /// into it. A video crossfades like anything else, so the picture has to move
  /// between them as the fade hands over — see [detachAllVideo] and
  /// `VideoSurface.rebind`.
  final Map<AudioPlayer, VideoOutput> _videoOutputs = {};

  /// The video surface of whichever player is currently audible.
  VideoOutput get video => videoOutputFor(currentTrackPlayer);

  VideoOutput videoOutputFor(AudioPlayer player) =>
      _videoOutputs.putIfAbsent(player, () => VideoOutput(player));

  /// Hands back every surface except [except]'s.
  ///
  /// A crossfade ends by swapping which player is active, so the picture has to
  /// move with it, and the player the fade just stopped must not be left
  /// holding a surface — that is the frozen last frame of the previous video
  /// over the new one's soundtrack.
  ///
  /// [except] is the player that should keep what it has. Sweeping up *every*
  /// surface and re-attaching afterwards reads more simply and is wrong twice
  /// over: it tears the incoming player's texture down and rebuilds it for no
  /// reason, and because both halves are asynchronous the sweep arrives after
  /// the re-attach and undoes it, blacking out the video until a host claims
  /// the surface again.
  ///
  /// The snapshot matters for the same reason: attaching creates a surface for
  /// a player that may not have had one, and inserting into a map while
  /// iterating it throws — a crossfade into the first video of a session hit
  /// exactly that.
  Future<void> detachAllVideo({AudioPlayer? except}) async {
    for (final entry in _videoOutputs.entries.toList()) {
      if (identical(entry.key, except)) continue;
      await entry.value.detach();
    }
  }

  /// The player that has the latest track loaded.
  /// During crossfade this returns the incoming player (new track).
  /// Outside crossfade this is the same as [player].
  AudioPlayer get currentTrackPlayer =>
      _isCrossfading ? _inactivePlayer : _activePlayer;

  /// Repeat mode, held here rather than on one player.
  ///
  /// There are two players so tracks can crossfade, and a crossfade ends by
  /// swapping which one is active. Setting the mode on `player` alone therefore
  /// survived exactly until the first crossfade, after which the incoming
  /// player — which had never been told — silently reverted to no repeat. Both
  /// are set, always, so the swap cannot lose it.
  LoopMode _loopMode = LoopMode.off;

  LoopMode get loopMode => _loopMode;

  Future<void> setLoopMode(LoopMode mode) async {
    _loopMode = mode;
    await Future.wait([
      _playerA.setLoopMode(mode),
      _playerB.setLoopMode(mode),
    ]);
  }

  VoidCallback? onSkipToNext;
  VoidCallback? onSkipToPrevious;

  /// Fired right after the new track starts playing on the incoming player
  /// (before the fade begins) so the UI can bind to [currentTrackPlayer].
  VoidCallback? onCrossfadeStarted;

  /// Fired after a crossfade completes so AppController can re-bind streams.
  VoidCallback? onPlayerSwapped;

  HypeAudioHandler() {
    _activePlayer = _playerA;
    _inactivePlayer = _playerB;
    _bindPlaybackState();
  }

  /// Called when the player rejects what it was given — a dead stream URL, a
  /// file that has gone, a format it cannot open.
  ///
  /// Something has to be listening. An error on [AudioPlayer.playbackEventStream]
  /// with no `onError` is an unhandled async error: it never reaches this class,
  /// the queue stops where it stands, and the interface goes on showing a pause
  /// button over a track at 00:00. That is the whole of "it just doesn't play".
  void Function(Object error)? onPlaybackError;

  /// The error already handed to [onPlaybackError], so one failure is reported
  /// once rather than on every event that follows it.
  int? _reportedErrorCode;

  void _bindPlaybackState() => bindPlaybackEvents(_activePlayer.playbackEventStream);

  /// Binds [events] as the source of playback state.
  ///
  /// Takes the stream rather than reading it off the active player so a test
  /// can deliver a failure without a device, a network and a dead URL.
  @visibleForTesting
  void bindPlaybackEvents(Stream<PlaybackEvent> events) {
    _playbackSub?.cancel();
    _reportedErrorCode = null;
    _playbackSub = events.listen(
      (event) {
        playbackState.add(_transformEvent(event));
        _reportError(event);
      },
      // Not the path Android takes — see [_reportError] — but the one an
      // upstream just_audio and the darwin side use, and an unobserved error
      // here would be an unhandled async error rather than a reported one.
      onError: (Object error) => onPlaybackError?.call(error),
      // The default would cancel the subscription on the first failure, so one
      // dead track would take every later track's state reporting with it.
      cancelOnError: false,
    );
  }

  /// Reports a track the player could not open.
  ///
  /// The error arrives as *data*, not as a stream error. `AudioPlayer.java`
  /// calls `sendError`, which does two things: it raises an error on the event
  /// channel — which this fork of just_audio swallows with an empty `onError`
  /// handler — and it sets `errorCode`/`errorMessage` on the next ordinary
  /// event, switching the processing state to idle. Only the second of those
  /// survives to Dart, so this is where a dead track is actually detectable.
  ///
  /// Reported on the edge into an error, so a failure is acted on once. The
  /// platform clears `errorCode` when it loads something new, which is what
  /// re-arms this.
  void _reportError(PlaybackEvent event) {
    final code = event.errorCode;
    if (code == null) {
      _reportedErrorCode = null;
      return;
    }
    if (code == _reportedErrorCode) return;
    _reportedErrorCode = code;
    onPlaybackError?.call(PlayerException(code, event.errorMessage, event.currentIndex));
  }

  /// Forgets the last reported error, so the next one is reported even if it is
  /// identical. Called before loading a track that is being retried: two dead
  /// urls in a row carry the same code, and without this the second would look
  /// like an echo of the first.
  void clearPlaybackError() => _reportedErrorCode = null;

  /// Run before playback starts, if set.
  ///
  /// Exists for the restored session: reopening the app rebuilds the queue and
  /// the position but deliberately loads nothing into the player, because doing
  /// so would spend a request — sometimes several — on music the user may not
  /// have come back to hear. Pressing play is the signal that they have, and
  /// this is where that work happens. Awaited, so play acts on a loaded player.
  Future<void> Function()? onBeforePlay;

  // Controls route to [currentTrackPlayer]: during a crossfade the audible
  // track lives on the incoming player — acting on _activePlayer (outgoing)
  // would target a player the fade loop is about to stop.
  @override
  Future<void> play() async {
    final before = onBeforePlay;
    if (before != null) await before();
    await currentTrackPlayer.play();
  }

  /// Run after playback pauses, if set.
  ///
  /// The mirror of [onBeforePlay], and here for the same reason: this is the one
  /// place every pause funnels through — the app's own transport, the lock
  /// screen and a headset button alike — so it is the only place that can note
  /// the position without being wired into each of them separately.
  void Function()? onPaused;

  @override
  Future<void> pause() async {
    await currentTrackPlayer.pause();
    onPaused?.call();
  }

  @override
  Future<void> stop() async {
    await abortCrossfade();
    await _activePlayer.stop();
    await _inactivePlayer.stop();
  }

  @override
  Future<void> seek(Duration position) => currentTrackPlayer.seek(position);

  /// Fast-settle any in-flight crossfade: the fade loop breaks at its next
  /// step (≤ fadeDuration/20), the swap completes immediately, and callers can
  /// then safely act on [player]. No-op when no crossfade is running.
  Future<void> abortCrossfade() async {
    final done = _fadeDone;
    if (done == null) return;
    _cancellation?.cancel();
    await done.future;
  }

  @override
  Future<void> skipToNext() async {
    onSkipToNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    onSkipToPrevious?.call();
  }

  void setCurrentMediaItem(MediaItem item) {
    mediaItem.add(item);
  }

  /// Crossfade from current track to next.
  /// Loads [nextSource] on the inactive player, fades volumes, then swaps.
  Future<void> beginCrossfade(
    AudioSource nextSource,
    SongModel nextSong,
    Duration fadeDuration, {
    bool replayGain = false,
  }) async {
    if (_fadeDone != null) return; // one crossfade at a time

    final fadeDone = Completer<void>();
    _fadeDone = fadeDone;
    final cancellation = FadeCancellation();
    _cancellation = cancellation;
    final origVolume = trackGainOf(_activePlayer);
    var incomingStarted = false;

    try {
      final targetVolume = replayGain
          ? await computeReplayGainVolume(nextSong.data)
          : 1.0;
      // The first of several. Everything above the fade loop is *setup* — a
      // network load, an artwork fetch — and it used to be uninterruptible:
      // `abortCrossfade` waited for all of it, so a press of next during a slow
      // load did nothing at all until the load finished. Each await is followed
      // by this question so the answer arrives while the user is still asking.
      if (cancellation.isCancelled) {
        await _abandonSetup(origVolume, incomingStarted);
        return;
      }

      await _inactivePlayer.setAudioSource(nextSource);
      setTrackGain(_inactivePlayer, 0.0);
      _inactivePlayer.play();
      incomingStarted = true;
      if (cancellation.isCancelled) {
        await _abandonSetup(origVolume, incomingStarted);
        return;
      }

      // Update media item for the next track
      final image = await fetchArtworkUrl(nextSong.data, nextSong.id);
      if (cancellation.isCancelled) {
        await _abandonSetup(origVolume, incomingStarted);
        return;
      }
      final item = MediaItem(
        id: nextSong.data,
        album: nextSong.album,
        title: nextSong.title,
        artist: nextSong.artist,
        duration: Duration(milliseconds: nextSong.duration ?? 0),
        artUri: Uri.file(image),
      );

      setCurrentMediaItem(item);

      // Signal that the new track is now playing on _inactivePlayer.
      // currentTrackPlayer will return _inactivePlayer while _isCrossfading.
      _isCrossfading = true;
      onCrossfadeStarted?.call();

      const steps = 20;
      final stepDuration = Duration(
        milliseconds: fadeDuration.inMilliseconds ~/ steps,
      );
      final currentVolume = trackGainOf(_activePlayer);

      for (var i = 1; i <= steps; i++) {
        await cancellation.wait(stepDuration);
        // Abort requested (user skipped/paused/loaded a track): jump straight
        // to the end state instead of finishing the audible fade. The wait
        // above returns the instant that happens, rather than at the end of a
        // step — which at a 20 s crossfade is a whole second of dead button.
        if (cancellation.isCancelled) break;
        final progress = i / steps;
        setTrackGain(_activePlayer, currentVolume * (1.0 - progress));
        setTrackGain(_inactivePlayer, targetVolume * progress);
      }

      // Stop old active player, snap incoming to target, swap
      setTrackGain(_inactivePlayer, targetVolume);
      await _activePlayer.stop();
      setTrackGain(_activePlayer, 1.0);

      final temp = _activePlayer;
      _activePlayer = _inactivePlayer;
      _inactivePlayer = temp;

      _isCrossfading = false;
      _bindPlaybackState();
      onPlayerSwapped?.call();
    } catch (e) {
      // Failed before the swap (e.g. dead cloud URL in setAudioSource, or
      // artwork I/O). Restore the outgoing player and silence the incoming
      // one so it can't keep playing invisibly; rethrow so the caller can
      // roll back its track state.
      _isCrossfading = false;
      setTrackGain(_activePlayer, origVolume);
      if (incomingStarted) {
        try {
          await _inactivePlayer.stop();
        } catch (_) {}
      }
      rethrow;
    } finally {
      // Whatever happened, the crossfade is settled: unblock abortCrossfade()
      // waiters and clear the guard so future crossfades can run.
      _isCrossfading = false;
      _cancellation = null;
      _fadeDone = null;
      fadeDone.complete();
    }
  }

  /// Gives up a crossfade that was cancelled before the fade began.
  ///
  /// Leaves the outgoing player exactly as it was found — it is still the
  /// audible one, and the caller that cancelled is usually about to load
  /// something onto it — and silences the incoming one, which may already be
  /// playing at volume zero and would otherwise decode on for ever.
  ///
  /// Returns normally rather than throwing. A cancellation is not a failure: a
  /// throw here reaches `AppController._beginCrossfade`'s catch, which rolls the
  /// track index back — undoing the very skip the user asked for.
  Future<void> _abandonSetup(double origVolume, bool incomingStarted) async {
    setTrackGain(_activePlayer, origVolume);
    if (incomingStarted) {
      try {
        await _inactivePlayer.stop();
      } catch (_) {}
    }
  }

  /// Compute replay gain volume from ID3 tags
  static Future<double> computeReplayGainVolume(String filePath) async {
    try {
      final parser = ID3TagReader.path(filePath);
      final tag = await parser.readTag();
      // Look for TXXX frames with replaygain_track_gain
      final txxxFrames = tag.framesWithName('TXXX');
      for (final frame in txxxFrames) {
        if (frame is TextInformation) {
          final val = frame.value.toLowerCase();
          if (val.contains('replaygain_track_gain')) {
            final gainStr = frame.value
                .replaceAll(RegExp(r'replaygain_track_gain', caseSensitive: false), '')
                .replaceAll(RegExp(r'[^\d.\-+]'), '');
            final dB = double.tryParse(gainStr) ?? 0.0;
            final linear = math.pow(10, dB / 20).toDouble();
            return linear.clamp(0.1, 2.5);
          }
        }
      }
    } catch (_) {
      // If we can't read tags, return default
    }
    return 1.0;
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_activePlayer.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_activePlayer.processingState]!,
      playing: _activePlayer.playing,
      updatePosition: _activePlayer.position,
      bufferedPosition: _activePlayer.bufferedPosition,
      speed: _activePlayer.speed,
      queueIndex: event.currentIndex,
    );
  }
}
