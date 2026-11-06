/// The route every library page rides: the old page zooms out and fades while
/// the new one zooms in and fades in, both on one cos-eased clock.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../library_page_key.dart';
import '../motion/page_layer.dart';
import '../motion_spec.dart';

/// Where the two layers of one page change pivot and how far they scale.
class ListGeometry {
  const ListGeometry({
    required this.oldPivot,
    required this.oldScale1,
    required this.newPivot,
    required this.newScale0,
  });

  /// Old page: scale 1 to [oldScale1] about [oldPivot] (layer pixels).
  final Offset oldPivot;
  final double oldScale1;

  /// New page: scale [newScale0] to 1 about [newPivot].
  final Offset newPivot;
  final double newScale0;
}

double _cosInverse(double e) {
  final x = e.clamp(0.0, 1.0);
  return math.acos(1 - 2 * x) / math.pi;
}

class _CosCurve extends Curve {
  const _CosCurve();

  @override
  double transformInternal(double t) => cosEase(t);
}

class ListPageRoute<T> extends PageRoute<T> {
  ListPageRoute({
    required this.builder,
    required this.key,
    this.morphFrom,
    this.sibling = false,
    this.instant = false,
    this.tappedRect,
    this.tappedIsGrid,
    this.destinationIsGrid = false,
    super.settings,
  });

  final WidgetBuilder builder;
  final LibraryPageKey key;

  /// Tag of the row or tile that opened this page, when there is one.
  final Object? morphFrom;

  /// An unrelated or sibling list: both layers pivot about the centre and the
  /// change takes the short clock.
  final bool sibling;

  /// Built in place with no animation on the way in (rebuilding a trail). It
  /// still animates when it is left.
  final bool instant;

  /// The tapped item's rectangle in the layer's own pixels.
  final Rect? tappedRect;

  /// Whether the tapped item is a tile in a grid (true) or a row (false).
  /// Null falls back to its shape: narrower than the list means a tile.
  final bool? tappedIsGrid;

  /// Whether the opened page is a grid; it decides the start scale. Starts
  /// from the page's kind and is corrected from the page's real zoom step once
  /// it has been laid out (the first frame is drawn at opacity 0).
  bool destinationIsGrid;

  /// While a finger swipes this page away the pivots move one list width in
  /// the swipe direction (+1 right, -1 left), so the page drifts with it.
  final ValueNotifier<int> swipeDir = ValueNotifier<int>(0);

  /// The header's resting rectangle in layer pixels, once measured. A grid
  /// open anchors the content under it on the tapped tile.
  Rect? headerRest;

  /// A flight for this page's leave has been started.
  bool flightStarted = false;

  ListPageRoute<dynamic>? _next;

  /// The route was popped from rest (its open had finished), so it is leaving
  /// by its back geometry. A pop in the middle of the open reverses the open's
  /// own mapping from where it is, so nothing jumps.
  bool _closing = false;

  /// Leaving by the back pivot: a sibling page, or one opened with no row to
  /// return to. Matched rows leave by the reverse of their open.
  bool get _backPivot => sibling || tappedRect == null;

  @override
  Duration get transitionDuration => instant
      ? Duration.zero
      : (sibling ? MotionSpec.listSibling : MotionSpec.listPage);

  @override
  Duration get reverseTransitionDuration =>
      _backPivot ? MotionSpec.listSibling : MotionSpec.listPage;

  @override
  bool didPop(T? result) {
    final fromRest = controller?.status == AnimationStatus.completed;
    final popped = super.didPop(result);
    if (popped) _closing = fromRest;
    return popped;
  }

  @override
  bool get opaque => true;

  @override
  bool get barrierDismissible => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Animation<double> createAnimation() => CurvedAnimation(
    parent: super.createAnimation(),
    curve: const _CosCurve(),
    reverseCurve: const _CosCurve(),
  );

