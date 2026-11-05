// ignore_for_file: experimental_member_use
/// A resume held for a call or another app dies with an unplug or a stop.
library;

import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:eq_app/audio/focus/audio_focus_settings.dart';
import 'package:eq_app/audio/focus/playback_target.dart';
import 'package:eq_app/audio/headset/headset_settings.dart';
import 'package:eq_app/services/audio_focus_service.dart';
import 'package:eq_app/services/headset_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

class Target implements PlaybackTarget {
  final calls = <String>[];
  bool _playing = true;
  final _changes = StreamController<bool>.broadcast();

  @override
  bool get playing => _playing;

  @override
  Stream<bool> get playingStream => _changes.stream;

  @override
  Future<void> play() {
    calls.add('play');
    _set(true);
    return Completer<void>().future;
  }

  @override
  Future<void> pause({bool fade = true}) async {
    calls.add('pause');
    _set(false);
  }

  void _set(bool v) {
    if (v == _playing) return;
    _playing = v;
    _changes.add(v);
  }

  @override
  Future<void> setDuck(double level) async {}

  @override
  Future<void> restartPlayback() => Completer<void>().future;
}

class Rig {
  Rig({required this.isIos}) {
    focus = AudioFocusService(
      target: target,
      settings: () => const AudioFocusSettings(),
      hasSession: () => true,
      canResume: () => true,
      isIos: isIos,
      interruptions: interruptions.stream,
      requestFocus: () async => true,
    )..start();
    headset = HeadsetService(
      target: target,
      onBluetoothConnected: (_) {},
      settings: () => const HeadsetSettings(),
      canResume: () => true,
      waitingForFocus: () => focus.waitingForFocus,
      onCancelHold: focus.cancelHold,
      isIos: isIos,
      devicesChanged: const Stream.empty(),
      becomingNoisy: noisy.stream,
      currentDevices: () async => <AudioDevice>{},
    );
    unawaited(headset.start());
  }

  final bool isIos;
  final target = Target();
  final interruptions = StreamController<AudioInterruptionEvent>.broadcast();
  final noisy = StreamController<void>.broadcast();
  late final AudioFocusService focus;
  late final HeadsetService headset;
}

void main() {
  test('noisy then focus gain: no play', () {
    fakeAsync((async) {
      final r = Rig(isIos: false);
      async.flushMicrotasks();
      r.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      async.flushMicrotasks();
      expect(r.focus.waitingForFocus, isTrue);
      r.target.calls.clear();

      r.noisy.add(null); // the headset is unplugged during the call
      async.flushMicrotasks();
      r.interruptions.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      async.flushMicrotasks();
      expect(r.target.calls, isEmpty);
    });
  });

  test('noisy then iOS InterruptionEnded(shouldResume): no play', () {
    fakeAsync((async) {
      final r = Rig(isIos: true);
      async.flushMicrotasks();
      r.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown),
      );
      async.flushMicrotasks();
      r.target.calls.clear();

      r.noisy.add(null);
      async.flushMicrotasks();
      r.interruptions.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      async.flushMicrotasks();
      expect(r.target.calls, isEmpty);
    });
  });

  test('stop while held (the handler hook calls cancelHold): no play', () {
    fakeAsync((async) {
      final r = Rig(isIos: false);
      async.flushMicrotasks();
      r.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      async.flushMicrotasks();
      r.target.calls.clear();

      r.focus
          .cancelHold(); // main.dart: handler.onStopped = audioFocus.cancelHold
      r.interruptions.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      async.flushMicrotasks();
      expect(r.target.calls, isEmpty);
    });
  });

  test('without the unplug the gain still resumes (control)', () {
    fakeAsync((async) {
      final r = Rig(isIos: false);
      async.flushMicrotasks();
      r.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      async.flushMicrotasks();
      r.target.calls.clear();
      r.interruptions.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      async.flushMicrotasks();
      expect(r.target.calls, ['play']);
    });
  });
}
