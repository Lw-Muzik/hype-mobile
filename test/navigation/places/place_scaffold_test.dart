import 'package:eq_app/navigation/places/place_scaffold.dart';
import 'package:eq_app/navigation/places/places_page.dart';
import 'package:eq_app/widgets/song_sort_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(PlaceId id) => MaterialApp(
  home: PlaceScaffold(
    id: id,
    onBack: () {},
    onMenu: () {},
    onSearch: () {},
    body: const SizedBox(key: Key('body')),
  ),
);

void main() {
  testWidgets('Songs shows its title; sort stays in the body header', (
    tester,
  ) async {
    await tester.pumpWidget(_host(PlaceId.songs));
    expect(find.text('Songs'), findsOneWidget);
    expect(find.byType(SongSortButton), findsNothing);
    expect(find.byKey(const Key('body')), findsOneWidget);
  });

  testWidgets('app bar is back + title + search', (tester) async {
    await tester.pumpWidget(_host(PlaceId.albums));
    expect(find.text('Albums'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
  });
}
