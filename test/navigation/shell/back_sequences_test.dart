import 'dart:async';

import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/shell/scene_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_harness.dart';

const _a = LibraryPageKey('album', {'id': 1});
const _b = LibraryPageKey('album', {'id': 2});

Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pump();
}

void main() {
  testWidgets('back at the player lets the route pop (the app leaves)', (
    tester,
  ) async {
    await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
    expect(find.text('base'), findsNothing);
    await _back(tester);
    await tester.pumpAndSettle();
    expect(find.text('base'), findsOneWidget);
  });

  testWidgets(
    'library depth 2: back steps one level, then to Places, then the player',
    (tester) async {
      final lib = FakeLibrary();
      await pumpShell(tester, app: FakeApp(), library: lib);
      final scenes = AppNav.host! as SceneController;
      scenes.toLibrary();
      await advance(tester, 600);
      lib.stack.addAll([_a, _b]);

      await _back(tester);
      expect(lib.stack, [_a]);
      await _back(tester);
      expect(lib.stack, isEmpty);
      expect(scenes.scene.value, Scene.library);

      await _back(tester); // at Places: the player
      await advance(tester, 600);
      expect(scenes.scene.value, Scene.player);
      expect(find.byKey(kPlayerKey), findsOneWidget);
      expect(find.text('base'), findsNothing);
    },
  );

  testWidgets(
    'a second back while one is still running neither skips a level nor throws',
    (tester) async {
      final lib = FakeLibrary()..popGate = Completer<void>();
      await pumpShell(tester, app: FakeApp(), library: lib);
      final scenes = AppNav.host! as SceneController;
      scenes.toLibrary();
      await advance(tester, 600);
      lib.stack.addAll([_a, _b]);

      await _back(tester);
      await _back(tester);
      await _back(tester);
      expect(lib.pops, 1, reason: 'the others wait for the running one');
      lib.popGate!.complete();
      await tester.pump();
      expect(lib.stack, [_a]);
      expect(scenes.scene.value, Scene.library);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'double back during the player-to-library move stays consistent',
    (tester) async {
      final lib = FakeLibrary();
      await pumpShell(tester, app: FakeApp(), library: lib);
      final scenes = AppNav.host! as SceneController;
      scenes.toLibrary();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await advance(tester, 100);
      await _back(tester); // library is at its top: heads back to the player
      await _back(tester);
      await advance(tester, 700);
      expect(tester.takeException(), isNull);
      expect(scenes.scene.value, Scene.player);
      expect(scenes.list.value, 0);
      expect(find.text('base'), findsNothing, reason: 'shell route survives');
    },
  );
}
