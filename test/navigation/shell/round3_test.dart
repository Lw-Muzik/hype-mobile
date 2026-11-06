import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/shell/scene_controller.dart';
import 'package:eq_app/onboarding/home_guide.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_harness.dart';

void main() {
  tearDown(() => HomeGuide.visible.value = false);

  testWidgets('grabbing the cover while a root swipe settles leaves no wedge', (
    tester,
  ) async {
    await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
    final scenes = AppNav.host! as SceneController;
    scenes.toLibrary();
    await advance(tester, 700);

    expect(scenes.beginRootSwipe(), isTrue);
    scenes.updateRootSwipe(0.2);
    await tester.pump();
    final settle = scenes.endRootSwipe(0, width: 400); // a cancel
    await advance(tester, 30);
    expect(
      scenes.beginPlayerDrag(),
      isFalse,
      reason: 'the swipe owns the move',
    );
    await advance(tester, 700);
    await settle;
    expect(scenes.scene.value, Scene.library);
    expect(scenes.list.value, 1);
    expect(scenes.list.isFingerDriven, isFalse);
    expect(scenes.container.value, 1);
    expect(scenes.container.isFingerDriven, isFalse);

    // Back and the mini player still work.
    await tester.binding.handlePopRoute();
    await advance(tester, 800);
    expect(scenes.scene.value, Scene.player);
    expect(scenes.list.value, 0);
    scenes.toLibrary();
    await advance(tester, 700);
    expect(scenes.scene.value, Scene.library);
  });

  testWidgets('the mini bar steps aside for the first-run guide', (
    tester,
  ) async {
    await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
    final scenes = AppNav.host! as SceneController;
    scenes.toLibrary();
    await advance(tester, 700);
    expect(find.byKey(kMiniKey), findsOneWidget);
    HomeGuide.visible.value = true;
    await tester.pump();
    expect(find.byKey(kMiniKey), findsNothing);
    HomeGuide.visible.value = false;
    await tester.pump();
    expect(find.byKey(kMiniKey), findsOneWidget);
  });

  testWidgets('a rightward flick that starts on the bar opens the drawer', (
    tester,
  ) async {
    var opened = 0;
    await pumpShell(
      tester,
      app: FakeApp(),
      library: FakeLibrary(),
      onDrawerOpen: () => opened++,
      miniBuilder: (_, _) =>
          const SizedBox(key: kMiniKey, height: 60, width: 400),
    );
    final scenes = AppNav.host! as SceneController;
    scenes.toLibrary();
    await advance(tester, 700);
    await tester.fling(find.byKey(kMiniKey), const Offset(200, 0), 1500);
    await tester.pump();
    expect(opened, 1);
    // A slow drag does not.
    await tester.drag(find.byKey(kMiniKey), const Offset(30, 0));
    expect(opened, 1);
  });
}
