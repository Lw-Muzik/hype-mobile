// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:eq_app/audio/focus/audio_focus_settings.dart';
import 'package:eq_app/audio/focus/focus_policy.dart';
import 'package:eq_app/audio/focus/playback_target.dart';
import 'package:eq_app/services/audio_focus_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

/// Records what the service asks of the player. A pause completes after 50 ms;
/// a play never completes (it is the player's own `play()`, which ends only
/// when playback next pauses).
class FakeTarget implements PlaybackTarget {
  FakeTarget({bool playing = true}) : _playing = playing;

  /// How long a duck glide takes to complete.
  Duration duckTime = Duration.zero;

  final calls = <String>[];
  bool _playing;
  final _changes = StreamController<bool>.broadcast();

  @override
  bool get playing => _playing;

  @override
  Stream<bool> get playingStream => _changes.stream;

  /// Something other than the service changed the playing state.
  void setPlaying(bool value) {
    if (value == _playing) return;
    _playing = value;
    _changes.add(value);
  }

  @override
  Future<void> play() {
    calls.add('play');
    setPlaying(true);
    return Completer<void>().future;
  }

  @override
  Future<void> pause({bool fade = true}) async {
    calls.add('pause(fade: $fade)');
    setPlaying(false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    calls.add('paused');
  }

  @override
  Future<void> setDuck(double level) async {
    calls.add('duck($level)');
    if (duckTime > Duration.zero) await Future<void>.delayed(duckTime);
  }

  @override
  Future<void> restartPlayback() {
    calls.add('restart');
    return Completer<void>().future;
  }
}

AudioInterruptionEvent begin(AudioInterruptionType t) =>
    AudioInterruptionEvent(true, t);
AudioInterruptionEvent end(AudioInterruptionType t) =>
    AudioInterruptionEvent(false, t);

class Rig {
  Rig({
    AudioFocusSettings settings = const AudioFocusSettings(),
    bool isIos = false,
    bool systemMutesLosers = false,
    bool playing = true,
    bool hasSession = true,
    bool canResume = true,
    bool Function()? connectAnswerPending,
    bool Function()? isForeground,
    Future<AndroidAudioHardwareMode> Function()? audioMode,
    bool withLifecycle = false,
    Future<bool> Function()? requestFocus,
  }) : target = FakeTarget(playing: playing) {
    this.settings = settings;
    this.hasSession = hasSession;
    this.canResume = canResume;
    service = AudioFocusService(
      target: target,
      settings: () => this.settings,
      hasSession: () => this.hasSession,
      canResume: () => this.canResume,
      connectAnswerPending: connectAnswerPending,
      isForeground: isForeground,
      isIos: isIos,
      interruptions: interruptions.stream,
      requestFocus:
          requestFocus ??
          () async {
            focusRequests++;
            return true;
          },
      audioMode: audioMode,
      lifecycle: withLifecycle ? lifecycle.stream : null,
      systemMutesLosers: systemMutesLosers,
      bindActivation: (f) => activation = f,
    )..start();
  }

