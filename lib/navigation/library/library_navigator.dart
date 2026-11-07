/// The stack of library pages: a nested [Navigator] whose routes zoom and fade
/// in the reference player's style, with finger-driven back swipes.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PredictiveBackEvent, SwipeEdge;
import 'package:flutter/widgets.dart';

import '../app_nav.dart';
import '../library_page_key.dart';
import '../library_path.dart';
import '../motion/back_swipe.dart';
import '../motion/morph.dart';
import '../motion/motion_progress.dart';
import '../motion_spec.dart';
import '../zoom/zoom_step_list.dart';
import '../zoom/zoom_steps.dart';
import 'library_tags.dart';
import 'list_page_route.dart';
import 'page_factory.dart';

/// Hosts the library's pages above [root] (the Places list).
class LibraryNavigator extends StatefulWidget {
  const LibraryNavigator({
    required GlobalKey<LibraryNavigatorState> key,
    required this.root,
    this.onRootSwipeStart,
    this.onRootSwipeUpdate,
    this.onRootSwipeEnd,
    this.onRootSwipeCancel,
  }) : super(key: key);

  final Widget root;

  /// A rightward swipe at the root (Places) belongs to the shell, which moves
  /// from the library to the player with the finger. Progress is 0 to 1 and the
  /// end velocity is in progress per second. [onRootSwipeStart] returns false
  /// to refuse. When none are given the root rubber-bands instead.
  final bool Function()? onRootSwipeStart;
  final ValueChanged<double>? onRootSwipeUpdate;
  final ValueChanged<double>? onRootSwipeEnd;

  /// The swipe was cancelled (a second finger, a lost touch, the system): a
  /// cancel is never a commit. Without it a cancel ends as a release with no
  /// velocity.
  final VoidCallback? onRootSwipeCancel;

  @override
  State<LibraryNavigator> createState() => LibraryNavigatorState();
}

/// 1 - the wrapped animation, so a closing page can drive a flight.
class _Mirror extends ChangeNotifier implements ValueListenable<double> {
  _Mirror(this._source) {
    _source.addListener(notifyListeners);
  }

  final ValueListenable<double> _source;

  @override
  double get value => 1 - _source.value;

  @override
  void dispose() {
    _source.removeListener(notifyListeners);
    super.dispose();
  }
}

