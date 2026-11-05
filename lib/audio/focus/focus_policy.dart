import 'package:audio_session/audio_session.dart';
import 'package:flutter/widgets.dart';

import 'audio_focus_settings.dart';

/// Hype's own duck: a factor on the player volume.
const kDuckLevel = 0.25;
const kDuckDownMs = 100;
const kDuckUpMs = 500;

enum FocusLossKind { transient, canDuck, permanent }

/// What happened to audio focus (or the listener).
sealed class FocusEvent {
  const FocusEvent();
}

/// Android: focus was lost.
class FocusLost extends FocusEvent {
  const FocusLost(this.kind);
  final FocusLossKind kind;
}

/// Android: the audio mode says the loss is a phone call.
class CallDetected extends FocusEvent {
  const CallDetected();
}

/// Android: focus came back.
class FocusGained extends FocusEvent {
  const FocusGained();
}

/// iOS: an interruption (call, alarm, Siri) began.
class InterruptionBegan extends FocusEvent {
  const InterruptionBegan();
}

/// iOS: the interruption ended.
class InterruptionEnded extends FocusEvent {
  const InterruptionEnded({required this.shouldResume});
  final bool shouldResume;
}

/// Both: the listener pressed play (not Hype's own resume).
class ListenerPlayed extends FocusEvent {
  const ListenerPlayed();
}

/// Both: the listener paused (not one of Hype's own focus pauses).
class PlaybackPaused extends FocusEvent {
  const PlaybackPaused();
}

enum FocusHold { none, ducked, pausedByFocus, pausedByCall }

enum FocusAction {
  pause,
  resume,
  duck,

  /// Back to full level: glides while playing, instant while paused.
  unduck,
  reacquireFocus,
}

class FocusState {
  const FocusState({
    this.hold = FocusHold.none,
    this.lossActive = false,
    this.reclaimed = false,
    this.givenUp = false,
  });

  final FocusHold hold;

  /// A transient or duckable loss is in progress (no gain yet).
  final bool lossActive;

  /// Permanent-off: focus was asked back once since the last pause.
  final bool reclaimed;

  /// Permanent-off: lost again after reclaiming; keep playing, stop asking.
  final bool givenUp;

  bool get waitingForFocus =>
      hold == FocusHold.pausedByFocus || hold == FocusHold.pausedByCall;

  bool get needsFocusRequest => !givenUp;

  FocusState copyWith({
    FocusHold? hold,
    bool? lossActive,
    bool? reclaimed,
    bool? givenUp,
  }) => FocusState(
    hold: hold ?? this.hold,
    lossActive: lossActive ?? this.lossActive,
    reclaimed: reclaimed ?? this.reclaimed,
    givenUp: givenUp ?? this.givenUp,
  );

  @override
  bool operator ==(Object other) =>
      other is FocusState &&
      other.hold == hold &&
      other.lossActive == lossActive &&
      other.reclaimed == reclaimed &&
      other.givenUp == givenUp;

  @override
  int get hashCode => Object.hash(hold, lossActive, reclaimed, givenUp);

  @override
  String toString() =>
      'FocusState($hold, loss: $lossActive, reclaimed: $reclaimed, '
      'givenUp: $givenUp)';
}

class FocusStep {
  const FocusStep(this.state, [this.actions = const []]);
  final FocusState state;
  final List<FocusAction> actions;
}