  final FakeTarget target;
  final interruptions = StreamController<AudioInterruptionEvent>.broadcast();
  final lifecycle = StreamController<LifecycleResume>.broadcast();
  late AudioFocusSettings settings;
  late bool hasSession;
  late bool canResume;
  late final AudioFocusService service;
  int focusRequests = 0;
  Future<bool> Function()? activation;
}

void main() {
  group('LifecycleFeed', () {
    testWidgets('turns states into start and reopen, and lets go on cancel', (
      tester,
    ) async {
      final binding = tester.binding;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final feed = LifecycleFeed(); // seeded: the app is already resumed
      final got = <LifecycleResume>[];
      var done = false;
      final sub = feed.stream.listen(got.add, onDone: () => done = true);
      await tester.pump();
      expect(got, [LifecycleResume.start]);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(got, [LifecycleResume.start, LifecycleResume.reopen]);

      unawaited(sub.cancel());
      await tester.pump();
      // Cancelled: the observer is gone, so further changes do not reach a
      // closed controller (which would throw).
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(got, hasLength(2));
      expect(done, isFalse, reason: 'a cancelled listener hears no done');
    });
  });

  group('Android', () {
    test('transient_pauses_and_gain_resumes', () {
      fakeAsync((async) {
        final r = Rig();
        r.interruptions.add(begin(AudioInterruptionType.pause));
        async.elapse(const Duration(milliseconds: 100));
        expect(r.target.calls, ['pause(fade: true)', 'paused']);
        expect(r.service.waitingForFocus, isTrue);

        r.target.calls.clear();
        r.interruptions.add(end(AudioInterruptionType.pause));
        async.flushMicrotasks();
        expect(r.target.calls, ['play']);
        expect(r.service.waitingForFocus, isFalse);
      });
    });

    test('the pause is requested at once, before it completes', () {
      fakeAsync((async) {
        final r = Rig();
        r.interruptions.add(begin(AudioInterruptionType.pause));
        async.flushMicrotasks();
        expect(r.target.calls, ['pause(fade: true)']);
      });
    });

    test('late_call_detection_upgrades_the_hold', () {
      fakeAsync((async) {
        var mode = AndroidAudioHardwareMode.normal;
        final r = Rig(
          settings: const AudioFocusSettings(resumeAfterCall: false),
          audioMode: () async => mode,
        );
        r.interruptions.add(begin(AudioInterruptionType.pause));
        async.elapse(const Duration(milliseconds: 100));
        expect(r.target.calls, ['pause(fade: true)', 'paused']);

        async.elapse(const Duration(milliseconds: 300));
        mode = AndroidAudioHardwareMode.inCall; // seen by the poll at 500 ms
        async.elapse(const Duration(milliseconds: 100));
        async.elapse(const Duration(milliseconds: 1500));

        r.target.calls.clear();
        // A gain at 2 s: it was a call, and resuming after a call is off.
        r.interruptions.add(end(AudioInterruptionType.pause));
        async.flushMicrotasks();
        expect(r.target.calls, isNot(contains('play')));
        expect(r.target.calls, isEmpty);
      });
    });

    test('a call polled at 0, 500 and 1500 ms', () {
      expect(kCallModePolls, [
        Duration.zero,
        const Duration(milliseconds: 500),
        const Duration(milliseconds: 1500),
      ]);
    });

    test('without a call the resume follows Resume on focus gain', () {
      fakeAsync((async) {
        final r = Rig(
          settings: const AudioFocusSettings(resumeAfterCall: false),
          audioMode: () async => AndroidAudioHardwareMode.normal,
        );
        r.interruptions.add(begin(AudioInterruptionType.pause));
        async.elapse(const Duration(seconds: 2));
        r.target.calls.clear();
        r.interruptions.add(end(AudioInterruptionType.pause));
        async.flushMicrotasks();
        expect(r.target.calls, ['play']);
      });
    });

    test('short_off_pause_in_call', () {
      fakeAsync((async) {
        final r = Rig(
          settings: const AudioFocusSettings(shortFocusChange: false),
          audioMode: () async => AndroidAudioHardwareMode.inCall,
        );
        r.interruptions.add(begin(AudioInterruptionType.pause));
        async.elapse(const Duration(milliseconds: 100));
        expect(r.target.calls, ['pause(fade: true)', 'paused']);

        r.target.calls.clear();
        r.interruptions.add(end(AudioInterruptionType.pause));
        async.flushMicrotasks();
        expect(r.target.calls, ['play']);
      });
    });

    test('short off and no call: the loss is ignored entirely', () {
      fakeAsync((async) {
        final r = Rig(
          settings: const AudioFocusSettings(shortFocusChange: false),
          audioMode: () async => AndroidAudioHardwareMode.normal,
        );
        r.interruptions.add(begin(AudioInterruptionType.pause));
        r.interruptions.add(begin(AudioInterruptionType.duck));
        async.elapse(const Duration(seconds: 2));
        expect(r.target.calls, isEmpty);
      });
    });

    test('unduck_waits_for_the_pause', () {
      fakeAsync((async) {
        final r = Rig();
        r.interruptions.add(begin(AudioInterruptionType.duck));
        r.interruptions.add(begin(AudioInterruptionType.pause));
        async.elapse(const Duration(milliseconds: 200));
        expect(r.target.calls, [
          'duck(0.25)',
          'pause(fade: true)',
          'paused',
          'duck(1.0)',
        ]);
      });
    });

    test('a gain after a duck brings the level back', () {
      fakeAsync((async) {
        final r = Rig();
        r.interruptions.add(begin(AudioInterruptionType.duck));
        async.flushMicrotasks();
        r.interruptions.add(end(AudioInterruptionType.duck));
        async.flushMicrotasks();
        expect(r.target.calls, ['duck(0.25)', 'duck(1.0)']);
      });
    });

    test('listener_play_cancels', () {
      fakeAsync((async) {
        final r = Rig();
        r.interruptions.add(begin(AudioInterruptionType.pause));
        async.elapse(const Duration(milliseconds: 100));
        r.target.calls.clear();

        r.target.setPlaying(true); // the listener pressed play
        async.flushMicrotasks();
        r.interruptions.add(end(AudioInterruptionType.pause));
        async.flushMicrotasks();
        expect(r.target.calls, isNot(contains('play')));
        expect(r.service.waitingForFocus, isFalse);
      });
    });

    test('a pause before the loss is never undone', () {
      fakeAsync((async) {
        final r = Rig(playing: false);
        r.interruptions.add(begin(AudioInterruptionType.pause));
        r.interruptions.add(end(AudioInterruptionType.pause));
        async.elapse(const Duration(seconds: 2));
        expect(r.target.calls, isEmpty);
      });
    });

    test('listener_pause_while_ducked_releases_the_duck_without_resuming', () {
      fakeAsync((async) {
        final r = Rig();
        r.interruptions.add(begin(AudioInterruptionType.duck));
        async.flushMicrotasks();
        r.target.calls.clear();

        r.target.setPlaying(false); // the listener pauses while ducked
        async.flushMicrotasks();
        expect(r.target.calls, ['duck(1.0)']);

        r.target.calls.clear();
        r.interruptions.add(end(AudioInterruptionType.duck));
        async.flushMicrotasks();
        expect(r.target.calls, isNot(contains('play')));
      });
    });

    test('no_tug_of_war', () {
      fakeAsync((async) {
        final r = Rig(
          settings: const AudioFocusSettings(permanentFocusChange: false),
          systemMutesLosers: true,
        );
        r.interruptions.add(begin(AudioInterruptionType.unknown));
        r.interruptions.add(begin(AudioInterruptionType.unknown));
        async.flushMicrotasks();
        expect(r.focusRequests, 1);
        expect(r.target.calls, isEmpty, reason: 'it keeps playing');

        expect(r.service.activate(), completion(isTrue));
        async.flushMicrotasks();
        expect(r.focusRequests, 1, reason: 'no second request');

        r.target.setPlaying(false); // the listener pauses
        async.flushMicrotasks();
        expect(r.service.activate(), completion(isTrue));
        async.flushMicrotasks();
        expect(r.focusRequests, 2);
      });
    });

    test('a permanent loss pauses and nothing resumes', () {
      fakeAsync((async) {
        final r = Rig();
        r.interruptions.add(begin(AudioInterruptionType.unknown));
        async.elapse(const Duration(milliseconds: 100));
        r.target.calls.clear();
        r.interruptions.add(end(AudioInterruptionType.pause));
        async.flushMicrotasks();
        expect(r.target.calls, isEmpty);
      });
    });

    test('actions that throw do not stall the ones behind them', () {
      fakeAsync((async) {
        final r = Rig(
          settings: const AudioFocusSettings(permanentFocusChange: false),
          systemMutesLosers: true,
          requestFocus: () async => throw StateError('no focus'),
        );
        r.interruptions.add(begin(AudioInterruptionType.duck));
        r.interruptions.add(begin(AudioInterruptionType.unknown));
        r.interruptions.add(begin(AudioInterruptionType.pause));
        async.elapse(const Duration(seconds: 1));
        expect(r.target.calls, contains('duck(0.25)'));
      });
    });
  });

  group('cancelHold', () {
    test('a focus gain after a cancelled hold does not resume', () {
      fakeAsync((async) {
        final r = Rig();
        r.interruptions.add(begin(AudioInterruptionType.pause));
        async.elapse(const Duration(milliseconds: 100));
        expect(r.service.waitingForFocus, isTrue);
        r.service.cancelHold();
        async.flushMicrotasks();
        expect(r.service.waitingForFocus, isFalse);
        r.target.calls.clear();
        r.interruptions.add(end(AudioInterruptionType.pause));
        async.flushMicrotasks();
        expect(r.target.calls, isEmpty);
      });
    });

    test('an iOS interruption end that says resume does not resume', () {
      fakeAsync((async) {
        final r = Rig(isIos: true);
        r.interruptions.add(begin(AudioInterruptionType.unknown));
        async.elapse(const Duration(milliseconds: 100));
        r.service.cancelHold();
        r.target.calls.clear();
        r.interruptions.add(end(AudioInterruptionType.pause));
        async.flushMicrotasks();
        expect(r.target.calls, isEmpty);
      });
    });

    test('a call hold is cancelled too', () {
      fakeAsync((async) {
        final r = Rig(audioMode: () async => AndroidAudioHardwareMode.inCall);
        r.interruptions.add(begin(AudioInterruptionType.pause));
        async.elapse(const Duration(seconds: 2));
        r.service.cancelHold();
        r.target.calls.clear();
        r.interruptions.add(end(AudioInterruptionType.pause));
        async.flushMicrotasks();
        expect(r.target.calls, isEmpty);
      });
    });

    test('a duck is put back, and the gain does not resume', () {
      fakeAsync((async) {
        final r = Rig();
        r.interruptions.add(begin(AudioInterruptionType.duck));
        async.flushMicrotasks();
        r.target.calls.clear();
        r.service.cancelHold();
        async.flushMicrotasks();
        expect(r.target.calls, ['duck(1.0)']);
      });
    });

    test('with nothing held it does nothing', () {
      fakeAsync((async) {
        final r = Rig();
        r.service.cancelHold();
        async.flushMicrotasks();
        expect(r.target.calls, isEmpty);
      });
    });
  });

  group('ducking', () {
    test('back-to-back prompts do not swell to full between them', () {
      fakeAsync((async) {
        final r = Rig();
        r.target.duckTime = const Duration(milliseconds: 500);
        r.interruptions.add(begin(AudioInterruptionType.duck));
        r.interruptions.add(end(AudioInterruptionType.duck));
        r.interruptions.add(begin(AudioInterruptionType.duck));
        async.flushMicrotasks();
        // All three were asked for at once, none waiting for a glide.
        expect(r.target.calls, ['duck(0.25)', 'duck(1.0)', 'duck(0.25)']);
      });
    });

    test('a call pause does not wait for a duck glide', () {
      fakeAsync((async) {
        final r = Rig();
        r.target.duckTime = const Duration(milliseconds: 500);
        r.interruptions.add(begin(AudioInterruptionType.duck));
        r.interruptions.add(begin(AudioInterruptionType.pause));
        async.flushMicrotasks();
        expect(r.target.calls, ['duck(0.25)', 'pause(fade: true)']);
      });
    });

    test('a listener play during a duckable loss plays ducked', () {
      fakeAsync((async) {
        final r = Rig();
        r.interruptions.add(begin(AudioInterruptionType.duck));
        async.flushMicrotasks();
        r.target.setPlaying(false); // the listener pauses: level comes back
        async.flushMicrotasks();
        r.target.calls.clear();
        r.target.setPlaying(true); // and plays again; the prompt still talks
        async.flushMicrotasks();
        expect(r.target.calls, ['duck(0.25)']);

        r.target.calls.clear();
        r.interruptions.add(end(AudioInterruptionType.duck));
        async.flushMicrotasks();
        expect(r.target.calls, ['duck(1.0)']);
      });
    });

    test('a play after a duckable loss that began while paused is ducked', () {
      fakeAsync((async) {
        final r = Rig(playing: false);
        r.interruptions.add(begin(AudioInterruptionType.duck));
        async.flushMicrotasks();
        expect(r.target.calls, isEmpty);
        r.target.setPlaying(true);
        async.flushMicrotasks();
        expect(r.target.calls, ['duck(0.25)']);
      });
    });

    test('a play after the loss has ended is not ducked', () {
      fakeAsync((async) {
        final r = Rig(playing: false);
        r.interruptions.add(begin(AudioInterruptionType.duck));
        r.interruptions.add(end(AudioInterruptionType.duck));
        async.flushMicrotasks();
        r.target.setPlaying(true);
        async.flushMicrotasks();
        expect(r.target.calls, isEmpty);
      });
    });

    test('with Duck volume off a play during the loss is not ducked', () {
      fakeAsync((async) {
        final r = Rig(
          playing: false,
          settings: const AudioFocusSettings(duckVolume: false),
        );
        r.interruptions.add(begin(AudioInterruptionType.duck));
        async.flushMicrotasks();
        r.target.setPlaying(true);
        async.flushMicrotasks();
        expect(r.target.calls, isEmpty);
      });
    });
  });

  group('a process the listener never opened', () {
    test('playing there on purpose: the resume after a call still happens', () {
      fakeAsync((async) {
        final r = Rig(withLifecycle: true); // no lifecycle event: never opened
        expect(r.service.uiHasBeenForeground, isFalse);
        r.interruptions.add(begin(AudioInterruptionType.pause));
        async.elapse(const Duration(milliseconds: 100));
        r.target.calls.clear();
        r.interruptions.add(end(AudioInterruptionType.pause));
        async.flushMicrotasks();
        expect(r.target.calls, ['play']);
      });
    });

    test('an iOS interruption end resumes in a never-opened process too', () {
      fakeAsync((async) {
        final r = Rig(isIos: true, withLifecycle: true);
        r.interruptions.add(begin(AudioInterruptionType.unknown));
        async.elapse(const Duration(milliseconds: 100));
        r.target.calls.clear();
        r.interruptions.add(end(AudioInterruptionType.pause));
        async.flushMicrotasks();
        expect(r.target.calls, ['play']);
      });
    });

    test('mayResumeAutomatically: only the foreground flag differs', () {
      bool may({
        bool eq = false,
        bool queue = true,
        bool other = false,
        bool seen = false,
        bool require = true,
      }) => mayResumeAutomatically(
        eqMode: eq,
        hasQueue: queue,
        otherDeviceActive: other,
        uiSeen: seen,
        requireUiSeen: require,
      );
      // Car Bluetooth connects, UI never opened: no resume.
      expect(may(seen: false, require: true), isFalse);
      // The same process, the resume after a call: allowed.
      expect(may(seen: false, require: false), isTrue);
      expect(may(seen: true), isTrue);
      // The other rules hold on both paths.
      for (final require in [true, false]) {
        expect(may(seen: true, require: require, eq: true), isFalse);
        expect(may(seen: true, require: require, queue: false), isFalse);
        expect(may(seen: true, require: require, other: true), isFalse);
      }
    });

    test('after the UI has been seen the gain resumes too', () {
      fakeAsync((async) {
        final r = Rig(withLifecycle: true);
        r.lifecycle.add(LifecycleResume.start);
        async.flushMicrotasks();
        expect(r.service.uiHasBeenForeground, isTrue);
        r.interruptions.add(begin(AudioInterruptionType.pause));
        async.elapse(const Duration(milliseconds: 100));
        r.target.calls.clear();
        r.interruptions.add(end(AudioInterruptionType.pause));
        async.flushMicrotasks();
        expect(r.target.calls, ['play']);
      });
    });

    test('a service with no lifecycle source is not gated', () {
      fakeAsync((async) {
        final r = Rig();
        expect(r.service.uiHasBeenForeground, isTrue);
      });
    });

    test('a start that finds no queue stays quiet, and UI is still seen', () {
      fakeAsync((async) {
        final r = Rig(
          settings: const AudioFocusSettings(resumeOnStart: true),
          playing: false,
          withLifecycle: true,
          hasSession: false,
        );
        r.lifecycle.add(LifecycleResume.start);
        r.service.sessionRestored();
        async.flushMicrotasks();
        expect(r.target.calls, isEmpty);
        expect(r.service.uiHasBeenForeground, isTrue);
      });
    });
  });

  group('automatic resumes ask canResume (Hype Connect, equalizer, no queue)',
      () {
    test('a focus gain does not resume while canResume is false', () {
      fakeAsync((async) {
        final r = Rig();
        r.interruptions.add(begin(AudioInterruptionType.pause));
        async.elapse(const Duration(milliseconds: 100));
        r.canResume = false; // the listener moved playback to the desktop
        r.target.calls.clear();
        r.interruptions.add(end(AudioInterruptionType.pause));
        async.flushMicrotasks();
        expect(r.target.calls, isEmpty);
        expect(r.service.waitingForFocus, isFalse, reason: 'hold cleared');
      });
    });

    test('an iOS interruption end does not resume while canResume is false',
        () {
      fakeAsync((async) {
        final r = Rig(isIos: true);
        r.interruptions.add(begin(AudioInterruptionType.unknown));
        async.elapse(const Duration(milliseconds: 100));
        r.canResume = false;
        r.target.calls.clear();
        r.interruptions.add(end(AudioInterruptionType.pause));
        async.flushMicrotasks();
        expect(r.target.calls, isEmpty);
        expect(r.service.waitingForFocus, isFalse);
      });
    });

    test('a resume whose canResume turns true still goes through', () {
      fakeAsync((async) {
        final r = Rig(canResume: false);
        r.interruptions.add(begin(AudioInterruptionType.pause));
        async.elapse(const Duration(milliseconds: 100));
        r.canResume = true;
        r.target.calls.clear();
        r.interruptions.add(end(AudioInterruptionType.pause));
        async.flushMicrotasks();
        expect(r.target.calls, ['play']);
      });
    });
  });

  group('start waits for the Hype Connect hub', () {
    Rig rig({
      required bool Function() pending,
      bool canResume = true,
    }) => Rig(
      settings: const AudioFocusSettings(resumeOnStart: true),
      playing: false,
      withLifecycle: true,
      canResume: canResume,
      connectAnswerPending: pending,
    );

    test('goes ahead at once when Connect is not in use', () {
      fakeAsync((async) {
        final r = rig(pending: () => false);
        r.service.sessionRestored();
        r.lifecycle.add(LifecycleResume.start);
        async.flushMicrotasks();
        expect(r.target.calls, ['play']);
      });
    });

    test('waits for the answer, then resumes when nobody else is playing', () {
      fakeAsync((async) {
        var pending = true;
        final r = rig(pending: () => pending);
        r.service.sessionRestored();
        r.lifecycle.add(LifecycleResume.start);
        async.elapse(const Duration(milliseconds: 1000));
        expect(r.target.calls, isEmpty);
        pending = false;
        async.elapse(const Duration(milliseconds: 250));
        expect(r.target.calls, ['play']);
      });
    });

    test('an answer that names another player cancels the resume', () {
      fakeAsync((async) {
        var pending = true;
        final r = rig(pending: () => pending);
        r.service.sessionRestored();
        r.lifecycle.add(LifecycleResume.start);
        async.elapse(const Duration(milliseconds: 1000));
        r.canResume = false; // the hub named the desktop
        pending = false;
        async.elapse(const Duration(seconds: 1));
        expect(r.target.calls, isEmpty);
      });
    });

    test('no answer at all: resumes after 3 s, not before', () {
      fakeAsync((async) {
        final r = rig(pending: () => true);
        r.service.sessionRestored();
        r.lifecycle.add(LifecycleResume.start);
        async.elapse(const Duration(milliseconds: 2900));
        expect(r.target.calls, isEmpty);
        async.elapse(const Duration(milliseconds: 300));
        expect(r.target.calls, ['play']);
      });
    });

    test('a play then a pause during the wait cancels the resume', () {
      fakeAsync((async) {
        var pending = true;
        final r = rig(pending: () => pending);
        r.service.sessionRestored();
        r.lifecycle.add(LifecycleResume.start);
        async.elapse(const Duration(milliseconds: 500));
        r.target.setPlaying(true); // the listener presses play...
        async.flushMicrotasks();
        r.target.setPlaying(false); // ...and pause
        async.flushMicrotasks();
        pending = false;
        async.elapse(const Duration(seconds: 5));
        expect(r.target.calls, isEmpty);
      });
    });

    test('a pause alone during the wait also cancels it', () {
      fakeAsync((async) {
        var pending = true;
        final r = rig(pending: () => pending);
        r.target.setPlaying(true);
        r.service.sessionRestored();
        r.lifecycle.add(LifecycleResume.start);
        async.elapse(const Duration(milliseconds: 500));
        r.target.setPlaying(false);
        async.flushMicrotasks();
        pending = false;
        async.elapse(const Duration(seconds: 5));
        expect(r.target.calls, isEmpty);
      });
    });

    test('going to the background during the wait stops the resume', () {
      fakeAsync((async) {
        var pending = true;
        var foreground = true;
        final r = Rig(
          settings: const AudioFocusSettings(resumeOnStart: true),
          playing: false,
          withLifecycle: true,
          connectAnswerPending: () => pending,
          isForeground: () => foreground,
        );
        r.service.sessionRestored();
        r.lifecycle.add(LifecycleResume.start);
        async.elapse(const Duration(milliseconds: 500));
        foreground = false;
        pending = false;
        async.elapse(const Duration(seconds: 5));
        expect(r.target.calls, isEmpty);
      });
    });

    test('a reopen during the wait supersedes the start', () {
      fakeAsync((async) {
        var pending = true;
        final r = rig(pending: () => pending);
        r.service.sessionRestored();
        r.lifecycle.add(LifecycleResume.start);
        async.elapse(const Duration(milliseconds: 500));
        r.lifecycle.add(LifecycleResume.reopen); // needs resumeOnReopen: off
        async.flushMicrotasks();
        pending = false;
        async.elapse(const Duration(seconds: 5));
        expect(r.target.calls, isEmpty);
      });
    });

    test('in the foreground the happy path still resumes once', () {
      fakeAsync((async) {
        var pending = true;
        final r = Rig(
          settings: const AudioFocusSettings(resumeOnStart: true),
          playing: false,
          withLifecycle: true,
          connectAnswerPending: () => pending,
          isForeground: () => true,
        );
        r.service.sessionRestored();
        r.lifecycle.add(LifecycleResume.start);
        async.elapse(const Duration(milliseconds: 600));
        pending = false;
        async.elapse(const Duration(seconds: 5));
        expect(r.target.calls, ['play']);
      });
    });

    test('reopen_waits_for_connect_hub', () {
      fakeAsync((async) {
        var pending = true;
        final r = Rig(
          settings: const AudioFocusSettings(
            resumeOnStart: true,
            resumeOnReopen: true,
          ),
          playing: false,
          withLifecycle: true,
          connectAnswerPending: () => pending,
        );
        r.lifecycle.add(LifecycleResume.reopen);
        async.elapse(const Duration(milliseconds: 600));
        expect(r.target.calls, isEmpty, reason: 'the hub has not answered');
        pending = false;
        async.elapse(const Duration(milliseconds: 300));
        expect(r.target.calls, ['play']);
      });
    });

    test('a reopen whose hub names another player does not resume', () {
      fakeAsync((async) {
        var pending = true;
        final r = Rig(
          settings: const AudioFocusSettings(
            resumeOnStart: true,
            resumeOnReopen: true,
          ),
          playing: false,
          withLifecycle: true,
          connectAnswerPending: () => pending,
        );
        r.lifecycle.add(LifecycleResume.reopen);
        async.elapse(const Duration(milliseconds: 400));
        r.canResume = false;
        pending = false;
        async.elapse(const Duration(seconds: 2));
        expect(r.target.calls, isEmpty);
      });
    });

    test('a reopen waiting for the hub is dropped by a pause or background',
        () {
      fakeAsync((async) {
        var pending = true;
        var foreground = true;
        final r = Rig(
          settings: const AudioFocusSettings(
            resumeOnStart: true,
            resumeOnReopen: true,
          ),
          playing: false,
          withLifecycle: true,
          connectAnswerPending: () => pending,
          isForeground: () => foreground,
        );
        r.lifecycle.add(LifecycleResume.reopen);
        async.elapse(const Duration(milliseconds: 400));
        foreground = false;
        pending = false;
        async.elapse(const Duration(seconds: 2));
        expect(r.target.calls, isEmpty);
      });
    });

    test('dispose cancels the wait', () {
      fakeAsync((async) {
        final r = rig(pending: () => true);
        r.service.sessionRestored();
        r.lifecycle.add(LifecycleResume.start);
        async.elapse(const Duration(seconds: 1));
        r.service.dispose();
        async.elapse(const Duration(seconds: 5));
        expect(r.target.calls, isEmpty);
      });
    });
  });

  test('constants for the Connect wait', () {
    expect(kConnectAnswerWait, const Duration(seconds: 3));
  });

  group('activation', () {
    test('start binds activate; activate asks for focus', () {
      fakeAsync((async) {
        final r = Rig();
        expect(r.activation, isNotNull);
        expect(r.activation!(), completion(isTrue));
        async.flushMicrotasks();
        expect(r.focusRequests, 1);
      });
    });

    test('a denied request is reported as false', () {
      fakeAsync((async) {
        final r = Rig(requestFocus: () async => false);
        expect(r.service.activate(), completion(isFalse));
        async.flushMicrotasks();
      });
    });
  });

  group('iOS', () {
    test('an interruption pauses at once, and ends in a resume', () {
      fakeAsync((async) {
        final r = Rig(isIos: true);
        r.interruptions.add(begin(AudioInterruptionType.unknown));
        async.elapse(const Duration(milliseconds: 100));
        expect(r.target.calls, ['pause(fade: false)', 'paused']);

        r.target.calls.clear();
        r.interruptions.add(end(AudioInterruptionType.pause));
        async.flushMicrotasks();
        expect(r.target.calls, ['play']);
      });
    });

    test('an interruption that says do not resume is not resumed', () {
      fakeAsync((async) {
        final r = Rig(isIos: true);
        r.interruptions.add(begin(AudioInterruptionType.unknown));
        async.elapse(const Duration(milliseconds: 100));
        r.target.calls.clear();
        r.interruptions.add(end(AudioInterruptionType.unknown));
        async.flushMicrotasks();
        expect(r.target.calls, isEmpty);
      });
    });
  });

  group('lifecycle', () {
    test('start_waits_for_restore', () {
      fakeAsync((async) {
        final r = Rig(
          settings: const AudioFocusSettings(resumeOnStart: true),
          playing: false,
          withLifecycle: true,
        );
        r.lifecycle.add(LifecycleResume.start);
        async.flushMicrotasks();
        expect(r.target.calls, isEmpty);

        r.service.sessionRestored();
        async.flushMicrotasks();
        expect(r.target.calls, ['play']);
      });
    });

    test('a restore that came first lets the start through at once', () {
      fakeAsync((async) {
        final r = Rig(
          settings: const AudioFocusSettings(resumeOnStart: true),
          playing: false,
          withLifecycle: true,
        );
        r.service.sessionRestored();
        r.lifecycle.add(LifecycleResume.start);
        async.flushMicrotasks();
        expect(r.target.calls, ['play']);
      });
    });

    test('start does nothing with the switch off or without a session', () {
      fakeAsync((async) {
        final off = Rig(playing: false, withLifecycle: true);
        off.lifecycle.add(LifecycleResume.start);
        off.service.sessionRestored();
        async.flushMicrotasks();
        expect(off.target.calls, isEmpty);

        final none = Rig(
          settings: const AudioFocusSettings(resumeOnStart: true),
          playing: false,
          hasSession: false,
          withLifecycle: true,
        );
        none.lifecycle.add(LifecycleResume.start);
        none.service.sessionRestored();
        async.flushMicrotasks();
        expect(none.target.calls, isEmpty);
      });
    });

    test('reopen needs both switches and a session', () {
      fakeAsync((async) {
        final both = Rig(
          settings: const AudioFocusSettings(
            resumeOnStart: true,
            resumeOnReopen: true,
          ),
          playing: false,
          withLifecycle: true,
        );
        both.lifecycle.add(LifecycleResume.reopen);
        async.flushMicrotasks();
        expect(both.target.calls, ['play']);

        final noSession = Rig(
          settings: const AudioFocusSettings(
            resumeOnStart: true,
            resumeOnReopen: true,
          ),
          playing: false,
          hasSession: false,
          withLifecycle: true,
        );
        noSession.lifecycle.add(LifecycleResume.reopen);
        async.flushMicrotasks();
        expect(noSession.target.calls, isEmpty);

        final startOnly = Rig(
          settings: const AudioFocusSettings(resumeOnStart: true),
          playing: false,
          withLifecycle: true,
        );
        startOnly.lifecycle.add(LifecycleResume.reopen);
        async.flushMicrotasks();
        expect(startOnly.target.calls, isEmpty);
      });
    });

    test('reopen while waiting for focus (a call) does not play', () {
      fakeAsync((async) {
        final r = Rig(
          settings: const AudioFocusSettings(
            resumeOnStart: true,
            resumeOnReopen: true,
          ),
          withLifecycle: true,
        );
        r.interruptions.add(begin(AudioInterruptionType.pause));
        async.elapse(const Duration(milliseconds: 100));
        r.target.calls.clear();
        r.lifecycle.add(LifecycleResume.reopen);
        async.flushMicrotasks();
        expect(r.target.calls, isEmpty);
      });
    });

    test('no_lifecycle_no_resume', () {
      fakeAsync((async) {
        final r = Rig(
          settings: const AudioFocusSettings(resumeOnStart: true),
          playing: false,
        );
        r.service.sessionRestored();
        async.flushMicrotasks();
        expect(r.target.calls, isEmpty);
      });
    });
  });

  group('requestAudioFocus', () {
    test('Android asks with will-pause-when-ducked', () async {
      final calls = <String>[];
      final ok = await requestAudioFocus((
        active, {
        bool? androidWillPauseWhenDucked,
      }) async {
        calls.add('$active/$androidWillPauseWhenDucked');
        return true;
      }, isIos: false);
      expect(ok, isTrue);
      expect(calls, ['true/true']);
    });

    test('iOS just activates', () async {
      final calls = <String>[];
      final ok = await requestAudioFocus((
        active, {
        bool? androidWillPauseWhenDucked,
      }) async {
        calls.add('$active/$androidWillPauseWhenDucked');
        return true;
      }, isIos: true);
      expect(ok, isTrue);
      expect(calls, ['true/null']);
    });

    test('a denial is followed by a release so the next request asks', () async {
      final calls = <bool>[];
      var grant = false;
      Future<bool> setActive(
        bool active, {
        bool? androidWillPauseWhenDucked,
      }) async {
        calls.add(active);
        return active ? grant : true;
      }

      expect(await requestAudioFocus(setActive, isIos: false), isFalse);
      expect(calls, [true, false]);

      grant = true;
      calls.clear();
      expect(await requestAudioFocus(setActive, isIos: false), isTrue);
      expect(calls, [true], reason: 'a grant is not released');
    });

    test('a throw while releasing is swallowed', () async {
      Future<bool> setActive(
        bool active, {
        bool? androidWillPauseWhenDucked,
      }) async {
        if (!active) throw StateError('abandon');
        return false;
      }

      expect(await requestAudioFocus(setActive, isIos: false), isFalse);
    });
  });
}
