import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'library_harness.dart';

void main() {
  testWidgets('open: old layer 1.25, new 0.75 and the flight midway at 125 ms', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    final rowRect = tester.getRect(find.byKey(const ValueKey('row-src')));
    expect(rowRect.width, 800);

    nav.currentState!.openPage(
      albumPage(),
      key: albumKey,
      morphFrom: itemTag(albumKey),
    );
    await tester.pump(); // push, first frame
    await tester.pump(const Duration(milliseconds: 125));

    final old = layerScale(tester, find.text('row'), end: 1.5);
    final fresh = layerScale(tester, find.text('header'), end: 1);
    expect(old, closeTo(1.25, 0.05));
    expect(fresh, closeTo(0.75, 0.05));

    // The flight: a Positioned stand-in that is not an ancestor-free real tag.
    final positioned = find
        .ancestor(
          of: find.byKey(const ValueKey('row-src')),
          matching: find.byType(Positioned),
        )
        .evaluate()
        .map((e) => e.widget as Positioned)
        .where((p) => p.width != null)
        .toList();
    expect(positioned, hasLength(1));
    final p = positioned.single;
    // Row (0,100,800x72) to header (0,0,800x240), halfway.
    expect(p.left, closeTo(0, 2));
    expect(p.top, closeTo(50, 4));
    expect(p.width, closeTo(800, 2));
    expect(p.height, closeTo(156, 4));

    await tester.pumpAndSettle();
    final headerRect = tester.getRect(find.text('header').first);
    expect(headerRect.width, greaterThan(0));
  });

  testWidgets('open: at 62.5 ms the layers are 1.073 and 0.573', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    nav.currentState!.openPage(
      albumPage(),
      key: albumKey,
      morphFrom: itemTag(albumKey),
    );
    await tester.pump();
    await tester.pump(const Duration(microseconds: 62500));
    expect(
      layerScale(tester, find.text('row'), end: 1.5),
      closeTo(1.073, 0.01),
    );
    expect(
      layerScale(tester, find.text('header'), end: 1),
      closeTo(0.573, 0.01),
    );
  });

  testWidgets('open: the incoming page is drawn above the outgoing one', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    nav.currentState!.openPage(albumPage(), key: albumKey);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final order = tester.allElements.map((e) => e.widget).toList();
    int at(String t) => order.indexWhere((w) => w is Text && w.data == t);
    expect(at('header'), greaterThan(at('row')));
  });

  testWidgets('open: the page is on the path and the root keeps its state', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    nav.currentState!.openPage(albumPage(), key: albumKey);
    await tester.pumpAndSettle();
    expect(nav.currentState!.path, [albumKey]);
    expect(nav.currentState!.canPop, isTrue);
  });
}
