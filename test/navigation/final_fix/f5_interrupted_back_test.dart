import 'package:eq_app/navigation/library_page_key.dart';
import 'package:flutter_test/flutter_test.dart';

import '../library/library_harness.dart';

void main() {
  testWidgets('back during a sibling open reverses it from where it is', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    nav.currentState!.openPage(
      albumPage(),
      key: const LibraryPageKey('album', {'albumId': 9, 'album': 'Nine'}),
      sibling: true,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final before = layerScale(tester, find.text('row'), end: 0.5);
    final headerBefore = layerScale(tester, find.text('header'), end: 1);
    expect(before, lessThan(1.0)); // mid-open: the old page is shrinking
    nav.currentState!.pop();
    await tester.pump(); // the frame that starts the reverse
    final after = layerScale(tester, find.text('row'), end: 0.5);
    final headerAfter = layerScale(tester, find.text('header'), end: 1);
    expect(after, closeTo(before, 0.03));
    expect(headerAfter, closeTo(headerBefore, 0.03));
    await tester.pumpAndSettle();
    expect(nav.currentState!.path, isEmpty);
  });

  testWidgets('back from rest still uses the back pivot', (tester) async {
    final nav = await pumpNavigator(tester);
    nav.currentState!.openPage(albumPage(), key: albumKey, sibling: true);
    await tester.pumpAndSettle();
    nav.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 75));
    expect(layerScale(tester, find.text('row'), end: 1.5), closeTo(1.25, 0.03));
    await tester.pumpAndSettle();
  });
}
