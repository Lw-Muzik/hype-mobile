import 'package:eq_app/navigation/zoom/zoom_steps.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  int cols(double extent, double width, double spacing) {
    final d = SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: extent,
      crossAxisSpacing: spacing,
    );
    return (d.getLayout(
      SliverConstraints(
        axisDirection: AxisDirection.down,
        growthDirection: GrowthDirection.forward,
        userScrollDirection: ScrollDirection.idle,
        scrollOffset: 0,
        precedingScrollExtent: 0,
        overlap: 0,
        remainingPaintExtent: 600,
        crossAxisExtent: width,
        crossAxisDirection: AxisDirection.right,
        viewportMainAxisExtent: 600,
        remainingCacheExtent: 600,
        cacheOrigin: 0,
      ),
    ) as SliverGridRegularTileLayout).crossAxisCount;
  }

  test('grid columns match the sliver delegate', () {
    for (final w in [400.0, 412.0, 360.0, 799.0]) {
      for (final sp in [0.0, 8.0]) {
        final rects = zoomLayout(
          ZoomStep.grid(maxTileExtent: 200, childAspectRatio: 1, spacing: sp),
          itemCount: 30,
          width: w,
        );
        final firstRowCount = rects.where((r) => r.top == 0).length;
        expect(firstRowCount, cols(200, w, sp), reason: 'w=$w sp=$sp');
      }
    }
    final two = zoomLayout(
      const ZoomStep.grid(maxTileExtent: 200, childAspectRatio: 1),
      itemCount: 4,
      width: 400,
    );
    expect(two.where((r) => r.top == 0).length, 2);
    final three = zoomLayout(
      const ZoomStep.grid(maxTileExtent: 200, childAspectRatio: 1),
      itemCount: 4,
      width: 412,
    );
    expect(three.where((r) => r.top == 0).length, 3);
  });

  test('grid rects with spacing, padding and aspect ratio', () {
    final r = zoomLayout(
      const ZoomStep.grid(
        maxTileExtent: 200,
        childAspectRatio: 0.5,
        spacing: 10,
      ),
      itemCount: 3,
      width: 430,
      padding: const EdgeInsets.all(15),
    );
    // cross = 400, 2 columns, usable 390, tile 195 x 390.
    expect(r[0], const Rect.fromLTWH(15, 15, 195, 390));
    expect(r[1], const Rect.fromLTWH(220, 15, 195, 390));
    expect(r[2], const Rect.fromLTWH(15, 415, 195, 390));
  });

  test('list rects stack by rowExtent', () {
    final r = zoomLayout(
      const ZoomStep.list(rowExtent: 72),
      itemCount: 3,
      width: 300,
      padding: const EdgeInsets.symmetric(horizontal: 10),
    );
    expect(r[0], const Rect.fromLTWH(10, 0, 280, 72));
    expect(r[2], const Rect.fromLTWH(10, 144, 280, 72));
  });

  test('contentHeight and visibleRange', () {
    final g = ZoomGeometry(const ZoomStep.list(rowExtent: 50), width: 100);
    expect(g.contentHeight(10), 500);
    expect(g.contentHeight(0), 0);
    expect(g.visibleRange(120, 100, 10), (2, 4));
    expect(g.visibleRange(0, 100, 0), isNull);
  });

  test('separate axis spacings and a step padding shape the grid', () {
    final r = zoomLayout(
      const ZoomStep.grid(
        maxTileExtent: 200,
        childAspectRatio: 1,
        crossAxisSpacing: 8,
        mainAxisSpacing: 12,
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
      itemCount: 4,
      width: 428,
    );
    // cross = 408, 2 columns, usable 400, tile 200.
    expect(r[0], const Rect.fromLTWH(10, 4, 200, 200));
    expect(r[1], const Rect.fromLTWH(218, 4, 200, 200));
    expect(r[2], const Rect.fromLTWH(10, 216, 200, 200));
  });

  test('spacing is the default of both axes', () {
    const g = GridZoomStep(maxTileExtent: 100, childAspectRatio: 1, spacing: 6);
    expect((g.mainAxisSpacing, g.crossAxisSpacing), (6.0, 6.0));
  });
}
