import 'dart:convert';

import 'package:eq_app/audio/dsp_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

void main() {
  group('defaults', () {
    test('empty prefs, Android new install', () async {
      final s = DspCoreSettings.load(await prefsWith({}), isIos: false);
      expect(s.headroomDb, -6.0);
      expect(s.balance, 0.0);
      expect(s.mono, false);
      expect(s.limiter, true);
      expect(s.preampDb, 0.0);
      expect(s.tempoOn, false);
      expect(s.tempo, 1.0);
    });

    test('empty prefs, iOS headroom is 0', () async {
      final s = DspCoreSettings.load(await prefsWith({}), isIos: true);
      expect(s.headroomDb, 0.0);
    });

    for (final key in [
      'appMode', 'selectedPreset', 'isShuffled', 'loopMode', 'replayGain',
      'dvcEnabled', 'limiterEnabled', 'eqBandCount', 'fancyMode',
      'visualizerStyle', 'lastOutputDevice',
    ]) {
      test('Android existing install ($key present) keeps headroom 0', () async {
        final prefs = await prefsWith({key: key == 'appMode' ? 'x' : true});
        expect(DspCoreSettings.load(prefs, isIos: false).headroomDb, 0.0);
      });
    }

    test('stored headroom wins over the install default', () async {
      final prefs = await prefsWith({'appMode': 'x', 'dspHeadroomDb': -3.0});
      expect(DspCoreSettings.load(prefs, isIos: false).headroomDb, -3.0);
    });
  });

  group('existing install seeds headroom from the old auto-gain', () {
    String graphic(double peak) => json.encode(
        [for (var i = 0; i < 32; i++) i == 5 ? peak : (i == 6 ? -9.0 : 0.0)]);

    Future<double> headroom(Map<String, Object> extra,
        {bool isIos = false}) async {
      final prefs = await prefsWith({'appMode': 'x', ...extra});
      return DspCoreSettings.load(prefs, isIos: isIos).headroomDb;
    }

    test('+6 dB EQ boost gives -6.0', () async {
      expect(
          await headroom(
              {'graphicEqEnabled': true, 'graphicBandGains': graphic(6.0)}),
          -6.0);
    });

    test('+12 dB boost clamps to -10.0', () async {
      expect(
          await headroom(
              {'graphicEqEnabled': true, 'graphicBandGains': graphic(12.0)}),
          -10.0);
    });

    test('no boost gives 0.0', () async {
      expect(await headroom({}), 0.0);
      expect(
          await headroom({
            'graphicEqEnabled': true,
            'graphicBandGains': json.encode(List.filled(32, -4.0)),
          }),
          0.0);
    });

    test('the largest of EQ, parametric and tone counts, on 0.5 dB steps',
        () async {
      expect(
          await headroom({
            'graphicEqEnabled': true,
            'graphicBandGains': graphic(2.0),
            'parametricPoints': json.encode([
              {'frequency': 1000.0, 'gain': 3.3},
              {'frequency': 2000.0, 'gain': 9.0, 'enabled': false},
            ]),
          }),
          -3.5);
      expect(
          await headroom(
              {'toneEnabled': true, 'bassGain': 4.0, 'trebleGain': 2.0}),
          -4.0);
    });

    test('the stored preamp is not a boost', () async {
      expect(await headroom({'preampGain': 6.0}), 0.0);
      expect(
          await headroom({
            'preampGain': 3.0,
            'graphicEqEnabled': true,
            'graphicBandGains': graphic(6.0),
          }),
          -6.0);
    });

    test('an EQ or tone that is off adds nothing', () async {
      expect(await headroom({'graphicBandGains': graphic(8.0)}), 0.0);
      expect(await headroom({'bassGain': 8.0}), 0.0);
    });

    test('a stored headroom is not overridden', () async {
      expect(
          await headroom({
            'graphicEqEnabled': true,
            'graphicBandGains': graphic(6.0),
            'dspHeadroomDb': -2.0,
          }),
          -2.0);
    });

    test('iOS existing installs are seeded too; new installs are unchanged',
        () async {
      expect(
          await headroom(
              {'graphicEqEnabled': true, 'graphicBandGains': graphic(6.0)},
              isIos: true),
          -6.0);
      final fresh = await prefsWith({
        'graphicEqEnabled': true,
        'graphicBandGains': graphic(6.0),
      });
      expect(DspCoreSettings.load(fresh, isIos: false).headroomDb, -6.0);
      expect(DspCoreSettings.load(fresh, isIos: true).headroomDb, 0.0);
    });
  });

  group('migration', () {
    test('limiterEnabled false carries over', () async {
      final s = DspCoreSettings.load(
          await prefsWith({'limiterEnabled': false}), isIos: false);
      expect(s.limiter, false);
    });

    test('existing preampGain pref carries over, clamped to +-24', () async {
      expect(
          DspCoreSettings.load(await prefsWith({'preampGain': 7.5}),
                  isIos: false)
              .preampDb,
          7.5);
      expect(
          DspCoreSettings.load(await prefsWith({'preampGain': 40.0}),
                  isIos: false)
              .preampDb,
          24.0);
      expect(
          DspCoreSettings.load(await prefsWith({'preampGain': -40.0}),
                  isIos: false)
              .preampDb,
          -24.0);
    });
  });

  group('clamps and snaps', () {
    DspCoreSettings base() => const DspCoreSettings(
        headroomDb: 0, balance: 0, mono: false, limiter: true, preampDb: 0,
        tempoOn: false, tempo: 1.0);

    test('headroom clamps to -10..0 in 0.5 dB steps', () {
      expect(base().copyWith(headroomDb: -12).headroomDb, -10.0);
      expect(base().copyWith(headroomDb: 1).headroomDb, 0.0);
      expect(base().copyWith(headroomDb: -3.3).headroomDb, -3.5);
      expect(base().copyWith(headroomDb: -3.2).headroomDb, -3.0);
    });

    test('balance clamps and snaps to centre', () {
      expect(base().copyWith(balance: 1.5).balance, 1.0);
      expect(base().copyWith(balance: -1.5).balance, -1.0);
      expect(base().copyWith(balance: 0.02).balance, 0.0);
      expect(base().copyWith(balance: -0.015).balance, 0.0);
      expect(base().copyWith(balance: 0.1).balance, 0.1);
    });

    test('tempo clamps to 0.5..3.0 and snaps near 1.0', () {
      expect(base().copyWith(tempo: 0.4).tempo, 0.5);
      expect(base().copyWith(tempo: 3.5).tempo, 3.0);
      expect(base().copyWith(tempo: 1.02).tempo, 1.0);
      expect(base().copyWith(tempo: 0.98).tempo, 1.0);
      expect(base().copyWith(tempo: 1.1).tempo, 1.1);
    });

    test('preamp clamps to +-24', () {
      expect(base().copyWith(preampDb: 30).preampDb, 24.0);
      expect(base().copyWith(preampDb: -30).preampDb, -24.0);
    });

    test('load clamps out-of-range stored values', () async {
      final s = DspCoreSettings.load(
          await prefsWith({
            'dspHeadroomDb': -12.0,
            'dspBalance': 1.5,
            'dspTempo': 3.5,
          }),
          isIos: false);
      expect(s.headroomDb, -10.0);
      expect(s.balance, 1.0);
      expect(s.tempo, 3.0);
    });
  });

  group('headroomFor', () {
    test('DVC active -> 0', () {
      expect(headroomFor(dvcActive: true, headroomDb: -6), 0);
    });
    test('DVC inactive -> setting', () {
      expect(headroomFor(dvcActive: false, headroomDb: -6), -6);
    });
  });

  test('save then load round-trips', () async {
    final prefs = await prefsWith({});
    const s = DspCoreSettings(
        headroomDb: -4.5, balance: -0.3, mono: true, limiter: false,
        preampDb: 12.5, tempoOn: true, tempo: 1.25);
    await s.save(prefs);
    expect(DspCoreSettings.load(prefs, isIos: false), s);
    expect(prefs.getDouble('preampGain'), 12.5);
  });

  test('equality and hashCode', () {
    const a = DspCoreSettings(
        headroomDb: 0, balance: 0, mono: false, limiter: true, preampDb: 0,
        tempoOn: false, tempo: 1.0);
    expect(a, a.copyWith());
    expect(a.hashCode, a.copyWith().hashCode);
    expect(a == a.copyWith(mono: true), false);
  });
}
