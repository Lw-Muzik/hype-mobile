import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio/video.dart';

import '../Helpers/Channel.dart';
import '../player/engine_track_gain.dart';
import '../player/fade_cancellation.dart';
import '../player/fade_curve.dart';
import '../player/fade_settings.dart';
import '../player/output_gain.dart';

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

  /// Sets the playback speed on both players, so a crossfade's incoming player
  /// already matches. just_audio keeps the speed across `stop()` and a new
  /// source (it re-applies it whenever the platform player is re-activated), so
  /// it survives swaps. Tempo off is [speed] = 1.0.
  Future<void> setTempo(double speed) async {
    await Future.wait([_playerA.setSpeed(speed), _playerB.setSpeed(speed)]);
  }

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

  /// Sets [player]'s player-volume track gain, which is unity for every track
  /// (Replay Gain goes to the engine — see [setEngineTrackGainDb]) and a video
  /// player's own level. Applied under the crossfade, the play/pause fade and
  /// the listener volume, none of which it overwrites — see [OutputGain].
  void setTrackGain(AudioPlayer player, double gain) =>
      _gain.setTrack(player, gain);

  /// [player]'s track gain, before the listener volume.
  double trackGainOf(AudioPlayer player) => _gain.trackOf(player);

  late final EngineTrackGain<AudioPlayer> _engineGain = EngineTrackGain(
    idOf: (p) => p.playerId,
    idStream: (p) => p.platformIdStream,
    send: Channel.dspSetTrackGainDb,
  );

  /// Gives [player] a Replay Gain of [dB] in the native engine, ahead of its
  /// volume. Remembered, and sent again whenever the player is rebuilt under a
  /// new platform id (after a `stop()`) — see [EngineTrackGain]. 0 is unity.
  /// [subject] is the song it was worked out for, for a later re-gain.
  void setEngineTrackGainDb(AudioPlayer player, double dB, {Object? subject}) =>
      _engineGain.set(player, dB, subject: subject);

  /// The engine track gain last given to [player], dB; 0 if never set.
  double engineTrackGainDbOf(AudioPlayer player) => _engineGain.dbOf(player);

  /// What [player]'s engine gain was worked out for, if it was said.
  Object? engineGainSubjectOf(AudioPlayer player) =>
      _engineGain.subjectOf(player);

  /// Changes whenever [player] is given an engine gain.
  int engineGainSeqOf(AudioPlayer player) => _engineGain.seqOf(player);

  /// Both players, whichever is playing.
  List<AudioPlayer> get enginePlayers => [_playerA, _playerB];

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
    await Future.wait([_playerA.setLoopMode(mode), _playerB.setLoopMode(mode)]);
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

  void _bindPlaybackState() =>
      bindPlaybackEvents(_activePlayer.playbackEventStream);

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
    onPlaybackError?.call(
      PlayerException(code, event.errorMessage, event.currentIndex),
    );
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

  // ---------------------------------------------------------------------------
  // Fades
  //
  // Every fade Hype plays lives here: the crossfade between two tracks, and the
  // short ramps on play, pause, stop and seek. Lengths come from [fades], which
  // AppController keeps current. See `lib/player/fade_settings.dart`.
  // ---------------------------------------------------------------------------

  /// The fade lengths and switches in force. Pushed by AppController.
  FadeSettings fades = const FadeSettings();

  /// True while a pause (or stop) is fading out.
  ///
  /// The player still reports `playing` until the fade is over, so anything
  /// that shows a play/pause button reads this as well — a button that went on
  /// showing "pause" for the length of the fade would look like it had not
  /// heard the tap, and a second tap would land as another pause.
  final ValueNotifier<bool> pausing = ValueNotifier(false);

  /// Whether the listener can hear something right now: playing, not on its
  /// way to a pause, and not stalled on a finished or failed track.
  ///
  /// A track change crossfades only out of something audible. Out of silence
  /// — paused, or a track that has already ended — there is nothing to fade
  /// out, and the new track simply fades in.
  bool get isAudible {
    final p = currentTrackPlayer;
    if (!p.playing || pausing.value) return false;
    final state = p.processingState;
    return state == ProcessingState.ready ||
        state == ProcessingState.buffering ||
        state == ProcessingState.loading;
  }

  /// Bumped by every request to play something else — see [beginLoad].
  int _loadToken = 0;

  /// The newest load's token. A load that finds it has changed while it was
  /// waiting (on the network, on artwork) has been overtaken and stops.
  int get loadToken => _loadToken;

  /// Starts a request to play something else, and returns its token.
  ///
  /// The newest request always wins. Anything still in flight — a crossfade
  /// opening its track, or one halfway through its blend — is told to stop at
  /// once, not when the new request gets round to it; and a load overtaken
  /// while it waited notices by its token and gives way.
  int beginLoad() {
    _cancellation?.cancel();
    return ++_loadToken;
  }

  /// Whether a crossfade is anywhere between "opening the next track" and
  /// "handed over". The natural end of the outgoing track belongs to the fade
  /// in that window, not to the controller's advance.
  bool get crossfadeInFlight => _inFlight;
  bool _inFlight = false;

  /// The players the listener is hearing: both during a crossfade.
  List<AudioPlayer> get _audiblePlayers =>
      _isCrossfading ? [_activePlayer, _inactivePlayer] : [_activePlayer];

  /// The play/pause/seek ramp running on each player, if any. A new ramp on a
  /// player cancels the one before it, so a play pressed halfway through a
  /// pause's fade turns the fade around rather than racing it.
  final Map<AudioPlayer, FadeCancellation> _transportRamps = Map.identity();

  Future<bool> _rampTransport(
    List<AudioPlayer> players,
    double from,
    double to,
    Duration duration,
  ) async {
    final token = FadeCancellation();
    _cancelTransport(players);
    for (final p in players) {
      _transportRamps[p] = token;
    }
    final reached = await runRamp(
      from: from,
      to: to,
      duration: duration,
      cancel: token,
      apply: (gain) {
        for (final p in players) {
          if (identical(_transportRamps[p], token)) _gain.setFade(p, gain);
        }
      },
    );
    for (final p in players) {
      if (identical(_transportRamps[p], token)) _transportRamps.remove(p);
    }
    return reached;
  }

  /// Stops the ramps on [players]. A ramp shared with a player not in
  /// [players] — a pause fading both sides of a crossfade, when the crossfade
  /// hands over — carries on for that one.
  void _cancelTransport(Iterable<AudioPlayer> players) {
    for (final p in players) {
      final token = _transportRamps.remove(p);
      if (token != null &&
          !_transportRamps.values.any((t) => identical(t, token))) {
        token.cancel();
      }
    }
  }

  /// Tells the notification and lock screen "paused" the moment a pause is
  /// asked for, rather than when its fade finishes.
  void _publishPausedIntent() {
    final state = playbackState.value;
    playbackState.add(
      state.copyWith(playing: false, controls: _controlsFor(playing: false)),
    );
  }

  // Controls route to [currentTrackPlayer]: during a crossfade the audible
  // track lives on the incoming player — acting on _activePlayer (outgoing)
  // would target a player the fade loop is about to stop.
  //
  // A play or pause during a crossfade acts on both players, as one: the
  // listener hears one thing, so one thing pauses. The crossfade's progress is
  // measured on the incoming track's position, which stands still while
  // paused, so the blend resumes exactly where it was.
  @override
  Future<void> play() async {
    final before = onBeforePlay;
    if (before != null) await before();
    final players = _audiblePlayers;
    final target = currentTrackPlayer;
    final interruptedPause = pausing.value;
    pausing.value = false;
    // The lock screen was told "paused" when the pause began; a pause turned
    // round before it finished produces no player event to say otherwise.
    if (interruptedPause) {
      playbackState.add(
        playbackState.value.copyWith(
          playing: true,
          controls: _controlsFor(playing: true),
        ),
      );
    }
    // From silence when starting; from wherever it had got to when play
    // interrupts a pause that was still fading out. Switched off, a resume
    // still fades in over [kDeclickMs].
    if (!target.playing) {
      for (final p in players) {
        _gain.setFade(p, 0.0);
      }
    }
    final from = _gain.fadeOf(target);
    // just_audio's `play()` completes when playback *pauses*, so the ramp is
    // started beside it rather than after it.
    final playing = Future.wait([for (final p in players) p.play()]);
    unawaited(
      _rampTransport(
        players,
        from,
        1.0,
        rampDuration(from, 1.0, fades.resumeFadeMs),
      ),
    );
    await playing;
  }

  /// Run after playback pauses, if set.
  ///
  /// The mirror of [onBeforePlay], and here for the same reason: this is the one
  /// place every pause funnels through — the app's own transport, the lock
  /// screen and a headset button alike — so it is the only place that can note
  /// the position without being wired into each of them separately.
  void Function()? onPaused;

  /// Pauses, fading out first; the player pauses once the fade has finished.
  /// Switched off, the pause is immediate.
  @override
  Future<void> pause() async {
    if (pausing.value) return; // already on its way out
    final players = _audiblePlayers;
    final target = currentTrackPlayer;
    final fadeMs = fades.playPauseMs;
    if (fadeMs > 0 && target.playing) {
      pausing.value = true;
      _publishPausedIntent();
      final from = _gain.fadeOf(target);
      final reached = await _rampTransport(
        players,
        from,
        0.0,
        rampDuration(from, 0.0, fadeMs),
      );
      // Play was pressed, or a new track loaded, before the fade finished.
      // Whatever did that owns the player now.
      if (!reached) return;
      pausing.value = false;
    }
    await Future.wait([for (final p in players) p.pause()]);
    // Back to unity under the pause, so anything that starts this player
    // again without coming through [play] — the audio session resuming after
    // a phone call — is heard. Ordered after the pause on the platform
    // channel, so it is never audible; [play] starts from silence regardless.
    for (final p in players) {
      _gain.setFade(p, 1.0);
    }
    onPaused?.call();
  }

  /// Stops, fading out first like a pause. Switched off, a hard stop.
  @override
  Future<void> stop() async {
    final fadeMs = fades.playPauseMs;
    if (fadeMs > 0 && isAudible) {
      pausing.value = true;
      _publishPausedIntent();
      final from = _gain.fadeOf(currentTrackPlayer);
      final reached = await _rampTransport(
        _audiblePlayers,
        from,
        0.0,
        rampDuration(from, 0.0, fadeMs),
      );
      if (!reached) return;
      pausing.value = false;
    }
    await abortCrossfade();
    await _activePlayer.stop();
    await _inactivePlayer.stop();
    resetLevels(_activePlayer);
    resetLevels(_inactivePlayer);
  }

  /// Seeks the current track: [kDeclickMs] out, the jump, then a fade back in
  /// over the seek fade length — so the jump never lands with a click.
  /// Switched off, there is no fade out and the fade in is [kDeclickMs].
  ///
  /// A seek during a crossfade ends the crossfade first: the position being
  /// moved belongs to the incoming track, and the outgoing one is faded away
  /// over [kDeclickMs].
  @override
  Future<void> seek(Duration position) async {
    await abortCrossfade();
    final p = _activePlayer;
    if (!p.playing || pausing.value) {
      _gain.setMix(p, 1.0);
      await p.seek(position);
      return;
    }
    if (fades.fadeSeek) {
      final from = _gain.fadeOf(p);
      await _rampTransport([p], from, 0.0, rampDuration(from, 0.0, kDeclickMs));
    } else {
      _cancelTransport([p]);
      _gain.setFade(p, 0.0);
    }
    // Silent here, so a crossfade's leftover level can be put right unheard.
    _gain.setMix(p, 1.0);
    await p.seek(position);
    unawaited(
      _rampTransport([p], 0.0, 1.0, Duration(milliseconds: fades.seekFadeInMs)),
    );
  }

  /// Fades the active player out over [kDeclickMs], if anything is audible —
  /// the first half of a cut that must not click.
  Future<void> declickOut() async {
    if (!isAudible) return;
    final p = _activePlayer;
    final from = _gain.fadeOf(p);
    await _rampTransport([p], from, 0.0, rampDuration(from, 0.0, kDeclickMs));
  }

  /// Brings the active player back up to full after a change that did not
  /// happen — a skip to a track the data guard would not stream — so the
  /// track left playing is not stuck wherever the abandoned fade had got it to.
  Future<void> restoreLevel() async {
    final p = _activePlayer;
    final from = _gain.mixOf(p);
    if (from >= 1.0) return;
    await runRamp(
      from: from,
      to: 1.0,
      duration: rampDuration(from, 1.0, fades.resumeFadeMs),
      apply: (g) => _gain.setMix(p, g),
    );
  }

  /// Puts [player]'s crossfade and fade gains back to unity — for a player
  /// given something new to play, which owes nothing to what came before.
  void resetLevels(AudioPlayer player) {
    _cancelTransport([player]);
    _gain.setMix(player, 1.0);
    _gain.setFade(player, 1.0);
  }

  /// Starts the active player after a load, fading in from silence over
  /// [fadeInMs] (zero for none).
  ///
  /// Every load that is not a crossfade starts through here.
  void startPlayback({int fadeInMs = 0}) {
    final p = _activePlayer;
    pausing.value = false;
    _cancelTransport([p]);
    _gain.setMix(p, 1.0);
    if (fadeInMs > 0) {
      _gain.setFade(p, 0.0);
      unawaited(p.play());
      unawaited(
        _rampTransport([p], 0.0, 1.0, Duration(milliseconds: fadeInMs)),
      );
    } else {
      _gain.setFade(p, 1.0);
      unawaited(p.play());
    }
  }

  /// Settles any in-flight crossfade at once.
  ///
  /// One that has started blending hands over where it stands: the track that
  /// was fading out is faded away over [kDeclickMs], and the incoming one keeps
  /// the level it had reached — whatever is done next (another skip, a seek)
  /// carries on from there rather than jumping. One still opening its track is
  /// dropped, and the track playing is left as it was. Either way callers can
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

  /// Plays a new track (or queue) on the spare player and blends over to it.
  ///
  /// * [load] puts the new source — one track, or a whole gapless queue
  ///   positioned at the new track — on the player it is given.
  /// * [fadeMs] is the blend: the new track fades in over it, and the old one
  ///   fades out at the same rate, in a straight line, from whatever level it
  ///   is at ([crossfadeOutGain]). Zero is a handoff — the new track starts at
  ///   full volume the moment it is due.
  /// * [earlyFadeOutMs] — a change the listener asked for: the old track
  ///   starts on its way out at once, at the rate of a full fade over this
  ///   long, while the new one opens.
  /// * [startAt] — a track ending on its own: opened early, the blend begins
  ///   when the old track reaches this position. If the new one is late, the
  ///   old one starts fading on time anyway.
  /// * [startAtEnd] — a handoff: the new track starts when the old one ends,
  ///   after [gapAfterEnd] of silence.
  /// * [onStart] runs as the new track becomes audible: the moment the app
  ///   should start calling it the current track.
  ///
  /// Cancellable throughout via [abortCrossfade] — see there for where each
  /// kind of cancel leaves things.
  ///
  /// The blend's progress is the incoming track's *position*, not the clock.
  /// A pause halfway through holds both tracks where they are, and play picks
  /// the blend up again exactly there.
  Future<void> crossfade({
    required Future<void> Function(AudioPlayer incoming) load,
    required int fadeMs,
    FutureOr<MediaItem?> Function()? mediaItem,
    int earlyFadeOutMs = 0,
    Duration? startAt,
    bool startAtEnd = false,
    Duration gapAfterEnd = Duration.zero,
    void Function()? onStart,

    /// The [beginLoad] token this crossfade belongs to. A newer load cancels
    /// it.
    int? token,

    /// Whether to take over from a crossfade already in flight — what a change
    /// the listener asked for does — or to give way to it, as a track ending
    /// on its own does.
    bool replace = true,
  }) async {
    // One crossfade at a time: the newest request wins over one in flight, a
    // track ending on its own gives way to it.
    while (_fadeDone != null) {
      if (!replace) return;
      _cancellation?.cancel();
      await _fadeDone!.future;
    }
    if (token != null && token != _loadToken) return;

    final fadeDone = Completer<void>();
    _fadeDone = fadeDone;
    _inFlight = true;
    final cancellation = FadeCancellation();
    _cancellation = cancellation;
    if (token != null && token != _loadToken) cancellation.cancel();
    final outgoing = _activePlayer;
    final incoming = _inactivePlayer;
    final outgoingIndex = outgoing.currentIndex;
    final outFrom = _gain.mixOf(outgoing);
    final fadeUs = math.max(1, fadeMs * 1000);
    var incomingLoaded = false;
    var setupOver = false;

    // The outgoing track has nothing left to give once it ends — or, in a
    // gapless queue, moves on to its own next entry, which is the very track
    // coming in.
    //
    // Or loops back to its start, which a lone track does under repeat-all:
    // seen as its position jumping backwards.
    var lastOutPosition = outgoing.position;
    var wrapped = false;
    bool outgoingFinished() {
      final position = outgoing.position;
      if (position + const Duration(seconds: 1) < lastOutPosition) {
        wrapped = true;
      }
      lastOutPosition = position;
      final state = outgoing.processingState;
      return wrapped ||
          state == ProcessingState.completed ||
          state == ProcessingState.idle ||
          (outgoingIndex != null && outgoing.currentIndex != outgoingIndex);
    }

    try {
      _cancelTransport([incoming]);
      _gain.setFade(incoming, 1.0);
      _gain.setMix(incoming, 0.0);
      setTrackGain(incoming, 1.0);

      // While the new track opens, the old one may already be on its way out:
      // at once for a change the listener asked for, from [startAt] for a
      // track ending on its own whose successor is late.
      final requested = Stopwatch()..start();
      unawaited(() async {
        while (!setupOver && !cancellation.isCancelled) {
          double? level;
          if (earlyFadeOutMs > 0) {
            level =
                outFrom -
                requested.elapsedMicroseconds / (earlyFadeOutMs * 1000);
          } else if (startAt != null && fadeMs > 0) {
            final over = (outgoing.position - startAt).inMicroseconds;
            if (over > 0) level = outFrom - over / fadeUs;
          }
          if (level != null) _gain.setMix(outgoing, level.clamp(0.0, 1.0));
          await cancellation.wait(kFadeTick);
        }
      }());

      // Setup: open the track, find its artwork, wait for the moment. Each
      // await is followed by the same question, so a skip during any of them
      // is answered at once rather than when the network gets round to it.
      await load(incoming);
      incomingLoaded = true;
      if (cancellation.isCancelled) {
        setupOver = true;
        await _abandonSetup(incoming);
        return;
      }
      final item = mediaItem == null ? null : await mediaItem();
      if (!cancellation.isCancelled && startAt != null) {
        await _waitForPosition(
          outgoing,
          startAt,
          outgoingFinished,
          cancellation,
        );
      }
      if (!cancellation.isCancelled && startAtEnd) {
        while (!cancellation.isCancelled && !outgoingFinished()) {
          await cancellation.wait(kFadeTick);
        }
        if (gapAfterEnd > Duration.zero) await cancellation.wait(gapAfterEnd);
      }
      setupOver = true;
      if (cancellation.isCancelled) {
        await _abandonSetup(incoming);
        return;
      }

      // Paused while the new track was opening. The change still happens —
      // the listener asked for it — but into a paused player, with nothing to
      // blend: play fades it in like any resume.
      if (startAt == null && !startAtEnd && !outgoing.playing) {
        if (item != null) setCurrentMediaItem(item);
        await outgoing.stop();
        resetLevels(outgoing);
        setTrackGain(outgoing, 1.0);
        _gain.setMix(incoming, 1.0);
        _activePlayer = incoming;
        _inactivePlayer = outgoing;
        onStart?.call();
        _inFlight = false;
        _bindPlaybackState();
        onPlayerSwapped?.call();
        return;
      }

      // The blend.
      final outLevel = outgoingFinished() ? 0.0 : _gain.mixOf(outgoing);
      final startPosition = incoming.position;
      unawaited(incoming.play());
      if (item != null) setCurrentMediaItem(item);
      // currentTrackPlayer returns the incoming player from here on.
      _isCrossfading = true;
      onStart?.call();
      onCrossfadeStarted?.call();

      while (true) {
        final speed = incoming.speed > 0 ? incoming.speed : 1.0;
        final moved = (incoming.position - startPosition).inMicroseconds;
        final progress = fadeMs <= 0
            ? 1.0
            : (moved / (fadeUs * speed)).clamp(0.0, 1.0);
        _gain.setMix(
          outgoing,
          outgoingFinished() ? 0.0 : crossfadeOutGain(progress, from: outLevel),
        );
        _gain.setMix(incoming, crossfadeInGain(progress));
        if (progress >= 1.0) break;
        // The new track failed to open after all. Hand over now and let the
        // ordinary error path, which watches the active player, deal with it.
        if (incoming.processingState == ProcessingState.idle) break;
        await cancellation.wait(kFadeTick);
        if (cancellation.isCancelled) break;
      }

      if (cancellation.isCancelled) {
        // Interrupted mid-blend. The track fading out is declicked rather than
        // cut; the incoming one keeps the level it had reached.
        final from = _gain.mixOf(outgoing);
        if (from > 0) {
          await runRamp(
            from: from,
            to: 0.0,
            duration: rampDuration(from, 0.0, kDeclickMs),
            apply: (g) => _gain.setMix(outgoing, g),
          );
        }
      } else {
        _gain.setMix(incoming, 1.0);
      }
      await outgoing.stop();
      resetLevels(outgoing);
      setTrackGain(outgoing, 1.0);

      _activePlayer = incoming;
      _inactivePlayer = outgoing;

      _isCrossfading = false;
      _inFlight = false;
      _bindPlaybackState();
      onPlayerSwapped?.call();
    } catch (e) {
      // Failed before the swap (a dead cloud URL in the load, artwork I/O).
      // The outgoing player is still the audible one: bring it back to where
      // it was, silence the incoming one so it can't keep playing invisibly,
      // and rethrow so the caller can fall back.
      setupOver = true;
      _isCrossfading = false;
      _gain.setMix(outgoing, outFrom);
      if (incomingLoaded) {
        try {
          await incoming.stop();
        } catch (_) {}
      }
      resetLevels(incoming);
      rethrow;
    } finally {
      // Whatever happened, the crossfade is settled: unblock abortCrossfade()
      // waiters and clear the guard so future crossfades can run.
      setupOver = true;
      _isCrossfading = false;
      _inFlight = false;
      _cancellation = null;
      _fadeDone = null;
      fadeDone.complete();
    }
  }

  /// Waits until [outgoing] reaches [position] — or [finished] says it has
  /// nothing left — polling, because a pause, a stall or a change of speed all
  /// move the moment and the wait has to follow the track, not the clock.
  static Future<void> _waitForPosition(
    AudioPlayer outgoing,
    Duration position,
    bool Function() finished,
    FadeCancellation cancel,
  ) async {
    const poll = Duration(milliseconds: 100);
    while (!cancel.isCancelled && !finished()) {
      final remaining = position - outgoing.position;
      if (remaining <= Duration.zero) return;
      final speed = outgoing.speed > 0 ? outgoing.speed : 1.0;
      final wall = Duration(
        microseconds: (remaining.inMicroseconds / speed).round(),
      );
      await cancel.wait(wall < poll ? wall : poll);
    }
  }

  /// Gives up a crossfade that was cancelled before the blend began.
  ///
  /// The outgoing player is still the audible one — and the caller that
  /// cancelled is usually about to act on it — so it is left at whatever level
  /// it is at, for that action to carry on from. The incoming one holds a track
  /// nobody is going to hear.
  ///
  /// Returns normally rather than throwing. A cancellation is not a failure.
  Future<void> _abandonSetup(AudioPlayer incoming) async {
    try {
      await incoming.stop();
    } catch (_) {}
    resetLevels(incoming);
    setTrackGain(incoming, 1.0);
  }

  List<MediaControl> _controlsFor({required bool playing}) => [
    MediaControl.skipToPrevious,
    if (playing) MediaControl.pause else MediaControl.play,
    MediaControl.skipToNext,
    MediaControl.stop,
  ];

  PlaybackState _transformEvent(PlaybackEvent event) {
    // A pause that is still fading out is a pause as far as the lock screen is
    // concerned — see [pausing].
    final playing = _activePlayer.playing && !pausing.value;
    return PlaybackState(
      controls: _controlsFor(playing: playing),
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
      playing: playing,
      updatePosition: _activePlayer.position,
      bufferedPosition: _activePlayer.bufferedPosition,
      speed: _activePlayer.speed,
      queueIndex: event.currentIndex,
    );
  }
}