/// The pure focus policy. [playing] is whether Hype is audibly playing now.
/// [systemMutesLosers] is Android 12+ (an app that keeps playing after losing
/// focus is faded out). [noDuck] and [ignoreFocus] are per-output flags.
FocusStep focusStep(
  FocusState s,
  FocusEvent e,
  AudioFocusSettings settings, {
  required bool playing,
  bool systemMutesLosers = false,
  bool noDuck = false,
  bool ignoreFocus = false,
}) {
  final ducked = s.hold == FocusHold.ducked;

  // Pause that also puts a duck back (the unduck is instant once paused).
  FocusStep pauseFrom(FocusState next) =>
      FocusStep(next, [FocusAction.pause, if (ducked) FocusAction.unduck]);

  switch (e) {
    case PlaybackPaused():
      // The service may never send this when the listener "pauses" an already
      // focus-paused player (the player does nothing), which is fine.
      // The listener paused: a pending resume is cancelled. A duck stays
      // until the focus comes back; it is released then, without resuming.
      final next = s.copyWith(
        hold: ducked ? FocusHold.ducked : FocusHold.none,
        reclaimed: false,
        givenUp: false,
      );
      return FocusStep(next);

    case ListenerPlayed():
      if (s.waitingForFocus) return FocusStep(s.copyWith(hold: FocusHold.none));
      return FocusStep(s);

    case InterruptionBegan():
      if (!playing) return FocusStep(s);
      return FocusStep(s.copyWith(hold: FocusHold.pausedByCall), [
        FocusAction.pause,
      ]);

    case InterruptionEnded(:final shouldResume):
      if (s.hold != FocusHold.pausedByCall) return FocusStep(s);
      final resume = shouldResume && settings.resumeAfterCall;
      return FocusStep(s.copyWith(hold: FocusHold.none), [
        if (resume) FocusAction.resume,
      ]);

    case FocusLost() || CallDetected() || FocusGained():
      // Ignore audio focus ignores short losses, calls and gains. A permanent
      // loss still goes through the "permanent change off" path below (keep
      // playing, ask for focus back once), or Android 12+ fades Hype out while
      // it still shows playing.
      if (ignoreFocus &&
          !(e is FocusLost && e.kind == FocusLossKind.permanent)) {
        return FocusStep(s);
      }
  }

  switch (e) {
    case FocusLost(kind: FocusLossKind.transient):
      final next = s.copyWith(lossActive: true);
      if (!settings.shortFocusChange) return FocusStep(next);
      if (s.waitingForFocus) return FocusStep(next);
      if (!playing) return FocusStep(next); // the listener had paused already
      return pauseFrom(next.copyWith(hold: FocusHold.pausedByFocus));

    case FocusLost(kind: FocusLossKind.canDuck):
      if (!settings.shortFocusChange) return FocusStep(s);
      final next = s.copyWith(lossActive: true);
      if (ducked || s.waitingForFocus || !playing) return FocusStep(next);
      if (settings.duckVolume && !noDuck) {
        return FocusStep(next.copyWith(hold: FocusHold.ducked), [
          FocusAction.duck,
        ]);
      }
      return FocusStep(next.copyWith(hold: FocusHold.pausedByFocus), [
        FocusAction.pause,
      ]);

    case FocusLost(kind: FocusLossKind.permanent):
      final next = s.copyWith(hold: FocusHold.none, lossActive: false);
      if (settings.permanentFocusChange && !ignoreFocus) {
        return playing
            ? pauseFrom(next)
            : FocusStep(next, [if (ducked) FocusAction.unduck]);
      }
      // Permanent change off: keep playing.
      final undo = [if (ducked) FocusAction.unduck];
      if (!playing || !systemMutesLosers) return FocusStep(next, undo);
      if (s.reclaimed) return FocusStep(next.copyWith(givenUp: true), undo);
      return FocusStep(next.copyWith(reclaimed: true), [
        ...undo,
        FocusAction.reacquireFocus,
      ]);

    case CallDetected():
      if (!s.lossActive || !settings.effectivePauseInCall) return FocusStep(s);
      switch (s.hold) {
        case FocusHold.pausedByCall:
          return FocusStep(s);
        case FocusHold.pausedByFocus:
          return FocusStep(s.copyWith(hold: FocusHold.pausedByCall));
        case FocusHold.ducked:
        case FocusHold.none:
          if (!playing) return FocusStep(s);
          return pauseFrom(s.copyWith(hold: FocusHold.pausedByCall));
      }

    case FocusGained():
      final next = s.copyWith(hold: FocusHold.none, lossActive: false);
      switch (s.hold) {
        case FocusHold.ducked:
          return FocusStep(next, [FocusAction.unduck]);
        case FocusHold.pausedByFocus:
          return FocusStep(next, [
            if (settings.resumeOnFocusGain) FocusAction.resume,
          ]);
        case FocusHold.pausedByCall:
          return FocusStep(next, [
            if (settings.resumeAfterCall) FocusAction.resume,
          ]);
        case FocusHold.none:
          return FocusStep(next);
      }

    default:
      return FocusStep(s);
  }
}

FocusEvent focusEventFromInterruption(
  AudioInterruptionEvent e, {
  required bool isIos,
}) {
  if (isIos) {
    return e.begin
        ? const InterruptionBegan()
        : InterruptionEnded(
            shouldResume: e.type == AudioInterruptionType.pause,
          );
  }
  if (!e.begin) return const FocusGained();
  return FocusLost(switch (e.type) {
    AudioInterruptionType.pause => FocusLossKind.transient,
    AudioInterruptionType.duck => FocusLossKind.canDuck,
    AudioInterruptionType.unknown => FocusLossKind.permanent,
  });
}

bool isCallMode(AndroidAudioHardwareMode m) =>
    m == AndroidAudioHardwareMode.ringtone ||
    m == AndroidAudioHardwareMode.inCall ||
    m == AndroidAudioHardwareMode.inCommunication;

enum LifecycleResume { start, reopen }

/// Turns lifecycle states into "start" (first time in the foreground) and
/// "reopen" (a later return after the app was paused or hidden).
class ForegroundTracker {
  bool _started = false;
  bool _wasBackground = false;

  LifecycleResume? onState(AppLifecycleState s) {
    switch (s) {
      case AppLifecycleState.resumed:
        if (!_started) {
          _started = true;
          _wasBackground = false;
          return LifecycleResume.start;
        }
        if (_wasBackground) {
          _wasBackground = false;
          return LifecycleResume.reopen;
        }
        return null;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _wasBackground = true;
        return null;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        return null;
    }
  }
}

/// Reopen is a sub-option of start: it needs both switches.
bool shouldResumeOnLifecycle(
  LifecycleResume when,
  AudioFocusSettings s, {
  required bool playing,
  required bool hasSession,
  required bool waitingForFocus,
}) {
  if (playing || !hasSession || waitingForFocus) return false;
  return switch (when) {
    LifecycleResume.start => s.resumeOnStart,
    LifecycleResume.reopen => s.resumeOnStart && s.resumeOnReopen,
  };
}