class LibraryNavigatorState extends State<LibraryNavigator>
    with TickerProviderStateMixin, WidgetsBindingObserver
    implements LibraryNavigatorController {
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  final GlobalKey _layerKey = GlobalKey();
  final List<ListPageRoute<dynamic>> _stack = <ListPageRoute<dynamic>>[];
  late final _StackObserver _observer = _StackObserver(this);

  /// Routes whose pop animation is still running.
  int _busy = 0;

  // Back swipe (finger or predictive back).
  MotionProgress? _swipe;
  ListPageRoute<dynamic>? _swipeRoute;
  ListPageRoute<dynamic>? _swipeParent;
  int _dir = 0;
  bool _active = false;
  bool _settling = false;
  bool _regrab = false;
  double _base = 0;
  bool _rootHook = false;
  bool _rubberMode = false;

  /// A system back gesture owns the swipe until it has settled. One edge swipe
  /// also reaches the swipe detector until the system takes its pointers, in
  /// either order; those callbacks are ignored here, or the swipe would start
  /// twice and leave the navigator stuck in a user gesture, with every page in
  /// it ignoring touches.
  bool _systemSwipe = false;

  /// The route on top of the nested navigator (a sheet or menu is not a page).
  Route<dynamic>? _top;

  /// Every route in the nested navigator, bottom first (a route that is
  /// animating out stays until it has finished).
  final List<Route<dynamic>> _routes = <Route<dynamic>>[];

  /// Bumped by every open and every showPath; a rebuild that finds it changed
  /// stops, so the newest request wins.
  int _gen = 0;
  late final AnimationController _rubberReturn = AnimationController(
    vsync: this,
    duration: MotionSpec.backRubberReturn,
  )..addListener(_onRubberReturn);
  final ValueNotifier<double> _rubber = ValueNotifier<double>(0);
  double _rubberStart = 0;

  /// Lets the shell hand system back gestures (Android predictive back) to the
  /// stack. Off by default: the shell decides when the library is on screen.
  bool systemBackEnabled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _swipe?.dispose();
    _rubberReturn.dispose();
    _rubber.dispose();
    super.dispose();
  }

  NavigatorState? get _nav => _navKey.currentState;

  // --- LibraryNavigatorController ---

  /// The page on top of the stack (tests read its geometry).
  @visibleForTesting
  ListPageRoute<dynamic>? get topRoute => _stack.lastOrNull;

  @override
  List<LibraryPageKey> get path => [for (final r in _stack.skip(1)) r.key];

  @override
  bool get canPop =>
      _stack.length > 1 ||
      _busy > 0 ||
      (_top != null && _top is! ListPageRoute);

  bool get _pageOnTop => _top == null || identical(_top, _stack.lastOrNull);

  /// What a page is before it has been laid out: pages without a zoom list
  /// are card grids (Cloud, YouTube Music) or lists (everything else). Pages
  /// with a zoom list are corrected from their current step.
  static bool _isGridPage(LibraryPageKey key) =>
      key.kind == 'place' &&
      const {'cloud', 'youtube'}.contains(key.args['id']);

  /// The current zoom step's kind of the page's [ZoomStepList], if it has one.
  bool? _zoomKindOf(ListPageRoute<dynamic> route) {
    final ctx = route.subtreeContext;
    if (ctx == null) return null;
    bool? grid;
    void visit(Element e) {
      if (grid != null) return;
      final w = e.widget;
      if (w is ZoomStepList) {
        grid = w.steps[w.step.clamp(0, w.steps.length - 1)] is GridZoomStep;
        return;
      }
      e.visitChildren(visit);
    }

    (ctx as Element).visitChildren(visit);
    return grid;
  }

  /// Sets the start scale from the destination's real type, retrying for a few
  /// frames while a lazily built list is not there yet. [then] runs once the
  /// kind is final for the first time: a corrected kind gets one frame to
  /// paint before [then] measures anything; a page with no zoom list yet runs
  /// it at once (the retries carry on without it).
  void _settleDestinationKind(
    ListPageRoute<dynamic> route, {
    int tries = 0,
    VoidCallback? then,
  }) {
    if (!mounted || !route.isActive) return;
    final grid = _zoomKindOf(route);
    if (grid != null) {
      final changed = route.destinationIsGrid != grid;
      route.destinationIsGrid = grid;
      if (then == null) return;
      if (!changed) {
        then();
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) then();
      });
      WidgetsBinding.instance.scheduleFrame();
      return;
    }
    if (tries < 3) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _settleDestinationKind(route, tries: tries + 1),
      );
    }
    then?.call();
  }

  @override
  Future<void> openPage(
    Widget page, {
    required LibraryPageKey key,
    Object? morphFrom,
    bool sibling = false,
  }) {
    final nav = _nav;
    if (nav == null) return Future<void>.value();
    _gen++;
    final tapped = morphFrom == null ? null : _tagRectInLayer(morphFrom);
    final pagePath = [...path, key];
    final route = ListPageRoute<void>(
      builder: (_) => LibraryPathScope(path: pagePath, child: page),
      key: key,
      morphFrom: morphFrom,
      sibling: sibling,
      tappedRect: tapped,
      destinationIsGrid: _isGridPage(key),
    );
    final done = nav.push<void>(route);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // The flight measures the header under the start scale, so it waits
      // until the kind is settled.
      _settleDestinationKind(
        route,
        then: morphFrom == null ? null : () => _flyIn(route, morphFrom),
      );
    });
    return done;
  }

  @override
  Future<bool> pop() async {
    final nav = _nav;
    if (nav == null) return false;
    if (_busy > 0 || _swipe != null) return true;
    // A sheet or menu on the nested navigator closes first.
    if (!_pageOnTop) {
      await nav.maybePop();
      return true;
    }
    if (_stack.length < 2) return false;
    final route = _stack.last;
    final completed = route.completed;
    nav.pop();
    await completed;
    return true;
  }

  @override
  Future<void> showPath(List<LibraryPageKey> target) async {
    final gen = ++_gen;
    // Pages already open on the way to [target] stay as they are, so only what
    // lies past them is built: builders query the library, and the move that
    // asked for this trail waits for it.
    final current = path;
    var keep = 0;
    while (keep < current.length &&
        keep < target.length &&
        current[keep] == target[keep]) {
      keep++;
    }
    final pages = <(LibraryPageKey, Widget)>[];
    for (final key in target.skip(keep)) {
      final page = await buildLibraryPage(key, context: context);
      if (page == null) break;
      pages.add((key, page));
    }
    final nav = _nav;
    // A newer showPath, or a page the user opened meanwhile, wins.
    if (!mounted || nav == null || gen != _gen) return;
    for (final route in _stack.skip(keep + 1).toList().reversed) {
      nav.removeRoute(route);
    }
    for (var i = 0; i < pages.length; i++) {
      final (key, page) = pages[i];
      final pagePath = [
        ...target.take(keep),
        for (final p in pages.take(i + 1)) p.$1,
      ];
      final route = ListPageRoute<void>(
        builder: (_) => LibraryPathScope(path: pagePath, child: page),
        key: key,
        instant: true,
        destinationIsGrid: _isGridPage(key),
      );
      nav.push<void>(route);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _settleDestinationKind(route),
      );
    }
  }

  // --- Shared elements ---

  MorphScopeState? get _scope => MorphScope.maybeOf(context);

  Rect? _tagRectInLayer(Object tag) {
    final scope = _scope;
    final rect = scope?.rectOf(tag);
    if (scope == null || rect == null) return null;
    final layer = _layerKey.currentContext?.findRenderObject();
    final scopeBox = scope.context.findRenderObject();
    if (layer is! RenderBox || scopeBox is! RenderBox) return null;
    final topLeft = layer.globalToLocal(scopeBox.localToGlobal(rect.topLeft));
    return topLeft & rect.size;
  }

  Rect _layerRectToScope(Rect r) {
    final scope = _scope;
    final layer = _layerKey.currentContext?.findRenderObject();
    final scopeBox = scope?.context.findRenderObject();
    if (layer is! RenderBox || scopeBox is! RenderBox) return r;
    final topLeft = scopeBox.globalToLocal(layer.localToGlobal(r.topLeft));
    return topLeft & r.size;
  }

  Size get _layerSize {
    final box = _layerKey.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size : Size.zero;
  }

  void _flyIn(ListPageRoute<dynamic> route, Object itemTagValue) {
    if (!mounted) return;
    final scope = _scope;
    final anim = route.animation;
    if (scope == null || anim == null || !route.isActive) return;
    final header = headerTag(route.key);
    final measured = scope.rectOf(header);
    final tapped = route.tappedRect;
    if (measured == null || tapped == null) return;
    // The new layer starts shrunk; the flight must land on the header's
    // resting rectangle, so undo the layer's current scale about its pivot.
    final size = _layerSize;
    final geometry = route.geometry(size);
    final s = geometry.newScale0 + (1 - geometry.newScale0) * anim.value;
    final pivot = _layerRectToScope(geometry.newPivot & const Size(0, 0))
        .topLeft;
    // `rectOf` maps the tag's top-left through the layer transform but keeps
    // the tag's own (layout) size, so only the corner needs undoing.
    Rect unscale(Rect r) => Rect.fromLTWH(
      pivot.dx + (r.left - pivot.dx) / s,
      pivot.dy + (r.top - pivot.dy) / s,
      r.width,
      r.height,
    );
    final layerHeader = _tagRectInLayer(header);
    if (layerHeader != null) {
      final pl = geometry.newPivot;
      route.headerRest = Rect.fromLTWH(
        pl.dx + (layerHeader.left - pl.dx) / s,
        pl.dy + (layerHeader.top - pl.dy) / s,
        layerHeader.width,
        layerHeader.height,
      );
    }
    scope.fly(
      from: itemTagValue,
      to: header,
      progress: anim,
      fromRect: _layerRectToScope(tapped),
      toRect: unscale(measured),
    );
  }

  void _flyOut(ListPageRoute<dynamic> route, {ValueListenable<double>? by}) {
    if (route.flightStarted) return;
    route.flightStarted = true;
    final scope = _scope;
    final anim = route.animation;
    final item = route.morphFrom;
    if (scope == null || anim == null || item == null) return;
    final tapped = route.tappedRect;
    final progress = by ?? _Mirror(anim);
    final f = scope.fly(
      from: headerTag(route.key),
      to: item,
      progress: progress,
      toRect: tapped == null ? null : _layerRectToScope(tapped),
    );
    if (by == null) {
      f.whenComplete(() => (progress as _Mirror).dispose());
    }
  }

  // --- Back swipe ---

  /// The top page is still on its way in.
  bool get _topOpening =>
      _stack.lastOrNull?.animation?.status == AnimationStatus.forward;

  /// Whether the swipe may start now: no swipe is running, nothing is mid-pop,
  /// no sheet is open and the top page has finished opening.
  bool get _canStartSwipe =>
      _swipe == null && _busy == 0 && _pageOnTop && !_topOpening;

  ReleaseRules _rules(double width, int dir) {
    final r = ReleaseRules.backSwipe.forExtent(width);
    if (dir > 0) return r;
    // Leftward: the finger's velocity is used as it is, so a commit glides at
    // constant speed and a cancel is a timed ease.
    return ReleaseRules(
      commitAt: r.commitAt,
      flingPerSecond: r.flingPerSecond,
      settleCommit: r.settleCommit,
      settleCancel: r.settleCancel,
      minCommit: r.minCommit,
      minCancel: r.minCancel,
      glideMin: r.glideMin,
      glideMax: r.glideMax,
      cancelGlideMin: r.cancelGlideMin,
    );
  }

  double get _width => _layerSize.width <= 0 ? 360.0 : _layerSize.width;

  void _swipeStart() {
    if (_systemSwipe) return;
    _rubberReturn.stop();
    if (_settling && _swipe != null && _swipeRoute != null) {
      // Grabbed again while it settles: carry on from where it is.
      _settling = false;
      _regrab = true;
      _base = _swipe!.value;
      _swipe!.beginDrag();
      return;
    }
    _dir = 0;
    _active = false;
    _rootHook = false;
    _rubberMode = false;
  }

  /// Starts the swipe in [dir] (+1 right, -1 left); false when it is ignored.
  bool _begin(int dir) {
    if (!_canStartSwipe) return false;
    final nav = _nav;
    if (nav == null) return false;
    if (_stack.length < 2) {
      if (dir < 0) return false;
      if (widget.onRootSwipeStart != null) {
        // The shell may refuse (a transition is running); then the swipe is
        // left alone rather than swallowed.
        if (!widget.onRootSwipeStart!()) return false;
        _rootHook = true;
      } else {
        _rubberMode = true;
      }
      return true;
    }
    final route = _stack.last;
    final parent = _stack[_stack.length - 2];
    final mp = MotionProgress(vsync: this)..beginDrag();
    _swipe = mp;
    _swipeRoute = route;
    _swipeParent = parent;
    nav.didStartUserGesture();
    route.swipeDir.value = dir;
    mp.addListener(() {
      // The route may have been removed while the settle runs.
      if (route.isActive) route.setProgress(1 - mp.value);
    });
    _incomingOnTop(route, parent);
    _flyOut(route, by: mp);
    return true;
  }

  void _swipeUpdate(double signed) {
    if (_systemSwipe) return;
    if (_regrab) {
      _swipe?.dragTo(_base + signed * _dir);
      return;
    }
    if (_dir == 0) {
      if (signed == 0) return;
      final dir = signed > 0 ? 1 : -1;
      if (!_begin(dir)) {
        _dir = 2; // ignored for the rest of this drag
        return;
      }
      _dir = dir;
      _active = true;
    }
    if (!_active) return;
    _applyProgress((signed * _dir).clamp(0.0, 1.0));
  }

  void _applyProgress(double p) {
    if (_rootHook) {
      widget.onRootSwipeUpdate?.call(p);
    } else if (_rubberMode) {
      _rubber.value = MotionSpec.backRubberBand * _layerSize.width * p;
    } else {
      _swipe?.dragTo(p);
    }
  }

  /// [velocity] is progress per second in the screen's own direction (positive
  /// to the right).
  Future<void> _swipeEnd(double velocity) async {
    if (_systemSwipe) return;
    if (!_active && !_regrab) {
      _dir = 0;
      return;
    }
    await _endWith(velocity);
  }

  /// Ends the swipe. [cancel] settles back whatever the progress is, with no
  /// velocity: a timed ease (a system cancel, a second finger, a lost touch).
  Future<void> _endWith(double screenVelocity, {bool cancel = false}) async {
    final dir = _dir;
    if (_rootHook) {
      _rootHook = false;
      _active = false;
      _dir = 0;
      if (cancel && widget.onRootSwipeCancel != null) {
        widget.onRootSwipeCancel!();
      } else {
        widget.onRootSwipeEnd?.call(screenVelocity);
      }
      return;
    }
    if (_rubberMode) {
      _rubberMode = false;
      _active = false;
      _dir = 0;
      _startRubberReturn();
      return;
    }
    final mp = _swipe;
    final route = _swipeRoute;
    final parent = _swipeParent;
    if (mp == null || route == null) return;
    // Toward the commit: leftward swipes use the mirrored sign. Below the fling
    // speed a tiny floor makes a slow commit take the constant-speed glide; a
    // real fling either way decides by direction.
    var toward = dir > 0 ? screenVelocity : -screenVelocity;
    if (dir < 0 && toward.abs() < _rules(_width, dir).flingPerSecond) {
      toward = math.max(toward, 1e-3);
    }
    _settling = true;
    final bool? committed;
    if (cancel) {
      final rules = _rules(_width, dir);
      final timed = rules.settleCancel * mp.value;
      final reached = await mp.run(
        to: 0,
        duration: timed >= rules.minCancel ? timed : rules.minCancel,
        curve: cosEase,
      );
      committed = reached ? false : null;
    } else {
      committed = await mp.release(
        velocityPerSecond: toward,
        rules: _rules(_width, dir),
      );
    }
    if (committed == null) return; // grabbed again
    _settling = false;
    _regrab = false;
    await _finishSwipe(mp, route, parent, committed);
  }

  Future<void> _finishSwipe(
    MotionProgress mp,
    ListPageRoute<dynamic> route,
    ListPageRoute<dynamic>? parent,
    bool committed,
  ) async {
    final nav = _nav;
    _swipe = null;
    _swipeRoute = null;
    _swipeParent = null;
    _active = false;
    _systemSwipe = false;
    _dir = 0;
    try {
      // The route is gone when the library was hidden mid-settle and showPath
      // replaced the stack: leave it alone, but still free the navigator.
      final alive = route.isActive;
      if (alive) route.swipeDir.value = 0;
      if (committed && alive && nav != null) {
        route.setProgress(0);
        nav.pop();
      } else if (alive) {
        route.flightStarted = false;
        route.setProgress(1);
        if (parent != null) _restoreOrder(route, parent);
      } else if (parent != null &&
          parent.isActive &&
          parent.overlayEntries.isNotEmpty) {
        parent.overlayEntries.first.opaque = parent.opaque;
      }
    } finally {
      nav?.didStopUserGesture();
      mp.dispose();
    }
  }

  void _swipeCancel() {
    if (_systemSwipe) return;
    if (!_active) {
      _dir = 0;
      return;
    }
    unawaited(_endWith(0, cancel: true));
  }

  // The page being revealed is drawn above the one leaving.

  void _incomingOnTop(ListPageRoute<dynamic> child, Route<dynamic>? parent) {
    if (parent is! ListPageRoute) return;
    if (child.overlayEntries.isEmpty || parent.overlayEntries.isEmpty) return;
    if (child.animation?.status == AnimationStatus.dismissed) return;
    final order = [
      for (final r in _routes)
        if (!identical(r, child)) r,
    ];
    final at = order.indexOf(parent);
    if (at < 0) return;
    // The leaving page goes just below the revealed one; routes that are not
    // pages (a menu, a sheet) keep their place above both.
    order.insert(at, child);
    _arrange(order);
    parent.overlayEntries.first.opaque = false;
  }

  void _restoreOrder(
    ListPageRoute<dynamic> child,
    ListPageRoute<dynamic> parent,
  ) {
    if (child.overlayEntries.isEmpty || parent.overlayEntries.isEmpty) return;
    _arrange(_routes);
    parent.overlayEntries.first.opaque = parent.opaque;
  }

  void _arrange(List<Route<dynamic>> routes) {
    final overlay = _nav?.overlay;
    if (overlay == null) return;
    overlay.rearrange([for (final r in routes) ...r.overlayEntries]);
  }

  void _startRubberReturn() {
    _rubberStart = _rubber.value;
    if (_rubberStart == 0) return;
    _rubberReturn.forward(from: 0);
  }

  void _onRubberReturn() {
    _rubber.value = _rubberStart * (1 - cubicOut(_rubberReturn.value));
  }

  // System (predictive) back: same transition, forced commit on invoke.

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (!systemBackEnabled) return false;
    // The finger got there first and the system is about to take its pointers:
    // the system carries on with the same swipe.
    if (_swipe != null && _active && !_settling) {
      _regrab = false;
      _systemSwipe = true;
      return true;
    }
    // A finger swipe still settling owns the stack.
    if (_stack.length < 2 || !_canStartSwipe) return false;
    _swipeStart();
    // From the right edge the page leaves leftward (the mirrored look).
    final dir = backEvent.swipeEdge == SwipeEdge.right ? -1 : 1;
    if (!_begin(dir)) return false;
    _dir = dir;
    _active = true;
    _systemSwipe = true;
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (_active) _applyProgress(backEvent.progress.clamp(0.0, 1.0));
  }

  @override
  void handleCommitBackGesture() {
    // The system invoked back: a fast release in the swipe direction, so it
    // always commits.
    if (_active) {
      unawaited(_endWith(_dir * (MotionSpec.flingVelocity + 1) / _width));
    }
  }

  @override
  void handleCancelBackGesture() {
    // The system cancelled: released with no velocity, a timed ease back.
    if (_active) unawaited(_endWith(0, cancel: true));
  }

  @override
  Widget build(BuildContext context) {
    return BackSwipeDetector(
      enabled: true,
      onStart: _swipeStart,
      onUpdate: _swipeUpdate,
      onEnd: _swipeEnd,
      onCancel: _swipeCancel,
      child: ValueListenableBuilder<double>(
        valueListenable: _rubber,
        child: KeyedSubtree(
          key: _layerKey,
          child: Navigator(
            key: _navKey,
            observers: [_observer],
            onGenerateInitialRoutes: (navigator, name) => [
              ListPageRoute<void>(
                builder: (_) => widget.root,
                key: const LibraryPageKey('place', {'id': 'root'}),
                instant: true,
              ),
            ],
            onGenerateRoute: (settings) => null,
          ),
        ),
        builder: (context, dx, child) =>
            Transform.translate(offset: Offset(dx, 0), child: child),
      ),
    );
  }
}

