import 'dart:async';

import 'package:eq_app/audio/headset/button_presses.dart';
import 'package:eq_app/audio/headset/headset_settings.dart';
import 'package:eq_app/services/media_button_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<Object?, Object?> _key(
  int code, {
  required bool down,
  bool bt = false,
  int? deviceId,
  String? name,
}) => {
  'keyCode': code,
  'down': down,
  'repeat': 0,
  'deviceId': deviceId ?? (bt ? -1 : 7),
  'deviceName': name ?? (bt ? null : 'h2w headset'),
  'btOutput': bt,
};

const _voiceLong = <Object?, Object?>{'longPress': true, 'btOutput': false};

class _Rig {
  _Rig({this.settings = const HeadsetSettings(), this.playing = false});

  HeadsetSettings settings;
  bool playing;
  bool executeResult = true;
  int toneVolume = 60;

  final events = StreamController<Map<Object?, Object?>>.broadcast(sync: true);
  final playingChanges = StreamController<bool>.broadcast(sync: true);
  final executed = <String>[];
  final feedbacks = <String>[];
  final pushes = <String>[];
  final longPresses = <String>[];

  late final MediaButtonService service = MediaButtonService(
    events: events.stream,
    execute: (c, {required bluetooth}) async {
      executed.add('${c.name}${bluetooth ? ' bt' : ''}');
      return executeResult;
    },
    settings: () => settings,
    playing: () => playing,
    playingStream: playingChanges.stream,
    feedback: (f, vol) async {
      feedbacks.add('beeps:${f.beeps} vibrate:${f.vibrate} vol:$vol');
    },
    toneVolume: () => toneVolume,
    pushPolicy: ({
      required bool respond,
      required bool playing,
      required bool longPressProxy,
      required bool wiredLongPress,
      required bool bluetoothLongPress,
    }) async {
      pushes.add('respond:$respond playing:$playing proxy:$longPressProxy');
      longPresses.add('wired:$wiredLongPress bt:$bluetoothLongPress');
    },
  );

  void hookPress(FakeAsync a, {bool bt = false, int holdMs = 0}) {
    events.add(_key(MediaKey.headsetHook, down: true, bt: bt));
    a.elapse(Duration(milliseconds: holdMs));
    events.add(_key(MediaKey.headsetHook, down: false, bt: bt));
  }

  void settle(FakeAsync a) => a.flushMicrotasks();
}

