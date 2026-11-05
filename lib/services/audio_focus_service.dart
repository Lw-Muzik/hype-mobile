// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:clock/clock.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../audio/advanced/advanced_settings.dart';
import '../audio/focus/audio_focus_settings.dart';
import '../audio/focus/focus_policy.dart';
import '../audio/focus/playback_target.dart';

/// When, after a transient loss, the audio mode is read to find out whether
/// the loss is a phone call. Telecom requests focus before it sets the mode, so
/// the first reading can still say "normal".
const kCallModePolls = [
  Duration.zero,
  Duration(milliseconds: 500),
  Duration(milliseconds: 1500),
];

/// How long after the focus came back the output is given to move before
/// "Force audio on audio focus change" steps in.
const kForceAudioWait = Duration(milliseconds: 1500);

/// How long a restart's own pause and play are told apart from the listener's.
const _kForceOwnWindow = Duration(milliseconds: 500);

/// How long a resume on start waits for the Hype Connect hub to say whether
/// another device is the active player. Without an answer by then it goes ahead.
const kConnectAnswerWait = Duration(seconds: 3);
const _kConnectAnswerPoll = Duration(milliseconds: 200);

/// Android 12 (API 31) fades out and mutes an app that keeps playing after it
/// lost focus to another media player.
const _kSystemMutesLosersFromSdk = 31;

/// Asks the system for audio focus through [setActive] (an
/// `AudioSession.setActive`).
///
/// Android asks with will-pause-when-ducked, so a duckable loss is reported
/// instead of the system ducking Hype itself. A refusal is followed by a
/// release: audio_session keeps the refused request, so without it every later
/// `setActive(true)` answers true without asking the system again — and a play
/// during a call would be let through the next time.
Future<bool> requestAudioFocus(
  Future<bool> Function(bool active, {bool? androidWillPauseWhenDucked})
  setActive, {
  required bool isIos,
}) async {
  if (isIos) return setActive(true);
  final granted = await setActive(true, androidWillPauseWhenDucked: true);
  if (!granted) {
    try {
      await setActive(false);
    } catch (e) {
      debugPrint('Releasing a refused audio focus request failed: $e');
    }
  }
  return granted;
}

/// [requestAudioFocus] on the platform's audio session. The one request path:
/// the focus service uses it, and so does the plain activation the handler has
/// until the service starts.
Future<bool> requestPlatformAudioFocus() async {
  final session = await AudioSession.instance;
  return requestAudioFocus(
    (active, {androidWillPauseWhenDucked}) => session.setActive(
      active,
      androidWillPauseWhenDucked: androidWillPauseWhenDucked,
    ),
    isIos: defaultTargetPlatform == TargetPlatform.iOS,
  );
}

/// Whether Hype may start music on its own: the app is a music player with a
/// queue, no other Hype Connect device is the active player, and (when
/// [requireUiSeen]) the UI has been in the foreground in this process.
bool mayResumeAutomatically({
  required bool eqMode,
  required bool hasQueue,
  required bool otherDeviceActive,
  required bool uiSeen,
  required bool requireUiSeen,
}) => !eqMode && hasQueue && !otherDeviceActive && (uiSeen || !requireUiSeen);

