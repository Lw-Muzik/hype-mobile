import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/motion/page_layer.dart';
import 'package:eq_app/navigation/shell/scene_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_harness.dart';

double _scaleOf(WidgetTester tester, Finder layer) {
  final t = tester.widget<Transform>(
    find.descendant(of: layer, matching: find.byType(Transform)).first,
  );
  return t.transform.entry(0, 0);
}

double _opacityOf(WidgetTester tester, Finder layer) => tester
    .widget<Opacity>(
      find
          .ancestor(
            of: find
                .descendant(of: layer, matching: find.byType(Transform))
                .first,
            matching: find.byType(Opacity),
          )
          .first,
    )
    .opacity;

void main() {
  testWidgets('opens on the player when something is playing', (tester) async {
    await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
    expect(find.byKey(kPlayerKey), findsOneWidget);
    expect((AppNav.host as SceneController).scene.value, Scene.player);
  });

  testWidgets('opens on Places when nothing is playing', (tester) async {
    final app = FakeApp()..playing = false;
    await pumpShell(tester, app: app, library: FakeLibrary());
    expect(find.byKey(kPlayerKey), findsNothing);
    expect(find.text('Library'), findsOneWidget);
  });

  testWidgets('toLibrary: the player zooms out and fades, the library lands', (
    tester,
  ) async {
    await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
    final host = AppNav.host!;
    host.toLibrary();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await advance(tester, 240);
    final library = find.descendant(
      of: find.byKey(const ValueKey('library-layer')),
      matching: find.byType(PageLayer),
      skipOffstage: false,
    );
    final player = find.descendant(
      of: find.byKey(const ValueKey('player-layer')),
      matching: find.byType(PageLayer),
      skipOffstage: false,
    );
    expect(_scaleOf(tester, player), closeTo(1.25, 0.02));
    expect(_opacityOf(tester, player), closeTo(0, 0.05));
    expect(_scaleOf(tester, library), closeTo(1, 0.02));
    await advance(tester, 20);
    // The player is gone once the library has landed.
    expect(find.byKey(kPlayerKey), findsNothing);
  });

  testWidgets('the mini player rises on its own 500 ms quart clock', (
    tester,
  ) async {
    await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
    AppNav.host!.toLibrary();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await advance(tester, 100);
    final y100 = tester.getTopLeft(find.byKey(kMiniKey)).dy;
    expect(y100, greaterThan(740), reason: 'still rising at 100 ms');
    await advance(tester, 420);
    expect(tester.getTopLeft(find.byKey(kMiniKey)).dy, closeTo(740, 0.5));
  });

  testWidgets('toPlayer mirrors it; the chrome settles at 500 ms', (
    tester,
  ) async {
    await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
    final scenes = AppNav.host! as SceneController;
    scenes.toLibrary();
    await advance(tester, 600);
    expect(find.byKey(kPlayerKey), findsNothing);

    scenes.toPlayer();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await advance(tester, 250);
    expect(find.byKey(kPlayerKey), findsOneWidget);
    expect(scenes.list.value, closeTo(0, 0.01), reason: 'list done at 250 ms');
    // Quart at the halfway point: 1 - 0.9375 of the way still to go.
    expect(scenes.container.value, closeTo(0.0625, 0.03));
    await advance(tester, 260);
    expect(scenes.container.value, closeTo(0, 0.005));
    expect(scenes.mini.value, closeTo(0, 0.005));
  });

  test('soft overdrag follows the record', () {
    expect(softOverdrag(0.4), 0.4);
    expect(softOverdrag(-1), closeTo(-0.1643, 0.001));
    expect(softOverdrag(2), closeTo(1.1643, 0.001));
    expect(softOverdrag(-0.1), closeTo(-0.3 * 0.1732, 0.001));
  });
}