class _StackObserver extends NavigatorObserver {
  _StackObserver(this.owner);

  final LibraryNavigatorState owner;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    owner._top = route;
    owner._routes.add(route);
    if (route is ListPageRoute) owner._stack.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    owner._top = previousRoute;
    if (route is! ListPageRoute) {
      owner._routes.remove(route);
      return;
    }
    owner._stack.remove(route);
    owner._flyOut(route);
    // The page is gone from the logical stack but still animating out.
    owner._busy++;
    route.completed.whenComplete(() {
      owner._busy--;
      owner._routes.remove(route);
      if (previousRoute is ListPageRoute &&
          previousRoute.overlayEntries.isNotEmpty) {
        previousRoute.overlayEntries.first.opaque = previousRoute.opaque;
      }
    });
    // The navigator re-sorts its overlay when it finishes this pop; draw the
    // revealed page above the leaving one right after.
    scheduleMicrotask(() => owner._incomingOnTop(route, previousRoute));
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (identical(owner._top, route)) owner._top = previousRoute;
    owner._routes.remove(route);
    if (route is ListPageRoute) owner._stack.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) {
      if (identical(owner._top, oldRoute)) owner._top = newRoute;
      final at = owner._routes.indexOf(oldRoute);
      owner._routes.remove(oldRoute);
      if (newRoute != null) {
        owner._routes.insert(at < 0 ? owner._routes.length : at, newRoute);
      }
      if (oldRoute is ListPageRoute) owner._stack.remove(oldRoute);
    } else if (newRoute != null) {
      owner._routes.add(newRoute);
    }
    if (newRoute is ListPageRoute) owner._stack.add(newRoute);
  }
}