void main() {
  test('a single hook press executes toggle at the end of the window', () {
    fakeAsync((a) {
      final r = _Rig()..service.start();
      r.hookPress(a);
      a.elapse(const Duration(milliseconds: 399));
      expect(r.executed, isEmpty);
      a.elapse(const Duration(milliseconds: 1));
      expect(r.executed, ['toggle']);
      // Defaults: a plain toggle gives no beep and no buzz.
      expect(r.feedbacks, isEmpty);
      r.service.dispose();
    });
  });

  test('two presses execute next, then beep twice', () {
    fakeAsync((a) {
      final r = _Rig()..service.start();
      r.hookPress(a);
      a.elapse(const Duration(milliseconds: 100));
      r.hookPress(a);
      a.elapse(const Duration(milliseconds: 399));
      expect(r.executed, isEmpty);
      a.elapse(const Duration(milliseconds: 1));
      expect(r.executed, ['next']);
      expect(r.feedbacks, ['beeps:2 vibrate:false vol:60']);
      r.service.dispose();
    });
  });

  test('three presses execute previous with three beeps', () {
    fakeAsync((a) {
      final r = _Rig(settings: const HeadsetSettings(vibrate: true))
        ..service.start();
      for (var i = 0; i < 3; i++) {
        r.hookPress(a);
        a.elapse(const Duration(milliseconds: 100));
      }
      a.elapse(const Duration(milliseconds: 400));
      expect(r.executed, ['previous']);
      expect(r.feedbacks, ['beeps:3 vibrate:true vol:60']);
      r.service.dispose();
    });
  });

  test('ignored_command_gives_no_feedback', () {
    fakeAsync((a) {
      final r = _Rig(settings: const HeadsetSettings(vibrate: true))
        ..executeResult = false
        ..service.start();
      r.hookPress(a);
      a.elapse(const Duration(milliseconds: 100));
      r.hookPress(a);
      a.elapse(const Duration(milliseconds: 500));
      expect(r.executed, ['next']);
      expect(r.feedbacks, isEmpty);
      r.service.dispose();
    });
  });

  test('feedback uses the current tone volume', () {
    fakeAsync((a) {
      final r = _Rig()
        ..toneVolume = 24
        ..service.start();
      r.hookPress(a);
      r.hookPress(a);
      a.elapse(const Duration(milliseconds: 400));
      expect(r.feedbacks, ['beeps:2 vibrate:false vol:24']);
      r.service.dispose();
    });
  });

  test('a Bluetooth play key executes play as Bluetooth', () {
    fakeAsync((a) {
      final r = _Rig()..service.start();
      r.events.add(_key(MediaKey.play, down: true, bt: true));
      r.events.add(_key(MediaKey.play, down: false, bt: true));
      r.settle(a);
      expect(r.executed, ['play bt']);
      r.service.dispose();
    });
  });

  test('a wired key is not Bluetooth even while the output is', () {
    fakeAsync((a) {
      final r = _Rig()..service.start();
      r.events.add(_key(MediaKey.next, down: true, deviceId: 9, name: 'gpio'));
      r.settle(a);
      expect(r.executed, ['next']);
      r.service.dispose();
    });
  });

  test('Bluetooth keys follow the Bluetooth button mode', () {
    fakeAsync((a) {
      final r = _Rig(
        settings: const HeadsetSettings(bluetoothButtons: ButtonMode.singlePress),
      )..service.start();
      r.hookPress(a, bt: true);
      r.settle(a);
      expect(r.executed, ['toggle bt']);
      r.service.dispose();
    });
  });

  test('respondToButtons false executes nothing', () {
    fakeAsync((a) {
      final r = _Rig(settings: const HeadsetSettings(respondToButtons: false))
        ..service.start();
      r.hookPress(a);
      r.events.add(_key(MediaKey.play, down: true));
      r.events.add(_key(MediaKey.next, down: true));
      a.elapse(const Duration(seconds: 2));
      expect(r.executed, isEmpty);
      expect(r.feedbacks, isEmpty);
      r.service.dispose();
    });
  });

  test('start pushes the policy', () {
    fakeAsync((a) {
      final r = _Rig()..service.start();
      r.settle(a);
      expect(r.pushes, ['respond:true playing:false proxy:false']);
      r.service.dispose();
    });
  });

  test('playingStream true pushes the policy with playing', () {
    fakeAsync((a) {
      final r = _Rig()..service.start();
      r.settle(a);
      r.pushes.clear();
      r.playingChanges.add(true);
      r.settle(a);
      expect(r.pushes, ['respond:true playing:true proxy:false']);
      r.playingChanges.add(false);
      r.settle(a);
      expect(r.pushes.last, 'respond:true playing:false proxy:false');
      r.service.dispose();
    });
  });

  test('a Long press mode asks for the voice proxy', () {
    fakeAsync((a) {
      final r = _Rig(
        settings: const HeadsetSettings(wiredButtons: ButtonMode.longPressNext),
      )..service.start();
      r.settle(a);
      expect(r.pushes, ['respond:true playing:false proxy:true']);
      r.service.dispose();
    });
  });

  test('the platform connecting after start re-sends the policy', () {
    fakeAsync((a) {
      final r = _Rig()..service.start();
      r.settle(a);
      r.pushes.clear();
      r.events.add(const {'connected': true});
      r.settle(a);
      expect(r.pushes, ['respond:true playing:false proxy:false']);
      expect(r.executed, isEmpty);
      r.service.dispose();
    });
  });

  test('the long-press wish is pushed per source', () {
    fakeAsync((a) {
      final r = _Rig(
        settings: const HeadsetSettings(
          wiredButtons: ButtonMode.multiPress,
          bluetoothButtons: ButtonMode.longPressNext,
        ),
      )..service.start();
      r.settle(a);
      expect(r.pushes, ['respond:true playing:false proxy:true']);
      expect(r.longPresses, ['wired:false bt:true']);
      r.service.dispose();
    });
  });

  test('pushPolicy sends the settings in force now', () {
    fakeAsync((a) {
      final r = _Rig(playing: true)..service.start();
      r.settle(a);
      r.pushes.clear();
      r.settings = const HeadsetSettings(respondToButtons: false);
      r.service.pushPolicy();
      r.settle(a);
      expect(r.pushes, ['respond:false playing:true proxy:false']);
      r.service.dispose();
    });
  });

  group('long press', () {
    const mode = HeadsetSettings(wiredButtons: ButtonMode.longPressNext);

    test('while playing executes next at 600 ms; the up executes nothing', () {
      fakeAsync((a) {
        final r = _Rig(settings: mode, playing: true)..service.start();
        r.events.add(_key(MediaKey.headsetHook, down: true));
        a.elapse(const Duration(milliseconds: 599));
        expect(r.executed, isEmpty);
        a.elapse(const Duration(milliseconds: 1));
        expect(r.executed, ['next']);
        expect(r.feedbacks, ['beeps:1 vibrate:false vol:60']);
        a.elapse(const Duration(milliseconds: 300));
        r.events.add(_key(MediaKey.headsetHook, down: false));
        a.elapse(const Duration(seconds: 1));
        expect(r.executed, ['next']);
        r.service.dispose();
      });
    });

    test('a short press still toggles', () {
      fakeAsync((a) {
        final r = _Rig(settings: mode, playing: true)..service.start();
        r.hookPress(a, holdMs: 200);
        r.settle(a);
        expect(r.executed, ['toggle']);
        r.service.dispose();
      });
    });

    test('while not playing a long hold is a short press', () {
      fakeAsync((a) {
        final r = _Rig(settings: mode)..service.start();
        r.hookPress(a, holdMs: 900);
        a.elapse(const Duration(seconds: 1));
        expect(r.executed, ['toggle']);
        r.service.dispose();
      });
    });

    test('a voice long press after the 600 ms long press is dropped', () {
      fakeAsync((a) {
        final r = _Rig(settings: mode, playing: true)..service.start();
        r.events.add(_key(MediaKey.headsetHook, down: true));
        a.elapse(const Duration(milliseconds: 600));
        expect(r.executed, ['next']);
        a.elapse(const Duration(milliseconds: 100));
        r.events.add(_voiceLong);
        a.elapse(const Duration(seconds: 1));
        expect(r.executed, ['next']);
        expect(r.feedbacks, hasLength(1));
        r.service.dispose();
      });
    });

    test('a 600 ms long press after a voice long press is dropped', () {
      fakeAsync((a) {
        final r = _Rig(settings: mode, playing: true)..service.start();
        r.events.add(_key(MediaKey.headsetHook, down: true));
        a.elapse(const Duration(milliseconds: 300));
        r.events.add(_voiceLong);
        a.elapse(const Duration(milliseconds: 1));
        expect(r.executed, ['next']);
        a.elapse(const Duration(seconds: 1));
        expect(r.executed, ['next']);
        r.service.dispose();
      });
    });

    test('the release after a voice long press does not toggle', () {
      fakeAsync((a) {
        final r = _Rig(settings: mode, playing: true)..service.start();
        r.events.add(_key(MediaKey.headsetHook, down: true));
        a.elapse(const Duration(milliseconds: 300));
        r.events.add(_voiceLong);
        a.elapse(const Duration(milliseconds: 100));
        r.events.add(_key(MediaKey.headsetHook, down: false));
        a.elapse(const Duration(seconds: 3));
        expect(r.executed, ['next']);
        r.service.dispose();
      });
    });

    test('two long presses from the timer ~900 ms apart both act', () {
      fakeAsync((a) {
        final r = _Rig(settings: mode, playing: true)..service.start();
        r.events.add(_key(MediaKey.headsetHook, down: true));
        a.elapse(const Duration(milliseconds: 650));
        r.events.add(_key(MediaKey.headsetHook, down: false));
        a.elapse(const Duration(milliseconds: 250));
        r.events.add(_key(MediaKey.headsetHook, down: true));
        a.elapse(const Duration(milliseconds: 650));
        r.events.add(_key(MediaKey.headsetHook, down: false));
        a.elapse(const Duration(seconds: 2));
        expect(r.executed, ['next', 'next']);
        expect(r.feedbacks, hasLength(2));
        r.service.dispose();
      });
    });

    test('two voice long presses ~900 ms apart both act', () {
      fakeAsync((a) {
        final r = _Rig(settings: mode, playing: true)..service.start();
        r.events.add(_voiceLong);
        a.elapse(const Duration(milliseconds: 900));
        r.events.add(_voiceLong);
        a.elapse(const Duration(seconds: 2));
        expect(r.executed, ['next', 'next']);
        expect(r.feedbacks, hasLength(2));
        r.service.dispose();
      });
    });

    test('a new hold after a voice long press is not a duplicate', () {
      fakeAsync((a) {
        final r = _Rig(settings: mode, playing: true)..service.start();
        r.events.add(_key(MediaKey.headsetHook, down: true));
        a.elapse(const Duration(milliseconds: 300));
        r.events.add(_voiceLong);
        a.elapse(const Duration(milliseconds: 100));
        r.events.add(_key(MediaKey.headsetHook, down: false));
        a.elapse(const Duration(milliseconds: 200));
        r.events.add(_key(MediaKey.headsetHook, down: true));
        a.elapse(const Duration(milliseconds: 650));
        expect(r.executed, ['next', 'next']);
        r.service.dispose();
      });
    });

    test('two separate long presses both act', () {
      fakeAsync((a) {
        final r = _Rig(settings: mode, playing: true)..service.start();
        for (var i = 0; i < 2; i++) {
          r.events.add(_key(MediaKey.headsetHook, down: true));
          a.elapse(const Duration(milliseconds: 650));
          r.events.add(_key(MediaKey.headsetHook, down: false));
          a.elapse(const Duration(seconds: 2));
        }
        expect(r.executed, ['next', 'next']);
        r.service.dispose();
      });
    });
  });

  test('a voice long press does nothing outside Long press mode', () {
    fakeAsync((a) {
      final r = _Rig(playing: true)..service.start();
      r.events.add(_voiceLong);
      a.elapse(const Duration(seconds: 2));
      expect(r.executed, isEmpty);
      expect(r.feedbacks, isEmpty);
      r.service.dispose();
    });
  });

  group('missing platform handler', () {
    test('start does not throw when the stream errors', () {
      fakeAsync((a) {
        final r = _Rig();
        final broken = _Rig();
        final service = MediaButtonService(
          events: Stream<Map<Object?, Object?>>.error(
            MissingPluginException('no handler'),
          ),
          execute: (c, {required bluetooth}) async => true,
          settings: () => broken.settings,
          playing: () => false,
          playingStream: r.playingChanges.stream,
          feedback: (f, v) async {},
          toneVolume: () => 60,
          pushPolicy: ({
            required bool respond,
            required bool playing,
            required bool longPressProxy,
            required bool wiredLongPress,
            required bool bluetoothLongPress,
          }) async => throw MissingPluginException('no handler'),
        );
        expect(service.start, returnsNormally);
        a.flushMicrotasks();
        service.dispose();
      });
    });

    test('a failing feedback or execute does not break the next press', () {
      fakeAsync((a) {
        final r = _Rig();
        var calls = 0;
        final service = MediaButtonService(
          events: r.events.stream,
          execute: (c, {required bluetooth}) async {
            calls++;
            if (calls == 1) throw StateError('boom');
            return true;
          },
          settings: () => r.settings,
          playing: () => false,
          playingStream: r.playingChanges.stream,
          feedback: (f, v) async {},
          toneVolume: () => 60,
          pushPolicy: ({
            required bool respond,
            required bool playing,
            required bool longPressProxy,
            required bool wiredLongPress,
            required bool bluetoothLongPress,
          }) async {},
        )..start();
        r.events.add(_key(MediaKey.next, down: true));
        r.events.add(_key(MediaKey.next, down: true));
        a.flushMicrotasks();
        expect(calls, 2);
        service.dispose();
      });
    });
  });

  test('dispose cancels a pending press', () {
    fakeAsync((a) {
      final r = _Rig()..service.start();
      r.hookPress(a);
      r.service.dispose();
      a.elapse(const Duration(seconds: 1));
      expect(r.executed, isEmpty);
      expect(a.pendingTimers, isEmpty);
    });
  });

  test('unrelated keys and malformed events are ignored', () {
    fakeAsync((a) {
      final r = _Rig()..service.start();
      r.events.add(_key(24, down: true)); // volume up
      r.events.add(const {'keyCode': 'x'});
      r.events.add(const {});
      a.elapse(const Duration(seconds: 1));
      expect(r.executed, isEmpty);
      r.service.dispose();
    });
  });
}
