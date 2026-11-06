import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'package:eq_app/navigation/motion_spec.dart';

/// How a finger release settles a drag-driven progress value.
///
/// Velocities handed to [MotionProgress.release] are in progress per second,
/// positive toward the committed end (1).
class ReleaseRules {
  const ReleaseRules({
    required this.commitAt,
    required this.flingPerSecond,
    required this.settleCommit,
    required this.settleCancel,
    required this.minCommit,
    required this.minCancel,
    required this.glideMin,
    required this.glideMax,
    required this.cancelGlideMin,
    this.flipVelocity = false,
  });

  /// Progress beyond which a slow release commits.
  final double commitAt;

  /// Release speed (progress/s) at which direction alone decides.
  final double flingPerSecond;

  /// Timed settle base durations, scaled by the distance left.
  final Duration settleCommit;
  final Duration settleCancel;

  /// Floors for the timed settles.
  final Duration minCommit;
  final Duration minCancel;

  /// Constant-speed glide bounds (progress/s).
  final double glideMin;
  final double glideMax;

  /// Slowest constant-speed glide back to 0.
  final double cancelGlideMin;

  /// The settle sees the finger velocity with its sign reversed. This is how
  /// the reference player's horizontal back swipe behaves: commits fall through
  /// to the timed ease while a cancel above 0.2 glides at constant speed.
  final bool flipVelocity;

  /// The same rules for a drag whose full progress takes [extent] dp of finger
  /// travel (the real art box side or list width). Only the fling threshold
  /// depends on it: [MotionSpec.flingVelocity] dp/s becomes progress/s.
  ReleaseRules forExtent(double extent) => ReleaseRules(
    commitAt: commitAt,
    flingPerSecond: MotionSpec.flingVelocity / extent,
    settleCommit: settleCommit,
    settleCancel: settleCancel,
    minCommit: minCommit,
    minCancel: minCancel,
    glideMin: glideMin,
    glideMax: glideMax,
    cancelGlideMin: cancelGlideMin,
    flipVelocity: flipVelocity,
  );

  /// Dragging the album art (record T4), assuming the recorded 360 dp of
  /// travel; call [forExtent] with the real art side at runtime.
  static const ReleaseRules artDrag = ReleaseRules(
    commitAt: MotionSpec.commitProgress,
    flingPerSecond: MotionSpec.flingVelocity / MotionSpec.dragTravel,
    settleCommit: MotionSpec.settleCommit,
    settleCancel: MotionSpec.settleCancel,
    minCommit: MotionSpec.settleMinCommit,
    minCancel: MotionSpec.settleMinCancel,
    glideMin: MotionSpec.glideMin,
    glideMax: MotionSpec.glideMax,
    cancelGlideMin: MotionSpec.cancelGlideMin,
  );

  /// Horizontal back swipe (record T8): same numbers, reversed velocity sign.
  /// Call [forExtent] with the real list width at runtime.
  static const ReleaseRules backSwipe = ReleaseRules(
    commitAt: MotionSpec.commitProgress,
    flingPerSecond: MotionSpec.flingVelocity / MotionSpec.dragTravel,
    settleCommit: MotionSpec.settleCommit,
    settleCancel: MotionSpec.settleCancel,
    minCommit: MotionSpec.settleMinCommit,
    minCancel: MotionSpec.settleMinCancel,
    glideMin: MotionSpec.glideMin,
    glideMax: MotionSpec.glideMax,
    cancelGlideMin: MotionSpec.cancelGlideMin,
    flipVelocity: true,
  );
}

double _linear(double t) => t;

/// A 0..1 progress value that can be animated, dragged by a finger, and
/// settled after release. Ticker-based, so it follows frame time.
class MotionProgress extends ChangeNotifier implements ValueListenable<double> {
  MotionProgress({required TickerProvider vsync, double initial = 0})
    : _value = initial {
    _ticker = vsync.createTicker(_onTick);
  }

  late final Ticker _ticker;
  double _value;
  bool _fingerDriven = false;
  _Run? _run;

  @override
  double get value => _value;

  bool get isFingerDriven => _fingerDriven;

  bool get isAnimating => _run != null;

  void _set(double v) {
    if (v == _value) return;
    _value = v;
    notifyListeners();
  }

