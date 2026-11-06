import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'layer_snapshot.dart';
import 'motion_progress.dart';

/// Scales and fades [child] linearly with [progress] about [pivot].
///
/// The child is built once; only the transform and opacity change per tick.
/// Strictly between its two ends the child is drawn from a snapshot picture
/// (see [LayerSnapshot]); at either end it is the live widget.
class PageLayer extends StatelessWidget {
  const PageLayer({
    super.key,
    required this.progress,
    required this.scaleAt0,
    required this.scaleAt1,
    required this.opacityAt0,
    required this.opacityAt1,
    required this.pivot,
    required this.child,
  });

  final ValueListenable<double> progress;
  final double scaleAt0;
  final double scaleAt1;
  final double opacityAt0;
  final double opacityAt1;

  /// Pivot in the layer's local pixels.
  final Offset pivot;
  final Widget child;

  bool get _fingerDriven {
    final p = progress;
    return p is MotionProgress && p.isFingerDriven;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: progress,
      child: child,
      builder: (context, p, child) {
        final scale = scaleAt0 + (scaleAt1 - scaleAt0) * p;
        final opacity = (opacityAt0 + (opacityAt1 - opacityAt0) * p).clamp(
          0.0,
          1.0,
        );
        return Opacity(
          opacity: opacity,
          child: Transform(
            transform: Matrix4.diagonal3Values(scale, scale, 1),
            origin: pivot,
            child: LayerSnapshot(
              // Not while a finger drives a move: the page underneath is
              // still being filled in then (the trail pushed, the playing row
              // revealed) and a frozen picture would jump at the end. The
              // settle that follows snapshots.
              snapshotting: p > 0 && p < 1 && !_fingerDriven,
              child: RepaintBoundary(child: child!),
            ),
          ),
        );
      },
    );
  }
}
