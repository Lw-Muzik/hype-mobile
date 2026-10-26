/// Every normative fixture of the Hype Connect contract parses into this app's
/// typed models and re-serialises to the same JSON.
///
/// "The same JSON" is deep equality of the decoded values, key sets included —
/// so an optional field that was absent must stay absent, and a nullable field
/// that was present as `null` must stay present. Those are different frames to
/// a strict reader on the other end.
library;

import 'dart:convert';
import 'dart:io';

import 'package:eq_app/services/connect/connect_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const _dir = 'test/fixtures/connect';

Object? _load(String name) =>
    jsonDecode(File('$_dir/$name').readAsStringSync());

/// Round-trips through a JSON string too, so a value that only survives as a
/// Dart object (a non-string key, a `DateTime`) fails here rather than on the
/// socket.
Object? _wire(Map<String, Object?> json) => jsonDecode(jsonEncode(json));

/// `equals` compares maps and lists structurally, key sets included.
void _expectSame(Object? actual, Object? expected, String name) {
  expect(actual, equals(expected), reason: '$name did not round-trip');
}

/// What each fixture must parse as. Pinning the type matters: an
/// [UnknownFrame] round-trips anything verbatim, so without this a frame the
/// parser failed to recognise would pass.
const _frameTypes = <String, Type>{
  'ack.error.json': AckFrame,
  'ack.ok.json': AckFrame,
  'cmd.enqueue.json': CmdFrame,
  'cmd.jump.json': CmdFrame,
  'cmd.next.json': CmdFrame,
  'cmd.pause.json': CmdFrame,
  'cmd.play.from.json': CmdFrame,
  'cmd.play.radio.json': CmdFrame,
  'cmd.play.to.json': CmdFrame,
  'cmd.prev.json': CmdFrame,
  'cmd.repeat.json': CmdFrame,
  'cmd.resume.json': CmdFrame,
  'cmd.seek.json': CmdFrame,
  'cmd.shuffle.json': CmdFrame,
  'cmd.stop.json': CmdFrame,
  'cmd.volume.json': CmdFrame,
  'devices.json': DevicesFrame,
  'error.json': ErrorFrame,
  'hello.mobile.json': HelloFrame,
  'hello.mobile.v11.json': HelloFrame,
  'hello.web.json': HelloFrame,
  'ping.json': PingFrame,
  'pong.json': PongFrame,
  'rpc_result.artist.json': RpcResultFrame,
  'rpc_result.error.json': RpcResultFrame,
  'rpc_result.library.json': RpcResultFrame,
  'rpc_result.open.json': RpcResultFrame,
  'rpc_result.search.json': RpcResultFrame,
  'rpc_result.suggest.json': RpcResultFrame,
  'rpc.artist.from.json': RpcFrame,
  'rpc.library.from.json': RpcFrame,
  'rpc.open.from.json': RpcFrame,
  'rpc.search.from.json': RpcFrame,
  'rpc.search.to.json': RpcFrame,
  'rpc.suggest.from.json': RpcFrame,
  'rpc.lyrics.from.json': RpcFrame,
  'rpc.video.from.json': RpcFrame,
  'rpc_result.video.json': RpcResultFrame,
  'rpc_result.video.none.json': RpcResultFrame,
  'state.player.video.json': StateFrame,
  'hello.mobile.v13.json': HelloFrame,
  'rpc_result.lyrics.json': RpcResultFrame,
  'rpc_result.lyrics.none.json': RpcResultFrame,
  'rpc_result.lyrics.plain.json': RpcResultFrame,
  'viz_sub.player.off.json': VizSubFrame,
  'viz_sub.player.on.json': VizSubFrame,
  'viz_sub.to.json': VizSubFrame,
  'viz.player.json': VizFrame,
  'viz.stamped.json': VizFrame,
  'select.json': SelectFrame,
  'state.idle.json': StateFrame,
  'state.other.json': StateFrame,
  'state.player.json': StateFrame,
  'state.stamped.json': StampedStateFrame,
  'welcome.json': WelcomeFrame,
};

