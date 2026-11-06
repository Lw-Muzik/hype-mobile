import 'package:eq_app/navigation/zoom/zoom_step_list.dart';
import 'package:eq_app/navigation/zoom/zoom_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const zoomTestSteps = <ZoomStep>[
  ZoomStep.list(rowExtent: 80),
  ZoomStep.grid(maxTileExtent: 200, childAspectRatio: 1),
];

/// A parent that follows [ZoomStepList.onStepChanged]. With `follow: false`
/// it keeps the step it was given (a parent that rejects the change).
Widget harness({
  int step = 0,
  int count = 20,
  ValueChanged<int>? onChanged,
  double width = 400,
  double height = 600,
  List<ZoomStep> useSteps = zoomTestSteps,
  ScrollController? controller,
  bool follow = true,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          height: height,
          child: _Parent(
            initialStep: step,
            follow: follow,
            onChanged: onChanged,
            count: count,
            steps: useSteps,
            controller: controller,
          ),
        ),
      ),
    ),
  );
}

class _Parent extends StatefulWidget {
  const _Parent({
    required this.initialStep,
    required this.follow,
    required this.onChanged,
    required this.count,
    required this.steps,
    required this.controller,
  });
  final int initialStep;
  final bool follow;
  final ValueChanged<int>? onChanged;
  final int count;
  final List<ZoomStep> steps;
  final ScrollController? controller;

  @override
  State<_Parent> createState() => _ParentState();
}

class _ParentState extends State<_Parent> {
  late int step = widget.initialStep;

  @override
  void didUpdateWidget(_Parent old) {
    super.didUpdateWidget(old);
    if (old.initialStep != widget.initialStep) step = widget.initialStep;
  }

  @override
  Widget build(BuildContext context) => ZoomStepList(
    steps: widget.steps,
    step: step,
    controller: widget.controller,
    onStepChanged: (s) {
      widget.onChanged?.call(s);
      if (widget.follow) setState(() => step = s);
    },
    itemCount: widget.count,
    itemBuilder: (c, i, s) => Container(
      key: ValueKey('i$i${s is ListZoomStep ? 'L' : 'G'}'),
      color: Colors.blue,
    ),
  );
}

Future<(TestGesture, TestGesture)> startPinch(
  WidgetTester t,
  double span, {
  Offset centre = const Offset(200, 300),
}) async {
  final g1 = await t.startGesture(centre - Offset(span / 2, 0), pointer: 1);
  final g2 = await t.startGesture(centre + Offset(span / 2, 0), pointer: 2);
  return (g1, g2);
}

Future<void> setSpan(
  WidgetTester t,
  (TestGesture, TestGesture) g,
  double span, {
  Offset centre = const Offset(200, 300),
}) async {
  await g.$1.moveTo(centre - Offset(span / 2, 0));
  await g.$2.moveTo(centre + Offset(span / 2, 0));
  await t.pump();
}

/// Opacity of the shared item's cross-fade child ('from' or 'to').
double fadeOf(WidgetTester t, int item, String which) => t
    .widget<Opacity>(
      find.descendant(
        of: find.byKey(ValueKey('zoom-item-$item')),
        matching: find.byKey(ValueKey(which)),
      ),
    )
    .opacity;
