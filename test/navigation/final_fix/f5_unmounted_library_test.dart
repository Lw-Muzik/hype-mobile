import 'package:eq_app/controllers/app_controller.dart';
import 'package:eq_app/controllers/drawer_controller.dart';
import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/shell/motion_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../shell/shell_harness.dart';

class _App extends FakeApp {
  @override
  double get bgQuality => 2.0;

  @override
  double get blur => 0.0;
}

void main() {
  testWidgets('an app notification while the library is unmounted is safe', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => AppNav.host = null);
    final app = _App()
      ..eqMode = true
      ..playing = false;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppController>.value(value: app),
          ChangeNotifierProvider(create: (_) => DrawerProvider()),
        ],
        child: MaterialApp(
          home: MotionShell(
            announceShellReady: false,
            playerBuilder: (_) => const ColoredBox(color: Colors.black),
            equalizerBuilder: (_) => const ColoredBox(color: Colors.red),
            miniPlayerBuilder: (_, _) => const SizedBox(height: 60),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    // Back to music mode: the notification arrives before the library mounts.
    app
      ..eqMode = false
      ..playing = true;
    app.notifyListeners();
    expect(tester.takeException(), isNull);
  });
}
