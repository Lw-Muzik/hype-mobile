import 'dart:io';

import 'package:eq_app/controllers/app_controller.dart';
import 'package:eq_app/global/index.dart';
import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/library_path.dart';
import 'package:eq_app/navigation/playback_origin.dart';
import 'package:eq_app/services/connect/connect_protocol.dart';
import 'package:eq_app/services/connect/remote/connect_play_router.dart';
import 'package:eq_app/services/connect/remote/connect_remote_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:provider/provider.dart';

const _album = LibraryPageKey('album', {'id': 7});
const _folder = LibraryPageKey('folder', {'path': '/m'});

class _FakeController extends ChangeNotifier implements AppController {
  @override
  PlaybackOrigin? playbackOrigin;
  @override
  int queueGeneration = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Host implements NavHost {
  int players = 0;
  @override
  Future<void> toPlayer({Object? morphFrom}) async => players++;
  @override
  Future<void> toLibrary({PlaybackOrigin? landOn, Object? morphFrom}) async {}
  @override
  LibraryNavigatorController get library => throw UnimplementedError();
}

class _Ui implements ConnectPlayUi {
  @override
  Future<bool> confirmPlayHere(String title, String deviceName) async => true;
  @override
  void say(String message) {}
}

DeviceInfo _dev(String id) => DeviceInfo(
  id: id,
  kind: DeviceKind.desktop,
  name: 'Desk',
  platform: null,
  appVersion: null,
  caps: const [ConnectCap.player],
  online: true,
  lastSeenAt: 'x',
);

void _goRemote() {
  final session = ConnectRemoteSession(
    selfId: 'phone',
    send: (_) => true,
    hubNowMs: () => 1000,
  );
  session.onFrame(
    WelcomeFrame(
      v: 1,
      deviceId: 'phone',
      serverTime: 1000,
      devices: [_dev('phone'), _dev('desk')],
      activeDeviceId: 'desk',
      states: const {},
    ),
  );
  ConnectPlayRouter.instance = ConnectPlayRouter(
    session: session,
    deviceId: 'phone',
    ui: _Ui(),
  );
}

void main() {
  late _FakeController controller;
  late _Host host;
  late BuildContext inside;

  setUp(() {
    controller = _FakeController();
    host = _Host();
    AppNav.host = host;
  });

  tearDown(() {
    AppNav.host = null;
    ConnectPlayRouter.instance = null;
  });

  Future<void> pump(
    WidgetTester t, {
    List<LibraryPageKey> path = const [_album],
  }) => t.pumpWidget(
    ChangeNotifierProvider<AppController>.value(
      value: controller,
      child: MaterialApp(
        home: LibraryPathScope(
          path: path,
          child: Builder(
            builder: (c) {
              inside = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    ),
  );

  group('originForInstall: one origin per queue', () {
    const origin = PlaybackOrigin([_album]);

    test('a different queue starts with none', () {
      expect(originForInstall(origin, oldIds: [1, 2, 3], newIds: [9]), isNull);
      expect(
        originForInstall(origin, oldIds: [1, 2, 3], newIds: [3, 9]),
        isNull,
      );
    });

    test('nothing playing before: nothing to keep', () {
      expect(originForInstall(origin, oldIds: [], newIds: [1]), isNull);
      expect(originForInstall(null, oldIds: [1], newIds: [1]), isNull);
    });

    test('the same queue reshaped keeps its trail', () {
      expect(
        originForInstall(origin, oldIds: [1, 2, 3], newIds: [3, 1]),
        origin,
      );
      expect(originForInstall(origin, oldIds: [1, 2, 3], newIds: [2]), origin);
    });

    test('every install path in the controller goes through it', () {
      final src = File('lib/controllers/app_controller.dart')
          .readAsStringSync();
      final body = src.substring(src.indexOf('Future<void> playSongFromList('));
      final head = body.substring(0, body.indexOf('songs = songList;'));
      expect(head, contains('originForInstall('));
      // playStation, the mix path, Connect and "Play next" with nothing
      // playing all install through playSongFromList.
    });
  });

  testWidgets('a list action records its page as the origin', (t) async {
    await pump(t);
    await AppNav.toPlayer(inside);
    expect(controller.playbackOrigin, const PlaybackOrigin([_album]));
    expect(host.players, 1);
  });

  testWidgets('in remote mode a list tap leaves the local origin alone', (
    t,
  ) async {
    await pump(t);
    controller.playbackOrigin = const PlaybackOrigin([_folder]);
    _goRemote();
    await AppNav.toPlayer(inside);
    expect(controller.playbackOrigin, const PlaybackOrigin([_folder]));
    expect(host.players, 1);
  });

  group('toPlayerWhileStarting (mixes start asynchronously)', () {
    testWidgets('the origin goes to the queue the start installed', (t) async {
      await pump(t);
      controller.playbackOrigin = const PlaybackOrigin([_folder]);
      await AppNav.toPlayerWhileStarting(inside, controller, () async {
        // The old queue's origin is still there while the mix resolves.
        expect(controller.playbackOrigin, const PlaybackOrigin([_folder]));
        expect(host.players, 1, reason: 'the player opens at once');
        controller.queueGeneration++;
        controller.playbackOrigin = null; // the install drops the old one
      });
      expect(controller.playbackOrigin, const PlaybackOrigin([_album]));
    });

    testWidgets('a start that installs nothing leaves the old origin', (
      t,
    ) async {
      await pump(t);
      controller.playbackOrigin = const PlaybackOrigin([_folder]);
      await AppNav.toPlayerWhileStarting(inside, controller, () async {});
      expect(controller.playbackOrigin, const PlaybackOrigin([_folder]));
    });

    testWidgets('another queue getting in between gets no origin', (t) async {
      await pump(t);
      await AppNav.toPlayerWhileStarting(inside, controller, () async {
        controller.queueGeneration += 2;
        controller.playbackOrigin = null;
      });
      expect(controller.playbackOrigin, isNull);
    });

    testWidgets('remote mode records nothing', (t) async {
      await pump(t);
      _goRemote();
      await AppNav.toPlayerWhileStarting(inside, controller, () async {
        controller.queueGeneration++;
      });
      expect(controller.playbackOrigin, isNull);
    });
  });

  testWidgets('folder Play All opens the player like album Play', (t) async {
    // headerWidget is the folder page's header; its Play All button starts the
    // queue and must then show the player.
    final plays = <List<SongModel>>[];
    final fake = _PlayController(plays);
    final song = SongModel({
      '_id': 1,
      '_data': '/m/a.mp3',
      'title': 'A',
      '_display_name': 'a',
      '_display_name_wo_ext': 'a',
      '_size': 0,
      'is_music': true,
    });
    await t.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: fake,
        child: MaterialApp(
          home: LibraryPathScope(
            path: const [_folder],
            child: Builder(builder: (c) => headerWidget(fake, c, data: [song])),
          ),
        ),
      ),
    );
    await t.tap(find.text('Play All'));
    await t.pump();
    expect(plays, hasLength(1));
    expect(host.players, 1);
    expect(fake.playbackOrigin, const PlaybackOrigin([_folder]));
  });
}

class _PlayController extends _FakeController {
  _PlayController(this.plays);
  final List<List<SongModel>> plays;

  @override
  Future<void> playSongFromList(
    List<SongModel> songList,
    int index, {
    Duration? initialPosition,
  }) async {
    plays.add(songList);
  }
}
