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

  testWidgets('android shows 9 rows in order', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(isIos: false));
    expect(find.byType(PlaceRow), findsNWidgets(9));
    final ys = [
      for (final id in PlaceId.values)
        tester.getTopLeft(find.widgetWithText(PlaceRow, id.label)).dy,
    ];
    expect(ys, [...ys]..sort());
  });

  testWidgets('ios shows 8 rows, no Folders', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(isIos: true));
    expect(find.byType(PlaceRow), findsNWidgets(8));
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
