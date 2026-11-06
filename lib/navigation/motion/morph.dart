import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/widgets.dart';

import 'package:eq_app/navigation/motion/layer_snapshot.dart';
import 'package:eq_app/navigation/motion/motion_progress.dart';

/// Marks a widget as one end of a shared-element flight.
///
/// While a flight involving [tag] runs, the real widget stays laid out but is
/// not painted; the flight draws a stand-in in the scope's overlay.
class MorphTag extends StatefulWidget {
  const MorphTag({super.key, required this.tag, required this.child});

  final Object tag;
  final Widget child;

  @override
  State<MorphTag> createState() => _MorphTagState();
}

class _MorphTagState extends State<MorphTag> {
  final ValueNotifier<bool> _hidden = ValueNotifier<bool>(false);
  MorphScopeState? _scope;
  Object? _registeredTag;

  @override
  void initState() {
    super.initState();
    _hidden.addListener(_retakeSnapshot);
  }

  /// A snapshot of the page this tag sits in must show the tag as it is now
  /// (hidden or not), or a second copy of the flying widget would stay frozen
  /// under the stand-in.
  void _retakeSnapshot() {
    if (!mounted) return;
    LayerSnapshotScope.maybeOf(context)?.invalidate();
  }

  void _register() {
    final scope = MorphScope.maybeOf(context);
    if (scope == _scope && widget.tag == _registeredTag) return;
    _unregister();
    _scope = scope;
    _registeredTag = widget.tag;
    scope?._attach(widget.tag, this);
  }

  void _unregister() {
    final tag = _registeredTag;
    if (tag != null) _scope?._detach(tag, this);
    _scope = null;
    _registeredTag = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _register();
  }

  @override
  void didUpdateWidget(MorphTag oldWidget) {
    super.didUpdateWidget(oldWidget);
    _register();
  }

  @override
  void dispose() {
    _unregister();
    _hidden.dispose();
    super.dispose();
  }

  /// Whether the route this tag lives under is the one on top (true outside
  /// any route).
  bool get routeIsCurrent {
    if (!mounted) return false;
    return ModalRoute.of(context)?.isCurrent ?? true;
  }

  Rect? _rectIn(RenderBox ancestor) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: ancestor);
    return topLeft & box.size;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _hidden,
      child: widget.child,
      builder: (context, hidden, child) =>
          Opacity(opacity: hidden ? 0.0 : 1.0, child: child),
    );
  }
}

/// Hosts [MorphTag]s and draws shared-element flights above [child].
class MorphScope extends StatefulWidget {
  const MorphScope({super.key, required this.child});

  final Widget child;

  static MorphScopeState of(BuildContext context) {
    final scope = maybeOf(context);
    assert(scope != null, 'No MorphScope above this context.');
    return scope!;
  }

  static MorphScopeState? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<_MorphInherited>()?.state;
  }

  @override
  State<MorphScope> createState() => MorphScopeState();
}

class MorphScopeState extends State<MorphScope> {
  // Several tags may share a name (a covered page keeps its own); the ones
  // under the route on top win.
  final Map<Object, List<_MorphTagState>> _tags =
      <Object, List<_MorphTagState>>{};
  late final OverlayEntry _content = OverlayEntry(builder: (_) => widget.child);
  final GlobalKey _overlayKey = GlobalKey();
  final List<_Flight> _flights = <_Flight>[];

  /// The tags whose real widgets are hidden behind a flying stand-in right
  /// now. A widget drawn around a tag (the player's card deck, whose other
  /// cards sit behind the tagged one) hides with it, or it shows through where
  /// the tag was.
  final ValueNotifier<Set<Object>> hiddenTags = ValueNotifier<Set<Object>>(
    const <Object>{},
  );

  void _syncHiddenTags() {
    if (_disposed) return;
    hiddenTags.value = <Object>{
      for (final f in _flights)
        if (f._armed.value) ...[f.source.widget.tag, f.target.widget.tag],
    };
  }

  void _attach(Object tag, _MorphTagState state) =>
      (_tags[tag] ??= <_MorphTagState>[]).add(state);

  _MorphTagState? _resolve(Object tag) {
    final list = _tags[tag];
    if (list == null || list.isEmpty) return null;
    if (list.length == 1) return list.first;
    for (final state in list.reversed) {
      if (state.routeIsCurrent) return state;
    }
    return list.last;
  }