  /// Animates from the current value to [to]. A new run (or a drag) replaces
  /// the running one and continues from wherever the value is right now.
  ///
  /// Completes with true when the run reached [to], false when it was
  /// pre-empted by another [run], [beginDrag], [jumpTo] or [dispose].
  Future<bool> run({
    required double to,
    required Duration duration,
    required double Function(double) curve,
  }) {
    _fingerDriven = false;
    _cancelRun();
    if (duration <= Duration.zero || _value == to) {
      _set(to);
      return Future<bool>.value(true);
    }
    final run = _Run(_value, to, duration, curve);
    _run = run;
    _ticker.start();
    return run.done.future;
  }

  void _onTick(Duration elapsed) {
    final run = _run;
    if (run == null) return;
    final t = elapsed.inMicroseconds / run.duration.inMicroseconds;
    if (t >= 1) {
      _run = null;
      _ticker.stop();
      _set(run.to);
      run.done.complete(true);
    } else {
      _set(run.from + (run.to - run.from) * run.curve(t));
    }
  }

  void _cancelRun() {
    final run = _run;
    _run = null;
    if (_ticker.isActive) _ticker.stop();
    if (run != null && !run.done.isCompleted) run.done.complete(false);
  }

  void beginDrag() {
    _cancelRun();
    _fingerDriven = true;
  }

  /// Follows the finger. With [clamp] false the value may pass 0 or 1 (a soft
  /// overshoot); consumers clamp what they cannot show beyond the ends, and a
  /// release settles it back.
  void dragTo(double progress, {bool clamp = true}) {
    _fingerDriven = true;
    _set(clamp ? progress.clamp(0.0, 1.0) : progress);
  }

  void jumpTo(double v) {
    _cancelRun();
    _fingerDriven = false;
    _set(v);
  }

  /// Ends a drag and settles. Completes with true when it committed to 1,
  /// false when it cancelled back to 0, and null when something else (a new
  /// run, a drag, a jump or disposal) interrupted the settle.
  Future<bool?> release({
    required double velocityPerSecond,
    required ReleaseRules rules,
  }) async {
    final p = _value;
    final v = velocityPerSecond;
    final commit = v.abs() >= rules.flingPerSecond ? v > 0 : p > rules.commitAt;

    // The velocity the settle sees, dropped near the end it is heading to.
    var settleV = rules.flipVelocity ? -v : v;
    if ((commit && p > 0.8) || (!commit && p < 0.2)) settleV = 0;

    final double to;
    final Duration duration;
    final double Function(double) curve;
    if (commit) {
      to = 1;
      if (settleV > 0) {
        final speed = settleV.clamp(rules.glideMin, rules.glideMax);
        duration = _secs((1 - p) / speed);
        curve = _linear;
      } else {
        duration = _max(rules.minCommit, rules.settleCommit * (1 - p));
        curve = cosEase;
      }
    } else {
      to = 0;
      if (settleV < 0) {
        final speed = (-settleV).clamp(rules.cancelGlideMin, rules.glideMax);
        duration = _secs(p / speed);
        curve = _linear;
      } else {
        duration = _max(rules.minCancel, rules.settleCancel * p);
        curve = cosEase;
      }
    }
    final reached = await run(to: to, duration: duration, curve: curve);
    return reached ? commit : null;
  }

  static Duration _secs(double s) =>
      Duration(microseconds: (s * Duration.microsecondsPerSecond).round());

  static Duration _max(Duration a, Duration b) => a >= b ? a : b;

  bool _disposed = false;

  /// True once [dispose] ran.
  bool get isDisposed => _disposed;

  final List<VoidCallback> _disposeListeners = <VoidCallback>[];

  /// Calls [listener] once when this object is disposed. Unlike a value
  /// notification it does not wake value listeners, which may be mid-teardown
  /// (disposal normally happens inside State.dispose).
  void addDisposeListener(VoidCallback listener) =>
      _disposeListeners.add(listener);

  void removeDisposeListener(VoidCallback listener) =>
      _disposeListeners.remove(listener);

  @override
  void dispose() {
    _cancelRun();
    _ticker.dispose();
    _disposed = true;
    final pending = List<VoidCallback>.of(_disposeListeners);
    _disposeListeners.clear();
    for (final listener in pending) {
      listener();
    }
    super.dispose();
  }
}

class _Run {
  _Run(this.from, this.to, this.duration, this.curve);

  final double from;
  final double to;
  final Duration duration;
  final double Function(double) curve;
  final Completer<bool> done = Completer<bool>();
}