/// Runs Hype's audio focus: it feeds the interruptions the platform reports,
/// and the listener's own plays and pauses, into [focusStep] and carries out
/// what comes back, one action at a time and in order.
///
/// It also asks for focus when playback starts ([activate], which the handler
/// calls before every play), resumes on start and reopen, and tells
/// [waitingForFocus] to the headset service so a plug never starts music while
/// Hype waits for a call to end.
class AudioFocusService {
  AudioFocusService({
    required PlaybackTarget target,
    required AudioFocusSettings Function() settings,
    required bool Function() hasSession,

    /// Whether Hype may start music on its own right now: false in equalizer
    /// mode, with no queue, or while another Hype Connect device is the active
    /// player. Every automatic resume asks, whichever path started it.
    required bool Function() canResume,
    required bool isIos,
    required Stream<AudioInterruptionEvent> interruptions,
    required Future<bool> Function() requestFocus,
    Future<AndroidAudioHardwareMode> Function()? audioMode,
    Stream<LifecycleResume>? lifecycle,
    bool systemMutesLosers = false,

    /// True while Hype Connect is on but has not yet heard from the hub which
    /// device is the active player; a resume on start waits (up to
    /// [kConnectAnswerWait]) for it to turn false.
    bool Function()? connectAnswerPending,

    /// Whether the app is in the foreground now; a resume that waited for the
    /// Connect hub checks it again before it plays. Null: always.
    bool Function()? isForeground,

    /// Told about [activate] at [start], so the player asks through this
    /// service.
    void Function(Future<bool> Function() activate)? bindActivation,

    /// Per-output flags, read at each event: with [noDuck] a duckable loss
    /// pauses instead; with [ignoreFocus] losses and gains of focus are
    /// ignored.
    bool Function()? noDuck,
    bool Function()? ignoreFocus,
  }) : _target = target,
       _settings = settings,
       _hasSession = hasSession,
       _canResume = canResume,
       _connectAnswerPending = connectAnswerPending,
       _isForeground = isForeground,
       _isIos = isIos,
       _interruptions = interruptions,
       _requestFocus = requestFocus,
       _audioMode = audioMode,
       _lifecycle = lifecycle,
       _systemMutesLosers = systemMutesLosers,
       _noDuck = noDuck,
       _ignoreFocus = ignoreFocus,
       _bindActivation = bindActivation;

  /// The real thing: a configured audio session, the platform's focus request
  /// and the app's lifecycle.
  static Future<AudioFocusService> forPlatform({
    required PlaybackTarget target,
    required AudioFocusSettings Function() settings,
    required bool Function() hasSession,
    required bool Function() canResume,
    bool Function()? connectAnswerPending,
    void Function(Future<bool> Function() activate)? bindActivation,
    bool Function()? noDuck,
    bool Function()? ignoreFocus,
  }) async {
    final session = await AudioSession.instance;
    // `music()` leaves will-pause-when-ducked unset; Android asks with it per
    // request instead (see [requestAudioFocus]).
    await session.configure(const AudioSessionConfiguration.music());
    final isIos = defaultTargetPlatform == TargetPlatform.iOS;
    var sdk = 0;
    if (!isIos) {
      try {
        sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
      } catch (e) {
        debugPrint('Android version unavailable ($e); assuming it is old.');
      }
    }
    return AudioFocusService(
      target: target,
      settings: settings,
      hasSession: hasSession,
      canResume: canResume,
      connectAnswerPending: connectAnswerPending,
      isForeground: () =>
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      isIos: isIos,
      interruptions: session.interruptionEventStream,
      requestFocus: requestPlatformAudioFocus,
      audioMode: isIos ? null : () => AndroidAudioManager().getMode(),
      lifecycle: LifecycleFeed().stream,
      systemMutesLosers: sdk >= _kSystemMutesLosersFromSdk,
      bindActivation: bindActivation,
      noDuck: noDuck,
      ignoreFocus: ignoreFocus,
    );
  }

  final PlaybackTarget _target;
  final AudioFocusSettings Function() _settings;
  final bool Function() _hasSession;
  final bool Function() _canResume;
  final bool Function()? _connectAnswerPending;
  final bool Function()? _isForeground;
  final bool _isIos;
  final Stream<AudioInterruptionEvent> _interruptions;
  final Future<bool> Function() _requestFocus;
  final Future<AndroidAudioHardwareMode> Function()? _audioMode;
  final Stream<LifecycleResume>? _lifecycle;
  final bool _systemMutesLosers;
  final bool Function()? _noDuck;
  final bool Function()? _ignoreFocus;
  final void Function(Future<bool> Function() activate)? _bindActivation;

  FocusState _state = const FocusState();

  /// The tail of the action queue; each action starts when the one before it
  /// has finished.
  Future<void> _queue = Future<void>.value();

  /// The service itself is about to pause or play, so the next change of the
  /// player's state is its own and not the listener's.
  bool _ownPause = false;
  bool _ownPlay = false;

  // Force audio on audio focus change (Advanced tweaks); all null until
  // [configureForceAudio].
  bool Function()? _forceEnabled;
  Duration Function()? _forcePosition;
  Future<void> Function()? _forceSeek;
  bool Function()? _forceBuffering;
  // The restart's own pause is still expected (set with [_ownPause]).
  bool _forcePausePending = false;
  Timer? _forceTimer;
  Timer? _forceOwnTimer;
  int _forceAttempts = 0;