/// The command type inside each `cmd.*` fixture.
const _commandTypes = <String, Type>{
  'cmd.enqueue.json': EnqueueCommand,
  'cmd.jump.json': JumpCommand,
  'cmd.next.json': NextCommand,
  'cmd.pause.json': PauseCommand,
  'cmd.play.from.json': PlayCommand,
  'cmd.play.radio.json': PlayCommand,
  'cmd.play.to.json': PlayCommand,
  'cmd.prev.json': PrevCommand,
  'cmd.repeat.json': RepeatCommand,
  'cmd.resume.json': ResumeCommand,
  'cmd.seek.json': SeekCommand,
  'cmd.shuffle.json': ShuffleCommand,
  'cmd.stop.json': StopCommand,
  'cmd.volume.json': VolumeCommand,
};

final _restParsers = <String, Map<String, Object?> Function(Object?)>{
  'rest.devices.json': (raw) => DevicesResponse.fromJson(raw).toJson(),
  'rest.link-claim.approved.json': (raw) => LinkClaim.fromJson(raw).toJson(),
  'rest.link-claim.expired.json': (raw) => LinkClaim.fromJson(raw).toJson(),
  'rest.link-claim.pending.json': (raw) => LinkClaim.fromJson(raw).toJson(),
  'rest.link-preview.json': (raw) => LinkPreview.fromJson(raw).toJson(),
  'rest.link-ticket.json': (raw) => LinkTicket.fromJson(raw).toJson(),
};

/// The typed shape of each rpc's params, by method.
final _paramParsers = <String, Map<String, Object?> Function(Object?)>{
  'search': (raw) => SearchParams.fromJson(raw).toJson(),
  'suggest': (raw) => SuggestParams.fromJson(raw).toJson(),
  'open': (raw) => OpenParams.fromJson(raw).toJson(),
  'artist': (raw) => ArtistParams.fromJson(raw).toJson(),
  'library': (raw) => LibraryParams.fromJson(raw).toJson(),
  'lyrics': (raw) => Map<String, Object?>.of(raw as Map<String, Object?>),
  'video': (raw) => Map<String, Object?>.of(raw as Map<String, Object?>),
};

/// The typed shape of each successful rpc result. The frame does not say which
/// method it answers — the fixture's name does.
final _resultParsers = <String, Map<String, Object?> Function(Object?)>{
  'rpc_result.search.json': (raw) => ShelvesResult.fromJson(raw).toJson(),
  'rpc_result.artist.json': (raw) => ShelvesResult.fromJson(raw).toJson(),
  'rpc_result.suggest.json': (raw) => SuggestResult.fromJson(raw).toJson(),
  'rpc_result.open.json': (raw) => OpenResult.fromJson(raw).toJson(),
  'rpc_result.library.json': (raw) => LibraryResult.fromJson(raw).toJson(),
  'rpc_result.lyrics.json': (raw) => LyricsResult.fromJson(raw).toJson(),
  'rpc_result.lyrics.none.json': (raw) => LyricsResult.fromJson(raw).toJson(),
  'rpc_result.lyrics.plain.json': (raw) => LyricsResult.fromJson(raw).toJson(),
  'rpc_result.video.json': (raw) => VideoResult.fromJson(raw).toJson(),
  'rpc_result.video.none.json': (raw) => VideoResult.fromJson(raw).toJson(),
};

