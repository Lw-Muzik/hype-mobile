import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/shell/scene_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_harness.dart';

void main() {
  testWidgets(
    'tapping the mini player 120 ms into toLibrary reverses without a jump',
    (tester) async {
      await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
      final scenes = AppNav.host! as SceneController;
      scenes.toLibrary();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await advance(tester, 120);
      final before = scenes.list.value;
      expect(before, inInclusiveRange(0.2, 0.8));

      scenes.toPlayer();
      await tester.pump();
      final after = scenes.list.value;
      expect((after - before).abs(), lessThan(0.02), reason: 'no jump');
      await tester.pump(const Duration(milliseconds: 16));
      expect(scenes.list.value, lessThan(before + 0.02));
      expect(scenes.scene.value, Scene.player);

      await advance(tester, 600);
      expect(scenes.list.value, 0);
      expect(scenes.container.value, closeTo(0, 0.005));
      expect(find.byKey(kPlayerKey), findsOneWidget);
    },
  );

  testWidgets('and the other way, mid toPlayer', (tester) async {
    await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
    final scenes = AppNav.host! as SceneController;
    scenes.toLibrary();
    await advance(tester, 600);
    scenes.toPlayer();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await advance(tester, 100);
    final before = scenes.list.value;
    scenes.toLibrary();
    await advance(tester, 700);
    expect(scenes.list.value, 1);
    expect(before, lessThan(1));
    expect(find.byKey(kPlayerKey), findsNothing);
  });
}