  /// Bumped to drop the call-detection polls of an earlier loss.
  int _pollEpoch = 0;
  final _pollTimers = <Timer>[];

  bool _restored = false;
  LifecycleResume? _pendingStart;
  bool _started = false;

  /// The UI has been in the foreground at least once in this process. A
  /// process the listener never opened (Hype Connect's background service after
  /// a reboot) must not start music on its own.
  bool _uiSeen = false;

  /// The kind of the focus loss in progress, while one is.
  FocusLossKind? _lossKind;

  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<LifecycleResume>? _lifecycleSub;
  Timer? _connectWait;

  /// Whether Hype paused for a loss of focus or a call and is waiting for it
  /// to come back.
  bool get waitingForFocus => _state.waitingForFocus;

  /// Whether Hype may resume on its own as far as the process goes: its UI has
  /// been in the foreground, or there is no lifecycle to tell (a test).
  bool get uiHasBeenForeground => _lifecycle == null || _uiSeen;

  /// Drops whatever is waiting to resume, as a listener pause does: the hold
  /// ends, a duck is put back, and nothing is resumed when the focus returns.
  /// For the ways of ending playback that do not change the playing state while
  /// Hype is paused for a call: the headset unplugged, the notification closed.
  void cancelHold() {
    _cancelConnectWait();
    if (_state.hold == FocusHold.none && !_state.reclaimed) return;
    _handle(const PlaybackPaused());
  }

  /// Turns on "Force audio on audio focus change": 1.5 s after the focus came
  /// back, if Hype is meant to be playing but [position] has not moved, ask for
  /// focus again and restart the output once ([seekInPlace] first, if given).
  void configureForceAudio({
    required bool Function() enabled,
    required Duration Function() position,
    Future<void> Function()? seekInPlace,

    /// True while the player is loading or buffering: no progress is then no
    /// sign of a dead output.
    bool Function()? buffering,
  }) {
    _forceBuffering = buffering;
    _forceEnabled = enabled;
    _forcePosition = position;
    _forceSeek = seekInPlace;
  }

  void _watchOutput() {
    final enabled = _forceEnabled;
    final position = _forcePosition;
    if (enabled == null || position == null || !enabled()) return;
    _forceTimer?.cancel();
    _forceAttempts = 0;
    final atGain = position();
    _forceTimer = Timer(kForceAudioWait, () => _checkOutput(atGain));
  }

  void _checkOutput(Duration atGain) {
    _forceTimer = null;
    final enabled = _forceEnabled;
    final position = _forcePosition;
    if (enabled == null || position == null) return;
    if (_forceBuffering?.call() ?? false) return;
    final step = forceAudioDecision(
      enabled: enabled(),
      meantToPlay: _target.playing && !_state.waitingForFocus,
      positionAtGain: atGain,
      positionNow: position(),
      attempts: _forceAttempts,
    );
    if (step == ForceAudioStep.restart) {
      _forceAttempts++;
      unawaited(_forceRestart());
    }
  }

  Future<void> _forceRestart() async {
    try {
      await _requestFocus();
      await _forceSeek?.call();
      // The restart's own pause and play are not the listener's.
      _ownPause = true;
      _ownPlay = true;
      _forcePausePending = true;
      _forceOwnTimer?.cancel();
      _forceOwnTimer = Timer(_kForceOwnWindow, () {
        // Only what the restart set and nothing has consumed: a real focus
        // pause in the window owns [_ownPause] by then.
        if (_forcePausePending) {
          _forcePausePending = false;
          _ownPause = false;
        }
        _ownPlay = false;
      });
      unawaited(
        _target.restartPlayback().catchError((Object e) {
          debugPrint('Forced restart failed: $e');
        }),
      );
    } catch (e) {
      debugPrint('Forcing audio failed: $e');
    }
  }

  /// Listens, and makes this the way the player asks for focus.
  void start() {
    if (_started) return;
    _started = true;
    _bindActivation?.call(activate);
    _interruptionSub = _interruptions.listen(
      (e) => _handle(focusEventFromInterruption(e, isIos: _isIos)),
      onError: (Object e) => debugPrint('Audio interruption stream: $e'),
    );
    _playingSub = _target.playingStream.listen(_onPlayingChanged);
    _lifecycleSub = _lifecycle?.listen(_onLifecycle);
  }

