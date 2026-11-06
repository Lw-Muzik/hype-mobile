import 'package:eq_app/navigation/zoom/zoom_physics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pinchProgress follows the record', () {
    expect(pinchProgress(span: 180, startSpan: 100, zoomIn: true), 1.0);
    expect(pinchProgress(span: 20, startSpan: 100, zoomIn: false), 1.0);
    expect(pinchProgress(span: 100, startSpan: 100, zoomIn: true), 0.0);
    expect(
      pinchProgress(span: 250, startSpan: 100, zoomIn: true),
      greaterThan(1),
    );
    expect(pinchProgress(span: 90, startSpan: 100, zoomIn: true), lessThan(0));
  });

  test('slow release decides by 0.3', () {
    final a = decideZoomRelease(
      progress: 0.31,
      spanVelocityDpPerSecond: 0,
      zoomIn: true,
      startSpan: 300,
    );
    expect(a.commit, isTrue);
    expect(a.duration, const Duration(milliseconds: 345));
    expect(a.glidePerSecond, isNull);
    final b = decideZoomRelease(
      progress: 0.29,
      spanVelocityDpPerSecond: 0,
      zoomIn: true,
      startSpan: 300,
    );
    expect(b.commit, isFalse);
    expect(b.duration, const Duration(milliseconds: 167));
  });

  test('floors', () {
    expect(
      decideZoomRelease(
        progress: 0.95,
        spanVelocityDpPerSecond: 0,
        zoomIn: true,
        startSpan: 300,
      ).duration,
      const Duration(milliseconds: 100),
    );
    expect(
      decideZoomRelease(
        progress: 0.5,
        spanVelocityDpPerSecond: 0,
        zoomIn: true,
        startSpan: 300,
      ).duration,
      const Duration(milliseconds: 250),
    );
    expect(
      decideZoomRelease(
        progress: 0.2,
        spanVelocityDpPerSecond: 0,
        zoomIn: true,
        startSpan: 300,
      ).duration,
      const Duration(milliseconds: 167),
    );
    expect(
      decideZoomRelease(
        progress: 0.0,
        spanVelocityDpPerSecond: 0,
        zoomIn: true,
        startSpan: 300,
      ).duration,
      const Duration(milliseconds: 167),
    );
  });

  test('fast release: direction decides, span-sign convention', () {
    // Spreading, zoom-in: commit with constant speed.
    final a = decideZoomRelease(
      progress: 0.5,
      spanVelocityDpPerSecond: 3000,
      zoomIn: true,
      startSpan: 300,
    );
    expect(a.commit, isTrue);
    expect(a.glidePerSecond, inInclusiveRange(2, 8));
    // Pinching, zoom-in: cancel, timed.
    final b = decideZoomRelease(
      progress: 0.5,
      spanVelocityDpPerSecond: -600,
      zoomIn: true,
      startSpan: 300,
    );
    expect(b.commit, isFalse);
    expect(b.glidePerSecond, isNull);
    // Pinching, zoom-out: commit but timed (span-sign convention).
    final c = decideZoomRelease(
      progress: 0.5,
      spanVelocityDpPerSecond: -3000,
      zoomIn: false,
      startSpan: 300,
    );
    expect(c.commit, isTrue);
    expect(c.glidePerSecond, isNull);
    expect(c.duration, const Duration(milliseconds: 250));
    // Spreading, zoom-out: cancel at constant speed.
    final d = decideZoomRelease(
      progress: 0.5,
      spanVelocityDpPerSecond: 3000,
      zoomIn: false,
      startSpan: 300,
    );
    expect(d.commit, isFalse);
    expect(d.glidePerSecond, inInclusiveRange(-8, -3.5));
    // Velocity dropped when completing past 0.8.
    expect(
      decideZoomRelease(
        progress: 0.9,
        spanVelocityDpPerSecond: 3000,
        zoomIn: true,
        startSpan: 300,
      ).glidePerSecond,
      isNull,
    );
  });

  test('rubber band', () {
    expect(zoomBandDeviation(raw: 0.5, zoomIn: true), 0);
    expect(zoomBandDeviation(raw: 1.2, zoomIn: true), greaterThan(0));
    expect(
      zoomBandDeviation(raw: 1.25, zoomIn: false),
      closeTo(-0.0258, 0.001),
    );
    expect(
      zoomBandDeviation(raw: -1.25, zoomIn: true),
      closeTo(-0.0577, 0.001),
    );
    expect(zoomBandDeviation(raw: -5, zoomIn: false), closeTo(0.0894, 1e-4));
    expect(zoomEndBandDeviation(1.72), closeTo(0.0894, 0.001));
    expect(zoomEndBandDeviation(0), closeTo(-0.0577, 0.001));
    expect(zoomEndBandDeviation(1), 0);
  });

  test('exact glide values and durations', () {
    final a = decideZoomRelease(
      progress: 0.5,
      spanVelocityDpPerSecond: 3000,
      zoomIn: true,
      startSpan: 300,
    );
    expect(a.glidePerSecond, closeTo(2.5, 1e-9));
    expect(a.duration, const Duration(milliseconds: 200));
    final b = decideZoomRelease(
      progress: 0.5,
      spanVelocityDpPerSecond: 6000,
      zoomIn: true,
      startSpan: 300,
    );
    expect(b.glidePerSecond, closeTo(5.0, 1e-9));
    expect(b.duration, const Duration(milliseconds: 100));
    // Clamped at 8/s: 20000 dp/s -> 16.7/s.
    final c = decideZoomRelease(
      progress: 0.5,
      spanVelocityDpPerSecond: 20000,
      zoomIn: true,
      startSpan: 300,
    );
    expect(c.glidePerSecond, 8.0);
    // Slow fling at the floor of 2/s: 1000 dp/s -> 0.83/s clamps up to 2.
    final d = decideZoomRelease(
      progress: 0.5,
      spanVelocityDpPerSecond: 1000,
      zoomIn: true,
      startSpan: 300,
    );
    expect(d.glidePerSecond, 2.0);
    expect(d.duration, const Duration(milliseconds: 250));
  });

  test('cancel glide: clamped to at most -3.5/s, duration p / speed', () {
    final a = decideZoomRelease(
      progress: 0.5,
      spanVelocityDpPerSecond: 3000,
      zoomIn: false,
      startSpan: 300,
    );
    expect(a.commit, isFalse);
    expect(a.glidePerSecond, -3.5);
    expect(a.duration.inMicroseconds, (0.5 / 3.5 * 1e6).round());
    final b = decideZoomRelease(
      progress: 0.5,
      spanVelocityDpPerSecond: 9000,
      zoomIn: false,
      startSpan: 300,
    );
    expect(b.glidePerSecond, closeTo(-7.5, 1e-9));
  });

  test('cancel below 0.2 drops the velocity', () {
    final a = decideZoomRelease(
      progress: 0.1,
      spanVelocityDpPerSecond: 3000,
      zoomIn: false,
      startSpan: 300,
    );
    expect(a.commit, isFalse);
    expect(a.glidePerSecond, isNull);
    expect(a.duration, const Duration(milliseconds: 167));
    // At exactly 0.2 it is kept.
    final b = decideZoomRelease(
      progress: 0.2,
      spanVelocityDpPerSecond: 3000,
      zoomIn: false,
      startSpan: 300,
    );
    expect(b.glidePerSecond, isNotNull);
  });
}
