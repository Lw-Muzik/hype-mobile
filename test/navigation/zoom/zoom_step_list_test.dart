import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'zoom_test_helpers.dart';

void main() {
  testWidgets('idle renders a plain list', (t) async {
    await t.pumpWidget(harness());
    expect(find.byType(ListView), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    expect(find.byKey(const ValueKey('i0L')), findsOneWidget);
  });

  testWidgets('spread 1.8x moves step 0 to 1 and reports once', (t) async {
    final calls = <int>[];
    await t.pumpWidget(harness(onChanged: calls.add));
    final g = await startPinch(t, 100);
    await setSpan(t, g, 115); // crosses the slop; start span resets to 115
    await setSpan(t, g, 115 * 1.8);
    await g.$1.up();
    await g.$2.up();
    await t.pumpAndSettle();
    expect(calls, [1]);
    expect(find.byType(GridView), findsOneWidget);
    expect(find.byKey(const ValueKey('i3G')), findsOneWidget);
  });

  testWidgets('mid-pinch the item rect lies between both step rects', (
    t,
  ) async {
    await t.pumpWidget(harness());
    final g = await startPinch(t, 100);
    await setSpan(t, g, 115);
    await setSpan(t, g, 115 * 1.4); // raw 0.5
    final r = t.getRect(find.byKey(const ValueKey('zoom-item-3')));
    // List rect (0,240,400,80) -> grid rect (200,200,200,200).
    expect(r.left, inExclusiveRange(0, 200));
    expect(r.top, inExclusiveRange(200, 240));
    expect(r.width, inExclusiveRange(200, 400));
    expect(r.height, inExclusiveRange(80, 200));
    expect(r.left, closeTo(100, 1));
    await g.$1.up();
    await g.$2.up();
    await t.pumpAndSettle();
  });

  testWidgets('small pinch cancels back to the same step', (t) async {
    final calls = <int>[];
    await t.pumpWidget(harness(onChanged: calls.add));
    final g = await startPinch(t, 100);
    await setSpan(t, g, 115);
    await setSpan(t, g, 115 * 1.1);
    await g.$1.up();
    await g.$2.up();
    await t.pumpAndSettle();
    expect(calls, isEmpty);
    expect(find.byType(ListView), findsOneWidget);
  });

  testWidgets('pinch out from the grid goes back to the list', (t) async {
    final calls = <int>[];
    await t.pumpWidget(harness(step: 1, onChanged: calls.add));
    final g = await startPinch(t, 200);
    await setSpan(t, g, 185);
    await setSpan(t, g, 185 * 0.25);
    await g.$1.up();
    await g.$2.up();
    await t.pumpAndSettle();
    expect(calls, [0]);
    expect(find.byType(ListView), findsOneWidget);
  });

  testWidgets('new step keeps the middle visible item centred', (t) async {
    final c = ScrollController();
    addTearDown(c.dispose);
    await t.pumpWidget(harness(count: 200, controller: c));
    c.jumpTo(4000); // list rows 80 tall: first visible 50
    await t.pump();
    final g = await startPinch(t, 100);
    await setSpan(t, g, 115);
    await setSpan(t, g, 115 * 1.9);
    await g.$1.up();
    await g.$2.up();
    await t.pumpAndSettle();
    // anchor = 50 + 8 = 58 (first 50, last 57 or so); grid row of it centred.
    final first = (4000 / 80).floor();
    final last = ((4000 + 600) / 80).floor();
    final anchor = first + (last - first + 1) ~/ 2;
    final row = anchor ~/ 2;
    expect(c.offset, closeTo(row * 200 + 100 - 300, 0.01));
  });

  testWidgets('cross-fade opacities are 1-p and p', (t) async {
    await t.pumpWidget(harness());
    final g = await startPinch(t, 100);
    await setSpan(t, g, 115);
    await setSpan(t, g, 115 * 1.4); // raw 0.5
    expect(fadeOf(t, 3, 'from'), closeTo(0.5, 1e-6));
    expect(fadeOf(t, 3, 'to'), closeTo(0.5, 1e-6));
    await setSpan(t, g, 115 * 1.2); // raw 0.25
    expect(fadeOf(t, 3, 'from'), closeTo(0.75, 1e-6));
    expect(fadeOf(t, 3, 'to'), closeTo(0.25, 1e-6));
    await g.$1.up();
    await g.$2.up();
    await t.pumpAndSettle();
  });

  testWidgets('zoom-in: list-only items grow towards 1.5x and fade', (t) async {
    await t.pumpWidget(harness());
    final g = await startPinch(t, 100);
    await setSpan(t, g, 115);
    await setSpan(t, g, 115 * 1.4); // p = 0.5
    // Items 6 and 7 are visible in the list but not in the grid.
    final r = t.getRect(find.byKey(const ValueKey('i6L')));
    expect(r.width, closeTo(400 * 1.25, 0.5));
    final o = t.widget<Opacity>(
      find.descendant(
        of: find.byKey(const ValueKey('zoom-item-6')),
        matching: find.byType(Opacity),
      ),
    );
    expect(o.opacity, closeTo(0.5, 1e-6));
    await g.$1.up();
    await g.$2.up();
    await t.pumpAndSettle();
  });

  testWidgets('zoom-out: list-only items arrive from 1.5x and fade in', (
    t,
  ) async {
    await t.pumpWidget(harness(step: 1));
    final g = await startPinch(t, 200);
    await setSpan(t, g, 185);
    await setSpan(t, g, 185 * 0.6); // raw 0.5
    final r = t.getRect(find.byKey(const ValueKey('i6L')));
    expect(r.width, closeTo(400 * 1.25, 0.5));
    final o = t.widget<Opacity>(
      find.descendant(
        of: find.byKey(const ValueKey('zoom-item-6')),
        matching: find.byType(Opacity),
      ),
    );
    expect(o.opacity, closeTo(0.5, 1e-6));
    await g.$1.up();
    await g.$2.up();
    await t.pumpAndSettle();
  });

  testWidgets('cancel keeps the scroll offset', (t) async {
    final c = ScrollController();
    addTearDown(c.dispose);
    await t.pumpWidget(harness(count: 200, controller: c));
    c.jumpTo(1234);
    await t.pump();
    final g = await startPinch(t, 100);
    await setSpan(t, g, 115);
    await setSpan(t, g, 115 * 1.1);
    await g.$1.up();
    await g.$2.up();
    await t.pumpAndSettle();
    expect(c.offset, closeTo(1234, 0.01));
  });

  testWidgets(
    'fast spread, then a 300 ms hold before lift, settles by the slow rule',
    (t) async {
      final calls = <int>[];
      await t.pumpWidget(harness(onChanged: calls.add));
      final g1 = await t.startGesture(const Offset(150, 300), pointer: 1);
      final g2 = await t.startGesture(const Offset(250, 300), pointer: 2);
      var ms = 0;
      Duration ts() => Duration(milliseconds: ms);
      Future<void> to(double span) async {
        await g1.moveTo(Offset(200 - span / 2, 300), timeStamp: ts());
        await g2.moveTo(Offset(200 + span / 2, 300), timeStamp: ts());
        await t.pump();
      }

      await to(115);
      ms += 20;
      await to(160);
      ms += 20;
      await to(205); // ~2250 dp/s
      ms += 300;
      await g1.up(timeStamp: ts());
      await g2.up(timeStamp: ts());
      await t.pump();
      // p = 1.25*(205/115-1) = ~0.98 > 0.8 anyway; use the time to prove no
      // glide: a timed settle at p~0.98 takes the 100 ms floor and ends.
      await t.pumpAndSettle();
      expect(calls, [1]);
    },
  );

  testWidgets('stale velocity: a mid-progress release is not a glide', (
    t,
  ) async {
    final calls = <int>[];
    await t.pumpWidget(harness(onChanged: calls.add));
    final g1 = await t.startGesture(const Offset(150, 300), pointer: 1);
    final g2 = await t.startGesture(const Offset(250, 300), pointer: 2);
    var ms = 0;
    Duration ts() => Duration(milliseconds: ms);
    Future<void> to(double span) async {
      await g1.moveTo(Offset(200 - span / 2, 300), timeStamp: ts());
      await g2.moveTo(Offset(200 + span / 2, 300), timeStamp: ts());
      await t.pump();
    }

    await to(115);
    ms += 10;
    await to(135);
    ms += 10;
    await to(155); // 2000 dp/s, p = 0.43
    ms += 300;
    await g1.up(timeStamp: ts());
    await g2.up(timeStamp: ts());
    await t.pump();
    // Timed settle from p 0.43 lasts max(100, 500*0.57) = 285 ms. A glide at
    // 2000/115/4 = 4.3 progress/s would end in 130 ms.
    await t.pump(const Duration(milliseconds: 200));
    expect(find.byType(GridView), findsNothing);
    await t.pumpAndSettle();
    expect(calls, [1]);
  });

  testWidgets('end-step reversal heads for the opposite neighbour', (t) async {
    final calls = <int>[];
    await t.pumpWidget(harness(step: 1, onChanged: calls.add));
    final g = await startPinch(t, 200);
    await setSpan(t, g, 215); // spreading at the last step: end band
    await setSpan(t, g, 240);
    await setSpan(t, g, 215 * 0.3); // reversed past the start: zoom-out
    await g.$1.up();
    await g.$2.up();
    await t.pumpAndSettle();
    expect(calls, [0]);
    expect(find.byType(ListView), findsOneWidget);
  });

  testWidgets('rubber band at an end step relaxes along a cubic over 350 ms', (
    t,
  ) async {
    await t.pumpWidget(harness(step: 1));
    final g = await startPinch(t, 100);
    await setSpan(t, g, 115);
    await setSpan(t, g, 115 * 1.6);
    const s0 = 0.2 * 0.40824829046386296; // sqrt(0.2*0.75/0.9) = 0.40825
    final w0 = t.getRect(find.byKey(const ValueKey('i0G'))).width;
    expect(w0, closeTo(200 * (1 + s0), 0.2));
    await g.$1.up();
    await g.$2.up();
    await t.pump();
    await t.pump(const Duration(milliseconds: 175));
    final w1 = t.getRect(find.byKey(const ValueKey('i0G'))).width;
    expect(w1, closeTo(200 * (1 + s0 * 0.125), 0.2));
    await t.pump(const Duration(milliseconds: 200));
    await t.pumpAndSettle();
    expect(
      t.getRect(find.byKey(const ValueKey('i0G'))).width,
      closeTo(200, 0.01),
    );
  });

  testWidgets('parent that keeps the old step wins after a commit', (t) async {
    await t.pumpWidget(harness(follow: false));
    final g = await startPinch(t, 100);
    await setSpan(t, g, 115);
    await setSpan(t, g, 115 * 1.9);
    await g.$1.up();
    await g.$2.up();
    await t.pumpAndSettle();
    expect(find.byType(ListView), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
  });

  testWidgets('parent that changes step mid-pinch wins after the pinch', (
    t,
  ) async {
    await t.pumpWidget(harness());
    final g = await startPinch(t, 100);
    await setSpan(t, g, 115);
    await setSpan(t, g, 115 * 1.2);
    // Parent moves to step 1 while fingers are down, pinch then cancels.
    await t.pumpWidget(harness(step: 1));
    await g.$1.up();
    await g.$2.up();
    await t.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);
  });
}
