import 'package:eq_app/navigation/motion/back_swipe.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A horizontal list already scrolled away from its start, so a rightward drag
/// over it belongs to the list, unless the list is not on screen.
Widget _host({required bool offstage, required List<double> updates}) {
  final controller = ScrollController(initialScrollOffset: 300);
  return MaterialApp(
    home: BackSwipeDetector(
      enabled: true,
      onStart: () {},
      onUpdate: updates.add,
      onEnd: (_) {},
      child: Stack(
        children: [
          Offstage(
            offstage: offstage,
            child: SizedBox(
              height: 600,
              child: ListView(
                controller: controller,
                scrollDirection: Axis.horizontal,
                children: [
                  for (var i = 0; i < 10; i++)
                    const SizedBox(width: 200, child: Placeholder()),
                ],
              ),
            ),
          ),
          if (offstage) const SizedBox.expand(),
        ],
      ),
    ),
  );
}

Future<void> _drag(WidgetTester tester) async {
  final g = await tester.startGesture(const Offset(300, 300));
  for (var i = 0; i < 6; i++) {
    await g.moveBy(const Offset(30, 0));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await g.up();
}

void main() {
  testWidgets('a horizontal list that can scroll back keeps the drag', (
    tester,
  ) async {
    final updates = <double>[];
    await tester.pumpWidget(_host(offstage: false, updates: updates));
    await _drag(tester);
    expect(updates, isEmpty);
  });

  testWidgets('the same list offstage (a covered page) is skipped', (
    tester,
  ) async {
    final updates = <double>[];
    await tester.pumpWidget(_host(offstage: true, updates: updates));
    await _drag(tester);
    expect(updates, isNotEmpty);
  });
}