  void _detach(Object tag, _MorphTagState state) {
    final list = _tags[tag];
    if (list != null) {
      list.remove(state);
      if (list.isEmpty) _tags.remove(tag);
    }
    for (final flight in List<_Flight>.of(_flights)) {
      if (flight.source == state || flight.target == state) flight.abort();
    }
  }

  /// The tagged widget's rectangle in this scope's coordinates, or null when
  /// the tag is not mounted.
  Rect? rectOf(Object tag) {
    final state = _resolve(tag);
    final ancestor = context.findRenderObject();
    if (state == null || ancestor is! RenderBox) return null;
    return state._rectIn(ancestor);
  }

  /// Draws the [from] tag's widget travelling to the [to] tag's rectangle,
  /// cross-fading into the [to] widget, driven by [progress] (0 to 1).
  ///
  /// Both real tags stay hidden until the flight ends: at progress 1, when
  /// progress falls back to 0 with nothing holding it, when either tag
  /// unmounts, or when this scope is disposed (or a [MotionProgress] driving
  /// it is). A flight runs 0 to 1 only; for the reverse, run it again with the
  /// tags swapped.
  ///
  /// [fromRect] and [toRect] override the measured rectangles, in this scope's
  /// coordinates. Pass the final resting rectangle when a tag sits inside a
  /// layer that is still scaled at the moment the flight starts.
  Future<void> fly({
    required Object from,
    required Object to,
    required ValueListenable<double> progress,
    Rect? fromRect,
    Rect? toRect,
    Object? owner,
  }) {
    final source = _resolve(from);
    final target = _resolve(to);
    final startRect = fromRect ?? rectOf(from);
    final endRect = toRect ?? rectOf(to);
    final overlay = _overlayKey.currentState;
    if (source == null ||
        target == null ||
        startRect == null ||
        endRect == null ||
        overlay is! OverlayState) {
      return Future<void>.value();
    }
    final flight = _Flight(
      scope: this,
      source: source,
      target: target,
      fromRect: startRect,
      toRect: endRect,
      progress: progress,
      fromTheme: InheritedTheme.capture(from: source.context, to: context),
      toTheme: InheritedTheme.capture(from: target.context, to: context),
      owner: owner,
    );
    _flights.add(flight);
    overlay.insert(flight.entry);
    flight.start();
    return flight.done.future;
  }

  /// Ends every flight started for [owner] whose progress has not yet left 0.
  /// Such a flight would only end if its progress moved, which a retargeted
  /// move may never do; flights already under way end by themselves.
  void abortUnstartedFlights(Object owner) {
    for (final flight in List<_Flight>.of(_flights)) {
      if (identical(flight.owner, owner) && !flight._left0) flight.abort();
    }
  }

  bool _disposed = false;

  void _flightEnded(_Flight flight, {required bool deferred}) {
    _flights.remove(flight);
    if (_disposed) return;
    if (deferred) {
      // Triggered while the tree is being torn down: touching the overlay or
      // other tags now would be a mutation during a locked build state.
      scheduleMicrotask(() => _restore(flight));
    } else {
      _restore(flight);
    }
  }

  void _restore(_Flight flight) {
    if (_disposed) return;
    flight.entry.remove();
    flight.entry.dispose();
    // Keep a tag hidden while another flight still uses it.
    bool inUse(_MorphTagState s) =>
        _flights.any((f) => f.source == s || f.target == s);
    if (flight.source.mounted && !inUse(flight.source)) {
      flight.source._hidden.value = false;
    }
    if (flight.target.mounted && !inUse(flight.target)) {
      flight.target._hidden.value = false;
    }
    _syncHiddenTags();
  }

  @override
  void didUpdateWidget(MorphScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _content.markNeedsBuild();
  }

  @override
  void dispose() {
    for (final flight in List<_Flight>.of(_flights)) {
      flight.abort();
    }
    _disposed = true;
    hiddenTags.dispose();
    _content.remove();
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _MorphInherited(
      state: this,
      child: Overlay(
        key: _overlayKey,
        clipBehavior: Clip.none,
        initialEntries: <OverlayEntry>[_content],
      ),
    );
  }
}

class _MorphInherited extends InheritedWidget {
  const _MorphInherited({required this.state, required super.child});

  final MorphScopeState state;

  @override
  bool updateShouldNotify(_MorphInherited oldWidget) =>
      state != oldWidget.state;
}

