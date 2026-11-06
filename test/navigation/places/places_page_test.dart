import 'package:eq_app/navigation/places/places_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({
  required bool isIos,
  void Function(BuildContext, PlaceId)? onOpen,
  VoidCallback? onMenu,
  VoidCallback? onSearch,
}) => MaterialApp(
  home: PlacesPage(
    isIos: isIos,
    onOpen: onOpen ?? (_, _) {},
    onMenu: onMenu ?? () {},
    onSearch: onSearch ?? () {},
  ),
);

void main() {
  test('visiblePlaces keeps spec order and drops Folders on iOS', () {
    expect(visiblePlaces(isIos: false), PlaceId.values);
    expect(
      visiblePlaces(isIos: true),
      PlaceId.values.where((p) => p != PlaceId.folders).toList(),
    );
  });

  test('labels', () {
    expect(PlaceId.values.map((p) => p.label), [
      'For You',
      'Songs',
      'Albums',
      'Artists',
      'Genres',
      'Folders',
      'Playlists',
      'Discover',
      'Cloud',
    ]);
  });

  test('the YouTube place is named by build flavour', () {
    expect(youtubePlaceLabel(directBuild: true), 'YouTube Music');
    expect(youtubePlaceLabel(directBuild: false), 'Discover');
  });

  testWidgets('android shows 9 blocks in reading order', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(isIos: false));
    expect(find.byType(PlaceTile), findsNWidgets(9));
    // Row by row, left to right.
    final at = [
      for (final id in PlaceId.values)
        tester.getTopLeft(find.widgetWithText(PlaceTile, id.label)),
    ];
    for (var i = 1; i < at.length; i++) {
      final before = at[i - 1], here = at[i];
      expect(
        here.dy > before.dy || (here.dy == before.dy && here.dx > before.dx),
        isTrue,
        reason: '${PlaceId.values[i]} after ${PlaceId.values[i - 1]}',
      );
    }
  });

  testWidgets('a phone shows two columns, a tablet four', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    for (final (width, cols) in [(360.0, 2), (412.0, 2), (800.0, 4)]) {
      tester.view.physicalSize = Size(width, 1600);
      await tester.pumpWidget(_host(isIos: false));
      final ys = {
        for (final e in find.byType(PlaceTile).evaluate())
          tester.getTopLeft(find.byWidget(e.widget)).dy,
      }.toList()..sort();
      final firstRow = find
          .byType(PlaceTile)
          .evaluate()
          .where(
            (e) => tester.getTopLeft(find.byWidget(e.widget)).dy == ys.first,
          )
          .length;
      expect(firstRow, cols, reason: 'width $width');
    }
  });

  testWidgets('the title is Library', (tester) async {
    await tester.pumpWidget(_host(isIos: false));
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Places'), findsNothing);
  });

  testWidgets('ios shows 8 blocks, no Folders', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(isIos: true));
    expect(find.byType(PlaceTile), findsNWidgets(8));
    expect(find.text('Folders'), findsNothing);
  });

  testWidgets('tap calls onOpen; menu and search fire', (tester) async {
    PlaceId? opened;
    var menu = 0, search = 0;
    await tester.pumpWidget(
      _host(
        isIos: false,
        onOpen: (_, id) => opened = id,
        onMenu: () => menu++,
        onSearch: () => search++,
      ),
    );
    await tester.tap(find.text('Albums'));
    expect(opened, PlaceId.albums);
    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.tap(find.byIcon(Icons.search_rounded));
    expect(menu, 1);
    expect(search, 1);
  });
}
