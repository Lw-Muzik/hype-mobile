import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:on_audio_query/on_audio_query.dart';

import 'package:eq_app/services/connect/connect_executor.dart';
import 'package:eq_app/services/connect/connect_protocol.dart';
import 'package:eq_app/services/connect/connect_rpc.dart';
import 'package:eq_app/services/connect/connect_video.dart';
import 'package:eq_app/services/ytmusic/yt_models.dart';

const me = 'device-me';

SongModel song({int id = 7}) => SongModel({
      '_id': id,
      '_data': 'https://example/audio',
      'title': 'Hello',
      'artist': 'Adele',
      'album': '25',
      'duration': 295000,
      '_display_name': 'Hello',
      '_display_name_wo_ext': 'Hello',
      'hype_video_id': 'abc',
      'hype_is_video': true,
    });

// 2026-10-26T00:00:00Z
final now = DateTime.utc(2026, 10, 26);
final nowSec = now.millisecondsSinceEpoch ~/ 1000;

WebVideoRendition rendition({int? expiresAt, int height = 720}) =>
    WebVideoRendition(
      url: 'https://rr1---sn-test.googlevideo.com/videoplayback?expire=$expiresAt',
      mimeType: 'video/mp4; codecs="avc1.4d401f"',
      width: 1280,
      height: height,
      expiresAt: expiresAt,
    );

class FakeVideo implements ConnectVideoSource {
  bool shows = true;
  WebVideoRendition? web;
  Completer<WebVideoRendition?>? hang;
  Object? error;
  int calls = 0;

  @override
  bool showsPicture(SongModel? song) => shows;

  @override
  Future<WebVideoRendition?> renditionFor(SongModel song) {
    calls++;
    if (error != null) throw error!;
    return hang?.future ?? Future.value(web);
  }
}

class _NoCatalog implements ConnectCatalog {
  @override
  bool get available => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _NoLibrary implements ConnectLibrary {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

ConnectRpcHandler handler(
  FakeVideo? source,
  SongModel? Function() current, {
  Duration window = const Duration(seconds: 10),
}) =>
    ConnectRpcHandler(
      catalog: _NoCatalog(),
      library: _NoLibrary(),
      deviceId: me,
      video: source,
      currentSong: source == null ? null : current,
      videoWindow: window,
    );

RpcFrame ask([String id = 'r-1']) =>
    RpcFrame(id: id, from: 'web', method: 'video', params: const {});

Map<String, Object?> result(RpcResultFrame f) {
  expect(f.ok, isTrue);
  return jsonDecode(jsonEncode(f.result)) as Map<String, Object?>;
}

void main() {
  group('the video rpc', () {
    test('found:true carries the rendition, with expiresAt in ms', () async {
      await withClock(Clock.fixed(now), () async {
        final src = FakeVideo()
          ..web = rendition(expiresAt: nowSec + 6 * 3600);
        final r = result(await handler(src, () => song()).handle(ask()));
        expect(r['found'], isTrue);
        expect(r['url'], contains('googlevideo.com'));
        expect(r['mimeType'], 'video/mp4; codecs="avc1.4d401f"');
        expect(r['width'], 1280);
        expect(r['height'], 720);
        expect(r['expiresAt'], (nowSec + 6 * 3600) * 1000);
        expect((r['track']! as Map)['videoId'], 'abc');
      });
    });

    test('matches the contract fixture shape', () async {
      await withClock(Clock.fixed(now), () async {
        final fixture = jsonDecode(File(
                'test/fixtures/connect/rpc_result.video.json')
            .readAsStringSync()) as Map<String, Object?>;
        final expected = fixture['result']! as Map<String, Object?>;
        final src = FakeVideo()
          ..web = WebVideoRendition(
            url: expected['url']! as String,
            mimeType: expected['mimeType']! as String,
            width: 1280,
            height: 720,
            expiresAt: 1793062416,
          );
        final r = result(await handler(src, () => song()).handle(ask()));
        expect(r.keys.toSet(), expected.keys.toSet());
        expect(r['url'], expected['url']);
        expect(r['expiresAt'], expected['expiresAt']);
      });
    });

    test('not showing a picture: found:false, rendition never asked for',
        () async {
      final src = FakeVideo()
        ..shows = false
        ..web = rendition(expiresAt: nowSec + 9999);
      final r = result(await handler(src, () => song()).handle(ask()));
      expect(r['found'], isFalse);
      expect(r['url'], isNull);
      expect(r['expiresAt'], isNull);
      expect(r['track'], isNotNull);
      expect(src.calls, 0);
    });

    test('a stale URL is found:false', () async {
      await withClock(Clock.fixed(now), () async {
        final src = FakeVideo()..web = rendition(expiresAt: nowSec - 10);
        final r = result(await handler(src, () => song()).handle(ask()));
        expect(r['found'], isFalse);
        expect(r['url'], isNull);
      });
    });

    test('a URL inside the one-minute headroom counts as stale', () async {
      await withClock(Clock.fixed(now), () async {
        final src = FakeVideo()..web = rendition(expiresAt: nowSec + 30);
        final r = result(await handler(src, () => song()).handle(ask()));
        expect(r['found'], isFalse);
      });
    });

    test('a rendition with no stated expiry is not guessed at', () async {
      final src = FakeVideo()..web = rendition(expiresAt: null);
      final r = result(await handler(src, () => song()).handle(ask()));
      expect(r['found'], isFalse);
    });

    test('no rendition at all: found:false', () async {
      final r = result(await handler(FakeVideo(), () => song()).handle(ask()));
      expect(r['found'], isFalse);
    });

    test('nothing playing: track null, found:false', () async {
      final r = result(await handler(FakeVideo(), () => null).handle(ask()));
      expect(r['track'], isNull);
      expect(r['found'], isFalse);
    });

    test('a slow lookup answers found:false inside the window', () async {
      final src = FakeVideo()..hang = Completer();
      final r = result(await handler(src, () => song(),
              window: const Duration(milliseconds: 20))
          .handle(ask()));
      expect(r['found'], isFalse);
    });

    test('a failing lookup is found:false, not an error', () async {
      final src = FakeVideo()..error = StateError('boom');
      final reply = await handler(src, () => song()).handle(ask());
      expect(result(reply)['found'], isFalse);
    });

    test('without a source the rpc is unsupported', () async {
      final reply = await handler(null, () => song()).handle(ask());
      expect(reply.ok, isFalse);
      expect(reply.error, RpcError.unsupported);
    });
  });
}
