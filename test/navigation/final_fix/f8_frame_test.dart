import 'package:eq_app/controllers/app_controller.dart';
import 'package:eq_app/controllers/drawer_controller.dart';
import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/shell/motion_shell.dart';
import 'package:eq_app/widgets/body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../shell/shell_harness.dart';

class _App extends FakeApp {
  _App(this.fancy);
  final bool fancy;
  @override
  double get bgQuality => 1;
  @override
  double get blur => 0;
  @override
  bool get isFancy => fancy;
}

Future<void> _pump(WidgetTester tester, bool fancy) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(() => AppNav.host = null);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: _App(fancy)),
        ChangeNotifierProvider(create: (_) => DrawerProvider()),
      ],
      child: MaterialApp(
        home: MotionShell(
          libraryHost: FakeHost(FakeLibrary()),
          announceShellReady: false,
          playerBuilder: (_) => const ColoredBox(color: Colors.black),
          miniPlayerBuilder: (_, _) => const SizedBox(height: 60),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('normal mode: no Body backdrop (no blur) under the library', (
    tester,
  ) async {
    await _pump(tester, false);
    expect(find.byType(Body, skipOffstage: false), findsNothing);
    expect(find.byType(ImageFiltered, skipOffstage: false), findsNothing);
  });

  testWidgets('fancy mode keeps the Body backdrop', (tester) async {
    await _pump(tester, true);
    expect(find.byType(Body, skipOffstage: false), findsOneWidget);
  });
}
