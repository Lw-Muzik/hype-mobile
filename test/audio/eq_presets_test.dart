import 'dart:convert';

import 'package:eq_app/audio/eq/eq_layout.dart';
import 'package:eq_app/audio/eq/eq_presets.dart';
import 'package:eq_app/models/eq_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> prefsWith(Map<String, Object> v) async {
  SharedPreferences.setMockInitialValues(v);
  return SharedPreferences.getInstance();
}

List<double> factoryDb(String name) =>
    factoryPresets().firstWhere((p) => p.name == name).curve.db;

/// A 32-value native curve built from 10-band display values.
List<double> staircase10(List<double> display) {
  const groups = [
    [0, 1],
    [2, 3, 4],
    [5, 6, 7],
    [8, 9, 10],
    [11, 12, 13, 14],
    [15, 16, 17],
    [18, 19, 20],
    [21, 22, 23, 24],
    [25, 26, 27],
    [28, 29, 30, 31],
  ];
  final out = List<double>.filled(32, 0.0);
  for (var g = 0; g < 10; g++) {
    for (final i in groups[g]) {
      out[i] = display[g];
    }
  }
  return out;
}

void main() {
  late SharedPreferences empty;
  setUp(() async {
    empty = await prefsWith({});
  });

  group('new install', () {
    test('factory list, Flat selected, live flat', () async {
      final s = EqState.load(await prefsWith({}), centres: kIso10);
      expect(
        s.presets.map((p) => p.name).toList(),
        factoryPresets().map((p) => p.name).toList(),
      );
      expect(s.selected, 'Flat');
      expect(s.dirty, false);
      expect(s.live.hz, kIso10);
      expect(s.live.db, List<double>.filled(10, 0));
      expect(s.visibleNames.first, 'Flat');
      expect(s.isBuiltIn('Rock'), true);
    });
  });

  group('migration', () {
    test(
      '10-band staircase becomes a Custom preset on the 10 grouping',
      () async {
        final display = <double>[1.0, 2, 3, 4, 5, 6, 7, 8, 9, 10];
        final s = EqState.load(
          await prefsWith({
            'graphicBandGains': json.encode(staircase10(display)),
            'activePresetName': 'Custom',
          }),
          centres: kIso10,
        );
        final custom = s.preset('Custom')!;
        expect(custom.curve.hz, [
          31.5,
          63,
          125,
          250,
          500,
          1000,
          2000,
          4000,
          8000,
          16000,
        ]);
        expect(custom.curve.db, display);
        expect(s.selected, 'Custom');
        expect(s.isBuiltIn('Custom'), false);
        expect(s.live.db[1], closeTo(2.0, 1e-9));
        expect(s.live.db[9], closeTo(10.0, 1e-9));
        expect(s.live.db[0], closeTo(1.0, 0.05));
      },
    );

    test('legacy user preset keeps 32 points and its preamp', () async {
      final rock = factoryDb('Rock');
      final s = EqState.load(
        await prefsWith({
          'eqPresets': json.encode({
            'Mine': {'name': 'Mine', 'graphicGains': rock, 'preamp': 2.0},
          }),
        }),
        centres: kIso10,
      );
      final mine = s.preset('Mine')!;
      expect(mine.curve.hz.length, 32);
      expect(mine.curve.db, rock);
      expect(mine.preampDb, 2.0);
      expect(mine.builtIn, false);
    });

    test('user preset named like a built-in is renamed', () async {
      final s = EqState.load(
        await prefsWith({
          'eqPresets': json.encode({
            'Rock': {'name': 'Rock', 'graphicGains': List.filled(32, 1.0)},
          }),
        }),
        centres: kIso10,
      );
      expect(s.preset('Rock (2)'), isNotNull);
      expect(s.isBuiltIn('Rock'), true);
      expect(s.preset('Rock')!.curve.db, factoryDb('Rock'));
    });

    test('active built-in with matching curve selects it, no Custom', () async {
      final s = EqState.load(
        await prefsWith({
          'graphicBandGains': json.encode(factoryDb('Rock')),
          'activePresetName': 'Rock',
        }),
        centres: kIso10,
      );
      expect(s.selected, 'Rock');
      expect(s.preset('Custom'), isNull);
      expect(s.dirty, false);
    });

    test('active built-in with a 1 dB difference creates Custom', () async {
      final g = List<double>.from(factoryDb('Rock'));
      g[10] += 1;
      final s = EqState.load(
        await prefsWith({
          'graphicBandGains': json.encode(g),
          'activePresetName': 'Rock',
        }),
        centres: kIso10,
      );
      expect(s.selected, 'Custom');
      expect(s.preset('Custom'), isNotNull);
      expect(s.preset('Rock')!.curve.db, factoryDb('Rock'));
    });
  });

  group('legacyCurve uses the stored band count', () {
    // Constant over every 5-band group by construction.
    final fiveConstant = List<double>.filled(32, 0)..fillRange(0, 6, 6);

    test('32 bands keep all 32 points even when a grouping would fit', () {
      final c = legacyCurve(fiveConstant, legacyCount: 32);
      expect(c.hz, kLegacyIso32);
      expect(c.db, fiveConstant);
    });

    test('a known grouping that does not fit keeps 32 points', () {
      final ramp = [for (var i = 0; i < 32; i++) i.toDouble()];
      final c = legacyCurve(ramp, legacyCount: 10);
      expect(c.hz, kLegacyIso32);
    });

    test('an unknown count still falls back to coarsest-first', () {
      final c = legacyCurve(List<double>.filled(32, 0), legacyCount: null);
      expect(c.hz.length, 5);
    });
  });

  group('migration fixes', () {
    test('stored eqBandCount picks the grouping first', () async {
      final g = staircase10([6, 6, 6, 6, 0, 0, 0, 0, 0, 0]);
      final s = EqState.load(
        await prefsWith({
          'graphicBandGains': json.encode(g),
          'activePresetName': 'Custom',
          'eqBandCount': 10,
        }),
        centres: kIso10,
      );
      expect(s.preset('Custom')!.curve.hz.length, 10);
      expect(s.live.db[4], closeTo(0.0, 0.05));
      expect(s.live.db[3], closeTo(6.0, 0.05));
    });

    test('first slider keeps its value', () async {
      final g = staircase10([10, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
      final s = EqState.load(
        await prefsWith({
          'graphicBandGains': json.encode(g),
          'activePresetName': 'Custom',
          'eqBandCount': 10,
        }),
        centres: kIso10,
      );
      expect(s.live.db[0], closeTo(10.0, 0.05));
    });

    test('malformed legacy presets are skipped one by one', () async {
      final good = factoryDb('Rock');
      final s = EqState.load(
        await prefsWith({
          'eqPresets': json.encode({
            'A': {'name': 'A', 'graphicGains': good},
            'B': {'name': 'B', 'graphicGains': null},
            'C': {
              'name': 'C',
              'graphicGains': [1, 2, 3, 4, 5, 6, 7],
            },
            'D': 5,
            'E': {'name': 'E', 'graphicGains': good, 'preamp': 1.0},
          }),
        }),
        centres: kIso10,
      );
      expect(s.preset('A'), isNotNull);
      expect(s.preset('E')!.preampDb, 1.0);
      for (final n in ['B', 'C', 'D']) {
        expect(s.preset(n), isNull);
      }
    });
  });

  test('a built-in saved with parametric: [] does not set the parametric EQ',
      () {
    final p = EqPreset.fromJson({
      'name': 'Rock',
      'curve': {'hz': [100.0, 1000.0], 'db': [3.0, 0.0]},
      'preampDb': null,
      'parametric': <Map<String, dynamic>>[],
      'builtIn': true,
      'deviceType': null,
    });
    expect(p.parametric, isNull);
  });

  group('v2 load', () {
    test(
      'clean state derives live from the preset on the new centres',
      () async {
        final prefs = await prefsWith({});
        await EqState.load(
          prefs,
          centres: kIso10,
        ).applyPreset('Rock').saveTo(prefs);
        final r = EqState.load(prefs, centres: kLegacyIso32);
        expect(r.live.db, factoryDb('Rock'));
      },
    );

    test('EqCurve.fromJson drops bad points, sorts, flattens mismatches', () {
      final c = EqCurve.fromJson({
        'hz': [1000, -5, 100, 0],
        'db': [3, 1, 2, 4],
      });
      expect(c.hz, [100, 1000]);
      expect(c.db, [2, 3]);
      final flat = EqCurve.fromJson({
        'hz': [100, 1000],
        'db': [1],
      });
      expect(flat.db, [0, 0]);
    });

    test('lists are unmodifiable', () {
      final s = EqState.load(empty, centres: kIso10);
      expect(() => s.presets.add(s.presets.first), throwsUnsupportedError);
    });
  });

  group('editing', () {
    EqState rock() {
      final s = EqState.load(empty, centres: kIso10);
      return s.applyPreset('Rock');
    }

    test('auto save writes into the selected preset', () {
      final s = rock().withBandGain(3, 4.5, autoSave: true);
      expect(s.preset('Rock')!.curve.db[3], 4.5);
      expect(s.dirty, false);
      expect(s.live.db[3], 4.5);
    });

    test('auto save off keeps the preset and marks dirty; save writes', () {
      final before = rock();
      var s = before.withBandGain(3, 4.5, autoSave: false);
      expect(s.preset('Rock')!.curve.db, before.preset('Rock')!.curve.db);
      expect(s.dirty, true);
      s = s.save();
      expect(s.preset('Rock')!.curve.db[3], 4.5);
      expect(s.dirty, false);
    });

    test('preamp only lands in presets that carry one', () {
      var s = rock().withPreamp(3, autoSave: true);
      expect(s.preset('Rock')!.preampDb, isNull);
      s = s.saveAs('Mine', preampDb: 1).withPreamp(4, autoSave: true);
      expect(s.preset('Mine')!.preampDb, 4);
    });

    test('round trip through the legacy grid is exact', () {
      final s = rock().withLayout(kLegacyIso32);
      expect(s.live.hz, kLegacyIso32);
      expect(s.live.db, factoryDb('Rock'));
    });

    test('withLayout from a dirty state interpolates live', () {
      final s = rock()
          .withBandGain(0, 7, autoSave: false)
          .withLayout(kLegacyIso32);
      expect(s.live.hz, kLegacyIso32);
      expect(s.dirty, true);
      expect(s.preset('Rock')!.curve.hz, kLegacyIso32);
    });

    test('restoreFactory', () {
      var s = rock().withBandGain(3, 4.5, autoSave: true);
      s = s.saveAs('Mine');
      s = s.delete('Jazz');
      s = s.applyPreset('Rock');
      s = s.restoreFactory();
      final names = s.presets.map((p) => p.name).toList();
      final fac = factoryPresets().map((p) => p.name).toList();
      expect(names.sublist(0, fac.length), fac);
      expect(names.last, 'Mine');
      expect(s.preset('Mine')!.builtIn, false);
      expect(s.selected, 'Rock');
      final want = EqCurve(kLegacyIso32, factoryDb('Rock')).onto(kIso10);
      expect(s.live.db, want.db);
      expect(s.preset('Rock')!.curve.db, factoryDb('Rock'));
    });

    test('delete the selected preset', () {
      final s = rock().delete('Rock');
      expect(s.selected, '');
      expect(s.dirty, true);
      expect(s.preset('Rock'), isNull);
    });

    test('flatten', () {
      var s = EqState.load(empty, centres: kIso10);
      s = s.withBandGain(2, 5, autoSave: true);
      expect(s.preset('Flat')!.curve.db[2], 5);
      s = s.applyPreset('Rock').flatten();
      expect(s.live.db, List<double>.filled(10, 0));
      expect(s.selected, 'Flat');
      expect(s.preset('Flat')!.curve.db, List<double>.filled(10, 0));
      expect(s.dirty, false);
    });

    test('device curve is live only and clears the selection', () {
      final s = rock().withDeviceCurve(EqCurve([100, 1000], [3, 3]));
      expect(s.live.db.every((v) => v == 3), true);
      expect(s.dirty, true);
      expect(s.selected, '');
      expect(s.preset('Rock')!.curve.db, factoryDb('Rock'));
      // With Auto save on, the next edit stays live and writes no preset.
      final edited = s.withBandGain(1, 7, autoSave: true);
      expect(edited.preset('Rock')!.curve.db, factoryDb('Rock'));
      expect(edited.dirty, true);
    });

    test('uniqueName', () {
      expect(uniqueName('Custom', {'Custom', 'Custom (2)'}), 'Custom (3)');
      expect(uniqueName('New', {'Custom'}), 'New');
    });
  });

  group('parametric on presets', () {
    test('null means the preset does not set it; [] is distinct', () {
      expect(factoryPresets().every((p) => p.parametric == null), true);
      final none = EqPreset.fromJson(
        EqPreset(name: 'A', curve: EqCurve([100], [0])).toJson(),
      );
      expect(none.parametric, isNull);
      final empty = EqPreset.fromJson(
        EqPreset(
          name: 'B',
          curve: EqCurve([100], [0]),
          parametric: [],
        ).toJson(),
      );
      expect(empty.parametric, isNotNull);
      expect(empty.parametric, isEmpty);
      final pts = EqPreset.fromJson(
        EqPreset(
          name: 'C',
          curve: EqCurve([100], [0]),
          parametric: [ParametricPoint(frequency: 1000, gain: 3)],
        ).toJson(),
      );
      expect(pts.parametric!.single.frequency, 1000);
    });

    test('a v2 preset JSON without the field loads as null', () {
      final p = EqPreset.fromJson({
        'name': 'Old',
        'curve': {
          'hz': [100.0],
          'db': [1.0],
        },
      });
      expect(p.parametric, isNull);
    });

    test(
      'migrated Custom has null; a legacy preset with points keeps them',
      () async {
        final prefs = await prefsWith({
          'graphicBandGains': json.encode(List<double>.filled(32, 2.0)),
          'activePresetName': 'Custom',
          'eqPresets': json.encode({
            'Mine': {
              'name': 'Mine',
              'graphicGains': List<double>.filled(32, 1.0),
              'parametric': [
                {'frequency': 500.0, 'gain': 4.0, 'q': 1.4, 'enabled': true},
              ],
              'preamp': 0.0,
            },
            'Plain': {
              'name': 'Plain',
              'graphicGains': List<double>.filled(32, 0.5),
              'parametric': [],
              'preamp': 0.0,
            },
          }),
        });
        final s = EqState.load(prefs, centres: kIso10);
        expect(s.preset('Custom')!.parametric, isNull);
        expect(s.preset('Plain')!.parametric, isNull);
        expect(s.preset('Mine')!.parametric!.single.frequency, 500);
      },
    );
  });

  test('save then load round-trips including dirty and live', () async {
    final prefs = await prefsWith({});
    final s = EqState.load(prefs, centres: kIso10)
        .applyPreset('Rock')
        .saveAs('Mine', preampDb: 2)
        .withBandGain(4, 6.5, autoSave: false);
    await s.saveTo(prefs);
    final r = EqState.load(prefs, centres: kIso10);
    expect(r.selected, 'Mine');
    expect(r.dirty, true);
    expect(r.live.db, s.live.db);
    expect(r.presets.length, s.presets.length);
    expect(r.preset('Mine')!.preampDb, 2);
    expect(r.preset('Mine')!.builtIn, false);
    expect(r.preset('Mine')!.curve.db, s.preset('Mine')!.curve.db);
  });

  test('legacy prefs are not touched by save', () async {
    final prefs = await prefsWith({
      'graphicBandGains': json.encode(factoryDb('Rock')),
      'activePresetName': 'Rock',
    });
    await EqState.load(prefs, centres: kIso10).saveTo(prefs);
    expect(prefs.getString('graphicBandGains'), json.encode(factoryDb('Rock')));
    expect(prefs.getString('eqPresetsV2'), isNotNull);
  });
}
