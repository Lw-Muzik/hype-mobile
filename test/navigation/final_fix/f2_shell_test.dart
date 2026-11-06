import 'dart:async';

import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/motion/morph.dart';
import 'package:eq_app/navigation/shell/cover_drag.dart';
import 'package:eq_app/navigation/shell/motion_shell.dart';
import 'package:eq_app/navigation/shell/scene_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/shell_harness.dart';

Rect? _flightRect(WidgetTester tester) {
  final found = find.ancestor(
    of: find.byType(FittedBox),
    matching: find.byType(Positioned),
  );
  if (found.evaluate().isEmpty) return null;
  final w = tester.widget<Positioned>(found.first);
  return Rect.fromLTWH(w.left!, w.top!, w.width!, w.height!);
}

Widget _player(BuildContext _) => Stack(
  key: kPlayerKey,
  children: [
    Positioned.fromRect(
      rect: kCoverRect,
      child: MorphTag(
        tag: kNowPlayingArtTag,
        child: const ColoredBox(key: ValueKey('cover'), color: Colors.orange),
      ),
    ),
  ],
);

class _ThrowingHost extends FakeHost {
  _ThrowingHost(super.library, this.app);

  final FakeApp app;

  @override
  LibraryNavigatorController get controller {
    if (app.eqMode) throw StateError('no library in equalizer-only mode');
    return super.controller;
  }
}

