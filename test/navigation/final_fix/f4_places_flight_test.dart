import 'package:eq_app/navigation/library/library_navigator.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/motion/morph.dart';
import 'package:eq_app/navigation/places/place_scaffold.dart';
import 'package:eq_app/navigation/places/places_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Finder _flights() => find.ancestor(
  of: find.byType(FittedBox),
  matching: find.byType(Positioned),
);

Future<GlobalKey<LibraryNavigatorState>> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = GlobalKey<LibraryNavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      home: MorphScope(
        child: LibraryNavigator(
          key: key,
          root: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 180,
                height: 138,
                child: PlaceTile(id: PlaceId.albums, onTap: () {}),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return key;
}

Future<void> _open(GlobalKey<LibraryNavigatorState> nav) =>
    nav.currentState!.openPage(
      PlaceScaffold(
        id: PlaceId.albums,
        onBack: () {},
        onMenu: () {},
        onSearch: () {},
        body: const SizedBox.expand(),
      ),
      key: LibraryPageKey.place(PlaceId.albums.name),
      morphFrom: PlaceId.albums.morphTag,
    );

void main() {
  testWidgets('opening a place flies the block into the title', (tester) async {
    final nav = await _pump(tester);
    expect(_flights(), findsNothing);
    _open(nav);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 125));
    expect(_flights(), findsWidgets);
    await tester.pumpAndSettle();
  });

  testWidgets('backing out of a place flies the title into the block', (
    tester,
  ) async {
    final nav = await _pump(tester);
    _open(nav);
    await tester.pumpAndSettle();
    expect(_flights(), findsNothing);
    nav.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 125));
    expect(_flights(), findsWidgets);
    await tester.pumpAndSettle();
  });

  testWidgets('the whole block is the tag, so the page grows out of it', (
    tester,
  ) async {
    await _pump(tester);
    final tag = find.descendant(
      of: find.byType(PlaceTile),
      matching: find.byType(MorphTag),
      matchRoot: true,
    );
    expect(tester.getSize(tag.first), tester.getSize(find.byType(PlaceTile)));
  });
}
