/// The shape of a fade, and the loop that plays one.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/player/fade_cancellation.dart';
import 'package:eq_app/player/fade_curve.dart';

void main() {
  group('crossfade gains', () {
    test('a straight line each way', () {
      expect(crossfadeInGain(0), 0);
      expect(crossfadeInGain(0.25), 0.25);
      expect(crossfadeOutGain(0.25), 0.75);
      expect(crossfadeInGain(1), 1);
      expect(crossfadeOutGain(1), 0);
    });

    /// A fade never restarts from the top: a track already partly faded is
    /// gone that much sooner, at the same rate.
    test('the outgoing side carries on from its level', () {
      expect(crossfadeOutGain(0, from: 0.6), 0.6);
      expect(crossfadeOutGain(0.25, from: 0.6), closeTo(0.35, 1e-9));
      expect(crossfadeOutGain(0.6, from: 0.6), 0);
      expect(crossfadeOutGain(0.9, from: 0.6), 0);
    });

    test('clamped outside 0..1', () {
      expect(crossfadeInGain(-1), 0);
      expect(crossfadeOutGain(2), 0);
    });
  });

  group('ramp duration is a slope', () {
    test('a full sweep takes the full length', () {
      expect(rampDuration(0, 1, 400), const Duration(milliseconds: 400));
    });

    test('half way takes half as long', () {
      expect(rampDuration(0.5, 0, 400), const Duration(milliseconds: 200));
    });

    test('already there takes no time', () {
      expect(rampDuration(1, 1, 400), Duration.zero);
    });
  });

  group('runRamp', () {
    test('ends exactly on the target', () async {
      final seen = <double>[];
      final reached = await runRamp(
        from: 0,
        to: 1,
        duration: const Duration(milliseconds: 60),
        apply: seen.add,
        tick: const Duration(milliseconds: 5),
      );
      expect(reached, isTrue);
      expect(seen.first, 0);
      expect(seen.last, 1);
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]),
            reason: 'never steps backwards');
      }
    });

    test('zero length jumps straight there', () async {
      final seen = <double>[];
      await runRamp(from: 1, to: 0, duration: Duration.zero, apply: seen.add);
      expect(seen, [0]);
    });

    test('a cancel stops it where it was', () async {
      final cancel = FadeCancellation();
      final seen = <double>[];
      final ramp = runRamp(
        from: 1,
        to: 0,
        duration: const Duration(seconds: 10),
        apply: seen.add,
        cancel: cancel,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      cancel.cancel();
      expect(await ramp, isFalse);
      expect(seen.last, greaterThan(0.9), reason: 'left mid-ramp, not snapped');
    });

    test('cancelled before it starts does nothing', () async {
      final cancel = FadeCancellation()..cancel();
      final seen = <double>[];
      final reached = await runRamp(
        from: 0,
        to: 1,
        duration: const Duration(seconds: 1),
        apply: seen.add,
        cancel: cancel,
      );
      expect(reached, isFalse);
      expect(seen, isEmpty);
    });
  });
}
