import 'package:eq_app/navigation/motion/motion_progress.dart';
import 'package:eq_app/navigation/motion/page_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A snapshot is a frozen picture. While a finger drives a scene move, the
// library is still being filled in underneath (the trail pushed, the playing
// row revealed), so a picture taken at the first frame would be stale and jump
// at the end. Finger-driven moves draw live; their settle snapshots.

SnapshotController _controllerOf(WidgetTester tester) => tester
    .widget<SnapshotWidget>(
      find.descendant(
        of: find.byType(PageLayer),
        matching: find.byType(SnapshotWidget),
      ),
    )
    .controller;

void main() {
  testWidgets('no snapshot while a finger drives, snapshot on the settle', (
    tester,
  ) async {
    final p = MotionProgress(vsync: tester);
    addTearDown(p.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: PageLayer(
          progress: p,
          scaleAt0: 1,
          scaleAt1: 1.25,
          opacityAt0: 1,
          opacityAt1: 0,
          pivot: Offset.zero,
          child: const SizedBox(width: 50, height: 50),
        ),
      ),
    );
    p.beginDrag();
    p.dragTo(0.2);
    await tester.pump();
    expect(_controllerOf(tester).allowSnapshotting, isFalse, reason: 'finger');
    p.dragTo(0.4);
    await tester.pump();
    expect(_controllerOf(tester).allowSnapshotting, isFalse, reason: 'finger');

    final done = p.release(
      velocityPerSecond: 0,
      rules: ReleaseRules.artDrag.forExtent(360),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(p.isFingerDriven, isFalse);
    expect(p.value, inExclusiveRange(0.0, 1.0));
    expect(_controllerOf(tester).allowSnapshotting, isTrue, reason: 'settle');
    await tester.pumpAndSettle();
    await done;
  });
}
