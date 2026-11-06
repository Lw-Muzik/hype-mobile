import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/motion/morph.dart';
import 'package:eq_app/navigation/motion_spec.dart';
import 'package:eq_app/navigation/shell/cover_drag.dart';
import 'package:eq_app/navigation/shell/player_chrome.dart';
import 'package:eq_app/navigation/shell/scene_controller.dart';
import 'package:eq_app/player/remote/remote_player.dart';
import 'package:eq_app/services/connect/connect_protocol.dart';
import 'package:eq_app/services/connect/remote/connect_remote_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_zoom_drawer/flutter_zoom_drawer.dart';
import 'package:eq_app/widgets/bottom_player.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_harness.dart';

Future<void> _backGesture(WidgetTester tester, String method, [Object? args]) =>
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/backgesture',
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );

const _start = {
  'touchOffset': [0.0, 0.0],
  'progress': 0.0,
  'swipeEdge': 0,
};

/// The stand-in a flight draws: the one Positioned that holds a FittedBox.
Rect? _flightRect(WidgetTester tester, [Size? a, Size? b]) {
  final found = find.ancestor(
    of: find.byType(FittedBox),
    matching: find.byType(Positioned),
  );
  if (found.evaluate().isEmpty) return null;
  final w = tester.widget<Positioned>(found.first);
  return Rect.fromLTWH(w.left!, w.top!, w.width!, w.height!);
}

