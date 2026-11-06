import 'package:eq_app/navigation/library/library_navigator.dart';
import 'package:eq_app/navigation/motion/morph.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a second finger during a root swipe cancels, never ends', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var last = 0.0;
    final ends = <double>[];
    var cancels = 0;
    final key = GlobalKey<LibraryNavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: MorphScope(
          child: LibraryNavigator(
            key: key,
            root: const Scaffold(body: SizedBox.expand()),
            onRootSwipeStart: () => true,
            onRootSwipeUpdate: (p) => last = p,
            onRootSwipeEnd: ends.add,
            onRootSwipeCancel: () => cancels++,
          ),
        ),
      ),
    );
    final g1 = await tester.startGesture(const Offset(50, 400), pointer: 1);
    for (var i = 0; i < 8; i++) {
      await g1.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(last, greaterThan(0.3));
    final g2 = await tester.startGesture(const Offset(300, 600), pointer: 2);
    await tester.pump(const Duration(milliseconds: 16));
    await g1.up();
    await g2.up();
    await tester.pumpAndSettle();
    expect(cancels, 1);
    expect(ends, isEmpty);
  });

  testWidgets('a normal release still ends with its velocity', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ends = <double>[];
    var cancels = 0;
    final key = GlobalKey<LibraryNavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: MorphScope(
          child: LibraryNavigator(
            key: key,
            root: const Scaffold(body: SizedBox.expand()),
            onRootSwipeStart: () => true,
            onRootSwipeUpdate: (_) {},
            onRootSwipeEnd: ends.add,
            onRootSwipeCancel: () => cancels++,
          ),
        ),
      ),
    );
    final g = await tester.startGesture(const Offset(50, 400));
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(ends.length, 1);
    expect(cancels, 0);
  });
}
