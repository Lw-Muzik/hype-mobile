import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:flutter_test/flutter_test.dart';

import '../library/library_harness.dart';

void main() {
  testWidgets('back from a sibling: closing 1 to 0.5, revealed 1.5 to 1', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    nav.currentState!.openPage(albumPage(), key: albumKey, sibling: true);
    await tester.pumpAndSettle();
    nav.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 75)); // half of 150 ms
    expect(layerScale(tester, find.text('row'), end: 1.5), closeTo(1.25, 0.03));
    expect(
      layerScale(tester, find.text('header'), end: 1),
      closeTo(0.75, 0.03),
    );
    await tester.pump(const Duration(milliseconds: 90));
    await tester.pumpAndSettle(const Duration(milliseconds: 10));
    expect(nav.currentState!.path, isEmpty);
  });

  testWidgets('back from an unmatched page uses the back pivot in 150 ms', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    nav.currentState!.openPage(albumPage(), key: albumKey);
    await tester.pumpAndSettle();
    nav.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 75));
    expect(layerScale(tester, find.text('row'), end: 1.5), closeTo(1.25, 0.03));
    expect(
      layerScale(tester, find.text('header'), end: 1),
      closeTo(0.75, 0.03),
    );
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.text('header'), findsNothing);
  });

  testWidgets('a matched row back is still the reverse of the open', (
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
  });

  testWidgets('a sibling open itself is unchanged: old 0.5, new 1.5', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    nav.currentState!.openPage(
      albumPage(),
      key: const LibraryPageKey('album', {'albumId': 9, 'album': 'Nine'}),
      sibling: true,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 75));
    expect(layerScale(tester, find.text('row'), end: 0.5), closeTo(0.75, 0.03));
    expect(
      layerScale(tester, find.text('header'), end: 1),
      closeTo(1.25, 0.03),
    );
  });
}
