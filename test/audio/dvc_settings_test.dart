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

  group('first-enable level from the system volume', () {
    test('maps index/max onto -30..0 dB', () {
      expect(dvcGainFromSystemVolume(0, 15), -30);
      expect(dvcGainFromSystemVolume(15, 15), 0);
      expect(dvcGainFromSystemVolume(5, 15), closeTo(-20, 1e-9));
      expect(dvcGainFromSystemVolume(30, 15), 0);
      expect(dvcGainFromSystemVolume(5, 0), -30);
    });
    test('the real attenuation wins, clamped to the DVC range', () {
      expect(dvcGainFromSystemVolume(3, 15, streamDb: -22.5), -22.5);
      expect(dvcGainFromSystemVolume(1, 15, streamDb: -48), -30);
      expect(dvcGainFromSystemVolume(1, 15, streamDb: double.negativeInfinity), -30);
      expect(dvcGainFromSystemVolume(15, 15, streamDb: 2), 0);
    });
    test('unreadable attenuation falls back to the linear map', () {
      expect(dvcGainFromSystemVolume(5, 15, streamDb: null), closeTo(-20, 1e-9));
      expect(dvcGainFromSystemVolume(5, 15, streamDb: double.nan),
          closeTo(-20, 1e-9));
    });
  });

  group('route read', () {
    test('a failed read is not a probe', () {
      expect(dvcRouteReadValid(null), isFalse);
      expect(dvcRouteReadValid('speaker'), isTrue);
    });
  });
}
