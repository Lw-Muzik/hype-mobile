import 'package:eq_app/navigation/motion/page_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('interpolates scale and opacity linearly, child built once', (
    tester,
  ) async {
    final p = ValueNotifier<double>(0.5);
    var builds = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: PageLayer(
          progress: p,
          scaleAt0: 1,
          scaleAt1: 1.25,
          opacityAt0: 0,
          opacityAt1: 1,
          pivot: const Offset(10, 20),
          child: Builder(
            builder: (_) {
              builds++;
              return const SizedBox(width: 50, height: 50);
            },
          ),
        ),
      ),
    );
    final t = tester.widget<Transform>(
      find.descendant(
        of: find.byType(PageLayer),
        matching: find.byType(Transform),
      ),
    );
    expect(t.transform.storage[0], closeTo(1.125, 1e-9));
    expect(t.origin, const Offset(10, 20));
    expect(
      tester.widget<Opacity>(find.byType(Opacity)).opacity,
      closeTo(0.5, 1e-9),
    );
    p.value = 1;
    await tester.pump();
    final t2 = tester.widget<Transform>(
      find.descendant(
        of: find.byType(PageLayer),
        matching: find.byType(Transform),
      ),
    );
    expect(t2.transform.storage[0], closeTo(1.25, 1e-9));
    expect(builds, 1);
  });
}
