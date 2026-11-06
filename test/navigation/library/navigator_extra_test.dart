import 'package:eq_app/navigation/library/library_navigator.dart';
import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/library/list_page_route.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/library/page_factory.dart';
import 'package:eq_app/navigation/motion/morph.dart';
import 'package:eq_app/navigation/zoom/zoom_step_list.dart';
import 'package:eq_app/navigation/zoom/zoom_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'library_harness.dart';

const _six = LibraryPageKey('album', {'albumId': 6, 'album': 'Six'});

Future<void> _drag(
  WidgetTester tester,
  double dx, {
  bool hold = true,
  Offset from = const Offset(400, 400),
}) async {
  final g = await tester.startGesture(from);
  var moved = 0.0;
  final step = dx < 0 ? -40.0 : 40.0;
  while (moved.abs() < dx.abs()) {
    final s = (dx - moved).abs() < 40 ? dx - moved : step;
    await g.moveBy(Offset(s, 0));
    moved += s;
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (hold) await tester.pump(const Duration(milliseconds: 300));
  await g.up();
}

void main() {
  group('geometry', () {
    ListPageRoute<void> route({
      Rect? tapped,
      bool sibling = false,
      bool destGrid = false,
    }) => ListPageRoute<void>(
      builder: (_) => const SizedBox(),
      key: albumKey,
      sibling: sibling,
      tappedRect: tapped,
      destinationIsGrid: destGrid,
    );

    const size = Size(800, 600);

    test('a row: old grows about its bottom edge, new from 0.5', () {
      final g = route(tapped: const Rect.fromLTWH(0, 100, 800, 72))
          .geometry(size);
      expect(g.oldPivot, const Offset(400, 172));
      expect(g.oldScale1, 1.5);
      expect(g.newScale0, 0.5);
      expect(g.newPivot, const Offset(400, 300));
    });

    test(
      'a grid tile: its corner goes to the origin; content starts on it',
      () {
        final tile = const Rect.fromLTWH(300, 100, 300, 72);
        final r = route(tapped: tile, destGrid: true)
          ..headerRest = const Rect.fromLTWH(0, 0, 800, 240);
        final g = r.geometry(size);
        expect(g.oldScale1, closeTo(800 / 600 < 2 ? 2 : 800 / 600, 1e-9));
        // c + s * (p - c) == 0 for the tile's top-left
        final p = tile.topLeft;
        final end = g.oldPivot + (p - g.oldPivot) * g.oldScale1;
        expect(end.dx, closeTo(0, 1e-6));
        expect(end.dy, closeTo(0, 1e-6));
        // the page's content corner (0, header bottom) starts on the tile
        expect(g.newScale0, 0.25);
        const q = Offset(0, 240);
        final start = g.newPivot + (q - g.newPivot) * g.newScale0;
        expect(start.dx, closeTo(tile.left, 1e-6));
        expect(start.dy, closeTo(tile.top, 1e-6));
      },
    );

    test('a grid zoom never drops below 2 and follows the right edge', () {
      final g = route(tapped: const Rect.fromLTWH(0, 0, 200, 72))
          .geometry(size);
      expect(g.oldScale1, 4); // 800 / 200
    });

    test('sibling pivots about the centre: old to 0.5, new from 1.5', () {
      final g = route(sibling: true).geometry(size);
      expect(g.oldScale1, 0.5);
      expect(g.newScale0, 1.5);
      expect(g.oldPivot, const Offset(400, 300));
    });

    test('a swipe uses one look, shifted a width in its direction', () {
      final right = route(tapped: const Rect.fromLTWH(300, 100, 300, 72))
          .geometry(size, dir: 1);
      final left = route(sibling: true).geometry(size, dir: -1);
      expect(right.oldPivot, const Offset(1200, 300));
      expect(right.newScale0, 0.5);
      expect(right.oldScale1, 1.5);
      expect(left.oldPivot, const Offset(-400, 300));
      expect(left.newPivot, const Offset(-400, 300));
    });
  });

  testWidgets('sibling open runs on the 150 ms clock', (tester) async {
    final nav = await pumpNavigator(tester);
    nav.currentState!.openPage(albumPage(), key: albumKey, sibling: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 75));
    expect(layerScale(tester, find.text('row'), end: 0.5), closeTo(0.75, 0.02));
    expect(
      layerScale(tester, find.text('header'), end: 1),
      closeTo(1.25, 0.02),
    );
  });

  testWidgets('a grid open flies the tile into the header', (tester) async {
    final nav = await pumpNavigator(tester, root: rootList(grid: true));
    nav.currentState!.openPage(
      albumPage(),
      key: albumKey,
      morphFrom: itemTag(albumKey),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 125));
    final flying = find
        .ancestor(
          of: find.byKey(const ValueKey('row-src')),
          matching: find.byType(Positioned),
        )
        .evaluate();
    expect(flying, isNotEmpty);
    await tester.pumpAndSettle();
    expect(nav.currentState!.path, [albumKey]);
  });

  testWidgets(
    'back flies the header into the row and draws the parent on top',
    (tester) async {
      final nav = await pumpNavigator(tester);
      final s = nav.currentState!;
      s.openPage(albumPage(), key: albumKey, morphFrom: itemTag(albumKey));
      await tester.pumpAndSettle();
      s.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 125));
      final flying = find
          .ancestor(
            of: find.byKey(const ValueKey('row-src')),
            matching: find.byType(Positioned),
          )
          .evaluate();
      expect(flying, isNotEmpty);
      final order = tester.allElements.map((e) => e.widget).toList();
      int at(String t) => order.indexWhere((w) => w is Text && w.data == t);
      expect(at('row'), greaterThan(at('header')));
      await tester.pumpAndSettle();
      expect(s.path, isEmpty);
      // after the pop the root is back to normal
      expect(find.text('row'), findsWidgets);
    },
  );

  testWidgets('a restored page animates on the way back', (tester) async {
    final nav = await pumpNavigator(tester);
    final s = nav.currentState!;
    s.openPage(albumPage(), key: albumKey); // no tapped rect
    await tester.pumpAndSettle();
    s.pop();
    await tester.pump();
    // The back pivot takes 150 ms: halfway is 75 ms.
    await tester.pump(const Duration(milliseconds: 75));
    expect(layerScale(tester, find.text('row'), end: 1.5), closeTo(1.25, 0.05));
    expect(
      layerScale(tester, find.text('header'), end: 1),
      closeTo(0.75, 0.05),
    );
  });

  group('sheets on the nested navigator', () {
    testWidgets('back closes the sheet first, then pops the page', (
      tester,
    ) async {
      final nav = await pumpNavigator(tester);
      final s = nav.currentState!;
      s.openPage(albumPage(), key: albumKey);
      await tester.pumpAndSettle();
      final ctx = tester.element(find.byKey(const ValueKey('album-body')));
      showModalBottomSheet<void>(
        context: ctx,
        builder: (_) => const SizedBox(height: 100, child: Text('sheet')),
      );
      await tester.pumpAndSettle();
      expect(find.text('sheet'), findsOneWidget);
      expect(s.canPop, isTrue);

      expect(await s.pop(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('sheet'), findsNothing);
      expect(s.path, [albumKey]);

      final popped = s.pop(); // animates: pump before awaiting
      await tester.pumpAndSettle();
      expect(await popped, isTrue);
      expect(s.path, isEmpty);
    });

    testWidgets('a sheet at the root closes instead of reporting no parent', (
      tester,
    ) async {
      final nav = await pumpNavigator(tester);
      final s = nav.currentState!;
      final ctx = tester.element(find.byKey(const ValueKey('row-src')));
      showModalBottomSheet<void>(
        context: ctx,
        builder: (_) => const SizedBox(height: 100, child: Text('sheet')),
      );
      await tester.pumpAndSettle();
      expect(await s.pop(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('sheet'), findsNothing);
      expect(await s.pop(), isFalse);
    });

    testWidgets('a back swipe does not start while a sheet is open', (
      tester,
    ) async {
      final nav = await pumpNavigator(tester);
      final s = nav.currentState!;
      s.openPage(albumPage(), key: albumKey);
      await tester.pumpAndSettle();
      final ctx = tester.element(find.byKey(const ValueKey('album-body')));
      showModalBottomSheet<void>(
        context: ctx,
        builder: (_) => const SizedBox(height: 100, child: Text('sheet')),
      );
      await tester.pumpAndSettle();
      await _drag(tester, 400, from: const Offset(100, 200));
      await tester.pumpAndSettle();
      expect(s.path, [albumKey]);
    });
  });

  group('swipes', () {
    testWidgets('a leftward swipe past 30 percent goes back too', (
      tester,
    ) async {
      final nav = await pumpNavigator(tester);
      nav.currentState!.openPage(albumPage(), key: albumKey);
      await tester.pumpAndSettle();
      await _drag(tester, -(8 + 0.5 * 800), from: const Offset(700, 400));
      await tester.pumpAndSettle();
      expect(nav.currentState!.path, isEmpty);
    });

    testWidgets('a leftward commit glides at 4 per second', (tester) async {
      final nav = await pumpNavigator(tester);
      nav.currentState!.openPage(albumPage(), key: albumKey);
      await tester.pumpAndSettle();
      await _drag(tester, -(8 + 0.5 * 800), from: const Offset(700, 400));
      await tester.pump(); // settle's first frame
      await tester.pump(const Duration(milliseconds: 100));
      expect(nav.currentState!.path, [albumKey]); // 0.5 / 4 = 125 ms
      await tester.pump(const Duration(milliseconds: 40));
      expect(nav.currentState!.path, isEmpty);
    });

    testWidgets('a leftward swipe under 30 percent cancels', (tester) async {
      final nav = await pumpNavigator(tester);
      nav.currentState!.openPage(albumPage(), key: albumKey);
      await tester.pumpAndSettle();
      await _drag(tester, -(8 + 0.2 * 800), from: const Offset(700, 400));
      await tester.pumpAndSettle();
      expect(nav.currentState!.path, [albumKey]);
    });

    testWidgets('grabbing again while it settles stays consistent', (
      tester,
    ) async {
      final nav = await pumpNavigator(tester);
      final s = nav.currentState!;
      s.openPage(albumPage(), key: albumKey);
      await tester.pumpAndSettle();
      s.openPage(albumPage(), key: _six);
      await tester.pumpAndSettle();

      // First swipe: cancels (settling), second grabs it and commits.
      final g1 = await tester.startGesture(const Offset(100, 400));
      await g1.moveBy(const Offset(120, 0));
      await tester.pump(const Duration(milliseconds: 50));
      await g1.moveBy(const Offset(100, 0));
      await tester.pump(const Duration(milliseconds: 300));
      await g1.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      final g2 = await tester.startGesture(const Offset(100, 400));
      for (var i = 0; i < 8; i++) {
        await g2.moveBy(const Offset(60, 0));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 300));
      await g2.up();
      await tester.pumpAndSettle();

      expect(s.path.length, 1); // exactly one level
      expect(tester.takeException(), isNull);
      // the navigator's gesture bookkeeping is balanced
      final nav2 = tester.state<NavigatorState>(find.byType(Navigator).last);
      expect(nav2.userGestureInProgress, isFalse);
    });

    testWidgets('the root hands a rightward swipe to the shell', (
      tester,
    ) async {
      final events = <String>[];
      final key = GlobalKey<LibraryNavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          home: MorphScope(
            child: LibraryNavigator(
              key: key,
              root: rootList(),
              onRootSwipeStart: () {
                events.add('start');
                return true;
              },
              onRootSwipeUpdate: (p) => events.add('update'),
              onRootSwipeEnd: (v) => events.add('end'),
            ),
          ),
        ),
      );
      await _drag(tester, 200);
      expect(events.first, 'start');
      expect(events.last, 'end');
      expect(events.contains('update'), isTrue);
      // no rubber band when the shell owns the swipe
      expect(tester.getTopLeft(find.byKey(const ValueKey('row-src'))).dx, 0);
    });

    testWidgets('a leftward swipe at the root does nothing', (tester) async {
      final nav = await pumpNavigator(tester);
      await _drag(tester, -300, from: const Offset(700, 400));
      await tester.pumpAndSettle();
      expect(nav.currentState!.path, isEmpty);
      expect(tester.getTopLeft(find.byKey(const ValueKey('row-src'))).dx, 0);
    });
  });

  group('predictive back', () {
    PredictiveBackEvent ev(double p) => PredictiveBackEvent.fromMap({
      'touchOffset': [0.0, 300.0],
      'progress': p,
      'swipeEdge': 0,
    });

    testWidgets('is ignored until the shell enables it', (tester) async {
      final nav = await pumpNavigator(tester);
      final s = nav.currentState!;
      s.openPage(albumPage(), key: albumKey);
      await tester.pumpAndSettle();
      expect(s.handleStartBackGesture(ev(0)), isFalse);
    });

    testWidgets('invoke always commits, cancel returns', (tester) async {
      final nav = await pumpNavigator(tester);
      final s = nav.currentState!..systemBackEnabled = true;
      s.openPage(albumPage(), key: albumKey);
      await tester.pumpAndSettle();

      expect(s.handleStartBackGesture(ev(0)), isTrue);
      s.handleUpdateBackGestureProgress(ev(0.1));
      await tester.pump();
      s.handleCancelBackGesture();
      await tester.pumpAndSettle();
      expect(s.path, [albumKey]);

      expect(s.handleStartBackGesture(ev(0)), isTrue);
      s.handleUpdateBackGestureProgress(ev(0.05));
      await tester.pump();
      s.handleCommitBackGesture();
      await tester.pumpAndSettle();
      expect(s.path, isEmpty);
    });

    testWidgets('does not start at the root', (tester) async {
      final nav = await pumpNavigator(tester);
      final s = nav.currentState!..systemBackEnabled = true;
      expect(s.handleStartBackGesture(ev(0)), isFalse);
    });
  });

  testWidgets('the newest showPath wins and a page opened meanwhile survives', (
    tester,
  ) async {
    // showPath awaiting a builder while the user opens a page: the page stays.
    final nav = await pumpNavigator(tester);
    final s = nav.currentState!;
    final f = s.showPath(const []); // resolves immediately, but is async
    s.openPage(albumPage(), key: albumKey);
    await f;
    await tester.pumpAndSettle();
    expect(s.path, [albumKey]);
  });

  group('start scale follows the destination type', () {
    Widget zoomPage(int step) => Scaffold(
      body: ZoomStepList(
        steps: const [
          ZoomStep.list(rowExtent: 72),
          ZoomStep.grid(maxTileExtent: 200, childAspectRatio: 1, spacing: 8),
        ],
        step: step,
        onStepChanged: (_) {},
        itemCount: 5,
        itemBuilder: (c, i, st) => Text('item $i'),
      ),
    );

    double startOf(GlobalKey<LibraryNavigatorState> nav) =>
        nav.currentState!.topRoute!.geometry(const Size(800, 600)).newScale0;

    testWidgets('a list step starts at 0.5, a grid step at 0.25', (
      tester,
    ) async {
      final nav = await pumpNavigator(tester);
      nav.currentState!.openPage(
        zoomPage(0),
        key: LibraryPageKey.place('songs'),
      );
      await tester.pump();
      await tester.pump();
      expect(startOf(nav), 0.5);
      nav.currentState!.pop();
      await tester.pumpAndSettle();

      nav.currentState!.openPage(
        zoomPage(1),
        key: LibraryPageKey.place('artists'),
      );
      await tester.pump();
      await tester.pump();
      expect(startOf(nav), 0.25);
    });

    testWidgets('pinching a page into a grid step changes the next open', (
      tester,
    ) async {
      final nav = await pumpNavigator(tester);
      var step = 0;
      nav.currentState!.openPage(
        zoomPage(step),
        key: LibraryPageKey.place('songs'),
      );
      await tester.pumpAndSettle();
      expect(startOf(nav), 0.5);
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      step = 1; // the user pinched Songs into a grid
      nav.currentState!.openPage(
        zoomPage(step),
        key: LibraryPageKey.place('songs'),
      );
      await tester.pump();
      await tester.pump();
      expect(startOf(nav), 0.25);
    });

    testWidgets('pages without a zoom list report a fixed type', (
      tester,
    ) async {
      final nav = await pumpNavigator(tester);
      nav.currentState!.openPage(
        albumPage(),
        key: LibraryPageKey.place('cloud'),
      );
      await tester.pump();
      await tester.pump();
      expect(startOf(nav), 0.25); // a card grid
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      nav.currentState!.openPage(
        albumPage(),
        key: LibraryPageKey.place('playlists'),
      );
      await tester.pump();
      await tester.pump();
      expect(startOf(nav), 0.5);
    });
  });

  testWidgets('a fling back decides by direction on a leftward swipe', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    nav.currentState!.openPage(albumPage(), key: albumKey);
    await tester.pumpAndSettle();
    final g = await tester.startGesture(const Offset(700, 400));
    var x = 700.0;
    while (x > 700 - (8 + 0.5 * 800)) {
      await g.moveBy(const Offset(-40, 0));
      x -= 40;
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 200));
    // Fling back to the right, far above 500 dp/s. The test gesture needs
    // explicit timestamps for the velocity to exist.
    for (var i = 0; i < 5; i++) {
      await g.moveBy(
        const Offset(30, 0),
        timeStamp: Duration(milliseconds: 1000 + 8 * i),
      );
    }
    await g.up(timeStamp: const Duration(milliseconds: 1040));
    await tester.pumpAndSettle();
    expect(nav.currentState!.path, [albumKey]);
  });

  testWidgets('predictive back refuses to start while a swipe settles', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    final s = nav.currentState!..systemBackEnabled = true;
    s.openPage(albumPage(), key: albumKey);
    await tester.pumpAndSettle();
    final g = await tester.startGesture(const Offset(100, 400));
    await g.moveBy(const Offset(120, 0));
    await tester.pump(const Duration(milliseconds: 50));
    await g.moveBy(const Offset(80, 0));
    await tester.pump(const Duration(milliseconds: 300));
    await g.up(); // 0.2: cancels, settling
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    final ev = PredictiveBackEvent.fromMap({
      'touchOffset': [0.0, 300.0],
      'progress': 0.0,
      'swipeEdge': 0,
    });
    expect(s.handleStartBackGesture(ev), isFalse);
    await tester.pumpAndSettle();
    expect(s.path, [albumKey]);
    // and once settled it works again
    expect(s.handleStartBackGesture(ev), isTrue);
    s.handleCancelBackGesture();
    await tester.pumpAndSettle();
  });

  testWidgets('predictive back from the right edge uses the leftward look', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    final s = nav.currentState!..systemBackEnabled = true;
    s.openPage(albumPage(), key: albumKey);
    await tester.pumpAndSettle();
    final ev = PredictiveBackEvent.fromMap({
      'touchOffset': [800.0, 300.0],
      'progress': 0.0,
      'swipeEdge': 1,
    });
    expect(s.handleStartBackGesture(ev), isTrue);
    expect(s.topRoute!.swipeDir.value, -1);
    s.handleCommitBackGesture();
    await tester.pumpAndSettle();
    expect(s.path, isEmpty);
  });

  testWidgets('a root swipe the shell refuses is left alone', (tester) async {
    final key = GlobalKey<LibraryNavigatorState>();
    var started = 0;
    var updates = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MorphScope(
          child: LibraryNavigator(
            key: key,
            root: rootList(),
            onRootSwipeStart: () {
              started++;
              return false;
            },
            onRootSwipeUpdate: (_) => updates++,
            onRootSwipeEnd: (_) {},
          ),
        ),
      ),
    );
    await _drag(tester, 200);
    expect(started, greaterThan(0));
    expect(updates, 0);
    expect(tester.getTopLeft(find.byKey(const ValueKey('row-src'))).dx, 0);
  });

  group('restored trails and the header rest rect', () {
    tearDown(resetLibraryPages);

    testWidgets('a page rebuilt by showPath animates on the way back', (
      tester,
    ) async {
      clearLibraryPages();
      registerLibraryPage('album', (key, _) => albumPage());
      final nav = await pumpNavigator(tester);
      final s = nav.currentState!;
      await s.showPath(const [albumKey]);
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
      s.pop();
      await tester.pump();
      // No row to return to: the back pivot, 150 ms, halfway at 75 ms.
      await tester.pump(const Duration(milliseconds: 75));
      expect(
        layerScale(tester, find.text('row'), end: 1.5),
        closeTo(1.25, 0.05),
      );
      expect(
        layerScale(tester, find.text('header'), end: 1),
        closeTo(0.75, 0.05),
      );
      await tester.pumpAndSettle();
      expect(s.path, isEmpty);
    });
  });

  testWidgets('the header rest rect is measured while the page opens', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester, root: rootList(grid: true));
    nav.currentState!.openPage(
      albumPage(),
      key: albumKey,
      morphFrom: itemTag(albumKey),
    );
    await tester.pump();
    await tester.pump();
    final rest = nav.currentState!.topRoute!.headerRest;
    expect(rest, isNotNull);
    expect(rest!.left, closeTo(0, 1));
    expect(rest.top, closeTo(0, 1));
    expect(rest.width, closeTo(800, 1));
    expect(rest.height, closeTo(240, 1));
    // the grid geometry now anchors the content under it on the tile
    final g = nav.currentState!.topRoute!.geometry(const Size(800, 600));
    const q = Offset(0, 240);
    final start = g.newPivot + (q - g.newPivot) * g.newScale0;
    final tile = nav.currentState!.topRoute!.tappedRect!;
    expect(start.dx, closeTo(tile.left, 0.01));
    expect(start.dy, closeTo(tile.top, 0.01));
  });
}