Future<void> _start250(WidgetTester tester, void Function() go) async {
  go();
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  group('back gesture belongs to the route on top', () {
    testWidgets('the shell answers it while it is current', (tester) async {
      final host = FakeHost(FakeLibrary());
      await pumpShell(
        tester,
        app: FakeApp(),
        library: FakeLibrary(),
        host: host,
      );
      final scenes = AppNav.host! as SceneController;
      scenes.toLibrary();
      await advance(tester, 600);
      expect(host.systemBack, isTrue);
      await _backGesture(tester, 'startBackGesture', _start);
      await tester.pump();
      expect(scenes.list.isFingerDriven, isTrue, reason: 'control case');
    });

    testWidgets('a page pushed over it gets the gesture and the pop', (
      tester,
    ) async {
      final host = FakeHost(FakeLibrary());
      final nav = await pumpShell(
        tester,
        app: FakeApp(),
        library: FakeLibrary(),
        host: host,
      );
      final scenes = AppNav.host! as SceneController;
      scenes.toLibrary();
      await advance(tester, 600);
      nav.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('settings')),
      );
      await tester.pumpAndSettle();
      expect(host.systemBack, isFalse);

      await _backGesture(tester, 'startBackGesture', _start);
      await tester.pump();
      expect(scenes.list.isFingerDriven, isFalse);
      expect(scenes.scene.value, Scene.library);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('settings'), findsNothing);
      expect(scenes.scene.value, Scene.library, reason: 'shell untouched');
      expect(scenes.list.value, 1);
      expect(host.systemBack, isTrue, reason: 'answers again once uncovered');
    });
  });

  group('remote player', () {
    testWidgets('its chevron goes to the library', (tester) async {
      final rig = _RemoteRig();
      await pumpShell(
        tester,
        app: FakeApp(),
        library: FakeLibrary(),
        playerBuilder: (_) => RemotePlayerView(
          remote: rig.session.nowPlaying()!,
          session: rig.session,
        ),
      );
      final scenes = AppNav.host! as SceneController;
      expect(find.byType(RemotePlayerView), findsOneWidget);
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
      await advance(tester, 600);
      expect(scenes.scene.value, Scene.library);
      expect(find.byType(RemotePlayerView), findsNothing);
      rig.session.dispose();
    });

    testWidgets('its down fling goes to the library', (tester) async {
      final rig = _RemoteRig();
      await pumpShell(
        tester,
        app: FakeApp(),
        library: FakeLibrary(),
        playerBuilder: (_) => RemotePlayerView(
          remote: rig.session.nowPlaying()!,
          session: rig.session,
        ),
      );
      final scenes = AppNav.host! as SceneController;
      await tester.fling(
        find.byKey(const Key('remote-art')),
        const Offset(0, 400),
        2000,
      );
      await advance(tester, 600);
      expect(scenes.scene.value, Scene.library);
      rig.session.dispose();
    });
  });

  group('flights', () {
    final cover = const ValueKey('cover');

    Widget player(BuildContext _) => Stack(
      key: kPlayerKey,
      children: [
        Positioned.fromRect(
          rect: kCoverRect,
          child: MorphTag(
            tag: kNowPlayingArtTag,
            child: ColoredBox(key: cover, color: Colors.orange),
          ),
        ),
      ],
    );

    testWidgets('player to library ends exactly on the row art (T1)', (
      tester,
    ) async {
      final app = FakeApp()..queue = [song(7)];
      await pumpShell(
        tester,
        app: app,
        library: FakeLibrary(),
        host: FakeHost(FakeLibrary(), rowTag: trackTag(7), rowRect: kRowRect),
        playerBuilder: player,
      );
      final scenes = AppNav.host! as SceneController;
      await _start250(tester, scenes.toLibrary);
      await advance(tester, 100);
      final mid = _flightRect(tester, kRowRect.size, kCoverRect.size);
      expect(mid, isNotNull, reason: 'the cover is flying');
      expect(mid!.width, greaterThan(kRowRect.width + 10));
      await advance(tester, 140);
      final end = _flightRect(tester, kRowRect.size, kCoverRect.size);
      expect(end, isNotNull);
      expect(end!.left, closeTo(kRowRect.left, 3));
      expect(end.top, closeTo(kRowRect.top, 3));
      expect(end.width, closeTo(kRowRect.width, 3));
    });

    testWidgets('library to player ends exactly on the cover (T5)', (
      tester,
    ) async {
      final app = FakeApp()..queue = [song(7)];
      await pumpShell(
        tester,
        app: app,
        library: FakeLibrary(),
        host: FakeHost(FakeLibrary(), rowTag: trackTag(7), rowRect: kRowRect),
        playerBuilder: player,
      );
      final scenes = AppNav.host! as SceneController;
      scenes.toLibrary();
      await advance(tester, 700);
      await _start250(tester, scenes.toPlayer);
      await advance(tester, 100);
      expect(
        _flightRect(tester, kRowRect.size, kCoverRect.size),
        isNotNull,
        reason: 'the row art flies into the cover',
      );
      await advance(tester, 140);
      final end = _flightRect(tester, kRowRect.size, kCoverRect.size)!;
      expect(end.left, closeTo(kCoverRect.left, 3));
      expect(end.top, closeTo(kCoverRect.top, 3));
      expect(end.width, closeTo(kCoverRect.width, 3));
    });

    testWidgets('a YouTube track flies by its video id, like its rows', (
      tester,
    ) async {
      final app = FakeApp()..queue = [song(123456, videoId: 'vid1')];
      await pumpShell(
        tester,
        app: app,
        library: FakeLibrary(),
        host: FakeHost(
          FakeLibrary(),
          rowTag: trackTag('vid1'),
          rowRect: kRowRect,
        ),
        playerBuilder: player,
      );
      final scenes = AppNav.host! as SceneController;
      await _start250(tester, scenes.toLibrary);
      await advance(tester, 100);
      expect(_flightRect(tester, kRowRect.size, kCoverRect.size), isNotNull);
    });

    testWidgets('no visible row: the player only zooms, no flight', (
      tester,
    ) async {
      final app = FakeApp()..queue = [song(7)];
      await pumpShell(
        tester,
        app: app,
        library: FakeLibrary(),
        playerBuilder: player,
      );
      final scenes = AppNav.host! as SceneController;
      await _start250(tester, scenes.toLibrary);
      await advance(tester, 100);
      expect(_flightRect(tester, kRowRect.size, kCoverRect.size), isNull);
      expect(find.byKey(cover), findsOneWidget);
    });

    testWidgets('the mini player art is never a flight source (T2)', (
      tester,
    ) async {
      final app = FakeApp()..queue = [song(7)];
      await pumpShell(
        tester,
        app: app,
        library: FakeLibrary(),
        playerBuilder: player,
        // The bar's art wears a tag: were it a source, a flight would show.
        miniBuilder: (_, _) => const MorphTag(
          tag: 'mini-art',
          child: SizedBox(key: kMiniKey, height: 60, width: 60),
        ),
      );
      final scenes = AppNav.host! as SceneController;
      scenes.toLibrary();
      await advance(tester, 700);
      await _start250(tester, scenes.toPlayer);
      await advance(tester, 100);
      // No row in the list: the player zooms in place, nothing flies.
      expect(_flightRect(tester), isNull);
    });
  });

  group('clocks', () {
    testWidgets('the mini player rise is 74 dp quartOut, on its own clock', (
      tester,
    ) async {
      await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
      final scenes = AppNav.host! as SceneController;
      await _start250(tester, scenes.toLibrary);
      await advance(tester, 250);
      // Past the 250 ms list: the mini player is still on its way.
      final y = tester.getTopLeft(find.byKey(kMiniKey)).dy;
      expect(
        y,
        closeTo(740 + MotionSpec.miniPlayerRise * (1 - quartOut(0.5)), 1.5),
      );
      expect(scenes.mini.value, lessThan(1));
      await advance(tester, 300);
      expect(tester.getTopLeft(find.byKey(kMiniKey)).dy, closeTo(740, 0.5));
    });

    testWidgets('a committed drag still plays the whole mini rise afterwards', (
      tester,
    ) async {
      await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
      final scenes = AppNav.host! as SceneController;
      final drag = CoverDrag(scenes, fallbackExtent: () => 360);
      drag.start(100);
      drag.update(100 + 8 + 200);
      drag.end(0);
      await advance(tester, 220);
      expect(scenes.scene.value, Scene.library);
      expect(scenes.list.value, 1);
      expect(scenes.mini.value, lessThan(0.9), reason: 'not cut short');
      await advance(tester, 120);
      final m = scenes.mini.value;
      expect(m, greaterThan(0.5));
      await advance(tester, 500);
      expect(scenes.mini.value, 1);
    });

    testWidgets('back at Places: the container copies the list (no tail)', (
      tester,
    ) async {
      final lib = FakeLibrary();
      await pumpShell(tester, app: FakeApp(), library: lib);
      final scenes = AppNav.host! as SceneController;
      scenes.toLibrary();
      await advance(tester, 700);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await advance(tester, 125);
      expect(scenes.container.value, closeTo(scenes.list.value, 0.001));
      await advance(tester, 135);
      expect(scenes.list.value, 0);
      expect(scenes.container.value, 0, reason: 'settled with the list');
      expect(scenes.mini.value, greaterThan(0), reason: 'mini keeps its clock');
    });
  });

  group('library frame', () {
    testWidgets(
      'the mini player rides above the layers, and inside the card once the drawer opens',
      (tester) async {
        final drawer = ValueNotifier<DrawerState>(DrawerState.closed);
        await pumpShell(
          tester,
          app: FakeApp(),
          library: FakeLibrary(),
          drawerState: drawer,
        );
        final scenes = AppNav.host! as SceneController;
        scenes.toLibrary();
        await advance(tester, 700);
        final inFrame = find.descendant(
          of: find.byKey(kFrameKey),
          matching: find.byKey(kMiniKey),
        );
        expect(find.byKey(kMiniKey), findsOneWidget);
        expect(
          inFrame,
          findsNothing,
          reason: 'closed drawer: above the layers',
        );

        drawer.value = DrawerState.opening;
        await tester.pump();
        await tester.pump();
        expect(inFrame, findsOneWidget, reason: 'travels with the card');
        expect(find.byKey(kMiniKey), findsOneWidget);

        drawer.value = DrawerState.closed;
        await tester.pump();
        await tester.pump();
        expect(inFrame, findsNothing);
        expect(find.byKey(kMiniKey), findsOneWidget);
      },
    );

    testWidgets('the mini player is not scaled or faded by the library layer', (
      tester,
    ) async {
      await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
      final scenes = AppNav.host! as SceneController;
      await _start250(tester, scenes.toLibrary);
      await advance(tester, 120);
      // Mid-move the library layer is scaled and translucent; the bar's size
      // is still its own.
      expect(tester.getSize(find.byKey(kMiniKey)).height, 60);
    });

    testWidgets('the bar follows the playing track while the library shows', (
      tester,
    ) async {
      final app = FakeApp()..queue = [song(1)];
      await pumpShell(
        tester,
        app: app,
        library: FakeLibrary(),
        miniBuilder: (ctx, a) => SizedBox(
          key: kMiniKey,
          height: 60,
          child: Text(a.queue.first.title),
        ),
      );
      final scenes = AppNav.host! as SceneController;
      scenes.toLibrary();
      await advance(tester, 700);
      expect(find.text('t1'), findsOneWidget);
      app.queue = [song(2)];
      app.notifyListeners();
      await tester.pump();
      expect(find.text('t2'), findsOneWidget);
      expect(find.text('t1'), findsNothing);
    });

    testWidgets('the equalizer and music modes share one drawer frame', (
      tester,
    ) async {
      var inits = 0;
      final app = FakeApp();
      await pumpShell(
        tester,
        app: app,
        library: FakeLibrary(),
        frameProbe: () => _Probe(onInit: () => inits++),
      );
      expect(inits, 1);
      app.eqMode = true;
      app.notifyListeners();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(kEqKey), findsOneWidget);
      app.eqMode = false;
      app.notifyListeners();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(kEqKey), findsNothing);
      expect(inits, 1, reason: 'the frame (and its state) was kept');
    });

    testWidgets('the keyboard is not subtracted twice from the library', (
      tester,
    ) async {
      double? inset;
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await pumpShell(
        tester,
        app: FakeApp(),
        library: FakeLibrary(),
        host: FakeHost(
          FakeLibrary(),
          onBuild: (c) => inset = MediaQuery.of(c).viewInsets.bottom,
        ),
      );
      // 300 of keyboard, of which the mini player's room (the bar and the gap
      // under it) already covers some.
      expect(inset, 300 - (BottomPlayer.barHeight + BottomPlayer.barGap));
    });

    testWidgets(
      'equalizer-only mode keeps the drawer frame and no scene host',
      (tester) async {
        final app = FakeApp()..eqMode = true;
        await pumpShell(tester, app: app, library: FakeLibrary());
        expect(
          find.descendant(
            of: find.byKey(kFrameKey),
            matching: find.byKey(kEqKey),
          ),
          findsOneWidget,
        );
        expect(AppNav.host, isNull);
      },
    );
  });

  group('go to album from the player', () {
    testWidgets('moves the player away and lands on that page', (tester) async {
      final lib = FakeLibrary();
      await pumpShell(tester, app: FakeApp(), library: lib);
      final scenes = AppNav.host! as SceneController;
      final ctx = tester.element(find.byKey(kPlayerKey));
      const key = LibraryPageKey('album', {'albumId': 5});
      AppNav.openPage(ctx, const Text('album'), key: key);
      await advance(tester, 700);
      expect(scenes.scene.value, Scene.library);
      expect(lib.stack.last, key);
      expect(find.byKey(kPlayerKey), findsNothing);
    });
  });

  group('chrome and drag details', () {
    testWidgets('chrome never remounts its child as the clock moves', (
      tester,
    ) async {
      final hidden = ValueNotifier<double>(0);
      var inits = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerChromeScope(
            hidden: hidden,
            child: PlayerChrome(child: _Probe(onInit: () => inits++)),
          ),
        ),
      );
      for (final v in [0.3, 1.0, 0.5, 0.0]) {
        hidden.value = v;
        await tester.pump();
      }
      expect(inits, 1);
    });

    testWidgets('a cover drag during a move is ignored', (tester) async {
      await pumpShell(tester, app: FakeApp(), library: FakeLibrary());
      final scenes = AppNav.host! as SceneController;
      await _start250(tester, scenes.toLibrary);
      await advance(tester, 100);
      final before = scenes.list.value;
      final drag = CoverDrag(scenes, fallbackExtent: () => 360);
      drag.start(100);
      drag.update(100 + 8 + 100);
      expect(scenes.list.isFingerDriven, isFalse);
      expect(scenes.list.value, greaterThanOrEqualTo(before));
      expect(drag.end(0), isFalse);
    });
  });
}

