import 'package:eq_app/navigation/library/page_factory.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../library/library_harness.dart';

// Pulling the player away rebuilds the trail to the playing list. When that
// trail is already open, nothing may be rebuilt: page builders query the
// library, and on a slow device the move waited for them (found on a tablet).
void main() {
  final built = <String, int>{};

  setUp(() {
    clearLibraryPages();
    built.clear();
    for (final kind in ['place', 'album']) {
      registerLibraryPage(kind, (key, context) async {
        built[kind] = (built[kind] ?? 0) + 1;
        return Scaffold(body: Text('${key.kind}:${key.args}'));
      });
    }
  });
  tearDown(resetLibraryPages);

  final albums = LibraryPageKey.place('albums');
  const album = LibraryPageKey('album', {'albumId': 5});

  testWidgets('a trail that is already open builds nothing', (tester) async {
    final nav = await pumpNavigator(tester);
    final s = nav.currentState!;
    await s.showPath([albums, album]);
    await tester.pump();
    expect(built, {'place': 1, 'album': 1});

    await s.showPath([albums, album]);
    await tester.pump();
    expect(built, {'place': 1, 'album': 1});
    expect(s.path, [albums, album]);
  });

  testWidgets('a deeper trail builds only the pages past the open ones', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    final s = nav.currentState!;
    await s.showPath([albums]);
    await tester.pump();
    expect(built, {'place': 1});

    await s.showPath([albums, album]);
    await tester.pump();
    expect(built, {'place': 1, 'album': 1});
    expect(s.path, [albums, album]);
    expect(find.text('album:{albumId: 5}'), findsOneWidget);
  });

  testWidgets('a shorter trail trims without building', (tester) async {
    final nav = await pumpNavigator(tester);
    final s = nav.currentState!;
    await s.showPath([albums, album]);
    await tester.pump();
    await s.showPath([albums]);
    await tester.pump();
    expect(built, {'place': 1, 'album': 1});
    expect(s.path, [albums]);
  });
}