void main() {
  final names = Directory(_dir)
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((n) => n.endsWith('.json'))
      .toList()
    ..sort();

  test('the folder holds the 61 fixtures the contract ships (56 + 5 v1.3 video)', () {
    expect(names, hasLength(61));
    // Every one is covered by exactly one of the two tables below, so a
    // fixture added upstream and re-copied here cannot slip through untested.
    for (final name in names) {
      expect(
        _frameTypes.containsKey(name) ^ _restParsers.containsKey(name),
        isTrue,
        reason: '$name is not mapped to a parser',
      );
    }
  });

  group('frames', () {
    for (final entry in _frameTypes.entries) {
      test('${entry.key} parses as ${entry.value} and round-trips', () {
        final raw = _load(entry.key);
        final frame = ConnectFrame.fromJson(raw);
        expect(frame.runtimeType, entry.value);
        _expectSame(_wire(frame.toJson()), raw, entry.key);
        // And through the string codec the socket actually uses.
        _expectSame(
          jsonDecode(ConnectFrame.decode(jsonEncode(raw)).encode()),
          raw,
          entry.key,
        );
      });
    }
  });

  group('commands', () {
    for (final entry in _commandTypes.entries) {
      test('${entry.key} carries a ${entry.value}', () {
        final frame = ConnectFrame.fromJson(_load(entry.key)) as CmdFrame;
        expect(frame.cmd.runtimeType, entry.value);
      });
    }
  });

  group('rpc params and results', () {
    for (final name in names.where((n) => n.startsWith('rpc.'))) {
      test('$name params parse as their method\'s typed params', () {
        final raw = _load(name) as Map<String, Object?>;
        final frame = ConnectFrame.fromJson(raw) as RpcFrame;
        expect(frame.knownMethod, isNotNull);
        final parse = _paramParsers[frame.method]!;
        _expectSame(_wire(parse(frame.params)), raw['params'], name);
      });
    }
    for (final entry in _resultParsers.entries) {
      test('${entry.key} result parses as typed and round-trips', () {
        final raw = _load(entry.key) as Map<String, Object?>;
        final frame = ConnectFrame.fromJson(raw) as RpcResultFrame;
        expect(frame.ok, isTrue);
        _expectSame(_wire(entry.value(frame.result)), raw['result'], entry.key);
      });
    }
  });

  group('REST bodies', () {
    for (final entry in _restParsers.entries) {
      test('${entry.key} round-trips', () {
        final raw = _load(entry.key);
        _expectSame(_wire(entry.value(raw)), raw, entry.key);
      });
    }
  });

  group('absent stays absent', () {
    test('a play without positionMs is re-emitted without it', () {
      final frame =
          ConnectFrame.fromJson(_load('cmd.play.radio.json')) as CmdFrame;
      final json = frame.toJson()['cmd'] as Map;
      expect(json.containsKey('positionMs'), isFalse);
      expect(json['radio'], isTrue);
    });

    test('an ok ack has no error key; a failed one has it', () {
      expect(const AckFrame.ok('a').toJson().containsKey('error'), isFalse);
      expect(
        const AckFrame.failed('a', AckError.nothingPlayable).toJson()['error'],
        'nothing_playable',
      );
    });

    test('a nullable field present as null stays present', () {
      final frame =
          ConnectFrame.fromJson(_load('state.idle.json')) as StateFrame;
      final json = frame.toJson()['state'] as Map;
      expect(json.containsKey('track'), isTrue);
      expect(json['track'], isNull);
      expect(json.containsKey('durationMs'), isTrue);
    });
  });

  group('the mobile hello this app sends', () {
    test('matches the fixture field for field', () {
      const hello = HelloFrame(
        token: 'eyJhbGciOiJIUzI1NiJ9.e30.sig',
        device: DeviceHello(
          id: '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b',
          kind: DeviceKind.mobile,
          name: "Bruno's Pixel",
          platform: 'android',
          appVersion: '1.0.0',
          caps: [ConnectCap.player, ConnectCap.yt, ConnectCap.local],
        ),
      );
      _expectSame(
        _wire(hello.toJson()),
        _load('hello.mobile.json'),
        'hello',
      );
    });

    test('v1.1 advertises lyrics and viz, as the fixture does', () {
      const hello = HelloFrame(
        token: 'eyJhbGciOiJIUzI1NiJ9.e30.sig',
        device: DeviceHello(
          id: '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b',
          kind: DeviceKind.mobile,
          name: "Bruno's Pixel",
          platform: 'android',
          appVersion: '1.1.0',
          caps: [
            ConnectCap.player,
            ConnectCap.yt,
            ConnectCap.local,
            ConnectCap.lyrics,
            ConnectCap.viz,
          ],
        ),
      );
      _expectSame(
        _wire(hello.toJson()),
        _load('hello.mobile.v11.json'),
        'hello v1.1',
      );
    });
  });

  group('v1.3 video', () {
    test('the cap is advertised and round-trips as the fixture does', () {
      final frame = ConnectFrame.fromJson(_load('hello.mobile.v13.json'))
          as HelloFrame;
      expect(frame.device.caps.last, ConnectCap.video);
      expect(ConnectCap.values.map((c) => c.name), contains('video'));
    });

    test('state.video is written only when true', () {
      final on = ConnectFrame.fromJson(_load('state.player.video.json'))
          as StateFrame;
      expect(on.state.video, isTrue);
      expect(on.toJson()['state'] as Map, containsPair('video', true));

      final off =
          ConnectFrame.fromJson(_load('state.player.json')) as StateFrame;
      expect(off.state.video, isFalse);
      expect((off.toJson()['state'] as Map).containsKey('video'), isFalse);
      // `video:false` from a sender is read as false, and not echoed.
      final raw = Map<String, Object?>.of(
          (_load('state.player.json') as Map<String, Object?>)['state']!
              as Map<String, Object?>)
        ..['video'] = false;
      expect(PlayerState.fromJson(raw).toJson().containsKey('video'), isFalse);
    });

    test('the video rpc is a known method', () {
      final frame =
          ConnectFrame.fromJson(_load('rpc.video.from.json')) as RpcFrame;
      expect(frame.knownMethod, RpcMethod.video);
    });

    test('found:false keeps its null fields on the wire', () {
      final raw = _load('rpc_result.video.none.json') as Map<String, Object?>;
      final json = VideoResult.fromJson(raw['result']).toJson();
      for (final key in ['url', 'mimeType', 'width', 'height', 'expiresAt']) {
        expect(json.containsKey(key), isTrue, reason: key);
        expect(json[key], isNull, reason: key);
      }
    });
  });

  group('tolerance', () {
    test('unknown caps are dropped, known ones kept', () {
      final hello = HelloFrame(
        token: 't',
        device: DeviceHello.fromJson({
          'id': 'i',
          'kind': 'mobile',
          'name': 'n',
          'platform': 'android',
          'appVersion': '1',
          'caps': ['player', 'hologram', 'viz', 42],
        }),
      );
      expect(hello.device.caps, [ConnectCap.player, ConnectCap.viz]);
    });

    test('an unknown frame type is carried, not rejected', () {
      final frame = ConnectFrame.fromJson({'t': 'telemetry', 'x': 1});
      expect(frame, isA<UnknownFrame>());
      expect(frame.t, 'telemetry');
    });

    test('an unknown command type becomes UnknownCommand', () {
      final frame = ConnectFrame.fromJson({
        't': 'cmd',
        'id': 'c-1',
        'from': 'w',
        'cmd': {'type': 'crossfade', 'seconds': 4},
      }) as CmdFrame;
      expect(frame.cmd, isA<UnknownCommand>());
      expect(frame.cmd.type, 'crossfade');
    });

    test('a known command with a mistyped field throws', () {
      expect(
        () => ConnectFrame.fromJson({
          't': 'cmd',
          'id': 'c-1',
          'cmd': {'type': 'seek', 'positionMs': 'soon'},
        }),
        throwsFormatException,
      );
    });

    test('a capability this version does not know is dropped', () {
      final device = DeviceInfo.fromJson({
        'id': 'd',
        'kind': 'desktop',
        'name': 'Mac',
        'platform': 'macos',
        'appVersion': '1',
        'caps': ['player', 'teleport'],
        'online': true,
        'lastSeenAt': '2026-10-12T18:20:00.000Z',
      });
      expect(device.caps, [ConnectCap.player]);
    });

    test('a whole number sent as a double reads as an int', () {
      final frame = ConnectFrame.fromJson({
        't': 'cmd',
        'id': 'c-9',
        'cmd': {'type': 'seek', 'positionMs': 90000.0},
      }) as CmdFrame;
      expect((frame.cmd as SeekCommand).positionMs, 90000);
    });
  });

  group('parseLinkCode', () {
    test('reads the QR form', () {
      expect(parseLinkCode('hypemuzik://link?c=483920'), '483920');
    });
    test('reads six typed digits, with or without spaces', () {
      expect(parseLinkCode('483920'), '483920');
      expect(parseLinkCode(' 483 920 '), '483920');
      expect(parseLinkCode('483-920'), '483920');
    });
    test('rejects anything else', () {
      expect(parseLinkCode('hypemuzik://pair?ep=x&pin=123456'), isNull);
      expect(parseLinkCode('hypemuzik://link?c=12345'), isNull);
      expect(parseLinkCode('https://example.com/?c=483920'), isNull);
      expect(parseLinkCode('48392a'), isNull);
      expect(parseLinkCode(''), isNull);
    });
  });
}
