import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../motion_spec.dart';
import 'zoom_physics.dart';
import 'zoom_steps.dart';

/// A list that pinch-zooms through a ladder of [ZoomStep]s.
///
/// At rest it is a plain `ListView` / `GridView`. While two fingers pinch (and
/// during the settle that follows) one stack of positioned items replaces it:
/// every item visible in both levels moves between its two rectangles and its
/// two looks cross-fade; items visible in only one level scale about the
/// viewport centre and fade. Only one level is crossed per pinch.
///
/// Higher step indices are more zoomed in: spreading moves up, pinching down.
/// Items in the morph carry `ValueKey('zoom-item-<index>')` on their
/// positioned wrapper.
class ZoomStepList extends StatefulWidget {
  const ZoomStepList({
    super.key,
    required this.steps,
    required this.step,
    required this.onStepChanged,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
    this.padding,
    this.listWrapper,
  }) : assert(steps.length > 0);

  final List<ZoomStep> steps;
  final int step;
  final ValueChanged<int> onStepChanged;
  final int itemCount;
  final Widget Function(BuildContext context, int index, ZoomStep step)
  itemBuilder;
  final ScrollController? controller;

  /// Scroll padding for every step that does not set its own. Null leaves
  /// it to `ListView` / `GridView`, which then inherit the `MediaQuery`
  /// padding (safe-area insets) exactly as a plain list would; layout math
  /// reads the same vertical `MediaQuery` padding.
  final EdgeInsets? padding;

  /// Wraps the resting list when the current step is a [ListZoomStep]
  /// (for example an alphabet scroller). Not used during the morph.
  final Widget Function(BuildContext, Widget list)? listWrapper;

  @override
  State<ZoomStepList> createState() => _ZoomStepListState();
}

enum _Phase { idle, pinching, settling }

class _SpanSample {
  _SpanSample(this.time, this.span);
  final Duration time;
  final double span;
}

