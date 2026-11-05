import 'package:audio_session/audio_session.dart';
import 'package:eq_app/audio/focus/audio_focus_settings.dart';
import 'package:eq_app/audio/focus/focus_policy.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _d = AudioFocusSettings();

FocusStep step(
  FocusState s,
  FocusEvent e, {
  AudioFocusSettings settings = _d,
  bool playing = true,
  bool systemMutesLosers = false,
  bool noDuck = false,
  bool ignoreFocus = false,
}) => focusStep(
  s,
  e,
  settings,
  playing: playing,
  systemMutesLosers: systemMutesLosers,
  noDuck: noDuck,
  ignoreFocus: ignoreFocus,
);

const _none = FocusState();
const _transient = FocusLost(FocusLossKind.transient);
const _canDuck = FocusLost(FocusLossKind.canDuck);
const _permanent = FocusLost(FocusLossKind.permanent);

void main() {
  test('constants', () {
    expect(kDuckLevel, 0.25);
    expect(kDuckDownMs, 100);
    expect(kDuckUpMs, 500);
  });

  test('transient_pauses_gain_resumes', () {
    final a = step(_none, _transient);
    expect(a.actions, [FocusAction.pause]);
    expect(a.state.hold, FocusHold.pausedByFocus);
    expect(a.state.lossActive, isTrue);
    final b = step(a.state, const FocusGained(), playing: false);
    expect(b.actions, [FocusAction.resume]);
    expect(b.state.hold, FocusHold.none);
    expect(b.state.lossActive, isFalse);
  });

  test('call_uses_resume_after_call', () {
    final a = step(_none, _transient);
    final c = step(a.state, const CallDetected(), playing: false);
    expect(c.actions, isEmpty);
    expect(c.state.hold, FocusHold.pausedByCall);
    expect(
      step(
        c.state,
        const FocusGained(),
        playing: false,
        settings: _d.copyWith(resumeAfterCall: false),
      ).actions,
      isEmpty,
    );
    expect(step(c.state, const FocusGained(), playing: false).actions, [
      FocusAction.resume,
    ]);
    // A call resumes by Resume after call, not Resume on focus gain.
    expect(
      step(
        c.state,
        const FocusGained(),
        playing: false,
        settings: _d.copyWith(resumeOnFocusGain: false),
      ).actions,
      [FocusAction.resume],
    );
  });

  test('focus_gain_switch', () {
    final s = _d.copyWith(resumeOnFocusGain: false);
    final a = step(_none, _transient, settings: s);
    expect(a.actions, [FocusAction.pause]);
    final b = step(a.state, const FocusGained(), playing: false, settings: s);
    expect(b.actions, isEmpty);
    expect(b.state.hold, FocusHold.none);
  });

  test('duck_and_unduck', () {
    final a = step(_none, _canDuck);
    expect(a.actions, [FocusAction.duck]);
    expect(a.state.hold, FocusHold.ducked);
    final b = step(a.state, const FocusGained());
    expect(b.actions, [FocusAction.unduck]);
    expect(b.state.hold, FocusHold.none);
  });

  test('duck_off_pauses', () {
    for (final noDuck in [false, true]) {
      final s = noDuck ? _d : _d.copyWith(duckVolume: false);
      final a = step(_none, _canDuck, settings: s, noDuck: noDuck);
      expect(a.actions, [FocusAction.pause]);
      expect(a.state.hold, FocusHold.pausedByFocus);
      final b = step(
        a.state,
        const FocusGained(),
        playing: false,
        settings: s,
        noDuck: noDuck,
      );
      expect(b.actions, [FocusAction.resume]);
    }
  });

  test('ducked_then_transient_pauses_then_unducks', () {
    final a = step(_none, _canDuck);
    final b = step(a.state, _transient);
    expect(b.actions, [FocusAction.pause, FocusAction.unduck]);
    expect(b.state.hold, FocusHold.pausedByFocus);
  });

  test('listener_pause_while_ducked_cancels_unduck_hold', () {
    final a = step(_none, _canDuck);
    final p = step(a.state, const PlaybackPaused(), playing: false);
    expect(p.actions, isEmpty);
    final g = step(p.state, const FocusGained(), playing: false);
    expect(g.actions, [FocusAction.unduck]); // duck released, no resume
    expect(g.state.hold, FocusHold.none);
    // Same for a transient that arrives after the listener paused.
    final t = step(p.state, _transient, playing: false);
    expect(t.actions, isEmpty);
    expect(step(t.state, const FocusGained(), playing: false).actions, [
      FocusAction.unduck,
    ]);
  });

  group('short_off', () {
    final s = _d.copyWith(shortFocusChange: false);
    test('transient ignored, call pauses', () {
      final a = step(_none, _transient, settings: s);
      expect(a.actions, isEmpty);
      expect(a.state.lossActive, isTrue);
      expect(a.state.hold, FocusHold.none);
      final c = step(a.state, const CallDetected(), settings: s);
      expect(c.actions, [FocusAction.pause]);
      expect(c.state.hold, FocusHold.pausedByCall);
      expect(
        step(c.state, const FocusGained(), playing: false, settings: s).actions,
        [FocusAction.resume],
      );
    });
    test('pauseInCall false ignores call', () {
      final s2 = s.copyWith(pauseInCall: false);
      final a = step(_none, _transient, settings: s2);
      expect(
        step(a.state, const CallDetected(), settings: s2).actions,
        isEmpty,
      );
    });
    test('canDuck ignored', () {
      expect(step(_none, _canDuck, settings: s).actions, isEmpty);
    });
  });

  group('permanent', () {
    test('pauses, no resume', () {
      final a = step(_none, _permanent);
      expect(a.actions, [FocusAction.pause]);
      expect(a.state.hold, FocusHold.none);
      expect(a.state.lossActive, isFalse);
      expect(
        step(a.state, const FocusGained(), playing: false).actions,
        isEmpty,
      );
    });
    test('while ducked', () {
      final a = step(_none, _canDuck);
      expect(step(a.state, _permanent).actions, [
        FocusAction.pause,
        FocusAction.unduck,
      ]);
    });
    test('after transient (not playing)', () {
      final a = step(_none, _transient);
      final b = step(a.state, _permanent, playing: false);
      expect(b.state.hold, FocusHold.none);
      expect(
        step(b.state, const FocusGained(), playing: false).actions,
        isEmpty,
      );
    });
  });

  group('permanent_off', () {
    final s = _d.copyWith(permanentFocusChange: false);
    test('no muting: nothing', () {
      expect(step(_none, _permanent, settings: s).actions, isEmpty);
    });
    test('system mutes losers: reclaim once', () {
      final a = step(_none, _permanent, settings: s, systemMutesLosers: true);
      expect(a.actions, [FocusAction.reacquireFocus]);
      expect(a.state.reclaimed, isTrue);
      expect(a.state.needsFocusRequest, isTrue);
      final b = step(a.state, _permanent, settings: s, systemMutesLosers: true);
      expect(b.actions, isEmpty);
      expect(b.state.needsFocusRequest, isFalse);
      final c = step(
        b.state,
        const PlaybackPaused(),
        playing: false,
        settings: s,
        systemMutesLosers: true,
      );
      expect(c.state.needsFocusRequest, isTrue);
      expect(c.state.reclaimed, isFalse);
    });
    test('while ducked', () {
      final a = step(_none, _canDuck);
      expect(step(a.state, _permanent, settings: s).actions, [
        FocusAction.unduck,
      ]);
    });
  });

  test('paused_before_loss_never_resumes', () {
    final a = step(_none, _transient, playing: false);
    expect(a.actions, isEmpty);
    expect(step(a.state, const FocusGained(), playing: false).actions, isEmpty);
  });

  test('listener_play_cancels_resume', () {
    final a = step(_none, _transient);
    final b = step(a.state, const ListenerPlayed());
    expect(b.state.hold, FocusHold.none);
    expect(step(b.state, const FocusGained()).actions, isEmpty);
  });

  test('listener_pause_cancels_held_resume', () {
    final f = step(_none, _transient);
    final fp = step(f.state, const PlaybackPaused(), playing: false);
    expect(fp.state.hold, FocusHold.none);
    expect(
      step(fp.state, const FocusGained(), playing: false).actions,
      isEmpty,
    );

    final c = step(f.state, const CallDetected(), playing: false);
    expect(c.state.hold, FocusHold.pausedByCall);
    final cp = step(c.state, const PlaybackPaused(), playing: false);
    expect(cp.state.hold, FocusHold.none);
    expect(
      step(cp.state, const FocusGained(), playing: false).actions,
      isEmpty,
    );
    // iOS call end too.
    final i = step(_none, const InterruptionBegan());
    final ip = step(i.state, const PlaybackPaused(), playing: false);
    expect(
      step(
        ip.state,
        const InterruptionEnded(shouldResume: true),
        playing: false,
      ).actions,
      isEmpty,
    );
  });

  test('stale_call_poll', () {
    expect(step(_none, const CallDetected()).actions, isEmpty);
  });

  test('ignore_focus', () {
    for (final e in <FocusEvent>[
      _transient,
      _canDuck,
      const CallDetected(),
      const FocusGained(),
    ]) {
      final r = step(const FocusState(lossActive: true), e, ignoreFocus: true);
      expect(r.actions, isEmpty);
      expect(r.state, const FocusState(lossActive: true));
    }
  });

  group('ignore focus and a permanent loss', () {
    test('keeps playing and asks for focus back once (Android 12+)', () {
      final a = step(
        _none,
        _permanent,
        ignoreFocus: true,
        systemMutesLosers: true,
      );
      expect(a.actions, [FocusAction.reacquireFocus]);
      expect(a.state.reclaimed, isTrue);
      expect(a.state.hold, FocusHold.none);
      final b = step(
        a.state,
        _permanent,
        ignoreFocus: true,
        systemMutesLosers: true,
      );
      expect(b.actions, isEmpty);
      expect(b.state.givenUp, isTrue);
    });

    test('never pauses, even where the system does not mute losers', () {
      final a = step(_none, _permanent, ignoreFocus: true);
      expect(a.actions, isEmpty);
    });

    test('releases a duck that was in place', () {
      final a = step(
        const FocusState(hold: FocusHold.ducked, lossActive: true),
        _permanent,
        ignoreFocus: true,
        systemMutesLosers: true,
      );
      expect(a.actions, [FocusAction.unduck, FocusAction.reacquireFocus]);
    });
  });

  group('ios', () {
    test('began pauses, ended resumes by shouldResume', () {
      final a = step(_none, const InterruptionBegan());
      expect(a.actions, [FocusAction.pause]);
      expect(a.state.hold, FocusHold.pausedByCall);
      expect(
        step(
          a.state,
          const InterruptionEnded(shouldResume: true),
          playing: false,
        ).actions,
        [FocusAction.resume],
      );
      expect(
        step(
          a.state,
          const InterruptionEnded(shouldResume: false),
          playing: false,
        ).actions,
        isEmpty,
      );
    });
    test('resumeAfterCall false', () {
      final a = step(_none, const InterruptionBegan());
      expect(
        step(
          a.state,
          const InterruptionEnded(shouldResume: true),
          playing: false,
          settings: _d.copyWith(resumeAfterCall: false),
        ).actions,
        isEmpty,
      );
    });
    test('paused before', () {
      final a = step(_none, const InterruptionBegan(), playing: false);
      expect(a.actions, isEmpty);
      expect(
        step(
          a.state,
          const InterruptionEnded(shouldResume: true),
          playing: false,
        ).actions,
        isEmpty,
      );
    });
  });

  test('waitingForFocus', () {
    expect(
      const FocusState(hold: FocusHold.pausedByFocus).waitingForFocus,
      isTrue,
    );
    expect(
      const FocusState(hold: FocusHold.pausedByCall).waitingForFocus,
      isTrue,
    );
    expect(const FocusState(hold: FocusHold.ducked).waitingForFocus, isFalse);
    expect(const FocusState().waitingForFocus, isFalse);
  });

  group('focusEventFromInterruption', () {
    AudioInterruptionEvent ev(bool b, AudioInterruptionType t) =>
        AudioInterruptionEvent(b, t);
    test('android', () {
      expect(
        focusEventFromInterruption(
          ev(true, AudioInterruptionType.pause),
          isIos: false,
        ),
        isA<FocusLost>().having((e) => e.kind, 'kind', FocusLossKind.transient),
      );
      expect(
        focusEventFromInterruption(
          ev(true, AudioInterruptionType.duck),
          isIos: false,
        ),
        isA<FocusLost>().having((e) => e.kind, 'kind', FocusLossKind.canDuck),
      );
      expect(
        focusEventFromInterruption(
          ev(true, AudioInterruptionType.unknown),
          isIos: false,
        ),
        isA<FocusLost>().having((e) => e.kind, 'kind', FocusLossKind.permanent),
      );
      expect(
        focusEventFromInterruption(
          ev(false, AudioInterruptionType.pause),
          isIos: false,
        ),
        isA<FocusGained>(),
      );
      expect(
        focusEventFromInterruption(
          ev(false, AudioInterruptionType.duck),
          isIos: false,
        ),
        isA<FocusGained>(),
      );
    });
    test('ios', () {
      expect(
        focusEventFromInterruption(
          ev(true, AudioInterruptionType.unknown),
          isIos: true,
        ),
        isA<InterruptionBegan>(),
      );
      expect(
        focusEventFromInterruption(
          ev(false, AudioInterruptionType.pause),
          isIos: true,
        ),
        isA<InterruptionEnded>().having(
          (e) => e.shouldResume,
          'shouldResume',
          true,
        ),
      );
      expect(
        focusEventFromInterruption(
          ev(false, AudioInterruptionType.unknown),
          isIos: true,
        ),
        isA<InterruptionEnded>().having(
          (e) => e.shouldResume,
          'shouldResume',
          false,
        ),
      );
    });
  });

  test('isCallMode', () {
    expect(isCallMode(AndroidAudioHardwareMode.ringtone), isTrue);
    expect(isCallMode(AndroidAudioHardwareMode.inCall), isTrue);
    expect(isCallMode(AndroidAudioHardwareMode.inCommunication), isTrue);
    expect(isCallMode(AndroidAudioHardwareMode.normal), isFalse);
    expect(isCallMode(AndroidAudioHardwareMode.invalid), isFalse);
    expect(isCallMode(AndroidAudioHardwareMode.current), isFalse);
  });

  group('ForegroundTracker', () {
    test('start then inactive/resumed', () {
      final t = ForegroundTracker();
      expect(t.onState(AppLifecycleState.resumed), LifecycleResume.start);
      expect(t.onState(AppLifecycleState.inactive), isNull);
      expect(t.onState(AppLifecycleState.resumed), isNull);
    });
    test('paused/hidden then resumed reopens', () {
      for (final bg in [AppLifecycleState.paused, AppLifecycleState.hidden]) {
        final t = ForegroundTracker();
        t.onState(AppLifecycleState.resumed);
        expect(t.onState(bg), isNull);
        expect(t.onState(AppLifecycleState.resumed), LifecycleResume.reopen);
        expect(t.onState(AppLifecycleState.resumed), isNull);
      }
    });
    test('fresh tracker', () {
      final t = ForegroundTracker();
      expect(t.onState(AppLifecycleState.inactive), isNull);
      expect(t.onState(AppLifecycleState.resumed), LifecycleResume.start);
    });
  });

  group('shouldResumeOnLifecycle', () {
    bool f(
      LifecycleResume w,
      AudioFocusSettings s, {
      bool playing = false,
      bool hasSession = true,
      bool waiting = false,
    }) => shouldResumeOnLifecycle(
      w,
      s,
      playing: playing,
      hasSession: hasSession,
      waitingForFocus: waiting,
    );
    test('start', () {
      expect(
        f(LifecycleResume.start, _d.copyWith(resumeOnStart: true)),
        isTrue,
      );
      expect(f(LifecycleResume.start, _d), isFalse);
    });
    test('reopen', () {
      expect(
        f(LifecycleResume.reopen, _d.copyWith(resumeOnReopen: true)),
        isFalse,
      );
      expect(
        f(
          LifecycleResume.reopen,
          _d.copyWith(resumeOnStart: true, resumeOnReopen: true),
        ),
        isTrue,
      );
    });
    test('blocked', () {
      final s = _d.copyWith(resumeOnStart: true, resumeOnReopen: true);
      expect(f(LifecycleResume.start, s, playing: true), isFalse);
      expect(f(LifecycleResume.start, s, hasSession: false), isFalse);
      expect(f(LifecycleResume.start, s, waiting: true), isFalse);
    });
  });
}
