import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'library_harness.dart';

Future<void> _swipe(WidgetTester tester, double dx) async {
  final g = await tester.startGesture(const Offset(100, 400));
  var moved = 0.0;
  while (moved < dx) {
    final step = (dx - moved).clamp(0.0, 40.0);
    await g.moveBy(Offset(step, 0));
    moved += step;
    await tester.pump(const Duration(milliseconds: 50));
  }
  // Stand still so the release velocity is zero.
  await tester.pump(const Duration(milliseconds: 300));
  await g.up();
}

void main() {
  testWidgets('back mirrors the open: parent 1.25, child 0.75 at 125 ms', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    nav.currentState!.openPage(
      albumPage(),
      key: albumKey,
      morphFrom: itemTag(albumKey),
    );
    await tester.pumpAndSettle();

    nav.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 125));
    expect(layerScale(tester, find.text('row'), end: 1.5), closeTo(1.25, 0.05));
    expect(
      layerScale(tester, find.text('header'), end: 1),
      closeTo(0.75, 0.05),
    );
    await tester.pumpAndSettle();
    expect(nav.currentState!.path, isEmpty);
  });

  testWidgets('a second back during the transition does not skip a level', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    final s = nav.currentState!;
    s.openPage(albumPage(), key: albumKey);
    await tester.pumpAndSettle();
    s.openPage(
      albumPage(),
      key: const LibraryPageKey('album', {'albumId': 6, 'album': 'Six'}),
    );
    await tester.pumpAndSettle();
    expect(s.path.length, 2);

    s.pop();
    await tester.pump(const Duration(milliseconds: 60));
    expect(await s.pop(), isTrue); // swallowed, not a second pop
    await tester.pumpAndSettle();
    expect(s.path.length, 1);
  });

  testWidgets('swipe at 31 percent commits', (tester) async {
    final nav = await pumpNavigator(tester);
    nav.currentState!.openPage(albumPage(), key: albumKey);
    await tester.pumpAndSettle();

    await _swipe(tester, 8 + 0.31 * 800);
    await tester.pumpAndSettle();
    expect(nav.currentState!.path, isEmpty);
  });

  testWidgets('swipe at 25 percent cancels', (tester) async {
    final nav = await pumpNavigator(tester);
    nav.currentState!.openPage(albumPage(), key: albumKey);
    await tester.pumpAndSettle();

    await _swipe(tester, 8 + 0.25 * 800);
    await tester.pumpAndSettle();
    expect(nav.currentState!.path, [albumKey]);
    expect(find.byKey(const ValueKey('album-body')), findsOneWidget);
  });

  testWidgets('at the root the page rubber-bands and returns in 350 ms', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    final root = find.byKey(const ValueKey('row-src'));
    final x0 = tester.getTopLeft(root).dx;

    final g = await tester.startGesture(const Offset(100, 400));
    await g.moveBy(const Offset(40, 0));
    await tester.pump(const Duration(milliseconds: 50));
    await g.moveBy(const Offset(160, 0));
    await tester.pump(const Duration(milliseconds: 50));
    final dragged = tester.getTopLeft(root).dx - x0;
    // finger fraction (200 - 8) / 800 = 0.24; offset = 0.25 * 800 * 0.24
    expect(dragged, closeTo(48, 6));
    await tester.pump(const Duration(milliseconds: 300));
    await g.up();
    await tester.pump(); // the return's first frame

    await tester.pump(const Duration(milliseconds: 175));
    final mid = tester.getTopLeft(root).dx - x0;
    expect(mid, lessThan(dragged));
    expect(mid, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 190));
    expect(tester.getTopLeft(root).dx - x0, closeTo(0, 0.01));
    expect(nav.currentState!.path, isEmpty);
  });
}
