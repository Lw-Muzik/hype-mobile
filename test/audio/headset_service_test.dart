// ignore_for_file: experimental_member_use, prefer_initializing_formals
import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:eq_app/audio/focus/playback_target.dart';
import 'package:eq_app/audio/headset/headset_settings.dart';
import 'package:eq_app/services/headset_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeTarget implements PlaybackTarget {
  FakeTarget({bool playing = false}) : _playing = playing;

  final calls = <String>[];
  bool _playing;
  final _changes = StreamController<bool>.broadcast();

  @override
  bool get playing => _playing;

  @override
  Stream<bool> get playingStream => _changes.stream;

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
  }

  @override
  Future<void> setDuck(double level) async {}

  @override
  Future<void> restartPlayback() {
    calls.add('restart');
    return Completer<void>().future;
  }
}

AudioDevice dev(String id, AudioDeviceType t, {bool out = true}) =>
    AudioDevice(id: id, name: 'd$id', isInput: !out, isOutput: out, type: t);

AudioDevicesChangedEvent added(Set<AudioDevice> d) =>
    AudioDevicesChangedEvent(devicesAdded: d);

class Rig {
  Rig({
    HeadsetSettings settings = const HeadsetSettings(),
    bool isIos = false,
    bool playing = false,
    bool canResume = true,
    bool waiting = false,
    Set<AudioDevice> initial = const {},
    Future<Set<AudioDevice>>? initialLater,
  }) : target = FakeTarget(playing: playing),
       devicesNow = {...initial} {
    this.settings = settings;
    this.canResume = canResume;
    this.waiting = waiting;
    service = HeadsetService(
      target: target,
      onBluetoothConnected: bluetoothAt.add,
      settings: () => this.settings,
      canResume: () => this.canResume,
      waitingForFocus: () => this.waiting,
      isIos: isIos,
      onCancelHold: () => holdCancels++,
      devicesChanged: devices.stream,
      becomingNoisy: noisy.stream,
      currentDevices: () => initialLater ?? Future.value({...devicesNow}),
      nowMs: () => 1234,
    );
    unawaited(service.start());
  }

  final FakeTarget target;
  final devices = StreamController<AudioDevicesChangedEvent>.broadcast();
  final noisy = StreamController<void>.broadcast();
  final bluetoothAt = <int>[];
  int holdCancels = 0;

  /// What the platform lists now.
  final Set<AudioDevice> devicesNow;
  late HeadsetSettings settings;
  late bool canResume;
  late bool waiting;
  late final HeadsetService service;
}

final a2dp9 = dev('9', AudioDeviceType.bluetoothA2dp);
const ms = Duration(milliseconds: 1);

