import 'dart:math' as math;

/// Ease-in-out: half minus half cosine. [t] is clamped to 0..1.
double cosEase(double t) {
  final x = t.clamp(0.0, 1.0);
  return 0.5 - 0.5 * math.cos(math.pi * x);
}

/// Ease-out quart. [t] is clamped to 0..1.
double quartOut(double t) {
  final x = 1 - t.clamp(0.0, 1.0);
  return 1 - x * x * x * x;
}

/// Ease-out cubic. [t] is clamped to 0..1.
double cubicOut(double t) {
  final x = 1 - t.clamp(0.0, 1.0);
  return 1 - x * x * x;
}

/// Shared motion numbers for navigation. Section tags (T1, T4 ...) refer to
/// the reference player's motion record.
abstract final class MotionSpec {
  // --- Durations of the three clocks (record overview, T1, T2, T9) ---

  /// List page change, cos ease (record T1, T6).
  static const listPage = Duration(milliseconds: 250);

  /// Sibling / unrelated list switch and back pivot (record T7, T9).
  static const listSibling = Duration(milliseconds: 150);

  /// Container chrome when entering the player, quart ease (record T2).
  /// Applies only to tap-driven timers; a finger drag or the back key makes
  /// the container copy the list progress 1:1 instead (record T3, T4).
  static const containerEnterPlayer = Duration(milliseconds: 500);

  /// Container chrome when leaving the player, quart ease (record T1).
  /// Tap-driven only; finger or back key copies the list progress.
  static const containerLeavePlayer = Duration(milliseconds: 250);

  /// Mini-player row rise / sink, quart ease (record T1, T2).
  static const miniPlayer = Duration(milliseconds: 500);

  /// Distance the mini-player row travels from behind the buttons, dp
  /// (record T1).
  static const miniPlayerRise = 74.0;

  // --- Art drag (record T4) ---

  /// Touch slop before the drag starts, dp (record T4).
  static const dragSlop = 8.0;

  /// Art box side measured on the recorded phone, dp (record T4); it only
  /// scales the fling speed here. At runtime progress = (finger dy - slop) /
  /// the real art box side, the smaller of the player's available width and
  /// height (not the drawn cover's side). The page swipe divides by the list
  /// width instead (record T8).
  static const dragTravel = 360.0;

  /// Release commits when progress passes this (record T4, T8).
  static const commitProgress = 0.3;

  /// Release speed at which direction decides, dp/s (record T4).
  static const flingVelocity = 500.0;

  // p = gesture progress (0..1) at the moment the finger is released.
  // Settles are not scaled by any animation-speed setting.
  // Art drag (T4) and page swipe (T8):
  //   commit: cos ease over max(settleMinCommit, settleCommit * (1 - p));
  //   cancel: cos ease over max(settleMinCancel, settleCancel * p).
  // Pinch (T10) completes over zoomSettle * (1 - p) instead, and shares only
  // the cancel base (500 ms * p) and the two floors (100 ms / 167 ms).

  /// Timed commit settle base: 250 ms * (1 - p) (record T4).
  static const settleCommit = Duration(milliseconds: 250);

  /// Timed cancel settle base: 500 ms * p (record T4).
  static const settleCancel = Duration(milliseconds: 500);

  /// Floor for a timed commit settle: max(100 ms, 250 ms * (1 - p)) (record T4).
  static const settleMinCommit = Duration(milliseconds: 100);

  /// Floor for a timed cancel settle: max(167 ms, 500 ms * p) (record T4).
  static const settleMinCancel = Duration(milliseconds: 167);

  /// Constant-speed commit glide bounds, progress/s (record T4).
  static const glideMin = 4.0;
  static const glideMax = 8.0;

  /// Slowest constant-speed cancel glide, progress/s (record T4).
  static const cancelGlideMin = 3.5;

  // --- Layer zoom factors (record T1, T2, T6, T7) ---

  /// Player page end scale when leaving; pivot is the art item centre
  /// (record T1).
  static const playerExitScale = 1.25;

  /// Player page start scale when entering; pivot is the art item centre
  /// (record T2).
  static const playerEnterFrom = 0.75;

  /// Library start scale when entering from the player; pivot is the screen
  /// centre (record T1).
  static const libraryEnterFrom = 0.5;

  /// Library end scale when leaving to the player; pivot is the screen
  /// centre (record T2).
  static const libraryExitTo = 1.5;

  /// Old single-column list end scale when opening a child (record T6).
  static const listOpenOldTo = 1.5;

  /// Old grid minimum end scale when opening a child (record T6).
  static const gridOpenOldTo = 2.0;

  /// New single-column list start scale when opening a child (record T6).
  static const listNewFrom = 0.5;

  /// New list start scale when the opened page is a grid (record T6 and the
  /// follow-up recordings: 0.19 to 0.31 across devices). Single-column
  /// destinations start at [listNewFrom]. The new content's top-left starts on
  /// the tapped tile's top-left.
  static const gridOpenNewFrom = 0.25;

  /// Chrome views shrink to this while fading out, about their own centre
  /// (record T1, T4). Exceptions: cast button 0.65, search bar 0.9.
  static const chromeHideScale = 0.75;

  // --- Back at a root list (record T8) ---

  /// Rubber band at a root list (record T8): offset = 0.25 * list width *
  /// finger fraction (dx / width), i.e. a quarter of the finger travel.
  static const backRubberBand = 0.25;

  /// Return after release: cubicOut over T seconds, T = max(0.35, |offset| / 2)
  /// where offset is the unitless accumulated finger fraction (dx / width),
  /// so T is 0.35 s for any normal drag; not a spring (record T8).
  static const backRubberReturn = Duration(milliseconds: 350);

  // --- Pinch zoom (record T10, T11) ---

  /// Multiplier from span change to progress (record T10).
  static const zoomGain = 1.25;

  /// Base for the timed pinch settle: completion 500 ms * (1 - p), cancel
  /// 500 ms * p; floors reuse settleMinCommit / settleMinCancel (record T10).
  static const zoomSettle = Duration(milliseconds: 500);

  /// Slowest constant-speed pinch completion, progress/s; the clamp is [2, 8]
  /// (record T10). glideMin (4) does not apply to the pinch.
  static const zoomGlideMin = 2.0;

  /// Cap of the end-level rubber band scale (record T10: 0.0894).
  static const zoomRubberBand = 0.0894;

  /// Rubber band return: cubicOut over T seconds, T = max(0.35, |start| / 2)
  /// where start is the unitless scale overshoot at release (at most 0.0894),
  /// so T is always 0.35 s; not a spring (record T10).
  static const zoomEndReturn = Duration(milliseconds: 350);

  /// Zoom triggered from list options (record T11).
  static const zoomOptions = Duration(milliseconds: 250);
}
