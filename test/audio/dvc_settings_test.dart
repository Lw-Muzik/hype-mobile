import 'package:eq_app/audio/dvc/dvc_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

bool allowed({
  bool isAndroid = true,
  bool dvcEnabled = true,
  bool onBluetooth = false,
  bool? btAbsoluteVolumeOff,
  bool noDvcForBtAbsolute = true,
  bool systemWide = false,
}) => dvcAllowedOnRoute(
  isAndroid: isAndroid,
  dvcEnabled: dvcEnabled,
  onBluetooth: onBluetooth,
  btAbsoluteVolumeOff: btAbsoluteVolumeOff,
  noDvcForBtAbsolute: noDvcForBtAbsolute,
  systemWide: systemWide,
);

void main() {
  group('dvcAllowedOnRoute', () {
    test('speaker is allowed', () => expect(allowed(), isTrue));
    test('bluetooth, setting on, absolute volume unknown: not allowed', () {
      expect(allowed(onBluetooth: true, btAbsoluteVolumeOff: null), isFalse);
    });
    test('bluetooth, setting on, absolute volume on: not allowed', () {
      expect(allowed(onBluetooth: true, btAbsoluteVolumeOff: false), isFalse);
    });
    test('bluetooth, absolute volume off: allowed', () {
      expect(allowed(onBluetooth: true, btAbsoluteVolumeOff: true), isTrue);
    });
    test('bluetooth, setting off: allowed whatever the flag says', () {
      expect(
        allowed(
          onBluetooth: true,
          btAbsoluteVolumeOff: null,
          noDvcForBtAbsolute: false,
        ),
        isTrue,
      );
    });
    test('system-wide mode: not allowed', () {
      expect(allowed(systemWide: true), isFalse);
    });
    test('setting off or iOS: not allowed', () {
      expect(allowed(dvcEnabled: false), isFalse);
      expect(allowed(isAndroid: false), isFalse);
    });
  });

  group('DvcSettings', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults', () async {
      final p = await SharedPreferences.getInstance();
      expect(DvcSettings.load(p).noDvcForBluetoothAbsoluteVolume, isTrue);
    });

    test('round trip, copyWith and equality', () async {
      final p = await SharedPreferences.getInstance();
      final s = const DvcSettings().copyWith(
        noDvcForBluetoothAbsoluteVolume: false,
      );
      await s.save(p);
      expect(p.getBool('dvcNoBtAbsolute'), isFalse);
      expect(DvcSettings.load(p), s);
      expect(s == const DvcSettings(), isFalse);
      expect(s.hashCode == DvcSettings.load(p).hashCode, isTrue);
    });
  });
}
