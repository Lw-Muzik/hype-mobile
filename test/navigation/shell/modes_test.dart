import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/motion/page_layer.dart';
import 'package:eq_app/navigation/shell/player_chrome.dart';
import 'package:eq_app/navigation/shell/scene_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_harness.dart';

void main() {
  testWidgets('equalizer-only mode builds the equalizer for the whole app', (
    tester,
  ) async {
    final app = FakeApp()..eqMode = true;
    await pumpShell(tester, app: app, library: FakeLibrary());
    expect(find.byKey(kEqKey), findsOneWidget);
    expect(find.byType(PageLayer, skipOffstage: false), findsNothing);
    expect(find.byKey(kPlayerKey), findsNothing);
  });

  testWidgets('the player scene sits under the chrome clock', (tester) async {
    await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
    final ctx = tester.element(find.byKey(kPlayerKey));
    expect(PlayerChromeScope.maybeOf(ctx), isNotNull);
  });

  testWidgets(
    "any caller, the floating video window's tap included, opens the player through AppNav",
    (tester) async {
      await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
      final scenes = AppNav.host! as SceneController;
      scenes.toLibrary();
      await advance(tester, 600);
      expect(scenes.scene.value, Scene.library);
      final ctx = tester.element(find.byKey(kMiniKey));
      AppNav.toPlayer(ctx, recordOrigin: false);
      await advance(tester, 600);
      expect(scenes.scene.value, Scene.player);
    },
  );

  testWidgets('chrome fades and shrinks to 0.75 in place', (tester) async {
    final holder = ValueNotifier<double>(0);
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerChromeScope(
          hidden: holder,
          child: const Center(
            child: PlayerChrome(
              child: SizedBox(key: Key('c'), width: 100, height: 40),
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byKey(const Key('c'))), const Size(100, 40));
    holder.value = 1;
    await tester.pump();
    expect(find.byKey(const Key('c')), findsOneWidget);
    holder.value = 0.5;
    await tester.pump();
    final t = tester.widget<Transform>(
      find
          .ancestor(
            of: find.byKey(const Key('c')),
            matching: find.byType(Transform),
          )
          .last,
    );
    expect(t.transform.entry(0, 0), closeTo(0.875, 0.001));
  });
}
