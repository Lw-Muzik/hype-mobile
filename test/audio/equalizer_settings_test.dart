import 'package:eq_app/audio/eq/eq_layout.dart';
import 'package:eq_app/audio/eq/equalizer_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> prefsWith(Map<String, Object> v) async {
  SharedPreferences.setMockInitialValues(v);
  return SharedPreferences.getInstance();
}

void main() {
  test('empty prefs give every default', () async {
    final s = EqualizerSettings.load(await prefsWith({}));
    expect(s.bandCount, 10);
    expect(s.customBands, false);
    expect(s.customCount, 10);
    expect(s.firstHz, 20);
    expect(s.lastHz, 16000);
    expect(s.bassFreq, 90);
    expect(s.bassQ, 0.80);
    expect(s.trebleFreq, 10000);
    expect(s.trebleQ, 0.60);
    expect(s.eqValues, EqValueLabels.db);
    expect(s.toneValues, EqValueLabels.percent);
    expect(s.autoSave, true);
    expect(s.smoothGains, true);
    expect(s.suggestAutoEq, true);
  });

  test('existing install keeps 32 bands and the old tone values', () async {
    final s = EqualizerSettings.load(await prefsWith({'isShuffled': true}));
    expect(s.bandCount, 32);
    expect(s.bassFreq, 80);
    expect(s.bassQ, 0.707);
    expect(s.trebleQ, 0.707);
    expect(s.trebleFreq, 10000);
  });

  test('stored tone values win on an existing install', () async {
    final s = EqualizerSettings.load(await prefsWith(
        {'isShuffled': true, 'bassFreq': 120.0, 'bassQ': 1.0}));
    expect(s.bassFreq, 120);
    expect(s.bassQ, 1.0);
  });

  test('lastHz defaults to 20000 on an existing install only', () async {
    expect(EqualizerSettings.load(await prefsWith({'isShuffled': true})).lastHz,
        20000);
    expect(EqualizerSettings.load(await prefsWith({})).lastHz, 16000);
    expect(
        EqualizerSettings.load(
                await prefsWith({'isShuffled': true, 'eqLastHz': 15000.0}))
            .lastHz,
        15000);
  });

  test('eqBandCount 20 becomes 24', () async {
    final s = EqualizerSettings.load(await prefsWith({'eqBandCount': 20}));
    expect(s.bandCount, 24);
  });

  test('clamps', () async {
    Future<EqualizerSettings> l(Map<String, Object> m) async =>
        EqualizerSettings.load(await prefsWith(m));
    expect((await l({'eqFirstHz': 3.0})).firstHz, 5);
    expect((await l({'eqFirstHz': 250.0})).firstHz, 200);
    expect((await l({'eqFirstHz': 37.6})).firstHz, 38);
    expect((await l({'eqLastHz': 13000.0})).lastHz, 14000);
    expect((await l({'eqLastHz': 21000.0})).lastHz, 20000);
    expect((await l({'eqLastHz': 16200.0})).lastHz, 16000);
    expect((await l({'eqCustomCount': 4})).customCount, 5);
    expect((await l({'eqCustomCount': 40})).customCount, 32);
    expect((await l({'bassFreq': 500.0})).bassFreq, 250);
    expect((await l({'bassQ': 3.0})).bassQ, 2.0);
    expect((await l({'trebleFreq': 1000.0})).trebleFreq, 5000);
  });

  test('copyWith normalises', () {
    const s = EqualizerSettings();
    expect(s.copyWith(bandCount: 20).bandCount, 24);
    expect(s.copyWith(firstHz: 1).firstHz, 5);
    expect(s.copyWith(lastHz: 16200).lastHz, 16000);
    expect(s.copyWith(bassQ: 9).bassQ, 2.0);
  });

  test('save then load round-trips', () async {
    final prefs = await prefsWith({});
    final s = const EqualizerSettings().copyWith(
      bandCount: 24,
      customBands: true,
      customCount: 13,
      firstHz: 30,
      lastHz: 18000,
      bassFreq: 100,
      bassQ: 1.1,
      trebleFreq: 8000,
      trebleQ: 0.9,
      eqValues: EqValueLabels.percent,
      toneValues: EqValueLabels.hidden,
      autoSave: false,
      smoothGains: false,
      suggestAutoEq: false,
    );
    await s.save(prefs);
    expect(EqualizerSettings.load(prefs), s);
  });

  test('usesFirstLast', () {
    expect(const EqualizerSettings(bandCount: 10).usesFirstLast, false);
    expect(const EqualizerSettings(bandCount: 12).usesFirstLast, true);
    expect(const EqualizerSettings(customBands: true).usesFirstLast, true);
    expect(kIsoBandCounts.contains(31), true);
  });

  test('tone gain normalisers', () {
    expect(EqualizerSettings.normBassGainDb(30), 22.5);
    expect(EqualizerSettings.normBassGainDb(-1), 0);
    expect(EqualizerSettings.normTrebleGainDb(20), 15);
  });

  test('labels', () {
    expect(EqValueLabels.hidden.label, 'Hidden');
    expect(EqValueLabels.db.label, 'dB');
    expect(EqValueLabels.percent.label, '%');
  });
}
