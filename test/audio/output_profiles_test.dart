import 'package:eq_app/audio/headset/output_kind.dart';
import 'package:eq_app/audio/output/output_profiles.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('resolveProfile', () {
    final btKind = const OutputProfile(eqPreset: 'Bass', noDuck: true);
    final named = const OutputProfile(eqPreset: 'Flat', noDvc: true);

    test('falls back to the default when nothing is set', () {
      final r = resolveProfile(
        const OutputProfiles(),
        kind: AudioOutputKind.speaker,
      );
      expect(r, const OutputProfile());
      expect(r.isDefault, isTrue);
    });

    test('a kind beats the default', () {
      final p = const OutputProfiles().withKind(
        AudioOutputKind.bluetooth,
        btKind,
      );
      expect(resolveProfile(p, kind: AudioOutputKind.bluetooth), btKind);
      expect(resolveProfile(p, kind: AudioOutputKind.wired).isDefault, isTrue);
    });

    test('a named device beats its kind, by normalised name', () {
      final p = const OutputProfiles()
          .withKind(AudioOutputKind.bluetooth, btKind)
          .withDevice('WH-1000XM4 (LE)', AudioOutputKind.bluetooth, named);
      expect(
        resolveProfile(
          p,
          kind: AudioOutputKind.bluetooth,
          deviceName: 'wh1000xm4',
        ),
        named,
      );
      expect(
        resolveProfile(p, kind: AudioOutputKind.bluetooth, deviceName: 'Other'),
        btKind,
      );
    });

    test('a remembered device without a profile falls through to the kind', () {
      final p = const OutputProfiles()
          .withKind(AudioOutputKind.usb, btKind)
          .rememberDevice('Dragonfly', AudioOutputKind.usb);
      expect(p.devices, hasLength(1));
      expect(
        resolveProfile(p, kind: AudioOutputKind.usb, deviceName: 'Dragonfly'),
        btKind,
      );
    });

    test('a short or empty name never selects a device', () {
      final p = const OutputProfiles().rememberDevice('', AudioOutputKind.usb);
      expect(p.devices, isEmpty);
    });
  });

  group('storage', () {
    test('round-trips through JSON', () {
      final p = const OutputProfiles()
          .withKind(
            AudioOutputKind.wired,
            const OutputProfile(
              eqPreset: 'Rock',
              noEqTone: true,
              noDuck: true,
              ignoreFocus: true,
              noDvc: true,
              noHeadroomReduction: true,
            ),
          )
          .withDevice(
            'Buds Pro',
            AudioOutputKind.bluetooth,
            const OutputProfile(autoEq: 'Sony WH-1000XM4'),
          )
          .rememberDevice('Car', AudioOutputKind.bluetooth);
      final back = OutputProfiles.fromJson(p.toJson());
      expect(back.toJson(), p.toJson());
      expect(back.kinds[AudioOutputKind.wired]!.noHeadroomReduction, isTrue);
      expect(back.devices['budspro']!.profile!.autoEq, 'Sony WH-1000XM4');
      expect(back.devices['car']!.profile, isNull);
    });

    test('corrupt data loads as empty', () async {
      SharedPreferences.setMockInitialValues({'outputProfilesV1': '{nope'});
      final prefs = await SharedPreferences.getInstance();
      expect(OutputProfiles.load(prefs).kinds, isEmpty);
    });

    test('save then load', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final p = const OutputProfiles().withKind(
        AudioOutputKind.usb,
        const OutputProfile(noDuck: true),
      );
      await p.save(prefs);
      expect(
        OutputProfiles.load(prefs).kinds[AudioOutputKind.usb]!.noDuck,
        isTrue,
      );
      expect(prefs.containsKey(OutputProfiles.prefKey), isTrue);
    });
  });

  group('legacy device presets', () {
    test('legacy output strings map to kinds', () {
      expect(kindOfLegacyOutput('bluetooth'), AudioOutputKind.bluetooth);
      expect(kindOfLegacyOutput('wired_headphone'), AudioOutputKind.wired);
      expect(kindOfLegacyOutput('headset'), AudioOutputKind.wired);
      expect(kindOfLegacyOutput('usb_audio'), AudioOutputKind.usb);
      expect(kindOfLegacyOutput('speaker'), AudioOutputKind.speaker);
      expect(kindOfLegacyOutput('airplay'), AudioOutputKind.other);
    });

    test('hidden _device_ presets become the matching kind eqPreset', () {
      final p = migrateLegacyDevicePresets(const OutputProfiles(), [
        'Flat',
        '_device_bluetooth',
        '_device_wired_headphone',
        '_device_speaker',
      ]);
      expect(p.kinds[AudioOutputKind.bluetooth]!.eqPreset, '_device_bluetooth');
      expect(
        p.kinds[AudioOutputKind.wired]!.eqPreset,
        '_device_wired_headphone',
      );
      expect(p.kinds[AudioOutputKind.speaker]!.eqPreset, '_device_speaker');
      expect(p.kinds.containsKey(AudioOutputKind.usb), isFalse);
    });

    test('an existing assignment is kept; the first of two aliases wins', () {
      final start = const OutputProfiles().withKind(
        AudioOutputKind.bluetooth,
        const OutputProfile(eqPreset: 'Mine'),
      );
      final p = migrateLegacyDevicePresets(start, [
        '_device_bluetooth',
        '_device_headset',
        '_device_wired_headphone',
      ]);
      expect(p.kinds[AudioOutputKind.bluetooth]!.eqPreset, 'Mine');
      expect(p.kinds[AudioOutputKind.wired]!.eqPreset, '_device_headset');
    });
  });

  group('startup migration honours link all devices', () {
    const names = ['Flat', '_device_bluetooth'];

    Future<SharedPreferences> prefs(Map<String, Object> v) async {
      SharedPreferences.setMockInitialValues(v);
      return SharedPreferences.getInstance();
    }

    test('linking off: the kept curves migrate', () async {
      final r = loadOutputProfiles(
        await prefs({'linkAllDevices': false}),
        names,
      );
      expect(r.migrated, isTrue);
      expect(
        r.profiles.kinds[AudioOutputKind.bluetooth]!.eqPreset,
        '_device_bluetooth',
      );
    });

    test('linking on: stale hidden curves are not applied', () async {
      final r = loadOutputProfiles(
        await prefs({'linkAllDevices': true}),
        names,
      );
      expect(r.migrated, isTrue);
      expect(r.profiles.kinds, isEmpty);
    });

    test('never set means on (the old default): no migration', () async {
      final r = loadOutputProfiles(await prefs({}), names);
      expect(r.profiles.kinds, isEmpty);
    });

    test('saved profiles are loaded as they are', () async {
      final saved = const OutputProfiles().withKind(
        AudioOutputKind.usb,
        const OutputProfile(noDuck: true),
      );
      final p = await prefs({});
      await saved.save(p);
      final r = loadOutputProfiles(p, names);
      expect(r.migrated, isFalse);
      expect(r.profiles.kinds.keys, [AudioOutputKind.usb]);
    });
  });

  group('activeRoute', () {
    test(
      'legacy string gives the kind; the device name comes from the list',
      () {
        final r = activeRouteOf('bluetooth', const [
          (name: 'Pixel speaker', kind: AudioOutputKind.speaker),
          (name: 'WH-1000XM4', kind: AudioOutputKind.bluetooth),
        ]);
        expect(r.kind, AudioOutputKind.bluetooth);
        expect(r.deviceName, 'WH-1000XM4');
        expect(r.key, 'bluetooth:wh1000xm4');
      },
    );

    test('speaker and wired routes carry no device name', () {
      final r = activeRouteOf('wired_headphone', const [
        (name: 'Headset', kind: AudioOutputKind.wired),
      ]);
      expect(r.deviceName, isNull);
      expect(r.key, 'wired');
    });

    test('a bluetooth route with no matching device keeps just the kind', () {
      final r = activeRouteOf('bluetooth', const []);
      expect(r.deviceName, isNull);
      expect(r.key, 'bluetooth');
    });
  });
}
