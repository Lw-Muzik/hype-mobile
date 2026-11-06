import 'dart:async';

import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/motion/morph.dart';
import 'package:eq_app/navigation/playback_origin.dart';
import 'package:eq_app/navigation/shell/scene_controller.dart';
import 'package:eq_app/services/player_reveal_bus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_harness.dart';

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
      child: const MorphTag(
        tag: kNowPlayingArtTag,
        child: ColoredBox(color: Colors.orange),
      ),
    ),
  ],
);

Future<void> _lead(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  tearDown(() => PlayerRevealBus.instant = false);

  group('an interrupted root swipe', () {
    testWidgets('a tap move during the finger phase takes over cleanly', (
      tester,
    ) async {
      final app = FakeApp()..playing = true;
      await pumpShell(tester, app: app, library: FakeLibrary());
      final scenes = AppNav.host! as SceneController;
      scenes.toLibrary();
      await advance(tester, 700);

      expect(scenes.beginRootSwipe(), isTrue);
      scenes.updateRootSwipe(0.3);
      await tester.pump();
      expect(scenes.list.value, closeTo(0.7, 1e-9));

      scenes.toLibrary(); // e.g. the player's own chevron
      await advance(tester, 700);
      expect(scenes.scene.value, Scene.library);
      expect(scenes.list.value, 1);
      expect(scenes.list.isFingerDriven, isFalse);
      expect(scenes.container.value, 1);
      scenes.updateRootSwipe(0.9); // a late update from the dead gesture
      await tester.pump();
      expect(scenes.list.value, 1);
    });

    testWidgets('a tap during the settle completes the move to the player', (
      tester,
    ) async {
      await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
      final scenes = AppNav.host! as SceneController;
      scenes.toLibrary();
      await advance(tester, 700);

      scenes.beginRootSwipe();
      scenes.updateRootSwipe(0.2);
      await tester.pump();
      final settle = scenes.endRootSwipe(0, width: 400); // a cancel
      await advance(tester, 40);
      scenes.toPlayer(); // the mini player, tapped
      await advance(tester, 800);
      await settle;
      expect(scenes.scene.value, Scene.player);
      expect(scenes.list.value, 0);
      expect(scenes.list.isFingerDriven, isFalse);
      expect(scenes.container.value, 0);
      expect(find.byKey(kPlayerKey), findsOneWidget);
    });

    testWidgets('a new drag after a dropped swipe still works', (tester) async {
      await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
      final scenes = AppNav.host! as SceneController;
      scenes.toLibrary();
      await advance(tester, 700);
      scenes.beginRootSwipe();
      scenes.updateRootSwipe(0.4);
      scenes.toLibrary();
      await advance(tester, 700);
      scenes.toPlayer();
      await advance(tester, 800);
      expect(scenes.beginPlayerDrag(), isTrue);
      scenes.dragPlayer(0.5);
      expect(scenes.list.value, closeTo(0.5, 1e-9));
    });
  });

  testWidgets(
    'the first library to player flight ends exactly on the cover (P2)',
    (tester) async {
      final app = FakeApp()
        ..playing = false
        ..queue = [song(7)];
      await pumpShell(
        tester,
        app: app,
        library: FakeLibrary(),
        host: FakeHost(FakeLibrary(), rowTag: trackTag(7), rowRect: kRowRect),
        playerBuilder: _player,
      );
      final scenes = AppNav.host! as SceneController;
      expect(scenes.scene.value, Scene.library);
      unawaited(scenes.toPlayer());
      await _lead(tester);
      await advance(tester, 100);
      expect(_flightRect(tester), isNotNull);
      await advance(tester, 140);
      final end = _flightRect(tester)!;
      expect(end.left, closeTo(kCoverRect.left, 3));
      expect(end.top, closeTo(kCoverRect.top, 3));
      expect(end.width, closeTo(kCoverRect.width, 3));
    },
  );

  testWidgets(
    'the playing row is revealed at once, not scrolled under the zoom',
    (tester) async {
      final app = FakeApp()..queue = [song(7)];
      await pumpShell(
        tester,
        app: app,
        library: FakeLibrary(),
        host: FakeHost(FakeLibrary(), rowTag: trackTag(7), rowRect: kRowRect),
        playerBuilder: _player,
      );
      final seen = <bool>[];
      PlayerRevealBus.tick.addListener(() => seen.add(PlayerRevealBus.instant));
      final scenes = AppNav.host! as SceneController;
      unawaited(scenes.toLibrary());
      await _lead(tester);
      expect(seen, [true]);
    },
  );

  group('soft overshoot', () {
    testWidgets(
      'a drag past full travel shows the overshoot and settles to 1',
      (tester) async {
        await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
        final scenes = AppNav.host! as SceneController;
        expect(scenes.beginPlayerDrag(), isTrue);
        scenes.dragPlayer(1.5);
        await tester.pump();
        expect(scenes.list.value, closeTo(softOverdrag(1.5), 1e-9));
        expect(scenes.list.value, greaterThan(1));
        expect(scenes.list.value, lessThanOrEqualTo(1.165));
        expect(scenes.container.value, closeTo(scenes.list.value, 1e-9));
        unawaited(scenes.endPlayerDrag(0, extent: 360));
        await advance(tester, 700);
        expect(scenes.list.value, 1);
        expect(scenes.scene.value, Scene.library);
      },
    );

    testWidgets('pulling up past the start settles back to the player', (
      tester,
    ) async {
      await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
      final scenes = AppNav.host! as SceneController;
      scenes.beginPlayerDrag();
      scenes.dragPlayer(-0.5);
      await tester.pump();
      expect(scenes.list.value, lessThan(0));
      expect(scenes.list.value, greaterThanOrEqualTo(-0.165));
      unawaited(scenes.endPlayerDrag(0, extent: 360));
      await advance(tester, 700);
      expect(scenes.list.value, 0);
      expect(scenes.scene.value, Scene.player);
    });
  });

  testWidgets('the back key during a running move is a plain retarget', (
    tester,
  ) async {
    await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
    final scenes = AppNav.host! as SceneController;
    unawaited(scenes.toLibrary());
    await _lead(tester);
    await advance(tester, 100);
    unawaited(tester.binding.handlePopRoute());
    await tester.pump();
    await tester.pump();
    await advance(tester, 60);
    // Locked, the container would equal the list; on its own quart clock it
    // does not.
    expect(
      (scenes.container.value - scenes.list.value).abs(),
      greaterThan(0.02),
    );
  });

  group('pivot', () {
    testWidgets('falls back to the plain screen centre, also in a root swipe', (
      tester,
    ) async {
      final app = FakeApp()..playing = true;
      await pumpShell(tester, app: app, library: FakeLibrary());
      final scenes = AppNav.host! as SceneController;
      scenes.toLibrary();
      await advance(tester, 700);
      scenes.playerPivot.value = Offset.zero;
      scenes.beginRootSwipe();
      expect(scenes.playerPivotOrCenter, const Offset(200, 400));
    });

    testWidgets('a cover drag measures the cover centre as it starts', (
      tester,
    ) async {
      final app = FakeApp()..queue = [song(7)];
      await pumpShell(
        tester,
        app: app,
        library: FakeLibrary(),
        playerBuilder: _player,
      );
      final scenes = AppNav.host! as SceneController;
      scenes.beginPlayerDrag();
      expect(scenes.playerPivot.value, kCoverRect.center);
    });
  });

  group('go to album from the player', () {
    const key = LibraryPageKey('album', {'albumId': 5});

    testWidgets(
      'does not push the page twice when the origin already ends on it',
      (tester) async {
        final app = FakeApp()..playbackOrigin = const PlaybackOrigin([key]);
        final lib = FakeLibrary();
        await pumpShell(tester, app: app, library: lib);
        final ctx = tester.element(find.byKey(kPlayerKey));
        var done = false;
        AppNav.openPage(
          ctx,
          const Text('x'),
          key: key,
        ).then((_) => done = true);
        await advance(tester, 700);
        expect(lib.stack, [key]);
        expect(done, isTrue);
      },
    );

    testWidgets('completes when another move takes over first', (tester) async {
      final lib = FakeLibrary();
      await pumpShell(tester, app: FakeApp(), library: lib);
      final scenes = AppNav.host! as SceneController;
      final ctx = tester.element(find.byKey(kPlayerKey));
      var done = false;
      AppNav.openPage(ctx, const Text('x'), key: key).then((_) => done = true);
      scenes.showPlayerNow(); // supersedes before the page could be pushed
      await advance(tester, 300);
      expect(done, isTrue);
      expect(lib.stack, isEmpty);
    });

    testWidgets('hands an error from the library to the caller', (
      tester,
    ) async {
      final lib = _ThrowingLibrary();
      await pumpShell(tester, app: FakeApp(), library: lib);
      final ctx = tester.element(find.byKey(kPlayerKey));
      Object? caught;
      AppNav.openPage(ctx, const Text('x'), key: key).catchError((Object e) {
        caught = e;
      });
      await advance(tester, 400);
      expect(caught, isA<StateError>());
    });
  });
}

class _ThrowingLibrary extends FakeLibrary {
  @override
  Future<void> openPage(
    Widget page, {
    required LibraryPageKey key,
    Object? morphFrom,
    bool sibling = false,
  }) async => throw StateError('no such page');
}
