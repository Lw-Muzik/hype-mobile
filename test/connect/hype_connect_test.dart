import 'dart:async';
import 'dart:convert';

import 'package:eq_app/services/connect/connect_account.dart';
import 'package:eq_app/services/connect/connect_api.dart';
import 'package:eq_app/models/lyrics_model.dart';
import 'package:eq_app/services/connect/connect_client.dart';
import 'package:eq_app/services/connect/connect_lyrics.dart';
import 'package:eq_app/services/connect/connect_notification.dart';
import 'package:eq_app/services/connect/connect_service.dart';
import 'package:eq_app/services/connect/connect_viz.dart';
import 'package:eq_app/visualizers/beat_frame.dart';
import 'dart:typed_data';
import 'package:eq_app/services/connect/connect_executor.dart';
import 'package:eq_app/services/connect/connect_protocol.dart';
import 'package:eq_app/services/connect/connect_rpc.dart';
import 'package:eq_app/services/connect/connect_state_publisher.dart';
import 'package:eq_app/services/connect/hype_connect.dart';
import 'package:eq_app/services/ytmusic/yt_models.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryStore implements ConnectSecretStore {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _Socket implements ConnectSocket {
  final _incoming = StreamController<String>();
  final sent = <Map<String, Object?>>[];
  @override
  int? closeCode;
  @override
  String? closeReason;
  @override
  Future<void> get ready => Future.value();
  @override
  Stream<String> get messages => _incoming.stream;
  @override
  void send(String text) => sent.add(jsonDecode(text) as Map<String, Object?>);
  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_incoming.isClosed) await _incoming.close();
  }

  void receive(ConnectFrame frame) => _incoming.add(frame.encode());
  void serverClose(int code) {
    closeCode = code;
    _incoming.close();
  }

  Iterable<String> get types => sent.map((f) => f['t'] as String);
}

class _Player implements ConnectPlayer {
  final calls = <String>[];
  @override
  bool get available => true;
  @override
  bool get hasQueue => true;
  @override
  Future<void> play(PlayPlan plan) async => calls.add('play');
  @override
  Future<void> enqueue(List<Playable> items, EnqueueMode mode) async => calls.add('enqueue');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> resume() async => calls.add('resume');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> next() async => calls.add('next');
  @override
  Future<void> prev() async => calls.add('prev');
  @override
  Future<void> seek(Duration position) async => calls.add('seek');
  @override
  Future<bool> jump(String uid) async => true;
  @override
  Future<void> setVolume(double value) async => calls.add('volume');
  @override
  Future<void> setShuffle(bool on) async => calls.add('shuffle');
  @override
  Future<void> setRepeat(ConnectRepeat mode) async => calls.add('repeat');
}

class _Library implements ConnectLibrary {
  @override
  Future<Map<int, SongModel>> songsByIds(Iterable<int> ids) async => {};
  @override
  Future<({int total, List<SongModel> songs})> page({
    required int offset,
    required int limit,
    String? query,
  }) async => (total: 0, songs: <SongModel>[]);
}

class _Catalog implements ConnectCatalog {
  @override
  bool get available => true;
  @override
  Future<List<ExploreShelf>> search(String query, SearchFilter filter) async => [];
  @override
  Future<List<String>> suggest(String query) async => [];
  @override
  Future<({String title, List<YtTrack> tracks})> open(ExploreItem item) async =>
      (title: '', tracks: <YtTrack>[]);
  @override
  Future<List<ExploreShelf>> artist(String browseId) async => [];
}

class _Source implements ConnectStateSource {
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  ConnectSnapshot read() => const ConnectSnapshot(
        track: null,
        playing: false,
        position: Duration.zero,
        duration: null,
        volume: 1,
        shuffle: false,
        repeat: ConnectRepeat.off,
        upcoming: [],
      );
}

class _Feed implements ConnectVizFeed {
  final c = StreamController<BeatFrame>(sync: true);
  int listens = 0;
  int cancels = 0;

  @override
  Stream<BeatFrame> get frames => Stream<BeatFrame>.multi((m) {
        listens++;
        final sub = c.stream.listen(m.add);
        m.onCancel = () {
          cancels++;
          return sub.cancel();
        };
      });
}

