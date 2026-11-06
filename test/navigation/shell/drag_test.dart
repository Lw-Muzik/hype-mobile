import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/shell/cover_drag.dart';
import 'package:eq_app/navigation/shell/scene_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_harness.dart';

void main() {
  Future<SceneController> open(WidgetTester tester) async {
    await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
    return AppNav.host! as SceneController;
  }

  testWidgets(
    '140 dp down (progress 0.35) and release commits to the library',
    (tester) async {
      final scenes = await open(tester);
      final drag = CoverDrag(scenes, fallbackExtent: () => 360);
      drag.start(100);
      drag.update(100 + 8 + 140);
      // Divided by the art box side (the 400 dp wide test view).
      expect(scenes.list.value, closeTo(140 / 400, 0.001));
      expect(scenes.container.value, closeTo(140 / 400, 0.001));
      expect(drag.end(0), isTrue);
      await advance(tester, 600);
      expect(scenes.scene.value, Scene.library);
      expect(scenes.list.value, 1);
      expect(find.byKey(kPlayerKey), findsNothing);
      expect(scenes.mini.value, closeTo(1, 0.01));
    },
  );

  testWidgets('90 dp (progress 0.225) cancels back to the player', (
    tester,
  ) async {
    final scenes = await open(tester);
    final drag = CoverDrag(scenes, fallbackExtent: () => 360);
    drag.start(100);
    drag.update(100 + 8 + 90);
    expect(scenes.list.value, closeTo(90 / 400, 0.001));
    drag.end(0);
    await advance(tester, 600);
    expect(scenes.scene.value, Scene.player);
    expect(scenes.list.value, 0);
    expect(scenes.container.value, 0);
    expect(find.byKey(kPlayerKey), findsOneWidget);
  });

  testWidgets('inside the slop nothing moves', (tester) async {
    final scenes = await open(tester);
    final drag = CoverDrag(scenes, fallbackExtent: () => 360);
    drag.start(100);
    drag.update(106);
    expect(scenes.list.isFingerDriven, isFalse);
    expect(scenes.list.value, 0);
    expect(drag.end(0), isFalse);
  });

  testWidgets('a fast fling commits whatever the distance', (tester) async {
    final scenes = await open(tester);
    final drag = CoverDrag(scenes, fallbackExtent: () => 360);
    drag.start(100);
    drag.update(100 + 8 + 20);
    drag.end(1200);
    await advance(tester, 600);
    expect(scenes.scene.value, Scene.library);
  });
}
