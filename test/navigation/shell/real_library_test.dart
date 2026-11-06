import 'package:eq_app/controllers/app_controller.dart';
import 'package:eq_app/controllers/drawer_controller.dart';
import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/shell/motion_shell.dart';
import 'package:eq_app/navigation/shell/scene_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'shell_harness.dart';

void main() {
  testWidgets('the shell drives the real library navigator', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => AppNav.host = null);
    final app = FakeApp();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppController>.value(value: app),
          ChangeNotifierProvider(create: (_) => DrawerProvider()),
        ],
        child: MaterialApp(
          home: MotionShell(
            announceShellReady: false,
            playerBuilder: (_) =>
                const ColoredBox(key: kPlayerKey, color: Colors.black),
            miniPlayerBuilder: (_, _) =>
                const SizedBox(key: kMiniKey, height: 60),
            libraryFrame: (_, _, content) => content,
          ),
        ),
      ),
    );
    await tester.pump();
    final scenes = AppNav.host! as SceneController;
    expect(scenes.scene.value, Scene.player);

    scenes.toLibrary();
    await advance(tester, 600);
    expect(find.text('Library'), findsOneWidget);
    expect(scenes.library.canPop, isFalse);

    // An origin the factory cannot build lands on Places, not a blank page.
    await scenes.library.showPath(const [
      LibraryPageKey('album', {'id': 99999}),
    ]);
    await tester.pump();
    expect(find.text('Library'), findsOneWidget);
  });
}
