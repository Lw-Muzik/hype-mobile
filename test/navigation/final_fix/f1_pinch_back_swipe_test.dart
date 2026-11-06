import 'dart:math' as math;

import 'package:eq_app/navigation/library/library_navigator.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/motion/morph.dart';
import 'package:eq_app/navigation/zoom/zoom_step_list.dart';
import 'package:eq_app/navigation/zoom/zoom_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A two-finger pinch over a zoom list inside the library must zoom at every
/// angle and never start (or leave running) the back swipe.
Future<void> _pinch(
  WidgetTester tester, {
  required double angleDeg,
  required double stepPx,
  required int steps,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = GlobalKey<LibraryNavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      home: MorphScope(
        child: LibraryNavigator(
          key: key,
          root: const Scaffold(body: Text('root')),
        ),
      ),
    ),
  );
  var step = 0;
  final page = StatefulBuilder(
    builder: (c, set) => Scaffold(
      body: ZoomStepList(
        steps: const [
          ZoomStep.list(rowExtent: 80),
          ZoomStep.grid(maxTileExtent: 200, childAspectRatio: 1),
        ],
        step: step,
        onStepChanged: (s) => set(() => step = s),
        itemCount: 30,
        itemBuilder: (c, i, s) =>
            Container(color: Colors.blue, child: Text('i$i')),
      ),
    ),
  );
  key.currentState!.openPage(
    page,
    key: const LibraryPageKey('album', {'albumId': 1, 'album': 'x'}),
  );
  await tester.pumpAndSettle();
  final a = angleDeg * math.pi / 180;
  final u = Offset(math.cos(a), -math.sin(a));
  const c = Offset(200, 400);
  final g1 = await tester.startGesture(c - u * 50, pointer: 1);
  final g2 = await tester.startGesture(c + u * 50, pointer: 2);
  var swipeSeen = false;
  for (var i = 1; i <= steps; i++) {
    final half = 50 + i * stepPx;
    await g1.moveTo(c - u * half);
    await g2.moveTo(c + u * half);
    await tester.pump(const Duration(milliseconds: 16));
    if ((key.currentState!.topRoute?.swipeDir.value ?? 0) != 0) {
      swipeSeen = true;
    }
  }
  await g1.up();
  await g2.up();
  await tester.pumpAndSettle();
  expect(swipeSeen, isFalse, reason: 'the back swipe must not start');
  expect(key.currentState!.path, isNotEmpty, reason: 'the page was popped');
  expect(step, 1, reason: 'the pinch must change the zoom step');
}

void main() {
  for (final angle in [0.0, 30.0, 40.0, 60.0, 90.0]) {
    testWidgets('fast pinch at ${angle.toInt()} degrees zooms, no pop', (t) {
      return _pinch(t, angleDeg: angle, stepPx: 8, steps: 10);
    });
    testWidgets('slow pinch at ${angle.toInt()} degrees zooms, no pop', (t) {
      return _pinch(t, angleDeg: angle, stepPx: 3, steps: 25);
    });
  }

  testWidgets('a second finger after the swipe began cancels it, no pop', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<LibraryNavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: MorphScope(
          child: LibraryNavigator(
            key: key,
            root: const Scaffold(body: Text('root')),
          ),
        ),
      ),
    );
    key.currentState!.openPage(
      const Scaffold(body: SizedBox.expand()),
      key: const LibraryPageKey('album', {'albumId': 1, 'album': 'x'}),
    );
    await tester.pumpAndSettle();
    final g1 = await tester.startGesture(const Offset(50, 400), pointer: 1);
    // 160 dp of travel: past the commit point if it were released alone.
    for (var i = 0; i < 8; i++) {
      await g1.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(key.currentState!.topRoute!.swipeDir.value, 1);
    final g2 = await tester.startGesture(const Offset(300, 600), pointer: 2);
    await tester.pump(const Duration(milliseconds: 16));
    await g2.moveBy(const Offset(40, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await g1.up();
    await g2.up();
    await tester.pumpAndSettle();
    expect(key.currentState!.path, isNotEmpty);
    expect(key.currentState!.topRoute!.animation!.value, 1.0);
  });
}
