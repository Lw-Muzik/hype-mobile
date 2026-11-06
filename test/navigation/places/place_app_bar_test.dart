import 'package:eq_app/navigation/places/place_app_bar.dart';
import 'package:eq_app/themes/ember.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(PlaceAppBar bar) => MaterialApp(
  home: Scaffold(appBar: bar, body: const SizedBox()),
);

void main() {
  testWidgets('matches the shell app bar metrics', (tester) async {
    await tester.pumpWidget(
      _host(PlaceAppBar(title: 'Songs', onMenu: () {}, onSearch: () {})),
    );
    final bar = tester.widget<AppBar>(find.byType(AppBar));
    expect(bar.elevation, 0);
    expect(bar.scrolledUnderElevation, 0);
    expect(bar.titleSpacing, Ember.gutter);
    expect(bar.backgroundColor, Ember.ground);
    expect(bar.surfaceTintColor, Colors.transparent);
    expect(
      const PlaceAppBar(title: '', onSearch: _noop).preferredSize.height,
      kToolbarHeight,
    );
    final title = tester.widget<Text>(find.text('Songs'));
    expect(title.style!.fontSize, 22);
    expect(title.style!.letterSpacing, -0.5);
    expect(title.style!.color, Ember.textPrimary);
    final search = tester.widget<Icon>(find.byIcon(Icons.search_rounded));
    expect(search.size, 22);
    expect(find.byIcon(Icons.menu_rounded), findsOneWidget);
  });

  testWidgets('back chevron replaces the hamburger', (tester) async {
    var back = 0;
    await tester.pumpWidget(
      _host(
        PlaceAppBar(
          title: 'Songs',
          onBack: () => back++,
          onMenu: () {},
          onSearch: () {},
        ),
      ),
    );
    expect(find.byIcon(Icons.menu_rounded), findsNothing);
    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    expect(back, 1);
  });

  testWidgets('actions sit before search', (tester) async {
    await tester.pumpWidget(
      _host(
        PlaceAppBar(
          title: 'Songs',
          onSearch: () {},
          actions: const [Icon(Icons.sort, key: Key('a'))],
        ),
      ),
    );
    expect(
      tester.getCenter(find.byKey(const Key('a'))).dx,
      lessThan(tester.getCenter(find.byIcon(Icons.search_rounded)).dx),
    );
  });
}

void _noop() {}
