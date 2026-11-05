import 'dart:typed_data';

import 'package:eq_app/audio/eq/eq_layout.dart';
import 'package:eq_app/audio/eq/eq_presets.dart';
import 'package:eq_app/audio/eq/eq_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<EqState> freshState(List<double> centres) async {
  SharedPreferences.setMockInitialValues({});
  return EqState.load(await SharedPreferences.getInstance(), centres: centres);
}

void main() {
  group('eqPushes', () {
    test('a layout change is one push that carries the gains', () async {
      final before = await freshState(kIso10);
      final after = before.applyPreset('Rock').withLayout(kIso15);

      final pushes = eqPushes(before, after);

      expect(pushes, hasLength(1));
      final p = pushes.single;
      expect(p.kind, EqPushKind.layout);
      expect(p.values, kIso15);
      expect(p.cutoffs, platformBandCutoffs(kIso15));
      expect(p.gains, after.live.db);
      expect(p.gains, hasLength(15));
      expect(p.cutoffs, hasLength(15));
    });

    test('layout goes alone: no gain push before or after it', () async {
      final before = (await freshState(kIso10))
          .withBandGain(2, 3.0, autoSave: false);
      final after = before.applyPreset('Jazz').withLayout(kIso31);
      expect(eqPushes(before, after).map((p) => p.kind), [EqPushKind.layout]);
    });

    test('editing one band is a bandGain push', () async {
      final before = await freshState(kIso10);
      final after = before.withBandGain(3, 4.5, autoSave: false);

      final pushes = eqPushes(before, after);

      expect(pushes, hasLength(1));
      expect(pushes.single.kind, EqPushKind.bandGain);
      expect(pushes.single.band, 3);
      expect(pushes.single.values, [4.5]);
    });

    test('a preset on the same layout is an allGains push', () async {
      final before = await freshState(kIso10);
      final after = before.applyPreset('Rock');

      final pushes = eqPushes(before, after);

      expect(pushes, hasLength(1));
      expect(pushes.single.kind, EqPushKind.allGains);
      expect(pushes.single.values, after.live.db);
    });

    test('no change gives no pushes', () async {
      final s = await freshState(kIso10);
      expect(eqPushes(s, s), isEmpty);
      // Unsaved-state changes alone do not reach the engine.
      expect(eqPushes(s, s.withBandGain(1, 0.0, autoSave: false)), isEmpty);
    });

    test('lists are plain List<double>, never typed lists', () async {
      final before = await freshState(kIso10);
      final all = eqPushes(before, before.applyPreset('Rock')).single;
      final layout = eqPushes(before, before.withLayout(kIso15)).single;
      for (final list in [
        all.values,
        layout.values,
        layout.cutoffs,
        layout.gains,
      ]) {
        expect(list, isNotNull);
        expect(list is Float64List, isFalse);
        expect(list!.runtimeType.toString(), startsWith('List<double>'));
      }
    });

    test('the pushed lists are copies', () async {
      final before = await freshState(kIso10);
      final p = eqPushes(before, before.applyPreset('Rock')).single;
      expect(() => p.values!.add(1), returnsNormally);
    });
  });
}