void main() {
  test('constants', () {
    expect(kResumeOnConnectDelay, const Duration(milliseconds: 500));
  });

  test('initial_devices_are_not_connections', () {
    fakeAsync((async) {
      final a2dp5 = dev('5', AudioDeviceType.bluetoothA2dp);
      final r = Rig(
        settings: const HeadsetSettings(resumeOnBluetooth: true),
        initial: {a2dp5},
      );
      async.flushMicrotasks();
      r.devices.add(added({a2dp5}));
      async.elapse(const Duration(seconds: 2));
      expect(r.bluetoothAt, isEmpty);
      expect(r.target.calls, isEmpty);
    });
  });

  test('an event that arrives while the baseline loads is judged against it', () {
    fakeAsync((async) {
      final a2dp5 = dev('5', AudioDeviceType.bluetoothA2dp);
      final later = Completer<Set<AudioDevice>>();
      final r = Rig(
        settings: const HeadsetSettings(resumeOnBluetooth: true),
        initialLater: later.future,
      );
      async.flushMicrotasks();
      r.devices.add(added({a2dp5}));
      async.flushMicrotasks();
      expect(r.bluetoothAt, isEmpty, reason: 'held until the baseline is in');
      later.complete({a2dp5});
      async.elapse(const Duration(seconds: 2));
      expect(r.bluetoothAt, isEmpty);
      expect(r.target.calls, isEmpty);
    });
  });

  test('an event buffered during the baseline load is acted on after it', () {
    fakeAsync((async) {
      final later = Completer<Set<AudioDevice>>();
      final r = Rig(
        settings: const HeadsetSettings(resumeOnBluetooth: true),
        initialLater: later.future,
      );
      async.flushMicrotasks();
      r.devices.add(added({a2dp9}));
      async.flushMicrotasks();
      expect(r.bluetoothAt, isEmpty, reason: 'not before the baseline');
      later.complete({});
      async.elapse(const Duration(seconds: 1));
      expect(r.bluetoothAt, [1234], reason: 'buffered, not dropped');
      expect(r.target.calls, ['play']);
    });
  });

  group('iOS: the first route change arrives with empty sets', () {
    test('an empty event plus a changed device list is a connection', () {
      fakeAsync((async) {
        final r = Rig(
          isIos: true,
          settings: const HeadsetSettings(resumeOnBluetooth: true),
        );
        async.flushMicrotasks();
        r.devicesNow.add(a2dp9);
        r.devices.add(AudioDevicesChangedEvent());
        async.flushMicrotasks();
        expect(r.bluetoothAt, [1234]);
        async.elapse(kResumeOnConnectDelay);
        expect(r.target.calls, ['play']);
      });
    });

    test('devices present at launch are still not connections', () {
      fakeAsync((async) {
        final r = Rig(
          isIos: true,
          settings: const HeadsetSettings(resumeOnBluetooth: true),
          initial: {a2dp9},
        );
        async.flushMicrotasks();
        r.devices.add(AudioDevicesChangedEvent());
        async.elapse(const Duration(seconds: 1));
        expect(r.bluetoothAt, isEmpty);
        expect(r.target.calls, isEmpty);
      });
    });

    test('a device that left and came back is a new connection', () {
      fakeAsync((async) {
        final r = Rig(
          isIos: true,
          settings: const HeadsetSettings(resumeOnBluetooth: true),
          initial: {a2dp9},
        );
        async.flushMicrotasks();
        r.devicesNow.clear();
        r.devices.add(AudioDevicesChangedEvent());
        async.flushMicrotasks();
        r.devicesNow.add(a2dp9);
        r.devices.add(AudioDevicesChangedEvent());
        async.flushMicrotasks();
        expect(r.bluetoothAt, [1234]);
      });
    });
  });

  test('input devices are not part of the baseline', () {
    fakeAsync((async) {
      final r = Rig(
        settings: const HeadsetSettings(resumeOnBluetooth: true),
        initial: {dev('9', AudioDeviceType.bluetoothSco, out: false)},
      );
      async.flushMicrotasks();
      r.devices.add(added({a2dp9}));
      async.elapse(const Duration(seconds: 1));
      expect(r.bluetoothAt, [1234]);
    });
  });

  test('connect_then_resume: grace at once, play after 500 ms', () {
    fakeAsync((async) {
      final r = Rig(settings: const HeadsetSettings(resumeOnBluetooth: true));
      async.flushMicrotasks();
      r.devices.add(added({a2dp9}));
      async.flushMicrotasks();
      expect(r.bluetoothAt, [1234]);

      async.elapse(const Duration(milliseconds: 499));
      expect(r.target.calls, isEmpty);
      async.elapse(ms);
      expect(r.target.calls, ['play']);
    });
  });

  test('a listener who is playing again by then is not resumed', () {
    fakeAsync((async) {
      final r = Rig(settings: const HeadsetSettings(resumeOnBluetooth: true));
      async.flushMicrotasks();
      r.devices.add(added({a2dp9}));
      async.elapse(const Duration(milliseconds: 200));
      r.target.setPlaying(true);
      async.elapse(const Duration(seconds: 1));
      expect(r.target.calls, isEmpty);
    });
  });

  test('a focus hold that begins in the 500 ms stops the resume', () {
    fakeAsync((async) {
      final r = Rig(settings: const HeadsetSettings(resumeOnBluetooth: true));
      async.flushMicrotasks();
      r.devices.add(added({a2dp9}));
      async.elapse(const Duration(milliseconds: 200));
      r.waiting = true;
      async.elapse(const Duration(seconds: 1));
      expect(r.target.calls, isEmpty);
    });
  });

  test('no_connect_resume_while_waiting_for_focus', () {
    fakeAsync((async) {
      final r = Rig(
        settings: const HeadsetSettings(resumeOnBluetooth: true),
        waiting: true,
      );
      async.flushMicrotasks();
      r.devices.add(added({a2dp9}));
      async.elapse(const Duration(seconds: 1));
      expect(r.bluetoothAt, [1234], reason: 'the grace window still starts');
      expect(r.target.calls, isEmpty);
    });
  });

  test('no resume when the player may not resume (equalizer, no queue, '
      'another Connect device active)', () {
    fakeAsync((async) {
      final r = Rig(
        settings: const HeadsetSettings(resumeOnBluetooth: true),
        canResume: false,
      );
      async.flushMicrotasks();
      r.devices.add(added({a2dp9}));
      async.elapse(const Duration(seconds: 1));
      expect(r.target.calls, isEmpty);
    });
  });

  test('canResume turning false inside the 500 ms stops the resume', () {
    fakeAsync((async) {
      final r = Rig(settings: const HeadsetSettings(resumeOnBluetooth: true));
      async.flushMicrotasks();
      r.devices.add(added({a2dp9}));
      async.elapse(const Duration(milliseconds: 100));
      r.canResume = false;
      async.elapse(const Duration(seconds: 1));
      expect(r.target.calls, isEmpty);
    });
  });

  test('wired plug resumes when Resume on wired is on', () {
    fakeAsync((async) {
      final r = Rig(settings: const HeadsetSettings(resumeOnWired: true));
      async.flushMicrotasks();
      r.devices.add(added({dev('2', AudioDeviceType.wiredHeadphones)}));
      async.elapse(const Duration(milliseconds: 500));
      expect(r.target.calls, ['play']);
      expect(r.bluetoothAt, isEmpty);
    });
  });

  test('a removal then the same device again is a new connection', () {
    fakeAsync((async) {
      final r = Rig(settings: const HeadsetSettings(resumeOnBluetooth: true));
      async.flushMicrotasks();
      r.devices.add(added({a2dp9}));
      async.elapse(const Duration(seconds: 1));
      r.target.setPlaying(false);
      r.target.calls.clear();
      r.devices.add(AudioDevicesChangedEvent(devicesRemoved: {a2dp9}));
      async.flushMicrotasks();
      r.devices.add(added({a2dp9}));
      async.elapse(const Duration(seconds: 1));
      expect(r.bluetoothAt, hasLength(2));
      expect(r.target.calls, ['play']);
    });
  });

  test('becomingNoisy while playing pauses at once', () {
    fakeAsync((async) {
      final r = Rig(playing: true);
      async.flushMicrotasks();
      r.noisy.add(null);
      async.flushMicrotasks();
      expect(r.target.calls, ['pause(fade: false)']);
    });
  });

  group('becomingNoisy while a resume is held for audio focus', () {
    test('cancels the hold, once, when nothing is playing', () {
      fakeAsync((async) {
        final r = Rig(waiting: true);
        async.flushMicrotasks();
        r.noisy.add(null);
        async.flushMicrotasks();
        expect(r.holdCancels, 1);
        expect(r.target.calls, isEmpty);
      });
    });

    test('keeps the hold when Pause on disconnect is off', () {
      fakeAsync((async) {
        final r = Rig(
          waiting: true,
          settings: const HeadsetSettings(pauseOnDisconnect: false),
        );
        async.flushMicrotasks();
        r.noisy.add(null);
        async.flushMicrotasks();
        expect(r.holdCancels, 0);
      });
    });

    test('is not asked when no hold exists', () {
      fakeAsync((async) {
        final r = Rig();
        async.flushMicrotasks();
        r.noisy.add(null);
        async.flushMicrotasks();
        expect(r.holdCancels, 0);
      });
    });

    test('while playing it just pauses', () {
      fakeAsync((async) {
        final r = Rig(playing: true, waiting: true);
        async.flushMicrotasks();
        r.noisy.add(null);
        async.flushMicrotasks();
        expect(r.holdCancels, 0);
        expect(r.target.calls, ['pause(fade: false)']);
      });
    });
  });

  test('becomingNoisy while paused does nothing', () {
    fakeAsync((async) {
      final r = Rig();
      async.flushMicrotasks();
      r.noisy.add(null);
      async.flushMicrotasks();
      expect(r.target.calls, isEmpty);
    });
  });

  test('iOS with Pause on disconnect off restarts playback', () {
    fakeAsync((async) {
      final r = Rig(
        isIos: true,
        playing: true,
        settings: const HeadsetSettings(pauseOnDisconnect: false),
      );
      async.flushMicrotasks();
      r.noisy.add(null);
      async.flushMicrotasks();
      expect(r.target.calls, ['restart']);
    });
  });

  test('Android: a USB DAC while playing pauses', () {
    fakeAsync((async) {
      final r = Rig(playing: true);
      async.flushMicrotasks();
      r.devices.add(added({dev('3', AudioDeviceType.usbAudio)}));
      async.flushMicrotasks();
      expect(r.target.calls, ['pause(fade: false)']);
    });
  });

  test('dispose cancels a pending resume', () {
    fakeAsync((async) {
      final r = Rig(settings: const HeadsetSettings(resumeOnBluetooth: true));
      async.flushMicrotasks();
      r.devices.add(added({a2dp9}));
      async.elapse(const Duration(milliseconds: 100));
      r.service.dispose();
      async.elapse(const Duration(seconds: 1));
      expect(r.target.calls, isEmpty);
    });
  });
}