class _ZoomStepListState extends State<ZoomStepList>
    with TickerProviderStateMixin {
  final Map<int, Offset> _pointers = {};
  final List<_SpanSample> _samples = [];
  ScrollController? _own;
  ScrollController get _ctrl =>
      widget.controller ?? (_own ??= ScrollController());

  late int _stepIdx = widget.step;
  _Phase _phase = _Phase.idle;
  bool _awaitingJump = false;

  bool _armed = false;
  double _span0 = 1;
  bool _zoomIn = true;
  int _from = 0;
  int? _to;
  int _anchor = -1;
  double _fromOffset = 0;
  double _raw = 0;
  double _p = 0;
  double _band = 0;
  bool _commit = false;
  Size _viewport = Size.zero;

  /// Items built for the running pinch, by (index, step, fitted): a pointer
  /// move re-wraps them but never rebuilds them.
  final Map<(int, int, bool), Widget> _built = {};

  late final AnimationController _settle;
  late final AnimationController _relax;
  double _settleFrom = 0;
  double _settleTo = 0;
  double? _glide;
  double _relaxStart = 0;

  int get _cur => _stepIdx.clamp(0, widget.steps.length - 1);

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(vsync: this)
      ..addListener(_onSettleTick)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) {
          _maybeFinish();
        }
      });
    _relax =
        AnimationController(vsync: this, duration: MotionSpec.zoomEndReturn)
          ..addListener(() {
            setState(() {
              _band = _relaxStart * (1 - cubicOut(_relax.value));
            });
          })
          ..addStatusListener((s) {
            if (s == AnimationStatus.completed) {
              _band = 0;
              _maybeFinish();
            }
          });
  }

  @override
  void didUpdateWidget(ZoomStepList old) {
    super.didUpdateWidget(old);
    _built.clear();
    if (_phase == _Phase.idle && !_awaitingJump && widget.step != old.step) {
      _stepIdx = widget.step;
    }
    if (widget.controller != null && _own != null) {
      // The list adopts the supplied controller during this build; the
      // internal one is released afterwards.
      final spare = _own!;
      _own = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => spare.dispose());
    }
  }

  @override
  void dispose() {
    _settle.dispose();
    _relax.dispose();
    _own?.dispose();
    super.dispose();
  }

  // ---- geometry helpers ----

  EdgeInsets? _padOf(ZoomStep step) => step.padding ?? widget.padding;

  /// What a scroll view with no padding of its own takes from `MediaQuery`
  /// (vertical insets only for a vertical list).
  EdgeInsets _inherited = EdgeInsets.zero;

  ZoomGeometry _geo(int step, double width) {
    final s = widget.steps[step.clamp(0, widget.steps.length - 1)];
    return ZoomGeometry(s, width: width, padding: _padOf(s) ?? _inherited);
  }

  double _clampOffset(ZoomGeometry g, double offset, double viewH) => offset
      .clamp(0.0, math.max(0.0, g.contentHeight(widget.itemCount) - viewH));

  double _toOffset(ZoomGeometry g, double viewH) {
    if (_anchor < 0 || _anchor >= widget.itemCount) {
      return 0;
    }
    final r = g.rectOf(_anchor);
    if (r.top < viewH / 2) {
      return 0;
    }
    return _clampOffset(g, r.center.dy - viewH / 2, viewH);
  }

  // ---- pointer handling ----

  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2 && _phase == _Phase.idle && !_awaitingJump) {
      _armed = true;
      _span0 = math.max(1.0, _span());
      _samples.clear();
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) {
      return;
    }
    _pointers[e.pointer] = e.position;
    if (_pointers.length != 2) {
      return;
    }
    final span = _span();
    if (_phase == _Phase.pinching) {
      _samples.add(_SpanSample(e.timeStamp, span));
      _samples.removeWhere(
        (s) => e.timeStamp - s.time > const Duration(milliseconds: 100),
      );
      _updatePinch(span);
    } else if (_armed && _phase == _Phase.idle) {
      if ((span - _span0).abs() >= MotionSpec.dragSlop) {
        _begin(span > _span0);
        _span0 = math.max(1.0, span);
        _samples.add(_SpanSample(e.timeStamp, span));
      }
    }
  }

  void _up(PointerEvent e) {
    if (!_pointers.containsKey(e.pointer)) {
      return;
    }
    final wasTwo = _pointers.length == 2;
    final velocity = e is PointerCancelEvent ? 0.0 : _spanVelocity(e.timeStamp);
    _pointers.remove(e.pointer);
    if (wasTwo) {
      _armed = false;
    }
    if (wasTwo && _phase == _Phase.pinching) {
      _release(velocity);
    }
  }

  double _span() {
    final pts = _pointers.values.toList();
    return (pts[0] - pts[1]).distance;
  }

  /// Span speed over the last 100 ms before [lift]; zero when the fingers
  /// had already stopped (newest sample older than 80 ms at lift).
  double _spanVelocity(Duration lift) {
    _samples.removeWhere(
      (s) => lift - s.time > const Duration(milliseconds: 100),
    );
    if (_samples.length < 2 ||
        lift - _samples.last.time > const Duration(milliseconds: 80)) {
      return 0;
    }
    final dt = (_samples.last.time - _samples.first.time).inMicroseconds / 1e6;
    if (dt <= 0.001) {
      return 0;
    }
    return (_samples.last.span - _samples.first.span) / dt;
  }

  // ---- gesture phases ----

  void _begin(bool zoomIn) {
    final steps = widget.steps;
    final next = _cur + (zoomIn ? 1 : -1);
    final w = _viewport.width;
    final h = _viewport.height;
    final pos = _ctrl.positions;
    final g = _geo(_cur, w);
    final off = _clampOffset(g, pos.isEmpty ? 0 : pos.last.pixels, h);
    var anchor = -1;
    final range = g.visibleRange(off, h, widget.itemCount);
    if (range != null && range.$1 >= 1) {
      anchor = math.min(
        widget.itemCount - 1,
        range.$1 + (range.$2 - range.$1 + 1) ~/ 2,
      );
    }
    _built.clear();
    setState(() {
      _phase = _Phase.pinching;
      _zoomIn = zoomIn;
      _from = _cur;
      _to = (next >= 0 && next < steps.length) ? next : null;
      _anchor = anchor;
      _fromOffset = off;
      _raw = 0;
      _p = 0;
      _band = 0;
    });
  }

  void _updatePinch(double span) {
    setState(() {
      if (_to == null) {
        final ratio = span / _span0;
        // At an end step a pinch that reverses past its starting span heads
        // for the opposite neighbour, when there is one.
        final wantIn = ratio > 1 ? true : (ratio < 1 ? false : _zoomIn);
        final other = _from + (wantIn ? 1 : -1);
        if (wantIn != _zoomIn && other >= 0 && other < widget.steps.length) {
          _zoomIn = wantIn;
          _to = other;
        } else {
          _band = zoomEndBandDeviation(ratio);
          return;
        }
      }
      _raw = pinchProgress(span: span, startSpan: _span0, zoomIn: _zoomIn);
      _p = _raw.clamp(0.0, 1.0);
      _band = zoomBandDeviation(raw: _raw, zoomIn: _zoomIn);
    });
  }

  void _release(double velocity) {
    setState(() => _phase = _Phase.settling);
    if (_band.abs() > 1e-6) {
      _relaxStart = _band;
      _relax.forward(from: 0);
    }
    if (_to == null) {
      _commit = false;
      _maybeFinish();
      return;
    }
    final rel = decideZoomRelease(
      progress: _p,
      spanVelocityDpPerSecond: velocity,
      zoomIn: _zoomIn,
      startSpan: _span0,
    );
    _commit = rel.commit;
    _settleFrom = _p;
    _settleTo = rel.commit ? 1.0 : 0.0;
    _glide = rel.glidePerSecond;
    if (_settleFrom == _settleTo || rel.duration == Duration.zero) {
      setState(() => _p = _settleTo);
      _maybeFinish();
      return;
    }
    _settle.duration = rel.duration;
    _settle.forward(from: 0);
  }

  void _onSettleTick() {
    final t = _settle.value;
    final eased = _glide != null ? t : cosEase(t);
    setState(() => _p = _settleFrom + (_settleTo - _settleFrom) * eased);
  }

  void _maybeFinish() {
    if (_phase != _Phase.settling) {
      return;
    }
    if (_settle.isAnimating || _relax.isAnimating) {
      return;
    }
    final commit = _commit && _to != null;
    final w = _viewport.width;
    final h = _viewport.height;
    final step = commit ? _to! : _from;
    final g = _geo(step, w);
    final offset = commit ? _toOffset(g, h) : _clampOffset(g, _fromOffset, h);
    final changed = step != _from;
    _built.clear();
    setState(() {
      _stepIdx = step;
      _phase = _Phase.idle;
      _awaitingJump = true;
      _p = commit ? 1.0 : 0.0;
      _band = 0;
    });
    if (changed) {
      widget.onStepChanged(step);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _handOver(offset));
  }

  /// Ends the hand-over from the morph to the resting list: shows the
  /// parent's step if it differs (kept the old one, or changed it mid-pinch),
  /// then restores the scroll offset.
  void _handOver(double offset) {
    if (!mounted) {
      return;
    }
    final parent = widget.step.clamp(0, widget.steps.length - 1);
    if (parent != _cur) {
      setState(() => _stepIdx = parent);
      WidgetsBinding.instance.addPostFrameCallback((_) => _handOver(offset));
      return;
    }
    final pos = _ctrl.positions;
    if (pos.isNotEmpty) {
      final p = pos.last;
      _ctrl.jumpTo(offset.clamp(p.minScrollExtent, p.maxScrollExtent));
    }
    setState(() => _awaitingJump = false);
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: LayoutBuilder(
        builder: (context, c) {
          assert(
            c.hasBoundedHeight,
            'ZoomStepList needs a parent with bounded height.',
          );
          _viewport = Size(c.maxWidth, c.maxHeight);
          _inherited =
              MediaQuery.maybeOf(context)?.padding
                  .copyWith(left: 0, right: 0) ??
              EdgeInsets.zero;
          final morphing = _phase != _Phase.idle || _awaitingJump;
          // The resting list keeps its slot (hidden while the morph covers
          // it) so its scroll position survives the hand-over.
          return Stack(
            children: [
              Positioned.fill(
                child: _phase == _Phase.idle
                    ? Opacity(opacity: morphing ? 0 : 1, child: _idle(context))
                    : const SizedBox.shrink(),
              ),
              if (morphing)
                Positioned.fill(
                  child: ClipRect(child: _morph(context, _viewport)),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _idle(BuildContext context) {
    final step = widget.steps[_cur];
    final key = ValueKey<int>(_cur);
    Widget list;
    switch (step) {
      case ListZoomStep(:final rowExtent):
        list = ListView.builder(
          key: key,
          controller: _ctrl,
          padding: _padOf(step),
          itemExtent: rowExtent,
          addAutomaticKeepAlives: false,
          itemCount: widget.itemCount,
          itemBuilder: (c, i) => widget.itemBuilder(c, i, step),
        );
        if (widget.listWrapper != null) {
          list = widget.listWrapper!(context, list);
        }
      case GridZoomStep(
        :final maxTileExtent,
        :final childAspectRatio,
        :final mainAxisSpacing,
        :final crossAxisSpacing,
      ):
        list = GridView.builder(
          key: key,
          controller: _ctrl,
          padding: _padOf(step),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: maxTileExtent,
            childAspectRatio: childAspectRatio,
            crossAxisSpacing: crossAxisSpacing,
            mainAxisSpacing: mainAxisSpacing,
          ),
          itemCount: widget.itemCount,
          itemBuilder: (c, i) => widget.itemBuilder(c, i, step),
        );
    }
    return list;
  }

  Widget _fit(Widget child, Size natural) => FittedBox(
    fit: BoxFit.contain,
    child: SizedBox(width: natural.width, height: natural.height, child: child),
  );

  /// Item [i] at step [stepIdx], built once per pinch ([fitted] items are
  /// scaled into [natural], the size they have at that step).
  Widget _item(
    BuildContext context,
    int i,
    int stepIdx, {
    Size? natural,
  }) => _built.putIfAbsent((i, stepIdx, natural != null), () {
    final built = widget.itemBuilder(context, i, widget.steps[stepIdx]);
    return natural == null ? built : _fit(built, natural);
  });

  Widget _morph(BuildContext context, Size view) {
    final w = view.width;
    final h = view.height;
    final count = widget.itemCount;
    final steps = widget.steps;
    final fromIdx = _from.clamp(0, steps.length - 1);
    final fg = _geo(fromIdx, w);
    final fo = _clampOffset(fg, _fromOffset, h);
    final toIdx = _to?.clamp(0, steps.length - 1);
    final tg = toIdx == null ? null : _geo(toIdx, w);
    final to = tg == null ? 0.0 : _toOffset(tg, h);
    final p = tg == null ? 0.0 : _p;
    final pivot = Offset(w / 2, h / 2);
    final bandScale = 1 + _band;

    bool vis(Rect r, double off) => r.bottom > off && r.top < off + h;

    final indices = <int>{};
    final fr = fg.visibleRange(fo, h, count);
    if (fr != null) {
      for (var i = fr.$1; i <= fr.$2; i++) {
        indices.add(i);
      }
    }
    final tr = tg?.visibleRange(to, h, count);
    if (tr != null) {
      for (var i = tr.$1; i <= tr.$2; i++) {
        indices.add(i);
      }
    }
    final order = indices.toList()..sort();

    final oldTo = _zoomIn ? 1.5 : 0.5;
    final newFrom = _zoomIn ? 0.5 : 1.5;

    final children = <Widget>[];
    for (final i in order) {
      final fRect = fg.rectOf(i);
      final tRect = tg?.rectOf(i);
      final inF = vis(fRect, fo);
      final inT = tRect != null && vis(tRect, to);
      final key = ValueKey<String>('zoom-item-$i');

      if (inF && inT) {
        final a = fRect.shift(Offset(0, -fo));
        final b = tRect.shift(Offset(0, -to));
        final r = Rect.lerp(a, b, p)!;
        Widget content = Stack(
          fit: StackFit.expand,
          children: [
            if (p < 1)
              Opacity(
                key: const ValueKey('from'),
                opacity: 1 - p,
                child: _item(context, i, fromIdx, natural: fRect.size),
              ),
            if (p > 0)
              Opacity(
                key: const ValueKey('to'),
                opacity: p,
                child: _item(context, i, toIdx!, natural: tRect.size),
              ),
          ],
        );
        if (_band != 0) {
          content = Transform.scale(scale: bandScale, child: content);
        }
        children.add(Positioned.fromRect(key: key, rect: r, child: content));
      } else if (inF || inT) {
        // Present in one level only: scale about the viewport centre and fade.
        final leaving = inF;
        final rect = (leaving
            ? fRect.shift(Offset(0, -fo))
            : tRect!.shift(Offset(0, -to)));
        final f = leaving ? p : 1 - p;
        final target = leaving ? oldTo : newFrom;
        final k = 1 + (target - 1) * f;
        final alpha = 1 - f;
        if (tg == null) {
          // End step: nothing to leave or arrive, items sit at rest.
          Widget content = _item(context, i, fromIdx);
          if (_band != 0) {
            content = Transform.scale(scale: bandScale, child: content);
          }
          children.add(
            Positioned.fromRect(key: key, rect: rect, child: content),
          );
          continue;
        }
        if (alpha <= 0) {
          continue;
        }
        final c2 = pivot + (rect.center - pivot) * k;
        final stepAt = leaving ? fromIdx : toIdx!;
        children.add(
          Positioned(
            key: key,
            left: c2.dx - rect.width / 2,
            top: c2.dy - rect.height / 2,
            width: rect.width,
            height: rect.height,
            child: Opacity(
              opacity: alpha,
              child: Transform.scale(
                scale: k * bandScale,
                child: _item(context, i, stepAt),
              ),
            ),
          ),
        );
      }
    }
    return SizedBox(
      width: w,
      height: h,
      child: Stack(clipBehavior: Clip.none, children: children),
    );
  }
}