class _Lyrics implements ConnectLyricsSource {
  @override
  Future<LyricsData?> lyricsFor(SongModel song) async =>
      parseLrc('[00:01.00]hello');
}

class _Bridge implements ConnectServiceBridge {
  bool running = false;
  final calls = <String>[];
  final updates = <ConnectNotificationContent>[];
  void Function(String id)? action;
  void Function(String direction)? volumeKey;
  final remoteKeys = <bool>[];

  @override
  set onAction(void Function(String id)? handler) => action = handler;
  @override
  set onOpenRequested(void Function()? handler) {}
  @override
  set onVolumeChanged(void Function(double value)? handler) {}
  @override
  set onVolumeKey(void Function(String direction)? handler) =>
      volumeKey = handler;
  @override
  Future<double?> getVolume() async => null;
  @override
  Future<bool> setVolume(double value) async => false;
  @override
  Future<void> watchVolume(bool on) async {}
  @override
  Future<void> setRemoteVolumeKeys(bool on) async => remoteKeys.add(on);
  @override
  Future<bool> isRunning() async => running;
  @override
  Future<bool> start() async {
    calls.add('start');
    return running = true;
  }

  @override
  Future<void> update(ConnectNotificationContent content) async =>
      updates.add(content);
  @override
  Future<void> stop() async {
    calls.add('stop');
    running = false;
  }

  @override
  Future<void> setBootEnabled(bool enabled) async => calls.add('boot:$enabled');
  @override
  Future<bool> isIgnoringBatteryOptimizations() async => true;
  @override
  Future<void> openBatterySettings() async {}
  @override
  Future<bool> takeOpenRequest() async => false;
}

class _Rig {
  _Rig({this.musicMode = true});

  /// Set before [build] to behave like Android: a background service and a
  /// socket that is never let go in the background.
  _Bridge? bridge;
  bool backgroundAlways = false;
  Duration grace = const Duration(minutes: 2);

  bool musicMode;
  bool playing = false;
  final sockets = <_Socket>[];
  final requests = <String>[];
  final player = _Player();
  late HypeConnect connect;

  /// Set before [build] to wire the v1.1 features.
  _Feed? feed;
  _Lyrics? lyrics;
  SongModel? song;
  int nowUs = 1000000000;

  Future<void> build({Map<String, Object> prefsValues = const {}}) async {
    SharedPreferences.setMockInitialValues(prefsValues);
    final prefs = await SharedPreferences.getInstance();
    final backend = MockClient((request) async {
      requests.add('${request.method} ${request.url.path}');
      if (request.url.path.endsWith('/connect/devices')) {
        return http.Response(
          jsonEncode({'devices': <Object?>[], 'activeDeviceId': null}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200, headers: {'content-type': 'application/json'});
    });
    final account = ConnectAccount(
      client: backend,
      apiBase: Uri.parse('http://hub.test/api'),
      store: _MemoryStore()
        ..values[ConnectAccount.tokensKey] = jsonEncode(ConnectTokens(
          accessToken: 'a',
          refreshToken: 'r',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
          userId: 'u-1',
        ).toJson()),
      installInfo: () async => const ConnectInstallInfo(os: 'android', appVersion: '1'),
      newInstallId: () => 'install-1',
    );
    final client = ConnectClient(
      wsUri: Uri.parse('ws://hub.test/api/connect/ws'),
      connect: (_) {
        final socket = _Socket();
        sockets.add(socket);
        return socket;
      },
      accessToken: () async => 'a',
      refreshToken: () async {},
      resetSession: () async {},
      device: () async => const DeviceHello(
        id: 'install-1',
        kind: DeviceKind.mobile,
        name: 'Test phone',
        platform: 'android',
        appVersion: '1',
        caps: [ConnectCap.player, ConnectCap.yt, ConnectCap.local],
      ),
    );
    connect = HypeConnect(
      prefs: prefs,
      account: account,
      api: ConnectApi(client: backend, account: account),
      client: client,
      player: player,
      library: _Library(),
      catalog: _Catalog(),
      stateSource: _Source(),
      isMusicMode: () => musicMode,
      isPlaying: () => playing,
      lyrics: lyrics,
      currentSong: () => song,
      vizFeed: feed,
      position: () => const Duration(seconds: 12),
      nowUs: () => nowUs,
      presenceGrace: grace,
      backgroundAlways: backgroundAlways,
      serviceBridge: bridge,
    );
    await connect.start();
    await pump();
  }

  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 20));

