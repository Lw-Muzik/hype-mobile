import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../library/library_harness.dart';

PredictiveBackEvent _ev(double p, int edge) => PredictiveBackEvent.fromMap({
  'touchOffset': [edge == 0 ? 0.0 : 800.0, 300.0],
  'progress': p,
  'swipeEdge': edge,
});

void main() {
  for (final edge in [0, 1]) {
    testWidgets('system cancel from the ${edge == 0 ? 'left' : 'right'} edge '
        'is a cos ease over 250 ms from 0.5', (tester) async {
      final nav = await pumpNavigator(tester);
      final s = nav.currentState!..systemBackEnabled = true;
      s.openPage(albumPage(), key: albumKey);
      await tester.pumpAndSettle();
      expect(s.handleStartBackGesture(_ev(0, edge)), isTrue);
      s.handleUpdateBackGestureProgress(_ev(0.5, edge));
      await tester.pump();
      final route = s.topRoute!;
      expect(route.animation!.value, closeTo(0.5, 0.01));
      s.handleCancelBackGesture();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 125));
      // cos ease: halfway through the time the distance left is half.
      expect(route.animation!.value, closeTo(0.75, 0.03));
      await tester.pump(const Duration(milliseconds: 120));
      expect(route.animation!.value, lessThan(1.0));
      await tester.pumpAndSettle();
      expect(s.path, [albumKey]);
      expect(route.animation!.value, 1.0);
    });
  }

  testWidgets('system cancel past 30 percent still cancels', (tester) async {
    final nav = await pumpNavigator(tester);
    final s = nav.currentState!..systemBackEnabled = true;
    s.openPage(albumPage(), key: albumKey);
    await tester.pumpAndSettle();
    expect(s.handleStartBackGesture(_ev(0, 0)), isTrue);
    s.handleUpdateBackGestureProgress(_ev(0.7, 0));
    await tester.pump();
    s.handleCancelBackGesture();
    await tester.pumpAndSettle();
    expect(s.path, [albumKey]);
  });
}
