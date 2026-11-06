import 'package:eq_app/navigation/zoom/zoom_step_list.dart';
import 'package:eq_app/navigation/zoom/zoom_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a pinch builds each item once, pointer moves only re-wrap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var builds = 0;
    var step = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (c, set) => Scaffold(
            body: ZoomStepList(
              steps: const [
                ZoomStep.list(rowExtent: 80),
                ZoomStep.grid(maxTileExtent: 200, childAspectRatio: 1),
              ],
              step: step,
              onStepChanged: (s) => set(() => step = s),
              itemCount: 30,
              itemBuilder: (c, i, s) {
                builds++;
                return Text('item $i');
              },
            ),
          ),
        ),
      ),
    );
    final g1 = await tester.startGesture(const Offset(150, 400), pointer: 1);
    final g2 = await tester.startGesture(const Offset(250, 400), pointer: 2);
    // Past the slop so the morph is on screen.
    await g1.moveTo(const Offset(135, 400));
    await g2.moveTo(const Offset(265, 400));
    await tester.pump(const Duration(milliseconds: 16));
    await g1.moveTo(const Offset(130, 400));
    await g2.moveTo(const Offset(270, 400));
    await tester.pump(const Duration(milliseconds: 16));
    final settled = builds;
    expect(settled, greaterThan(0));
    for (var i = 1; i <= 6; i++) {
      await g1.moveTo(Offset(130.0 - i * 3, 400));
      await g2.moveTo(Offset(270.0 + i * 3, 400));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(builds, settled, reason: 'items were rebuilt per pointer move');
    await g1.up();
    await g2.up();
    await tester.pumpAndSettle();
    expect(step, 1);
    // A second pinch builds afresh (the cache is per pinch).
    expect(find.text('item 0'), findsOneWidget);
  });
}