void main() {
  group('NavHost.toPlayer closes routes above the shell', () {
    testWidgets('a route over the shell is popped and the player shows', (
      tester,
    ) async {
      final app = FakeApp()..queue = [song(1)];
      final navKey = await pumpShell(tester, app: app, library: FakeLibrary());
      final scenes = AppNav.host! as SceneController;
      scenes.toLibrary();
      await advance(tester, 700);
      expect(scenes.scene.value, Scene.library);
      unawaited(
        navKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('settings')),
          ),
        ),
      );
      await advance(tester, 500);
      expect(find.text('settings'), findsOneWidget);

      AppNav.host!.toPlayer();
      await advance(tester, 900);
      expect(find.text('settings'), findsNothing);
      expect(scenes.scene.value, Scene.player);
    });

    testWidgets('with the shell current nothing is popped', (tester) async {
      final app = FakeApp()..queue = [song(1)];
      final navKey = await pumpShell(tester, app: app, library: FakeLibrary());
      final scenes = AppNav.host! as SceneController;
      scenes.toLibrary();
      await advance(tester, 700);
      AppNav.host!.toPlayer();
      await advance(tester, 900);
      expect(scenes.scene.value, Scene.player);
      expect(navKey.currentState!.canPop(), isTrue);
      expect(find.text('base'), findsNothing);
    });

    testWidgets('a sheet opened by the same tap stays open over the player', (
      tester,
    ) async {
      // Hype Connect asks "Play it here instead?" in a sheet during the tap
      // that also shows the player; closing it would answer the question.
      final app = FakeApp()..queue = [song(1)];
      final navKey = await pumpShell(tester, app: app, library: FakeLibrary());
      final scenes = AppNav.host! as SceneController;
      scenes.toLibrary();
      await advance(tester, 700);
      bool? answer;
      unawaited(
        showModalBottomSheet<bool>(
          context: navKey.currentContext!,
          useRootNavigator: true,
          builder: (_) => const Text('play here?'),
        ).then((v) => answer = v),
      );
      AppNav.host!.toPlayer();
      await advance(tester, 900);
      expect(find.text('play here?'), findsOneWidget);
      expect(answer, isNull);
      expect(scenes.scene.value, Scene.player);
    });
  });

  testWidgets('a flight that never leaves 0 ends when the move is retargeted', (
    tester,
  ) async {
    final app = FakeApp()..queue = [song(7)];
    await pumpShell(
      tester,
      app: app,
      library: FakeLibrary(),
      host: FakeHost(FakeLibrary(), rowTag: trackTag(7), rowRect: kRowRect),
      playerBuilder: _player,
    );
    final scenes = AppNav.host! as SceneController;
    scenes.toLibrary();
    await advance(tester, 700);
    // To the player: the flight starts at 0 ...
    scenes.toPlayer();
    // One frame: the move and its flight exist, but no time has passed.
    await tester.pump();
    // ... and the move is reversed before its progress ever leaves 0.
    scenes.toLibrary();
    await advance(tester, 900);
    expect(scenes.scene.value, Scene.library);
    expect(_flightRect(tester), isNull, reason: 'no stuck stand-in');
  });

  testWidgets('the library takes no input before a move to it has started', (
    tester,
  ) async {
    var taps = 0;
    final app = FakeApp()..queue = [song(1)];
    await pumpShell(
      tester,
      app: app,
      library: FakeLibrary(),
      frameProbe: () => SizedBox(
        height: 600,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => taps++,
        ),
      ),
    );
    final scenes = AppNav.host! as SceneController;
    scenes.toLibrary();
    // The scene already reads library, the clocks have not started; one
    // frame lets the layers show it.
    await tester.pump();
    expect(scenes.scene.value, Scene.library);
    expect(scenes.list.value, 0);
    await tester.tapAt(const Offset(200, 400));
    expect(taps, 0);
    await advance(tester, 700);
    await tester.tapAt(const Offset(200, 400));
    expect(taps, 1);
  });

  group('cover drag divisor', () {
    testWidgets('is the art box side, not the drawn cover', (tester) async {
      final app = FakeApp()..queue = [song(7)];
      await pumpShell(
        tester,
        app: app,
        library: FakeLibrary(),
        playerBuilder: _player,
      );
      final scenes = AppNav.host! as SceneController;
      // 400 x 800 screen; the drawn cover is 300 wide.
      expect(scenes.artBoxSide(), 400);
      final drag = CoverDrag(scenes, fallbackExtent: () => 123);
      drag.start(100);
      drag.update(100 + 8 + 100);
      // 100 dp of travel past the slop over 400 = 0.25.
      expect(scenes.list.value, closeTo(0.25, 0.01));
      drag.end(0);
    });
  });

  group('a late saved session', () {
    testWidgets('does not cover a page the user opened', (tester) async {
      final app = FakeApp()..playing = false;
      final library = FakeLibrary();
      await pumpShell(tester, app: app, library: library);
      final scenes = AppNav.host! as SceneController;
      expect(scenes.scene.value, Scene.library);
      await scenes.library.openPage(
        const SizedBox(),
        key: const LibraryPageKey('search'),
      );
      app.playing = true;
      app.notifyListeners();
      await advance(tester, 200);
      expect(scenes.scene.value, Scene.library);
    });

    testWidgets('still opens on the player when nothing was touched', (
      tester,
    ) async {
      final app = FakeApp()..playing = false;
      await pumpShell(tester, app: app, library: FakeLibrary());
      final scenes = AppNav.host! as SceneController;
      app.playing = true;
      app.notifyListeners();
      await advance(tester, 200);
      expect(scenes.scene.value, Scene.player);
    });
  });

  testWidgets('equalizer-only mode ignores predictive back', (tester) async {
    final app = FakeApp()..queue = [song(1)];
    final library = FakeLibrary();
    await pumpShell(
      tester,
      app: app,
      library: library,
      host: _ThrowingHost(library, app),
    );
    final scenes = AppNav.host! as SceneController;
    scenes.toLibrary();
    await advance(tester, 700);
    app.eqMode = true;
    app.notifyListeners();
    await advance(tester, 100);
    final shell = tester.state(find.byType(MotionShell));
    final handled = (shell as WidgetsBindingObserver).handleStartBackGesture(
      PredictiveBackEvent.fromMap({
        'touchOffset': [0.0, 300.0],
        'progress': 0.0,
        'swipeEdge': 0,
      }),
    );
    expect(handled, isFalse);
  });

  testWidgets('the first root swipe zooms the player about the cover', (
    tester,
  ) async {
    final app = FakeApp()..playing = false;
    await pumpShell(
      tester,
      app: app,
      library: FakeLibrary(),
      playerBuilder: _player,
    );
    final scenes = AppNav.host! as SceneController;
    expect(scenes.playerPivot.value, Offset.zero);
    expect(scenes.beginRootSwipe(), isTrue);
    await advance(tester, 50);
    expect(scenes.playerPivot.value, kCoverRect.center);
  });
}
