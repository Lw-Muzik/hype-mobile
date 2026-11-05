import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:eq_app/audio/focus/audio_focus_settings.dart';
import 'package:eq_app/audio/focus/playback_target.dart';
import 'package:eq_app/services/audio_focus_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

class _Target implements PlaybackTarget {
  final calls = <String>[];
  bool _playing = true;
  final _changes = StreamController<bool>.broadcast();
  @override
  bool get playing => _playing;
  @override
  Stream<bool> get playingStream => _changes.stream;
  void set(bool v) {
    if (v == _playing) return;
    _playing = v;
    _changes.add(v);
  }

  @override
  Future<void> play() {
    calls.add('play');
    set(true);
    return Completer<void>().future;
  }

  @override
  Future<void> pause({bool fade = true}) async {
    calls.add('pause');
    set(false);
  }

  @override
  Future<void> setDuck(double level) async {}
  @override
  Future<void> restartPlayback() {
    calls.add('restart');
    return Completer<void>().future;
  }
}

void main() {
  late _Target target;
  late StreamController<AudioInterruptionEvent> interruptions;
  late int focusRequests;
  late Duration position;
  late bool forceOn;
  var buffering = false;
  late AudioFocusService service;

  void build() {
    target = _Target();
    interruptions = StreamController<AudioInterruptionEvent>.broadcast();
    focusRequests = 0;
    position = const Duration(seconds: 10);
    service =
        AudioFocusService(
            target: target,
            settings: () => const AudioFocusSettings(),
            hasSession: () => true,
            canResume: () => true,
            isIos: false,
            interruptions: interruptions.stream,
            requestFocus: () async {
              focusRequests++;
              return true;
            },
          )
          ..configureForceAudio(
            enabled: () => forceOn,
            position: () => position,
            buffering: () => buffering,
          )
          ..start();
  }

  Future<void> loseAndRegain(FakeAsync async) async {
    interruptions.add(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );
    async.flushMicrotasks();
    async.elapse(const Duration(milliseconds: 100));
    interruptions.add(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    async.flushMicrotasks();
  }

  test('stalled output after a regain: re-request focus and restart once', () {
    fakeAsync((async) {
      forceOn = true;
      build();
      loseAndRegain(async);
      final before = focusRequests;
      async.elapse(const Duration(milliseconds: 1600));
      async.flushMicrotasks();
      expect(target.calls.where((c) => c == 'restart').length, 1);
      expect(focusRequests, before + 1);
      async.elapse(const Duration(seconds: 10));
      expect(target.calls.where((c) => c == 'restart').length, 1);
      service.dispose();
    });
  });

  test('position advancing: no restart', () {
    fakeAsync((async) {
      forceOn = true;
      build();
      loseAndRegain(async);
      position += const Duration(seconds: 1);
      async.elapse(const Duration(milliseconds: 1600));
      async.flushMicrotasks();
      expect(target.calls, isNot(contains('restart')));
      service.dispose();
    });
  });

  test('setting off: no restart', () {
    fakeAsync((async) {
      forceOn = false;
      build();
      loseAndRegain(async);
      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();
      expect(target.calls, isNot(contains('restart')));
      service.dispose();
    });
  });

  test('listener paused in the meantime: no restart', () {
    fakeAsync((async) {
      forceOn = true;
      build();
      loseAndRegain(async);
      target.set(false);
      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();
      expect(target.calls, isNot(contains('restart')));
      service.dispose();
    });
  });

  test('buffering player: no restart', () {
    fakeAsync((async) {
      forceOn = true;
      buffering = true;
      build();
      loseAndRegain(async);
      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();
      expect(target.calls, isNot(contains('restart')));
      buffering = false;
      service.dispose();
    });
  });

  test('a duck and its gain: no restart', () {
    fakeAsync((async) {
      forceOn = true;
      build();
      interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      async.flushMicrotasks();
      interruptions.add(
        AudioInterruptionEvent(false, AudioInterruptionType.duck),
      );
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 3));
      expect(target.calls, isNot(contains('restart')));
      service.dispose();
    });
  });
}
