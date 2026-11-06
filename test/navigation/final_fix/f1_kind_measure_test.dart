import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/motion/morph.dart';
import 'package:eq_app/navigation/zoom/zoom_step_list.dart';
import 'package:eq_app/navigation/zoom/zoom_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../library/library_harness.dart';

void main() {
  testWidgets('the header is measured after the corrected kind has painted', (
    tester,
  ) async {
    // The key says "list" but the page's zoom list shows a grid step.
    final page = Scaffold(
      body: Column(
        children: [
          MorphTag(
            tag: headerTag(albumKey),
            child: Container(
              width: double.infinity,
              height: 240,
              color: Colors.blue,
              child: const Text('header'),
            ),
          ),
          Expanded(
            child: ZoomStepList(
              steps: const [
                ZoomStep.list(rowExtent: 72),
                ZoomStep.grid(maxTileExtent: 200, childAspectRatio: 1),
              ],
              step: 1,
              onStepChanged: (_) {},
              itemCount: 4,
              itemBuilder: (c, i, st) => Text('item $i'),
            ),
          ),
        ],
      ),
    );
    final nav = await pumpNavigator(tester, root: rootList(grid: true));
    nav.currentState!.openPage(
      page,
      key: albumKey,
      morphFrom: itemTag(albumKey),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    final route = nav.currentState!.topRoute!;
    expect(route.destinationIsGrid, isTrue);
    final rest = route.headerRest;
    expect(rest, isNotNull);
    expect(rest!.left, closeTo(0, 1));
    expect(rest.top, closeTo(0, 1));
    expect(rest.width, closeTo(800, 1));
    await tester.pumpAndSettle();
  });
}