  /// Puts the eased progress (0 closed, 1 open) at [e], for a finger drag.
  void setProgress(double e) {
    final c = controller;
    if (c != null) c.value = _cosInverse(e);
  }

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    _next = nextRoute is ListPageRoute ? nextRoute : null;
    super.didChangeNext(nextRoute);
  }

  @override
  void dispose() {
    swipeDir.dispose();
    super.dispose();
  }

  /// Layer geometry for a list of [size]. Once the route is closing, a
  /// sibling or unmatched page uses the back pivot (see [_backPivot]). Single
  /// column: the old page grows
  /// about the bottom edge of the tapped row. Grid: it grows until the tapped
  /// tile's corner reaches the origin, and the new content's top-left starts on
  /// the tile's. No tapped item: both about the centre. While a finger swipes
  /// ([dir] not 0) every page uses one look: the closing page shrinks to half
  /// and the revealed one settles from 1.5, both about a pivot one width off.
  ListGeometry geometry(Size size, {int dir = 0}) {
    final centre = Offset(size.width / 2, size.height / 2);
    if (dir != 0) {
      final pivot = centre + Offset(size.width * dir, 0);
      return ListGeometry(
        oldPivot: pivot,
        oldScale1: MotionSpec.listOpenOldTo,
        newPivot: pivot,
        newScale0: MotionSpec.listNewFrom,
      );
    }
    if (_closing && _backPivot) {
      // Closing page 1 to 0.5, the page revealed under it 1.5 to 1.
      return ListGeometry(
        oldPivot: centre,
        oldScale1: 1.5,
        newPivot: centre,
        newScale0: 0.5,
      );
    }
    if (sibling) {
      return ListGeometry(
        oldPivot: centre,
        oldScale1: 0.5,
        newPivot: centre,
        newScale0: 1.5,
      );
    }
    final newFrom = destinationIsGrid
        ? MotionSpec.gridOpenNewFrom
        : MotionSpec.listNewFrom;
    final t = tappedRect;
    if (t == null || size.isEmpty) {
      return ListGeometry(
        oldPivot: centre,
        oldScale1: MotionSpec.listOpenOldTo,
        newPivot: centre,
        newScale0: newFrom,
      );
    }
    final isGrid = tappedIsGrid ?? t.width < size.width * 0.9;
    if (!isGrid) {
      return ListGeometry(
        oldPivot: Offset(centre.dx, t.bottom),
        oldScale1: MotionSpec.listOpenOldTo,
        newPivot: centre,
        newScale0: newFrom,
      );
    }
    final s = math.max(
      MotionSpec.gridOpenOldTo,
      t.right <= 0 ? MotionSpec.gridOpenOldTo : size.width / t.right,
    );
    // The page point that must start on the tile's corner: the first row under
    // the header (the page's own corner until the header is measured).
    final q = headerRest?.bottomLeft ?? Offset.zero;
    return ListGeometry(
      oldPivot: t.topLeft * (s / (s - 1)),
      oldScale1: s,
      newPivot: q - (q - t.topLeft) / (1 - newFrom),
      newScale0: newFrom,
    );
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => Semantics(
    scopesRoute: true,
    explicitChildNodes: true,
    child: builder(context),
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // The same widget structure at all times, so the page keeps its state
    // when a route is pushed over it.
    final inner = LayoutBuilder(
      builder: (context, constraints) => ValueListenableBuilder<int>(
        valueListenable: swipeDir,
        builder: (context, dir, _) {
          final g = geometry(constraints.biggest, dir: dir);
          return PageLayer(
            progress: animation,
            scaleAt0: g.newScale0,
            scaleAt1: 1,
            opacityAt0: 0,
            opacityAt1: 1,
            pivot: g.newPivot,
            child: _PointerGate(
              animation: animation,
              secondaryAnimation: secondaryAnimation,
              child: child,
            ),
          );
        },
      ),
    );
    final next = _next;
    return LayoutBuilder(
      builder: (context, constraints) => ValueListenableBuilder<int>(
        valueListenable: next?.swipeDir ?? _never,
        builder: (context, dir, _) {
          final g = next?.geometry(constraints.biggest, dir: dir);
          return PageLayer(
            progress: secondaryAnimation,
            scaleAt0: 1,
            scaleAt1: g?.oldScale1 ?? 1,
            opacityAt0: 1,
            opacityAt1: next == null ? 1 : 0,
            pivot: g?.oldPivot ?? Offset.zero,
            child: inner,
          );
        },
      ),
    );
  }
}

final ValueNotifier<int> _never = ValueNotifier<int>(0);

/// Ignores pointers on a page while a transition is moving it: the page is
/// opening, or another page is opening or closing over it. Pointers still
/// reach the back-swipe detector above the navigator.
class _PointerGate extends StatefulWidget {
  const _PointerGate({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  State<_PointerGate> createState() => _PointerGateState();
}

class _PointerGateState extends State<_PointerGate> {
  bool _ignoring = false;

  bool _moving() =>
      widget.animation.status == AnimationStatus.forward ||
      widget.secondaryAnimation.status == AnimationStatus.forward ||
      widget.secondaryAnimation.status == AnimationStatus.reverse;

  void _onStatus(AnimationStatus _) {
    final now = _moving();
    if (now != _ignoring) setState(() => _ignoring = now);
  }

  @override
  void initState() {
    super.initState();
    _ignoring = _moving();
    widget.animation.addStatusListener(_onStatus);
    widget.secondaryAnimation.addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(_PointerGate old) {
    super.didUpdateWidget(old);
    if (old.animation != widget.animation) {
      old.animation.removeStatusListener(_onStatus);
      widget.animation.addStatusListener(_onStatus);
    }
    if (old.secondaryAnimation != widget.secondaryAnimation) {
      old.secondaryAnimation.removeStatusListener(_onStatus);
      widget.secondaryAnimation.addStatusListener(_onStatus);
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    widget.secondaryAnimation.removeStatusListener(_onStatus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      IgnorePointer(ignoring: _ignoring, child: widget.child);
}