  /// Asks for focus before playback starts. True when playback may start.
  ///
  /// Without a request while Hype is playing on without focus on purpose
  /// (Permanent audio focus change off, lost again after asking back once): a
  /// request would only start the tug of war again.
  Future<bool> activate() async {
    if (!_state.needsFocusRequest) return true;
    return _requestFocus();
  }

  /// The saved session has been read; a start that came earlier is judged now.
  void sessionRestored() {
    _restored = true;
    final pending = _pendingStart;
    _pendingStart = null;
    if (pending != null) _resumeAfterConnect(pending);
  }

  void dispose() {
    _forceTimer?.cancel();
    _forceOwnTimer?.cancel();
    _cancelConnectWait();
    _pollEpoch++;
    for (final t in _pollTimers) {
      t.cancel();
    }
    _pollTimers.clear();
    unawaited(_interruptionSub?.cancel());
    unawaited(_playingSub?.cancel());
    unawaited(_lifecycleSub?.cancel());
    _interruptionSub = _playingSub = _lifecycleSub = null;
  }

  // -- Events ----------------------------------------------------------------

  void _handle(FocusEvent e) {
    if (e is FocusLost || e is FocusGained) _pollEpoch++;
    final step = focusStep(
      _state,
      e,
      _settings(),
      playing: _target.playing,
      systemMutesLosers: _systemMutesLosers,
      noDuck: _noDuck?.call() ?? false,
      ignoreFocus: _ignoreFocus?.call() ?? false,
    );
    final wasDucked = _state.hold == FocusHold.ducked;
    final hadLoss = _state.lossActive;
    _state = step.state;
    final actions = [...step.actions];
    if (e is FocusLost) _lossKind = e.kind;
    if (e is ListenerPlayed &&
        _lossKind == FocusLossKind.canDuck &&
        _state.lossActive &&
        !_state.waitingForFocus &&
        _settings().shortFocusChange &&
        _settings().duckVolume &&
        !(_noDuck?.call() ?? false) &&
        !(_ignoreFocus?.call() ?? false)) {
      // The other sound is still going: what the listener starts now plays
      // ducked, as it would have had it been playing when the loss began.
      _state = _state.copyWith(hold: FocusHold.ducked);
      actions.add(FocusAction.duck);
    }
    // The listener paused while ducked: the other sound may still be going, but
    // what is heard next should not be quiet, so the level comes back now. The
    // hold stays, so the gain still finds it and does not resume.
    if (e is PlaybackPaused && wasDucked) actions.add(FocusAction.unduck);
    _enqueue(actions);
    // Only after a transient loss and its gain; a permanent loss or a duck is
    // no reason to restart the output.
    if (e is FocusGained && hadLoss && _lossKind == FocusLossKind.transient) {
      _watchOutput();
    }
    // The listener's own pause or a new loss ends the watch.
    if (e is FocusLost || e is PlaybackPaused) _forceTimer?.cancel();
    if (e is FocusLost && e.kind == FocusLossKind.transient) _pollForCall();
  }

  void _onPlayingChanged(bool playing) {
    // The listener (or anything) has played or paused since the start: what was
    // waiting for the Connect hub is out of date.
    _cancelConnectWait();
    if (playing) {
      if (_ownPlay) {
        _ownPlay = false;
        return;
      }
      _handle(const ListenerPlayed());
      return;
    }
    // The forced restart's pause comes before its play: keep the play mark.
    if (!_forcePausePending) _ownPlay = false;
    if (_ownPause) {
      _ownPause = false;
      _forcePausePending = false;
      return;
    }
    // Already paused for focus: nothing the listener does to a paused player
    // changes that.
    if (_state.waitingForFocus) return;
    _handle(const PlaybackPaused());
  }

  void _pollForCall() {
    final mode = _audioMode;
    if (mode == null) return;
    final epoch = ++_pollEpoch;
    for (final t in _pollTimers) {
      t.cancel();
    }
    _pollTimers.clear();
    for (final delay in kCallModePolls) {
      _pollTimers.add(
        Timer(delay, () async {
          if (epoch != _pollEpoch) return;
          try {
            final m = await mode();
            if (epoch != _pollEpoch) return;
            if (isCallMode(m)) {
              _pollEpoch++; // found; the later readings are not needed
              _handle(const CallDetected());
            }
          } catch (e) {
            debugPrint('Reading the audio mode failed: $e');
          }
        }),
      );
    }
  }

