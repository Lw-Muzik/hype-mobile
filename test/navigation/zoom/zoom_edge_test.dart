import 'package:eq_app/navigation/zoom/zoom_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'zoom_test_helpers.dart' as base;

void main() {
  Future<void> pinch(WidgetTester t, double from, double to) async {
    final g = await base.startPinch(t, 100);
    await base.setSpan(t, g, 115);
    await base.setSpan(t, g, to);
    await g.$1.up();
    await g.$2.up();
    await t.pumpAndSettle();
  }

  testWidgets('zero items', (t) async {
    final calls = <int>[];
    await t.pumpWidget(base.harness(count: 0, onChanged: calls.add));
    await pinch(t, 100, 115 * 1.9);
    expect(t.takeException(), isNull);
    expect(calls.every((c) => c >= 0 && c < 2), isTrue);
    expect(
      find.byType(ListView).evaluate().length +
          find.byType(GridView).evaluate().length,
      1,
    );
    expect(find.byType(Container), findsNothing);
  });

  testWidgets('one item', (t) async {
    await t.pumpWidget(base.harness(count: 1));
    await pinch(t, 100, 115 * 1.9);
    expect(t.takeException(), isNull);
    expect(find.byKey(const ValueKey('i0G')), findsOneWidget);
    expect(find.byType(Container), findsOneWidget);
  });

  testWidgets('pinch past the last step rubber-bands and stays valid', (
    t,
  ) async {
    final calls = <int>[];
    await t.pumpWidget(base.harness(step: 1, onChanged: calls.add));
    final g = await base.startPinch(t, 100);
    await base.setSpan(t, g, 115);
    await base.setSpan(t, g, 115 * 1.6);
    final r = t.getRect(find.byKey(const ValueKey('i0G')));
    expect(r.width, greaterThan(200)); // grew
    await g.$1.up();
    await g.$2.up();
    await t.pumpAndSettle();
    expect(calls, isEmpty);
    expect(find.byType(GridView), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('one step per pinch even when overshooting', (t) async {
    final calls = <int>[];
    const three = <ZoomStep>[
      ZoomStep.list(rowExtent: 80),
      ZoomStep.grid(maxTileExtent: 200, childAspectRatio: 1),
      ZoomStep.grid(maxTileExtent: 400, childAspectRatio: 1),
    ];
    await t.pumpWidget(base.harness(useSteps: three, onChanged: calls.add));
    await pinch(t, 100, 115 * 3);
    expect(calls, [1]);
  });

  testWidgets('pinch during a fling', (t) async {
    await t.pumpWidget(base.harness(count: 200));
    await t.fling(find.byType(ListView), const Offset(0, -300), 3000);
    await t.pump(const Duration(milliseconds: 50));
    await pinch(t, 100, 115 * 1.9);
    expect(t.takeException(), isNull);
    expect(find.byType(GridView), findsOneWidget);
  });

  testWidgets('viewport resize mid-pinch', (t) async {
    await t.pumpWidget(base.harness());
    final g = await base.startPinch(t, 100);
    await base.setSpan(t, g, 115);
    await base.setSpan(t, g, 115 * 1.4);
    await t.pumpWidget(base.harness(width: 300, height: 400));
    await base.setSpan(t, g, 115 * 1.6);
    await g.$1.up();
    await g.$2.up();
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    final items = find.byType(Container).evaluate().length;
    expect(items, inInclusiveRange(1, 20));
  });

  testWidgets('step prop change while idle is followed', (t) async {
    await t.pumpWidget(base.harness());
    await t.pumpWidget(base.harness(step: 1));
    expect(find.byType(GridView), findsOneWidget);
  });
}