  /// Plays the hub: lets the phone say hello and answers with welcome.
  Future<_Socket> welcome() async {
    await pump();
    final socket = sockets.last;
    socket.receive(const WelcomeFrame(
      v: 1,
      deviceId: 'install-1',
      serverTime: 1,
      devices: [],
      activeDeviceId: null,
      states: {},
    ));
    await pump();
    return socket;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('switch', () {
    test('is off by default and opens no socket', () async {
      final rig = _Rig();
      await rig.build();
      expect(rig.connect.enabled, isFalse);
      expect(rig.sockets, isEmpty);
    });

    test('turning it on connects and says hello first', () async {
      final rig = _Rig();
      await rig.build();
      await rig.connect.setEnabled(true);
      await rig.pump();
      expect(rig.sockets, hasLength(1));
      expect(rig.sockets.single.types.first, 'hello');
      final hello = rig.sockets.single.sent.first['device']! as Map;
      expect(hello['kind'], 'mobile');
      expect(hello['caps'], ['player', 'yt', 'local']);
    });

    test('is remembered', () async {
      final rig = _Rig();
      await rig.build();
      await rig.connect.setEnabled(true);
      final again = _Rig();
      await again.build(prefsValues: {HypeConnect.enabledKey: true});
      expect(again.connect.enabled, isTrue);
      expect(again.sockets, hasLength(1));
    });

    test('turning it off hangs up', () async {
      final rig = _Rig();
      await rig.build(prefsValues: {HypeConnect.enabledKey: true});
      final socket = await rig.welcome();
      await rig.connect.setEnabled(false);
      await rig.pump();
      expect(rig.connect.connection.status, ConnectStatus.off);
      expect(socket.closeCode ?? 1000, isNotNull);
    });

    test('an equalizer-only app does not connect', () async {
      final rig = _Rig(musicMode: false);
      await rig.build(prefsValues: {HypeConnect.enabledKey: true});
      expect(rig.sockets, isEmpty);
      rig.musicMode = true;
      rig.connect.inputsChanged();
      await rig.pump();
      expect(rig.sockets, hasLength(1));
    });

    test('backgrounded it stays on the hub for the grace, and playing keeps it', () async {
      final rig = _Rig();
      await rig.build(prefsValues: {HypeConnect.enabledKey: true});
      await rig.welcome();
      rig.connect.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(rig.connect.wantsConnection, isTrue);
      rig.playing = true;
      rig.connect.inputsChanged();
      expect(rig.connect.wantsConnection, isTrue);
    });
  });

  group('linking', () {
    test('approving a link switches it on', () async {
      final rig = _Rig();
      await rig.build();
      await rig.connect.approveLink('123456');
      expect(rig.requests, contains('POST /api/connect/links/123456/approve'));
      expect(rig.connect.enabled, isTrue);
      await rig.pump();
      expect(rig.sockets, hasLength(1));
    });

    test('a failed approval leaves it off', () async {
      SharedPreferences.setMockInitialValues({});
      final rig = _Rig();
      await rig.build();
      final failing = HypeConnect(
        prefs: rig.connect.prefs,
        account: rig.connect.account,
        api: ConnectApi(
          client: MockClient((_) async => http.Response(
                jsonEncode({'message': 'gone'}),
                404,
                headers: {'content-type': 'application/json'},
              )),
          account: rig.connect.account,
        ),
        client: rig.connect.client,
        player: rig.player,
        library: _Library(),
        catalog: _Catalog(),
        stateSource: _Source(),
        isMusicMode: () => true,
        isPlaying: () => false,
      );
      await expectLater(failing.approveLink('000000'), throwsA(isA<ConnectHttpException>()));
      expect(failing.enabled, isFalse);
    });
  });

  group('session', () {
    test('sends its state as soon as the hub welcomes it', () async {
      final rig = _Rig();
      await rig.build(prefsValues: {HypeConnect.enabledKey: true});
      final socket = await rig.welcome();
      // The client measures the hub clock on every welcome (contract §3.7).
      expect(socket.types, ['hello', 'ping', 'state']);
    });

    test('advertises v1.3: lyrics, viz and video', () {
      expect(HypeConnect.deviceCaps.map((c) => c.name),
          ['player', 'yt', 'local', 'lyrics', 'viz', 'video']);
    });

    test('answers the lyrics rpc end to end', () async {
      final rig = _Rig()
        ..lyrics = _Lyrics()
        ..song = SongModel({
          '_id': 7,
          '_data': '/m/a.mp3',
          'title': 'Hello',
          'artist': 'Adele',
          'duration': 1000,
          '_display_name': 'a.mp3',
          '_display_name_wo_ext': 'a',
        });
      await rig.build(prefsValues: {HypeConnect.enabledKey: true});
      final socket = await rig.welcome();
      socket.receive(const RpcFrame(
          id: 'r-1', from: 'web', method: 'lyrics', params: {}));
      await rig.pump();
      final out = socket.sent.firstWhere((f) => f['t'] == 'rpc_result');
      expect(out['ok'], isTrue);
      expect((out['result'] as Map)['found'], isTrue);
    });

    test('streams viz only after viz_sub on, and releases on off', () async {
      final rig = _Rig()..feed = _Feed();
      rig.playing = true;
      await rig.build(prefsValues: {HypeConnect.enabledKey: true});
      final socket = await rig.welcome();
      expect(rig.feed!.listens, 0, reason: 'nobody is watching');

      socket.receive(const VizSubFrame(on: true));
      await rig.pump();
      expect(rig.feed!.listens, 1);
      rig.nowUs += 100000;
      rig.feed!.c.add(BeatFrame(
        sampleRate: 44100,
        hopSeconds: 0.005,
        synced: false,
        hops: Float32List(0),
        bandsDb: Float32List.fromList(List.filled(64, -40)),
      ));
      await rig.pump();
      final viz = socket.sent.firstWhere((f) => f['t'] == 'viz');
      expect(((viz['frame'] as Map)['bands'] as List), hasLength(32));
      expect((viz['frame'] as Map)['positionMs'], 12000);

      socket.receive(const VizSubFrame(on: false));
      await rig.pump();
      expect(rig.feed!.cancels, 1);
    });

    test('a dropped socket releases the viz stream', () async {
      final rig = _Rig()..feed = _Feed();
      rig.playing = true;
      await rig.build(prefsValues: {HypeConnect.enabledKey: true});
      final socket = await rig.welcome();
      socket.receive(const VizSubFrame(on: true));
      await rig.pump();
      expect(rig.feed!.listens, 1);
      socket.serverClose(1006);
      await rig.pump();
      expect(rig.feed!.cancels, 1);
    });

    test('answers a command', () async {
      final rig = _Rig();
      await rig.build(prefsValues: {HypeConnect.enabledKey: true});
      final socket = await rig.welcome();
      socket.receive(const CmdFrame(id: 'c1', from: 'web-1', cmd: PauseCommand()));
      await rig.pump();
      expect(rig.player.calls, ['pause']);
      final ack = socket.sent.firstWhere((f) => f['t'] == 'ack');
      expect(ack['id'], 'c1');
      expect(ack['ok'], isTrue);
    });

    test('unlinked: turns itself off and says why', () async {
      final rig = _Rig();
      await rig.build(prefsValues: {HypeConnect.enabledKey: true});
      final socket = await rig.welcome();
      socket.serverClose(4003);
      await rig.pump();
      expect(rig.connect.enabled, isFalse);
      expect(rig.connect.notice, 'This phone was unlinked');
      expect(rig.connect.prefs.getBool(HypeConnect.enabledKey), isFalse);
      // …and does not come back by itself.
      await rig.pump();
      expect(rig.sockets, hasLength(1));
    });

    test('switching it on again clears the notice', () async {
      final rig = _Rig();
      await rig.build(prefsValues: {HypeConnect.enabledKey: true});
      final socket = await rig.welcome();
      socket.serverClose(4003);
      await rig.pump();
      await rig.connect.setEnabled(true);
      expect(rig.connect.notice, isNull);
    });

    test('the device list follows welcome and devices frames', () async {
      final rig = _Rig();
      await rig.build(prefsValues: {HypeConnect.enabledKey: true});
      final socket = await rig.welcome();
      socket.receive(const DevicesFrame(
        devices: [
          DeviceInfo(
            id: 'web-1',
            kind: DeviceKind.web,
            name: 'Chrome on macOS',
            platform: 'macos',
            appVersion: null,
            caps: [],
            online: true,
            lastSeenAt: '2026-10-12T08:00:00Z',
          ),
        ],
        activeDeviceId: 'install-1',
      ));
      await rig.pump();
      expect(rig.connect.devices.single.name, 'Chrome on macOS');
      expect(rig.connect.activeDeviceId, 'install-1');
    });
  });

  group('background service (Android)', () {
    _Rig android() => _Rig()
      ..bridge = _Bridge()
      ..backgroundAlways = true
      ..grace = const Duration(milliseconds: 30);

    test('stays on the hub in the background; iOS rules still let go', () async {
      final droid = android();
      await droid.build(prefsValues: {HypeConnect.enabledKey: true});
      await droid.welcome();
      droid.connect.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(droid.connect.wantsConnection, isTrue);

      final ios = _Rig()..grace = const Duration(milliseconds: 30);
      await ios.build(prefsValues: {HypeConnect.enabledKey: true});
      await ios.welcome();
      ios.connect.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(ios.connect.wantsConnection, isFalse);
    });

    test('turning it on starts the service; turning it off stops it', () async {
      final rig = android();
      await rig.build();
      await rig.connect.setEnabled(true);
      await rig.pump();
      expect(rig.bridge!.calls, contains('start'));
      expect(rig.bridge!.updates, isNotEmpty);
      await rig.connect.setEnabled(false);
      await rig.pump();
      expect(rig.bridge!.calls.last, 'stop');
      expect(rig.bridge!.calls, contains('boot:false'));
    });

    test('a service left running by a reboot is adopted, not restarted', () async {
      final rig = android();
      rig.bridge!.running = true;
      await rig.build(prefsValues: {HypeConnect.enabledKey: true});
      await rig.pump();
      expect(rig.bridge!.calls, isNot(contains('start')));
      expect(rig.bridge!.calls, isNot(contains('stop')));
      expect(rig.bridge!.updates.single.title, 'Reconnecting…');
    });

    test('leaving music-player mode stops the service', () async {
      final rig = android();
      await rig.build(prefsValues: {HypeConnect.enabledKey: true});
      expect(rig.bridge!.running, isTrue);
      rig.musicMode = false;
      rig.connect.inputsChanged();
      await rig.pump();
      expect(rig.bridge!.running, isFalse);
    });

    test('Turn off on the notification switches Hype Connect off', () async {
      final rig = android();
      await rig.build(prefsValues: {HypeConnect.enabledKey: true});
      await rig.welcome();
      rig.bridge!.action!('off');
      await rig.pump();
      expect(rig.connect.enabled, isFalse);
      expect(rig.bridge!.running, isFalse);
    });

    test('the notification says who is controlling and how many are online', () async {
      final rig = android();
      await rig.build(prefsValues: {HypeConnect.enabledKey: true});
      final socket = await rig.welcome();
      socket.receive(const DevicesFrame(
        devices: [
          DeviceInfo(
            id: 'web-1',
            kind: DeviceKind.web,
            name: 'Chrome',
            platform: null,
            appVersion: null,
            caps: [],
            online: true,
            lastSeenAt: '2026-10-12T08:00:00Z',
          ),
        ],
        activeDeviceId: 'install-1',
      ));
      socket.receive(const CmdFrame(id: 'c1', from: 'web-1', cmd: PauseCommand()));
      await rig.pump();
      // Updates are held back to one a second.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final last = rig.bridge!.updates.last;
      expect(last.title, 'Ready for your devices');
      expect(last.subText, 'Controlled from Chrome · 1 device online');
    });
  });

  group('remote volume keys', () {
    const phone = DeviceInfo(
      id: 'install-1',
      kind: DeviceKind.mobile,
      name: 'Test phone',
      platform: null,
      appVersion: null,
      caps: [ConnectCap.player],
      online: true,
      lastSeenAt: '2026-01-01T00:00:00Z',
    );
    const desk = DeviceInfo(
      id: 'desk',
      kind: DeviceKind.desktop,
      name: 'Studio PC',
      platform: null,
      appVersion: null,
      caps: [ConnectCap.player],
      online: true,
      lastSeenAt: '2026-01-01T00:00:00Z',
    );

    Future<_Socket> remoteWelcome(_Rig rig) async {
      await rig.pump();
      final socket = rig.sockets.last;
      socket.receive(const WelcomeFrame(
        v: 1,
        deviceId: 'install-1',
        serverTime: 1,
        devices: [phone, desk],
        activeDeviceId: 'desk',
        // A key steps from the level the device reported; with none it does
        // nothing (see ConnectRemoteSession.nudgeVolume).
        states: {
          'desk': StampedState(
            state: PlayerState(
              seq: 1,
              track: null,
              playing: true,
              positionMs: 0,
              durationMs: null,
              volume: 0.5,
              shuffle: false,
              repeat: ConnectRepeat.off,
              queue: [],
            ),
            at: 1,
          ),
        },
      ));
      await rig.pump();
      return socket;
    }

    test('go to the playing device while remote, and back when it ends', () async {
      final rig = _Rig()..bridge = _Bridge();
      await rig.build(prefsValues: {HypeConnect.enabledKey: true});
      final socket = await remoteWelcome(rig);
      expect(rig.bridge!.remoteKeys, contains(true));

      rig.bridge!.volumeKey!('down');
      await rig.pump();
      final cmd = socket.sent.lastWhere((f) => f['t'] == 'cmd');
      expect((cmd['cmd']! as Map)['type'], 'volume');
      expect((cmd['cmd']! as Map)['value'], closeTo(0.45, 0.001));
      expect(rig.connect.volumeHud.value?.deviceName, 'Studio PC');

      socket.serverClose(1006);
      await rig.pump();
      expect(rig.bridge!.remoteKeys.last, isFalse);
    });

    test('a key press outside remote mode does nothing', () async {
      final rig = _Rig()..bridge = _Bridge();
      await rig.build(prefsValues: {HypeConnect.enabledKey: true});
      final socket = await rig.welcome();
      rig.bridge!.volumeKey!('down');
      await rig.pump();
      expect(socket.types, isNot(contains('cmd')));
      expect(rig.connect.volumeHud.value, isNull);
    });
  });

  group('connectWsUri', () {
    test('http becomes ws and keeps host, port and prefix', () {
      expect(connectWsUri('http://192.168.1.2:4000/api').toString(),
          'ws://192.168.1.2:4000/api/connect/ws');
    });
    test('https becomes wss', () {
      expect(connectWsUri('https://hub.example/api/').toString(),
          'wss://hub.example/api/connect/ws');
    });
  });

  group('deviceDisplayName', () {
    test('android prefers the name the user gave', () {
      expect(
        deviceDisplayName(ios: false, name: "Bruno's S24", manufacturer: 'samsung', model: 'SM-S921B'),
        "Bruno's S24",
      );
    });
    test('android falls back to manufacturer and model', () {
      expect(
        deviceDisplayName(ios: false, name: '', manufacturer: 'samsung', model: 'SM-S921B'),
        'Samsung SM-S921B',
      );
    });
    test('does not repeat a manufacturer the model already starts with', () {
      expect(
        deviceDisplayName(ios: false, name: null, manufacturer: 'Xiaomi', model: 'Xiaomi 13'),
        'Xiaomi 13',
      );
    });
    test('ios uses the marketing name when name is generic', () {
      expect(
        deviceDisplayName(ios: true, name: 'iPhone', modelName: 'iPhone 15 Pro'),
        'iPhone 15 Pro',
      );
    });
    test('ios keeps a real name', () {
      expect(
        deviceDisplayName(ios: true, name: "Bruno's iPhone", modelName: 'iPhone 15 Pro'),
        "Bruno's iPhone",
      );
    });
  });
}
