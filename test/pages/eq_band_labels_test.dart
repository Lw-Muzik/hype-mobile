import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eq_app/pages/graphic_eq_view.dart';

void main() {
  testWidgets('32 band value labels fit at 360x780 and show when idle',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: List.generate(
                32,
                (i) => SizedBox(
                  height: 400,
                  child: EqBandSlider(
                    frequency: 20.0 * (i + 1),
                    gain: i.isEven ? -12.5 : 12.5,
                    valueLabel: i.isEven ? '-12.5' : '+12.5',
                    width: 38,
                    isActive: false,
                    showLabel: true,
                    onChanged: (_) {},
                    onDragStart: () {},
                    onDragEnd: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('+12.5'), findsWidgets);
    final op = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity).first);
    expect(op.opacity, greaterThan(0));
  });

  testWidgets('null label renders nothing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 400,
            child: EqBandSlider(
              frequency: 1000,
              gain: 3,
              valueLabel: null,
              width: 38,
              isActive: false,
              showLabel: true,
              onChanged: (_) {},
              onDragStart: () {},
              onDragEnd: () {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('+3.0'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
