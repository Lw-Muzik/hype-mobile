import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/painting.dart' show EdgeInsets;

/// One level of the pinch zoom ladder. Higher indices in a step list are the
/// more zoomed-in levels (bigger items); spreading moves up, pinching down.
sealed class ZoomStep {
  const ZoomStep._();

  /// A single column of rows, each [rowExtent] tall.
  const factory ZoomStep.list({
    required double rowExtent,
    EdgeInsets? padding,
  }) = ListZoomStep;

  /// A grid laid out like `SliverGridDelegateWithMaxCrossAxisExtent`.
  const factory ZoomStep.grid({
    required double maxTileExtent,
    required double childAspectRatio,
    double spacing,
    double? mainAxisSpacing,
    double? crossAxisSpacing,
    EdgeInsets? padding,
  }) = GridZoomStep;

  /// Scroll padding of this step. Null defers to the list's own padding (and
  /// when that is null too, to the framework's inherited one).
  EdgeInsets? get padding;
}

final class ListZoomStep extends ZoomStep {
  const ListZoomStep({required this.rowExtent, this.padding}) : super._();
  final double rowExtent;
  @override
  final EdgeInsets? padding;
}

final class GridZoomStep extends ZoomStep {
  const GridZoomStep({
    required this.maxTileExtent,
    required this.childAspectRatio,
    this.spacing = 0,
    double? mainAxisSpacing,
    double? crossAxisSpacing,
    this.padding,
  }) : mainAxisSpacing = mainAxisSpacing ?? spacing,
       crossAxisSpacing = crossAxisSpacing ?? spacing,
       super._();
  final double maxTileExtent;
  final double childAspectRatio;

  /// Default for both axes when they are not given.
  final double spacing;
  final double mainAxisSpacing;
  final double crossAxisSpacing;
  @override
  final EdgeInsets? padding;
}

/// Rectangles of every item of a [ZoomStep] in content coordinates (the
/// scroll origin is the content top-left, [padding] included).
class ZoomGeometry {
  ZoomGeometry(
    this.step, {
    required this.width,
    this.padding = EdgeInsets.zero,
  }) {
    final cross = math.max(0.0, width - padding.horizontal);
    switch (step) {
      case ListZoomStep(:final rowExtent):
        columns = 1;
        _cellW = cross;
        _cellH = rowExtent;
        _gap = 0;
        _colGap = 0;
      case GridZoomStep(
        :final maxTileExtent,
        :final childAspectRatio,
        :final mainAxisSpacing,
        :final crossAxisSpacing,
      ):
        columns = math.max(
          1,
          (cross / (maxTileExtent + crossAxisSpacing)).ceil(),
        );
        final usable = math.max(0.0, cross - crossAxisSpacing * (columns - 1));
        _cellW = usable / columns;
        _cellH = _cellW / childAspectRatio;
        _colGap = crossAxisSpacing;
        _gap = mainAxisSpacing;
    }
  }

  final ZoomStep step;
  final double width;
  final EdgeInsets padding;

  late final int columns;
  late final double _cellW;
  late final double _cellH;
  late final double _gap;
  late final double _colGap;

  double get _rowStride => _cellH + _gap;

  Rect rectOf(int index) {
    final row = index ~/ columns;
    final col = index % columns;
    return Rect.fromLTWH(
      padding.left + col * (_cellW + _colGap),
      padding.top + row * _rowStride,
      _cellW,
      _cellH,
    );
  }

  /// Total scrollable height for [itemCount] items.
  double contentHeight(int itemCount) {
    if (itemCount <= 0) return padding.vertical;
    final rows = (itemCount + columns - 1) ~/ columns;
    return padding.vertical + rows * _rowStride - _gap;
  }

  /// Inclusive index range of items whose rows touch the viewport
  /// `[offset, offset + viewport]`, or null when none do.
  (int, int)? visibleRange(double offset, double viewport, int itemCount) {
    if (itemCount <= 0 || _rowStride <= 0 || viewport <= 0) return null;
    final lastRowIndex = (itemCount - 1) ~/ columns;
    var firstRow = ((offset - padding.top) / _rowStride).floor();
    var lastRow = ((offset + viewport - padding.top) / _rowStride).floor();
    firstRow = firstRow.clamp(0, lastRowIndex);
    lastRow = lastRow.clamp(0, lastRowIndex);
    final first = firstRow * columns;
    final last = math.min(itemCount - 1, lastRow * columns + columns - 1);
    if (first > last) return null;
    return (first, last);
  }
}

/// Item rectangles for [step] in content coordinates (its own padding wins
/// over [padding]). Grid columns follow
/// `SliverGridDelegateWithMaxCrossAxisExtent` exactly.
List<Rect> zoomLayout(
  ZoomStep step, {
  required int itemCount,
  required double width,
  EdgeInsets padding = EdgeInsets.zero,
}) {
  final g = ZoomGeometry(step, width: width, padding: step.padding ?? padding);
  return [for (var i = 0; i < itemCount; i++) g.rectOf(i)];
}

/// The step a layout saved before zoom steps existed corresponds to.
///
/// The old pinch widget always settled on `(screenWidth - 24) / columns`, so a
/// saved extent really records a column count: [legacyExtent] against
/// [screenWidth] gives it back. The step whose grid shows that many columns in
/// [width] (the room the list really has) is chosen; when none does, the one
/// with the nearest count, then the nearest tile size. An extent at or above
/// [listThreshold] was the list, which is the trailing [ListZoomStep] if the
/// ladder has one.
int legacyZoomStep(
  List<ZoomStep> steps, {
  required double legacyExtent,
  required double screenWidth,
  required double width,
  EdgeInsets padding = EdgeInsets.zero,
  double listThreshold = 260.0,
}) {
  final listAt = steps.indexWhere((s) => s is ListZoomStep);
  if (listAt >= 0 && legacyExtent >= listThreshold) return listAt;
  final wanted = math.max(1, ((screenWidth - 24) / legacyExtent).round());
  var best = -1;
  var bestGap = 0;
  var bestSize = 0.0;
  for (var i = 0; i < steps.length; i++) {
    final s = steps[i];
    if (s is! GridZoomStep) continue;
    final columns = ZoomGeometry(
      s,
      width: width,
      padding: s.padding ?? padding,
    ).columns;
    final gap = (columns - wanted).abs();
    final size = (s.maxTileExtent - legacyExtent).abs();
    if (best < 0 || gap < bestGap || (gap == bestGap && size < bestSize)) {
      best = i;
      bestGap = gap;
      bestSize = size;
    }
  }
  return best < 0 ? 0 : best;
}