class _Probe extends StatefulWidget {
  const _Probe({required this.onInit});

  final VoidCallback onInit;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 10, height: 10);
}

class _RemoteRig {
  _RemoteRig() {
    session = ConnectRemoteSession(
      selfId: 'phone',
      send: (_) => true,
      hubNowMs: () => 1000000,
    );
    DeviceInfo device(String id, DeviceKind kind) => DeviceInfo(
      id: id,
      kind: kind,
      name: 'Name of $id',
      platform: null,
      appVersion: null,
      caps: const [ConnectCap.player, ConnectCap.yt],
      online: true,
      lastSeenAt: '2026-01-01T00:00:00Z',
    );
    session.onFrame(
      WelcomeFrame(
        v: 1,
        deviceId: 'phone',
        serverTime: 1000000,
        devices: [
          device('phone', DeviceKind.mobile),
          device('desk', DeviceKind.desktop),
        ],
        activeDeviceId: 'desk',
        states: const {},
      ),
    );
    session.onFrame(
      StampedStateFrame(
        deviceId: 'desk',
        state: StampedState(
          at: 1000000,
          state: PlayerState(
            seq: 1,
            track: YtTrackRef(
              videoId: 'now',
              title: 'tnow',
              artist: 'anow',
              album: null,
              durationMs: 200000,
              artUrl: null,
            ),
            playing: true,
            positionMs: 10000,
            durationMs: 200000,
            volume: 0.6,
            shuffle: false,
            repeat: ConnectRepeat.off,
            queue: const [],
          ),
        ),
      ),
    );
  }

  late final ConnectRemoteSession session;
}
