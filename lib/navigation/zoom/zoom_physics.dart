import 'dart:math' as math;

import '../motion_spec.dart';

/// Raw (unclamped) pinch progress from the finger span. [startSpan] is the
/// span captured when the pinch crossed the touch slop. Spreading drives a
/// zoom-in, pinching a zoom-out; both reach 1.0 at the end of the gesture.
/// Callers clamp to 0..1 for the visual and use the excess for the rubber band.
double pinchProgress({
  required double span,
  required double startSpan,
  required bool zoomIn,
}) {
  final base = math.max(1.0, startSpan);
  final delta = zoomIn ? span - base : base - span;
  return MotionSpec.zoomGain * delta / base;
}

/// How a released pinch settles.
class ZoomRelease {
  const ZoomRelease({
    required this.commit,
    required this.duration,
    this.glidePerSecond,
  });

  /// True when the zoom completes, false when it falls back.
  final bool commit;

  /// Time the settle takes.
  final Duration duration;

  /// When non-null the settle runs at this constant progress speed (signed,
  /// per second) instead of the eased timed curve.
  final double? glidePerSecond;
}

/// Release rules: a fast span change decides by direction, a slow one by
/// whether progress passed the commit line. [spanVelocityDpPerSecond] is
/// positive while the fingers spread. [startSpan] converts it to a progress
/// speed for the constant-speed branches.
///
/// The constant-speed branches only ever trigger for spreading fingers (a
/// span-sign convention of the spec); a fast pinch-in always gets the timed
/// settle.
ZoomRelease decideZoomRelease({
  required double progress,
  required double spanVelocityDpPerSecond,
  required bool zoomIn,
  required double startSpan,
}) {
  final p = progress.clamp(0.0, 1.0);
  final v = spanVelocityDpPerSecond;
  final fast = v.abs() >= MotionSpec.flingVelocity;
  final spreading = v > 0;

  late final bool commit;
  var speed = 0.0;
  if (fast) {
    commit = spreading == zoomIn;
    final ratioSpeed = v / math.max(1.0, startSpan);
    speed = (zoomIn == spreading) ? ratioSpeed : -ratioSpeed;
  } else {
    commit = p > MotionSpec.commitProgress;
  }
  speed /= 4;
  if ((commit && p > 0.8) || (!commit && p < 0.2)) speed = 0;

  if (commit && speed > 0) {
    final g = speed.clamp(MotionSpec.zoomGlideMin, MotionSpec.glideMax);
    return ZoomRelease(
      commit: true,
      duration: _secondsToDuration((1 - p) / g),
      glidePerSecond: g,
    );
  }
  if (!commit && speed < 0) {
    final g = speed.clamp(-MotionSpec.glideMax, -MotionSpec.cancelGlideMin);
    return ZoomRelease(
      commit: false,
      duration: _secondsToDuration(p / -g),
      glidePerSecond: g,
    );
  }

  final base = MotionSpec.zoomSettle.inMilliseconds;
  final ms = commit
      ? math.max(
          MotionSpec.settleMinCommit.inMilliseconds,
          (base * (1 - p)).round(),
        )
      : math.max(MotionSpec.settleMinCancel.inMilliseconds, (base * p).round());
  return ZoomRelease(
    commit: commit,
    duration: Duration(milliseconds: ms),
  );
}

Duration _secondsToDuration(double s) =>
    Duration(microseconds: (s * Duration.microsecondsPerSecond).round());

double _band(double overshoot, double scale) {
  final s = 0.2 * math.sqrt(0.2 * math.min(overshoot, scale) / scale);
  return math.min(s, MotionSpec.zoomRubberBand);
}

/// Item scale deviation (scale = 1 + result) while [raw] progress is outside
/// 0..1 inside a transition. Zero when inside.
double zoomBandDeviation({required double raw, required bool zoomIn}) {
  if (raw > 1) {
    final s = _band(raw - 1, 3);
    return zoomIn ? s : -s;
  }
  if (raw < 0) {
    return zoomIn ? -_band(-raw, 3) : _band(-raw, 0.9);
  }
  return 0;
}

/// Item scale deviation at an end step (no level to move to), from the span
/// ratio `span / startSpan`. Spreading grows the items, pinching shrinks them.
double zoomEndBandDeviation(double ratio) {
  if (ratio > 1) return _band(MotionSpec.zoomGain * (ratio - 1), 0.9);
  if (ratio < 1) return -_band(MotionSpec.zoomGain * (1 - ratio), 3);
  return 0;
}