class _Flight {
  _Flight({
    required this.scope,
    required this.source,
    required this.target,
    required this.fromRect,
    required this.toRect,
    required this.progress,
    required this.fromTheme,
    required this.toTheme,
    this.owner,
  });

  final MorphScopeState scope;

  /// Whoever started the flight, so it can be told apart when aborting.
  final Object? owner;
  final CapturedThemes fromTheme;
  final CapturedThemes toTheme;
  final _MorphTagState source;
  final _MorphTagState target;
  final Rect fromRect;
  final Rect toRect;
  final ValueListenable<double> progress;
  final Completer<void> done = Completer<void>();
  late final OverlayEntry entry = OverlayEntry(builder: _build);
  bool _left0 = false;
  bool _ended = false;

  /// The stand-in is drawn (and the real tags hidden) only from the second
  /// frame on. Images inside the stand-in are mounted fresh and resolve
  /// asynchronously: showing it at once would put a placeholder over the real
  /// picture for a frame.
  final ValueNotifier<bool> _armed = ValueNotifier<bool>(false);

  void _arm() {
    final binding = SchedulerBinding.instance;
    binding.addPostFrameCallback((_) {
      binding.addPostFrameCallback((_) {
        if (_ended) return;
        source._hidden.value = true;
        target._hidden.value = true;
        _armed.value = true;
        scope._syncHiddenTags();
      });
      binding.scheduleFrame();
    });
    binding.scheduleFrame();
  }

  void start() {
    _arm();
    _left0 = progress.value > 0;
    final driver = progress;
    if (driver is MotionProgress) {
      if (driver.isDisposed) {
        abort();
        return;
      }
      driver.addDisposeListener(abort);
    }
    progress.addListener(_check);
    _check();
  }

  void _check() {
    if (_ended) return;
    final p = progress.value;
    if (p > 0) _left0 = true;
    final held =
        progress is MotionProgress &&
        (progress as MotionProgress).isFingerDriven;
    // A finger past full travel is an overshoot, not the end: the flight
    // ends when the settle brings it back to 1.
    if ((p >= 1 && !held) || (_left0 && p <= 0 && !held)) {
      _finish(deferred: false);
    }
  }

  void abort() => _finish(deferred: true);

  void _finish({required bool deferred}) {
    if (_ended) return;
    _ended = true;
    final driver = progress;
    if (driver is MotionProgress) {
      driver.removeDisposeListener(abort);
      if (!driver.isDisposed) progress.removeListener(_check);
    } else {
      progress.removeListener(_check);
    }
    scope._flightEnded(this, deferred: deferred);
    if (!done.isCompleted) done.complete();
    _armed.dispose();
  }

  Widget _build(BuildContext context) {
    // Each end is laid out once at the size it rests at and then scaled
    // (uniformly) into the flight's rectangle, so what is inside never re-lays-out (or re-decodes
    // an image) as the rectangle changes.
    // The overlay sits above the pages, so what the pages provide (text style,
    // icon theme, a Material for ink) is carried over from each tag's own
    // context.
    Widget standIn(CapturedThemes themes, Size size, Widget child) => Material(
      type: MaterialType.transparency,
      child: themes.wrap(SizedBox.fromSize(size: size, child: child)),
    );
    final from = standIn(fromTheme, fromRect.size, source.widget.child);
    final to = standIn(toTheme, toRect.size, target.widget.child);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[progress, _armed]),
      builder: (context, _) {
        // A finger past the ends carries the rectangle past them too (the
        // art follows the finger linearly); the cross-fade stays inside 0..1.
        final raw = progress.value;
        final t = raw.clamp(0.0, 1.0);
        final lerped = Rect.lerp(fromRect, toRect, raw)!;
        final rect = Rect.fromLTWH(
          lerped.left,
          lerped.top,
          math.max(0.0, lerped.width),
          math.max(0.0, lerped.height),
        );
        return Positioned.fromRect(
          rect: rect,
          child: IgnorePointer(
            child: Opacity(
              opacity: _armed.value ? 1 : 0,
              // Each end is scaled uniformly (its text never stretches) and
              // clipped to the flight's rectangle.
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    Opacity(
                      opacity: 1 - t,
                      child: FittedBox(
                        fit: BoxFit.contain,
                        alignment: Alignment.topLeft,
                        child: from,
                      ),
                    ),
                    Opacity(
                      opacity: t,
                      child: FittedBox(
                        fit: BoxFit.contain,
                        alignment: Alignment.topLeft,
                        child: to,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
