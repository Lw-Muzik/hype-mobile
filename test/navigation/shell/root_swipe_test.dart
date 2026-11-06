import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/motion/page_layer.dart';
import 'package:eq_app/navigation/shell/scene_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_harness.dart';

List<Key?> _order(WidgetTester tester) {
  final stack = tester.widget<Stack>(
    find
        .ancestor(
          of: find.byKey(const ValueKey('library-layer')),
          matching: find.byType(Stack),
        )
        .first,
  );
  return [for (final c in stack.children) c.key];
}

void main() {
  Future<(SceneController, FakeHost)> open(WidgetTester tester) async {
    final host = FakeHost(FakeLibrary());
    await pumpShell(tester, app: FakeApp(), library: FakeLibrary(), host: host);
    final scenes = AppNav.host! as SceneController;
    scenes.toLibrary();
    await advance(tester, 700);
    return (scenes, host);
  }

  testWidgets(
    'a rightward swipe at Places brings the player in with the finger',
    (tester) async {
      final (scenes, host) = await open(tester);
      expect(host.swipeStart, isNotNull);
      host.swipeStart!();
      await tester.pump();
      host.swipeUpdate!(0.4);
      await tester.pump();
      expect(scenes.list.value, closeTo(0.6, 1e-9));
      expect(scenes.container.value, closeTo(0.6, 1e-9), reason: 'locked');
      // The library shrinks as 1 - 0.5p about a point a screen to the right.
      final library = find.byType(PageLayer, skipOffstage: false).first;
      final scale = tester
          .widget<Transform>(
            find
                .descendant(of: library, matching: find.byType(Transform))
                .first,
          )
          .transform
          .entry(0, 0);
      expect(scale, closeTo(0.8, 1e-6));

      host.swipeEnd!(0);
      await advance(tester, 400);
      expect(scenes.scene.value, Scene.player);
      expect(scenes.list.value, 0);
      expect(find.byKey(kPlayerKey), findsOneWidget);
    },
  );

  testWidgets('a short swipe cancels back to the library', (tester) async {
    final (scenes, host) = await open(tester);
    host.swipeStart!();
    host.swipeUpdate!(0.2);
    await tester.pump();
    host.swipeEnd!(0);
    await advance(tester, 700);
    expect(scenes.scene.value, Scene.library);
    expect(scenes.list.value, 1);
    expect(find.byKey(kPlayerKey), findsNothing);
  });

  testWidgets('the mini player keeps its own clock after a committed swipe', (
    tester,
  ) async {
    final (scenes, host) = await open(tester);
    host.swipeStart!();
    host.swipeUpdate!(0.5);
    await tester.pump();
    expect(scenes.mini.value, 1, reason: 'untouched during the finger move');
    host.swipeEnd!(0);
    await advance(tester, 200);
    expect(scenes.mini.value, lessThan(1));
    await advance(tester, 700);
    expect(scenes.mini.value, 0);
  });

  testWidgets('nothing playing: the root keeps its own behaviour', (
    tester,
  ) async {
    final host = FakeHost(FakeLibrary());
    final app = FakeApp()..playing = false;
    await pumpShell(tester, app: app, library: FakeLibrary(), host: host);
    expect(host.swipeStart, isNull);
  });

  testWidgets('the incoming layer is drawn on top', (tester) async {
    await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
    final scenes = AppNav.host! as SceneController;
    scenes.toLibrary();
    await advance(tester, 100);
    expect(_order(tester), [
      const ValueKey('player-layer'),
      const ValueKey('library-layer'),
    ]);
    await advance(tester, 600);
    scenes.toPlayer();
    await tester.pump();
    await tester.pump();
    await advance(tester, 100);
    expect(_order(tester), [
      const ValueKey('library-layer'),
      const ValueKey('player-layer'),
    ]);
  });
}
