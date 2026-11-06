import 'dart:math' as math;

import 'package:eq_app/audio/advanced/fine_volume.dart';
import 'package:flutter_test/flutter_test.dart';

const _max = 15;

/// A convex curve like a real music stream: steep near silence. Index 0 is
/// never asked for (it is silence, not a level).
double _realistic(int i) {
  if (i < 1) throw StateError('dbAt(0) must not be requested');
  return -60 * math.pow((_max - i) / _max, 1.4).toDouble();
}

double _fallback(int i) {
  if (i < 1) throw StateError('dbAt(0) must not be requested');
  return 20 * math.log(i / _max) / math.ln10;
}

void main() {
  group('fineVolumeStep', () {
    for (final entry in {'realistic': _realistic, 'fallback': _fallback}.entries) {
      for (final n in [30, 50, 75, 100]) {
        test('${entry.key} curve, $n levels: strictly rising, trim <= 0', () {
          var level = 0;
          double? previous;
          for (var k = 1; k <= n; k++) {
            final step = fineVolumeStep(
              level: level,
              levels: n,
              up: true,
              maxIndex: _max,
              dbAt: entry.value,
            );
            expect(step.level, level + 1);
            expect(step.systemIndex, inInclusiveRange(1, _max));
            expect(step.trimDb, lessThanOrEqualTo(1e-9));
            final effective = entry.value(step.systemIndex) + step.trimDb;
            if (previous != null) {
              expect(effective, greaterThan(previous),
                  reason: 'level ${step.level} of $n');
            }
            previous = effective;
            level = step.level;
          }
          expect(level, n);
        });
      }
    }

    test('level 0 is system index 0, no trim', () {
      final s = fineVolumeStep(
        level: 1, levels: 30, up: false, maxIndex: _max, dbAt: _realistic);
      expect(s.level, 0);
      expect(s.systemIndex, 0);
      expect(s.trimDb, 0);
    });

    test('top level is the system maximum, no trim', () {
      final s = fineVolumeStep(
        level: 99, levels: 100, up: true, maxIndex: _max, dbAt: _realistic);
      expect(s.level, 100);
      expect(s.systemIndex, _max);
      expect(s.trimDb, 0);
    });

    test('clamps at both ends', () {
      final low = fineVolumeStep(
        level: 0, levels: 50, up: false, maxIndex: _max, dbAt: _realistic);
      expect(low.level, 0);
      final high = fineVolumeStep(
        level: 50, levels: 50, up: true, maxIndex: _max, dbAt: _realistic);
      expect(high.level, 50);
      expect(high.systemIndex, _max);
    });

    test('a whole system index needs no trim', () {
      // 30 levels over 15 steps: level 10 is index 5 exactly.
      final s = fineVolumeStep(
        level: 9, levels: 30, up: true, maxIndex: _max, dbAt: _realistic);
      expect(s.systemIndex, 5);
      expect(s.trimDb, 0);
    });

    test('between two indices the system index rounds up and trim is negative',
        () {
      // 30 levels: level 11 -> t = 5.5, index 6, halfway in dB between 5 and 6.
      final s = fineVolumeStep(
        level: 10, levels: 30, up: true, maxIndex: _max, dbAt: _realistic);
      expect(s.systemIndex, 6);
      final mid = (_realistic(5) + _realistic(6)) / 2;
      expect(s.trimDb, closeTo(mid - _realistic(6), 1e-9));
    });

    test('below the first index the trim follows 20*log10(t)', () {
      // 100 levels: level 1 -> t = 0.15, index 1.
      final s = fineVolumeStep(
        level: 0, levels: 100, up: true, maxIndex: _max, dbAt: _realistic);
      expect(s.systemIndex, 1);
      expect(s.trimDb, closeTo(20 * math.log(0.15) / math.ln10, 1e-9));
    });

    test('stepping down mirrors stepping up', () {
      for (final n in [30, 100]) {
        for (var l = 1; l <= n; l++) {
          final down = fineVolumeStep(
            level: l, levels: n, up: false, maxIndex: _max, dbAt: _realistic);
          final up = fineVolumeStep(
            level: l - 1, levels: n, up: true, maxIndex: _max, dbAt: _realistic);
          expect(up.level, l);
          expect(down.level, l - 1);
          final again = fineVolumeStep(
            level: l - 2 < 0 ? 0 : l - 2,
            levels: n,
            up: true,
            maxIndex: _max,
            dbAt: _realistic,
          );
          if (l >= 2) expect(again.level, l - 1);
        }
      }
    });
  });

  group('fineLevelFromIndex', () {
    test('maps an index to the nearest level', () {
      expect(fineLevelFromIndex(index: 0, maxIndex: 15, levels: 30), 0);
      expect(fineLevelFromIndex(index: 15, maxIndex: 15, levels: 30), 30);
      expect(fineLevelFromIndex(index: 5, maxIndex: 15, levels: 100), 33);
      expect(fineLevelFromIndex(index: 8, maxIndex: 15, levels: 50), 27);
    });

    test('stays in range and survives a zero maximum', () {
      expect(fineLevelFromIndex(index: 99, maxIndex: 15, levels: 30), 30);
      expect(fineLevelFromIndex(index: 3, maxIndex: 0, levels: 30), 0);
    });
  });
}