  void _cancelConnectWait() {
    _connectWait?.cancel();
    _connectWait = null;
  }

  void _onLifecycle(LifecycleResume when) {
    _uiSeen = true;
    // A newer event supersedes one still waiting for the hub.
    _cancelConnectWait();
    // A start waits for the saved session: before it is read there is nothing
    // to resume, and deciding now would find "no session" for good.
    if (when == LifecycleResume.start && !_restored) {
      _pendingStart = when;
      return;
    }
    _resumeAfterConnect(when);
  }

  /// A start or a reopen also waits for Hype Connect: until the hub has said
  /// which device is the active player, "no other device is playing" cannot be
  /// told from "not heard yet", and music could start on two devices at once.
  void _resumeAfterConnect(LifecycleResume when) {
    final pending = _connectAnswerPending;
    if (pending == null || !pending()) return _resumeFor(when);
    final deadline = clock.now().add(kConnectAnswerWait);
    _connectWait?.cancel();
    void check() {
      if (pending() && clock.now().isBefore(deadline)) {
        _connectWait = Timer(_kConnectAnswerPoll, check);
        return;
      }
      _connectWait = null;
      // The app may have gone to the background while it waited.
      if (_isForeground != null && !_isForeground()) return;
      _resumeFor(when);
    }

    _connectWait = Timer(_kConnectAnswerPoll, check);
  }

  void _resumeFor(LifecycleResume when) {
    final ok = shouldResumeOnLifecycle(
      when,
      _settings(),
      playing: _target.playing,
      hasSession: _hasSession(),
      waitingForFocus: _state.waitingForFocus,
    );
    if (ok) _enqueue(const [FocusAction.resume]);
  }

  // -- Actions ---------------------------------------------------------------

  void _enqueue(List<FocusAction> actions) {
    if (actions.isEmpty) return;
    _queue = _queue.then((_) => _perform(actions));
  }

  void _glide(double level) => unawaited(
    _target.setDuck(level).catchError((Object e) {
      debugPrint('Ducking failed: $e');
    }),
  );

  Future<void> _perform(List<FocusAction> actions) async {
    for (final a in actions) {
      try {
        switch (a) {
          case FocusAction.pause:
            _ownPause = true;
            _forcePausePending = false; // a real pause owns the mark now
            _ownPlay = false;
            // iOS has already silenced the audio, so there is nothing to fade.
            await _target.pause(fade: !_isIos);
            // A pause that changed nothing publishes nothing.
            _ownPause = false;
          case FocusAction.resume:
            // Every automatic resume, whatever started it: not in equalizer
            // mode, not without a queue, and not while another Connect device
            // is the one playing (the call may have ended on a phone whose
            // music was moved to the desktop).
            // The process-never-opened rule is the caller's: a start, reopen,
            // wired or Bluetooth resume asks for it, a resume after a call or a
            // loss of focus does not (the hold exists only because music was
            // playing there on purpose).
            if (!_canResume()) break;
            _ownPlay = true;
            // The player's own play() ends only when playback next pauses.
            unawaited(
              _target.play().catchError((Object e) {
                debugPrint('Resuming playback failed: $e');
              }),
            );
          // The glides are not awaited: a new one carries on from wherever the
          // level has got to, so back-to-back prompts do not swell to full
          // between them, and a pause behind a duck does not wait for it.
          case FocusAction.duck:
            _glide(kDuckLevel);
          case FocusAction.unduck:
            _glide(1.0);
          case FocusAction.reacquireFocus:
            await _requestFocus();
        }
      } catch (e) {
        debugPrint('Audio focus action $a failed: $e');
      }
    }
  }
}

/// Turns the app lifecycle into start and reopen events.
@visibleForTesting
class LifecycleFeed with WidgetsBindingObserver {
  LifecycleFeed() {
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    final seed = binding.lifecycleState;
    if (seed != null) _emit(_tracker.onState(seed));
  }

  final _tracker = ForegroundTracker();

  // Single-subscription: what is added before the service listens is held.
  // When the service stops listening the observer goes and the stream closes.
  late final _controller = StreamController<LifecycleResume>(
    onCancel: _dispose,
  );

  void _dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_controller.close());
  }

  Stream<LifecycleResume> get stream => _controller.stream;

  void _emit(LifecycleResume? e) {
    if (e != null) _controller.add(e);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _emit(_tracker.onState(state));
}
