/// The shape of every fade Hype plays, and the loop that plays one.
///
/// Every fade ramps amplitude in a straight line — play/pause/seek and both
/// sides of a crossfade alike, gains summing to one, no equal-power curve. Hype has no access
/// to the samples — each player's volume is set from Dart — so a ramp here is
/// that straight line drawn in steps of [kFadeTick], fine enough (about sixty a
/// second) that no step is audible.
library;

import 'fade_cancellation.dart';

/// How often a fade sets a new volume.
const kFadeTick = Duration(milliseconds: 16);

/// The incoming track's gain at [progress] (0..1) through a crossfade.
double crossfadeInGain(double progress) => progress.clamp(0.0, 1.0);

/// The outgoing track's gain at [progress] (0..1) through a crossfade, for a
/// track that was at [from] when the blend began.
///
/// Both sides move at the same rate — one full sweep per crossfade length —
/// so a track that was already partly faded (a skip during a crossfade, or a
/// short crossfade whose old track began fading while the new one opened) is
/// gone that much sooner. A fade never restarts from the top; it carries on
/// from wherever the gain is.
double crossfadeOutGain(double progress, {double from = 1.0}) =>
    (from - progress.clamp(0.0, 1.0)).clamp(0.0, 1.0);

/// How long a ramp from [from] to [to] takes when a full 0→1 sweep takes
/// [fullMs].
///
/// A fade is a slope, not a duration: a pause pressed halfway through the fade
/// back in starts from half volume and so is over in half the time — which is
/// what makes an interrupted fade sound continuous rather than restarting.
Duration rampDuration(double from, double to, int fullMs) {
  final span = (to - from).abs().clamp(0.0, 1.0);
  return Duration(microseconds: (span * fullMs * 1000).round());
}

/// Moves a gain from [from] to [to] over [duration] in a straight line,
/// calling [apply] with each value.
///
/// Returns true when the ramp reached [to], false when [cancel] stopped it
/// first — in which case the gain is left wherever it had got to, for whatever
/// cancelled it to carry on from.
Future<bool> runRamp({
  required double from,
  required double to,
  required Duration duration,
  required void Function(double gain) apply,
  FadeCancellation? cancel,
  Duration tick = kFadeTick,
}) async {
  if (cancel?.isCancelled ?? false) return false;
  if (duration <= Duration.zero) {
    apply(to);
    return true;
  }
  final watch = Stopwatch()..start();
  final total = duration.inMicroseconds;
  // The first step is exactly [from]: a fade in from silence starts silent.
  var first = true;
  while (true) {
    final t = first ? 0.0 : (watch.elapsedMicroseconds / total).clamp(0.0, 1.0);
    first = false;
    apply(from + (to - from) * t);
    if (t >= 1.0) return true;
    if (cancel != null) {
      await cancel.wait(tick);
      if (cancel.isCancelled) return false;
    } else {
      await Future<void>.delayed(tick);
    }
  }
}
