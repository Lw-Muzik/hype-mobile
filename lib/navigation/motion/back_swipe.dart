import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'package:eq_app/navigation/motion_spec.dart';

/// Reports a mostly-horizontal drag as signed progress (distance beyond the
/// slop divided by the width, 1:1; negative for a leftward drag). Vertical
/// drags are left to scrollables, and so are horizontal drags over a
/// horizontal scrollable that can still scroll in that direction.
class BackSwipeDetector extends StatefulWidget {
  const BackSwipeDetector({
    super.key,
    required this.enabled,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    this.onCancel,
    required this.child,
  });

  final bool enabled;
  final VoidCallback onStart;

  /// Distance beyond the slop divided by the width, -1..1 (the sign is the
  /// direction of travel).
  final ValueChanged<double> onUpdate;

  /// Release velocity in progress per second (negative when moving left).
  final ValueChanged<double> onEnd;
  final VoidCallback? onCancel;
  final Widget child;

  @override
  State<BackSwipeDetector> createState() => _BackSwipeDetectorState();
}

class _BackSwipeDetectorState extends State<BackSwipeDetector> {
  // Kept on the state so a host rebuild mid-drag does not lose it.
  double _startX = 0;
  bool _started = false;

  /// A second finger ended this swipe; the rest of the sequence is ignored.
  bool _dead = false;

  double _width() {
    final size = context.size;
    return (size == null || size.width <= 0) ? 1.0 : size.width;
  }

  /// True when a horizontal scrollable under [position] can still scroll in
  /// the direction a drag of [dir] (+1 right, -1 left) moves it.
  bool _scrollableWantsDrag(Offset position, int dir) {
    bool found = false;
    void visit(Element element) {
      if (found) return;
      // A page covered by another route is still in the tree but not shown.
      if (element.widget is Offstage && (element.widget as Offstage).offstage) {
        return;
      }
      final render = element.renderObject;
      if (render is RenderBox && render.hasSize && render.attached) {
        final local = render.globalToLocal(position);
        if (!(Offset.zero & render.size).contains(local)) return;
      }
      if (element is StatefulElement && element.state is ScrollableState) {
        final state = element.state as ScrollableState;
        final pos = state.position;
        if (state.widget.axis == Axis.horizontal && pos.hasPixels) {
          final reversed = state.widget.axisDirection == AxisDirection.left;
          // A rightward drag moves the content toward its start (or its end
          // when reversed); a leftward drag the other way.
          final towardStart = (dir > 0) != reversed;
          final canScroll = towardStart
              ? pos.pixels > pos.minScrollExtent + 0.5
              : pos.pixels < pos.maxScrollExtent - 0.5;
          if (canScroll) {
            found = true;
            return;
          }
        }
      }
      element.debugVisitOnstageChildren(visit);
    }

    (context as Element).debugVisitOnstageChildren(visit);
    return found;
  }

  @override
  void didUpdateWidget(BackSwipeDetector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled && _started) {
      _started = false;
      // The recognizer is torn down with the gesture detector; report the
      // abandoned drag after this build instead of during it.
      final onCancel = widget.onCancel;
      if (onCancel != null) scheduleMicrotask(onCancel);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        _HorizontalSwipeRecognizer:
            GestureRecognizerFactoryWithHandlers<_HorizontalSwipeRecognizer>(
              _HorizontalSwipeRecognizer.new,
              (r) {
                r
                  ..yieldsTo = _scrollableWantsDrag
                  ..dragStartBehavior = DragStartBehavior.down
                  ..onSecondPointer = () {
                    // A pinch: hand the swipe back so the page settles where
                    // it was instead of following the second finger.
                    if (!_started) return;
                    _started = false;
                    _dead = true;
                    widget.onCancel?.call();
                  }
                  ..onStart = (d) {
                    _dead = false;
                    _startX = d.globalPosition.dx;
                    _started = true;
                    widget.onStart();
                  }
                  ..onUpdate = (d) {
                    if (_dead) return;
                    final travel = d.globalPosition.dx - _startX;
                    final beyond = travel.abs() - MotionSpec.dragSlop;
                    final p = (beyond / _width()).clamp(0.0, 1.0);
                    widget.onUpdate(travel < 0 ? -p : p);
                  }
                  ..onEnd = (d) {
                    if (_dead) return;
                    _started = false;
                    widget.onEnd(d.velocity.pixelsPerSecond.dx / _width());
                  }
                  ..onCancel = () {
                    if (!_started) return;
                    _started = false;
                    widget.onCancel?.call();
                  };
              },
            ),
      },
      child: widget.child,
    );
  }
}

/// Accepts after [MotionSpec.dragSlop] of horizontal travel that is larger than
/// the vertical travel, so a vertical scroll wins the arena.
class _HorizontalSwipeRecognizer extends HorizontalDragGestureRecognizer {
  _HorizontalSwipeRecognizer() {
    // A lone recognizer would otherwise be handed the pointer on release.
    onlyAcceptDragOnThreshold = true;
  }

  /// Returns true when the pointer should be left to a scrollable, given where
  /// it went down and its direction (+1 right, -1 left).
  bool Function(Offset globalPosition, int dir)? yieldsTo;

  /// Called when another finger lands after this recognizer has accepted.
  /// Before acceptance a second finger rejects the swipe instead.
  VoidCallback? onSecondPointer;
  bool _accepted = false;
  final Map<int, Offset> _down = <int, Offset>{};

  final Map<int, Offset> _moved = <int, Offset>{};
  Offset _latest = Offset.zero;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    final second = _down.isNotEmpty;
    _down[event.pointer] = event.position;
    _moved[event.pointer] = Offset.zero;
    _latest = Offset.zero;
    super.addAllowedPointer(event);
    if (!second) return;
    if (_accepted) {
      onSecondPointer?.call();
    } else {
      resolve(GestureDisposition.rejected);
    }
  }

  @override
  void acceptGesture(int pointer) {
    _accepted = true;
    super.acceptGesture(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _accepted = false;
    _down.clear();
    _moved.clear();
    super.didStopTrackingLastPointer(pointer);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      final total = (_moved[event.pointer] ?? Offset.zero) + event.delta;
      _moved[event.pointer] = total;
      _latest = total;
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _moved.remove(event.pointer);
      _down.remove(event.pointer);
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    final enough =
        _latest.dx.abs() > MotionSpec.dragSlop &&
        _latest.dx.abs() > _latest.dy.abs();
    if (!enough) return false;
    final down = _down.values.isEmpty ? null : _down.values.first;
    if (down != null &&
        (yieldsTo?.call(down, _latest.dx > 0 ? 1 : -1) ?? false)) {
      return false;
    }
    return true;
  }
}
