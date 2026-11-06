import 'package:eq_app/navigation/motion/back_swipe.dart';
import 'package:eq_app/navigation/motion_spec.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Rec {
  final updates = <double>[];
  final events = <String>[];
  final ends = <double>[];
}

Widget _host(_Rec r, Widget child, {bool enabled = true}) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(
    child: SizedBox(
      width: 400,
      height: 600,
      child: BackSwipeDetector(
        enabled: enabled,
        onStart: () => r.events.add('start'),
        onUpdate: r.updates.add,
        onEnd: (v) {
          r.events.add('end');
          r.ends.add(v);
        },
        onCancel: () => r.events.add('cancel'),
        child: child,
      ),
    ),
  ),
);

const _black = ColoredBox(color: Colors.black);

void main() {
  testWidgets('rightward drag reports distance beyond slop over width', (
    tester,
  ) async {
    final r = _Rec();
    await tester.pumpWidget(_host(r, _black));
    final g = await tester.startGesture(const Offset(300, 300));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(10.8, 0));
    }
    expect(r.events.first, 'start');
    expect(r.updates.last, closeTo((108 - MotionSpec.dragSlop) / 400, 0.005));
    await g.up();
    expect(r.events.last, 'end');
  });

  testWidgets('onEnd reports px/s over width', (tester) async {
    final r = _Rec();
    await tester.pumpWidget(_host(r, _black));
    final g = await tester.startGesture(const Offset(300, 300));
    // 20 px every 10 ms = 2000 px/s = 5 widths/s.
    for (var i = 0; i < 8; i++) {
      await g.moveBy(
        const Offset(20, 0),
        timeStamp: Duration(milliseconds: 10 * (i + 1)),
      );
    }
    await g.up(timeStamp: const Duration(milliseconds: 90));
    expect(r.ends.single, closeTo(5, 0.8));
  });

  testWidgets('vertical drag reports nothing and the list scrolls', (
    tester,
  ) async {
    final r = _Rec();
    final controller = ScrollController();
    await tester.pumpWidget(
      _host(
        r,
        ListView(
          controller: controller,
          children: [
            for (var i = 0; i < 50; i++)
              SizedBox(height: 50, child: Text('$i')),
          ],
        ),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(r.updates, isEmpty);
    expect(r.events, isEmpty);
    expect(controller.offset, greaterThan(0));
  });

  testWidgets('a leftward drag reports negative progress', (tester) async {
    final r = _Rec();
    await tester.pumpWidget(_host(r, _black));
    final g = await tester.startGesture(const Offset(300, 300));
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(-20, 0));
    }
    await g.up();
    expect(r.updates, isNotEmpty);
    expect(r.updates.every((u) => u < 0), isTrue);
  });

  testWidgets('diagonal drags are ignored', (tester) async {
    final r = _Rec();
    await tester.pumpWidget(_host(r, _black));
    final g = await tester.startGesture(const Offset(300, 300));
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(10, 20));
    }
    await g.up();
    expect(r.events, isEmpty);
    expect(r.updates, isEmpty);
  });

  testWidgets('enabled: false ignores drags', (tester) async {
    final r = _Rec();
    await tester.pumpWidget(_host(r, _black, enabled: false));
    final g = await tester.startGesture(const Offset(300, 300));
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(20, 0));
    }
    await g.up();
    expect(r.events, isEmpty);
  });

  Widget hList(ScrollController c) => ListView(
    controller: c,
    scrollDirection: Axis.horizontal,
    children: [
      for (var i = 0; i < 20; i++) SizedBox(width: 100, child: Text('$i')),
    ],
  );

  testWidgets('yields to a horizontal list that can scroll back', (
    tester,
  ) async {
    final r = _Rec();
    final c = ScrollController(initialScrollOffset: 500);
    await tester.pumpWidget(_host(r, hList(c)));
    final g = await tester.startGesture(const Offset(300, 300));
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(20, 0));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(r.events, isEmpty);
    expect(c.offset, lessThan(500));
  });

  testWidgets('wins over a horizontal list at its start', (tester) async {
    final r = _Rec();
    final c = ScrollController();
    await tester.pumpWidget(_host(r, hList(c)));
    final g = await tester.startGesture(const Offset(300, 300));
    for (var i = 0; i < 40; i++) {
      await g.moveBy(const Offset(4, 0));
    }
    expect(r.events.first, 'start');
    expect(r.updates, isNotEmpty);
    await g.up();
    await tester.pumpAndSettle();
    expect(c.offset, 0);
  });

  testWidgets('host rebuild mid-drag keeps progress continuous', (
    tester,
  ) async {
    final r = _Rec();
    await tester.pumpWidget(_host(r, _black));
    final g = await tester.startGesture(const Offset(300, 300));
    for (var i = 0; i < 5; i++) {
      await g.moveBy(const Offset(10, 0));
    }
    final before = r.updates.last;
    final r2 = _Rec();
    await tester.pumpWidget(_host(r2, const ColoredBox(color: Colors.red)));
    await g.moveBy(const Offset(10, 0));
    expect(r2.updates.last - before, closeTo(10 / 400, 0.002));
    await g.up();
  });

  testWidgets('disabling mid-drag reports cancel', (tester) async {
    final r = _Rec();
    await tester.pumpWidget(_host(r, _black));
    final g = await tester.startGesture(const Offset(300, 300));
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(10, 0));
    }
    expect(r.events, ['start']);
    await tester.pumpWidget(_host(r, _black, enabled: false));
    await tester.pump();
    expect(r.events, ['start', 'cancel']);
    await g.up();
  });
}
