// ignore_for_file: experimental_member_use
import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eq_app/audio/headset/headset_policy.dart';
import 'package:eq_app/audio/headset/headset_settings.dart';
import 'package:eq_app/audio/headset/output_kind.dart';

AudioDevice dev(String id, AudioDeviceType t, {bool out = true}) =>
    AudioDevice(
      id: id,
      name: 'd$id',
      isInput: !out,
      isOutput: out,
      type: t,
    );

void main() {
  group('outputKindOf', () {
    test('mapping', () {
      const m = {
        AudioDeviceType.wiredHeadset: AudioOutputKind.wired,
        AudioDeviceType.wiredHeadphones: AudioOutputKind.wired,
        AudioDeviceType.lineAnalog: AudioOutputKind.wired,
        AudioDeviceType.bluetoothA2dp: AudioOutputKind.bluetooth,
        AudioDeviceType.bluetoothLe: AudioOutputKind.bluetooth,
        AudioDeviceType.bluetoothSco: AudioOutputKind.other,
        AudioDeviceType.usbAudio: AudioOutputKind.usb,
        AudioDeviceType.builtInSpeaker: AudioOutputKind.speaker,
        AudioDeviceType.builtInEarpiece: AudioOutputKind.speaker,
        AudioDeviceType.builtInSpeakerSafe: AudioOutputKind.speaker,
        AudioDeviceType.airPlay: AudioOutputKind.other,
        AudioDeviceType.carAudio: AudioOutputKind.other,
        AudioDeviceType.hdmi: AudioOutputKind.other,
        AudioDeviceType.unknown: AudioOutputKind.other,
      };
      m.forEach((t, k) => expect(outputKindOf(t), k, reason: '$t'));
    });
  });

  group('newlyConnectedOutputs', () {
    test('counts outputs only and updates known ids', () {
      final known = {'1', '2'};
      final kinds = newlyConnectedOutputs(
        AudioDevicesChangedEvent(devicesAdded: {
          dev('2', AudioDeviceType.bluetoothA2dp),
          dev('3', AudioDeviceType.wiredHeadset),
          dev('4', AudioDeviceType.headsetMic, out: false),
        }),
        known,
      );
      expect(kinds, {AudioOutputKind.wired});
      expect(known, {'1', '2', '3'});
    });
    test('removed then re-added counts again', () {
      final known = {'1', '2', '3'};
      newlyConnectedOutputs(
        AudioDevicesChangedEvent(
            devicesRemoved: {dev('3', AudioDeviceType.wiredHeadset)}),
        known,
      );
      expect(known, {'1', '2'});
      final kinds = newlyConnectedOutputs(
        AudioDevicesChangedEvent(
            devicesAdded: {dev('3', AudioDeviceType.wiredHeadset)}),
        known,
      );
      expect(kinds, {AudioOutputKind.wired});
    });
    test('initial burst is not a connection', () {
      final known = <String>{};
      // Seeded with the initially present devices by the caller.
      known.addAll({'1', '2'});
      final kinds = newlyConnectedOutputs(
        AudioDevicesChangedEvent(devicesAdded: {
          dev('1', AudioDeviceType.builtInSpeaker),
          dev('2', AudioDeviceType.bluetoothA2dp),
        }),
        known,
      );
      expect(kinds, isEmpty);
    });
  });

  group('onOutputsConnected', () {
    const defaults = HeadsetSettings();
    List<HeadsetAction> run(
      Set<AudioOutputKind> k,
      HeadsetSettings s, {
      bool playing = false,
      bool canResume = true,
      bool waiting = false,
      bool ios = false,
    }) => onOutputsConnected(k, s,
        playing: playing,
        canResume: canResume,
        waitingForFocus: waiting,
        isIos: ios);
    const bt = {AudioOutputKind.bluetooth};
    final btResume = defaults.copyWith(resumeOnBluetooth: true);

    test('a USB-C headset resumes on wired on iOS, not on Android', () {
      final wiredResume = defaults.copyWith(resumeOnWired: true);
      const usbOnly = {AudioOutputKind.usb};
      const usbAndWired = {AudioOutputKind.usb, AudioOutputKind.wired};
      expect(run(usbOnly, wiredResume, ios: true), [HeadsetAction.resume]);
      expect(run(usbAndWired, wiredResume),
          isNot(contains(HeadsetAction.resume)));
    });
    test('bluetooth starts the grace window', () {
      expect(run(bt, defaults), [HeadsetAction.startBluetoothGrace]);
    });
    test('bluetooth resume when paused and allowed', () {
      expect(run(bt, btResume),
          [HeadsetAction.startBluetoothGrace, HeadsetAction.resume]);
    });
    test('bluetooth resume suppressed', () {
      const g = [HeadsetAction.startBluetoothGrace];
      expect(run(bt, btResume, playing: true), g);
      expect(run(bt, btResume, canResume: false), g);
      expect(run(bt, btResume, waiting: true), g);
    });
    test('wired resume', () {
      final s = defaults.copyWith(resumeOnWired: true);
      expect(run({AudioOutputKind.wired}, s), [HeadsetAction.resume]);
      expect(run({AudioOutputKind.wired}, s, waiting: true), isEmpty);
      expect(run({AudioOutputKind.wired}, s, canResume: false), isEmpty);
      expect(run({AudioOutputKind.wired}, defaults), isEmpty);
    });
    test('usb dac pauses on Android only while playing', () {
      const usb = {AudioOutputKind.usb};
      expect(run(usb, defaults, playing: true), [HeadsetAction.pause]);
      expect(run(usb, defaults), isEmpty);
      expect(run(usb, defaults, playing: true, ios: true), isEmpty);
      expect(
        run(usb, defaults.copyWith(pauseOnUsbDac: false), playing: true),
        isEmpty,
      );
    });
    test('usb alongside wired suppresses resume on wired', () {
      final s = defaults.copyWith(resumeOnWired: true);
      expect(
          run({AudioOutputKind.usb, AudioOutputKind.wired}, s), isEmpty);
    });
    test('bluetooth plus wired resumes once', () {
      final s = defaults.copyWith(resumeOnWired: true, resumeOnBluetooth: true);
      expect(
        run({AudioOutputKind.bluetooth, AudioOutputKind.wired}, s),
        [HeadsetAction.startBluetoothGrace, HeadsetAction.resume],
      );
    });
  });

  group('onBecomingNoisy', () {
    const d = HeadsetSettings();
    test('pauses while playing', () {
      expect(onBecomingNoisy(d, playing: true, isIos: false),
          [HeadsetAction.pause]);
      expect(onBecomingNoisy(d, playing: false, isIos: false), isEmpty);
    });
    test('pause on disconnect off', () {
      final s = d.copyWith(pauseOnDisconnect: false);
      expect(onBecomingNoisy(s, playing: true, isIos: false), isEmpty);
      expect(onBecomingNoisy(s, playing: true, isIos: true),
          [HeadsetAction.restartPlayback]);
      expect(onBecomingNoisy(s, playing: false, isIos: true), isEmpty);
    });
  });
}
