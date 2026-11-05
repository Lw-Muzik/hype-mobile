/// When an end-of-track crossfade starts opening the next track.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/player/crossfade_trigger.dart';

void main() {
  bool trigger({
    int fadeMs = 5000,
    int leadMs = 3000,
    Duration? duration = const Duration(seconds: 180),
    Duration position = const Duration(seconds: 172),
  }) =>
      shouldPrepareCrossfade(
        fadeMs: fadeMs,
        leadMs: leadMs,
        duration: duration,
        position: position,
      );

  test('opens the next track a lead ahead of the fade', () {
    // Fade due at 175 s; opened from 172 s.
    expect(trigger(), isTrue);
    expect(trigger(position: const Duration(milliseconds: 171999)), isFalse);
  });

  test('still true inside the fade itself', () {
    expect(trigger(position: const Duration(seconds: 178)), isTrue);
  });

  test('a longer preload opens it earlier', () {
    expect(trigger(leadMs: 5000, position: const Duration(seconds: 170)),
        isTrue);
    expect(trigger(leadMs: 3000, position: const Duration(seconds: 170)),
        isFalse);
  });

  test('no fade, no trigger', () {
    expect(trigger(fadeMs: 0, position: const Duration(seconds: 179)), isFalse);
  });

  test('nothing to time it against without a duration', () {
    expect(trigger(duration: null), isFalse);
  });

  /// A track crossfades out only if it is longer than the crossfade plus five
  /// seconds.
  test('a track no longer than the crossfade plus 5 s does not crossfade', () {
    expect(crossfadeFits(const Duration(seconds: 10), 5000), isFalse);
    expect(crossfadeFits(const Duration(milliseconds: 10001), 5000), isTrue);
    expect(
      trigger(
        fadeMs: 5000,
        duration: const Duration(seconds: 10),
        position: const Duration(seconds: 9),
      ),
      isFalse,
    );
    expect(
      trigger(
        fadeMs: 5000,
        duration: const Duration(seconds: 11),
        position: const Duration(seconds: 3),
      ),
      isTrue,
      reason: 'long enough to fade, and already inside the lead',
    );
  });

  test('no fade never fits', () {
    expect(crossfadeFits(const Duration(minutes: 3), 0), isFalse);
    expect(crossfadeFits(null, 5000), isFalse);
  });

  group('preloading a gapless handoff', () {
    bool handoff(int preloadMs, Duration position) => shouldPrepareHandoff(
          preloadMs: preloadMs,
          duration: const Duration(seconds: 200),
          position: position,
        );

    test('opens the next track the preload before the end', () {
      expect(handoff(1500, const Duration(milliseconds: 198500)), isTrue);
      expect(handoff(1500, const Duration(milliseconds: 198499)), isFalse);
    });

    test('a preload of zero opens nothing early', () {
      expect(handoff(0, const Duration(seconds: 199)), isFalse);
    });
  });
}
