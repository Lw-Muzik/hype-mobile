/// Deciding when the native FFT/PCM tap runs.
///
/// Extracted from `AppController` and tested on its own because the rule is no
/// longer "whatever the master switch says". The master switch is gone; the tap
/// is now implied by the surface that actually draws it, and getting the
/// implication wrong is invisible on screen — a tap left running costs CPU on
/// every audio buffer with nothing to show for it, and a tap wrongly stopped
/// leaves a visualizer frozen with no error anywhere.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/controllers/visualizer_tap.dart';

void main() {
  group('shouldRun', () {
    test('is false when no surface draws the visualizer', () {
      final tap = VisualizerTap();
      expect(tap.shouldRun, isFalse);
    });

    test('is true when only the player visual is on', () {
      final tap = VisualizerTap()..playerVisual = true;
      expect(tap.shouldRun, isTrue);
    });

    test('is false once the player visual goes away', () {
      final tap = VisualizerTap()..playerVisual = true;
      tap.playerVisual = false;
      expect(tap.shouldRun, isFalse);
    });

    test('is false while suspended, unless a remote viewer watches', () {
      final tap = VisualizerTap()
        ..playerVisual = true
        ..suspended = true;
      expect(tap.shouldRun, isFalse);
      tap.remoteVisual = true;
      expect(tap.shouldRun, isTrue);
    });
  });

  group('pendingPush', () {
    test('reports the first state so the native side is initialised', () {
      final tap = VisualizerTap();
      expect(tap.pendingPush(), isFalse,
          reason: 'native starts in an unknown state and must be told');
      expect(tap.pendingPush(), isNull, reason: 'already pushed');
    });

    test('reports nothing when the desired state has not changed', () {
      final tap = VisualizerTap();
      tap.pendingPush();

      tap.playerVisual = true;
      expect(tap.pendingPush(), isTrue);
      expect(tap.pendingPush(), isNull);
      expect(tap.pendingPush(), isNull);
    });

    test('pushes again after the state returns to a previous value', () {
      final tap = VisualizerTap();
      tap.pendingPush();

      tap.playerVisual = true;
      expect(tap.pendingPush(), isTrue);

      tap.playerVisual = false;
      expect(tap.pendingPush(), isFalse);
    });
  });

  group('suspend / resume', () {
    test('suspend stops the tap without forgetting what the user wanted', () {
      final tap = VisualizerTap()..playerVisual = true;
      tap.pendingPush();

      tap.suspended = true;
      expect(tap.shouldRun, isFalse);
      expect(tap.pendingPush(), isFalse);

      tap.suspended = false;
      expect(tap.shouldRun, isTrue);
      expect(tap.pendingPush(), isTrue);
    });

    test('resuming with every surface off leaves the tap off', () {
      final tap = VisualizerTap();
      tap.pendingPush();

      tap.suspended = true;
      expect(tap.pendingPush(), isNull, reason: 'it was already off');

      tap.suspended = false;
      expect(tap.pendingPush(), isNull);
    });
  });

  group('a Hype Connect viewer', () {
    test('turns the tap on with no surface on screen', () {
      final tap = VisualizerTap();
      tap.pendingPush();
      tap.remoteVisual = true;
      expect(tap.pendingPush(), isTrue);
      tap.remoteVisual = false;
      expect(tap.pendingPush(), isFalse);
    });

    test('keeps it on while the app is backgrounded', () {
      final tap = VisualizerTap()
        ..playerVisual = true
        ..remoteVisual = true;
      tap.pendingPush();
      tap.suspended = true;
      expect(tap.shouldRun, isTrue);
      expect(tap.pendingPush(), isNull);
      tap.remoteVisual = false;
      expect(tap.pendingPush(), isFalse, reason: 'now only the suspended surface');
    });
  });
}
