import 'package:eq_app/navigation/library/library_navigator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../library/library_harness.dart';

PredictiveBackEvent _ev(double p) => PredictiveBackEvent.fromMap({
  'touchOffset': [0.0, 300.0],
  'progress': p,
  'swipeEdge': 0,
});

void main() {
  testWidgets('predictive back does not start while the top page opens', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    final s = nav.currentState!..systemBackEnabled = true;
    s.openPage(albumPage(), key: albumKey);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(s.handleStartBackGesture(_ev(0)), isFalse);
    await tester.pumpAndSettle();
    expect(s.handleStartBackGesture(_ev(0)), isTrue);
    s.handleCancelBackGesture();
    await tester.pumpAndSettle();
  });

  testWidgets('a finger swipe does not start while the top page opens', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    final s = nav.currentState!;
    s.openPage(albumPage(), key: albumKey);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final g = await tester.startGesture(const Offset(100, 400));
    await g.moveBy(const Offset(200, 0));
    await tester.pump(const Duration(milliseconds: 30));
    expect(s.topRoute!.swipeDir.value, 0);
    await g.moveBy(const Offset(200, 0));
    await tester.pump(const Duration(milliseconds: 20));
    await g.up();
    await tester.pumpAndSettle();
    expect(s.path, [albumKey]);
  });

  testWidgets('a removed route is not touched when its swipe settles', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    final s = nav.currentState!;
    s.openPage(albumPage(), key: albumKey);
    await tester.pumpAndSettle();
    final g = await tester.startGesture(const Offset(100, 400));
    await g.moveBy(const Offset(120, 0));
    await tester.pump(const Duration(milliseconds: 50));
    await g.moveBy(const Offset(120, 0));
    await tester.pump(const Duration(milliseconds: 300));
    await g.up(); // slow release at 0.3: a timed settle starts
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    // The stack is replaced while the settle runs.
    await s.showPath(const []);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final navigator = tester.state<NavigatorState>(
      find.descendant(
        of: find.byType(LibraryNavigator),
        matching: find.byType(Navigator),
      ),
    );
    expect(navigator.userGestureInProgress, isFalse);
    expect(s.path, isEmpty);
  });
}
