/// The cloud cache's downloader under the conditions it actually meets.
///
/// Playing one cloud track used to start several downloads at once — the
/// track, the next, the one after — and every `ready` event (a track change, a
/// seek, each rebuffer) asked again. The downloader kept ONE slot for "what is
/// downloading", so the second request overwrote it and the third, for a file
/// already in flight, opened a second writer on the same `.part` file. These
/// tests serve real bytes from a local server, so what they check is what a
/// phone would have on disk afterwards.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eq_app/services/cloud_cache_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bytes that make any reordering, duplication or truncation visible.
Uint8List _pattern(int seed, int length) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) (i * 31 + seed) & 0xff]);

/// A slow file server that honours `Range`, counts how many requests are open
/// at once, and remembers what was asked for.
class _Server {
  _Server._(this._http, this._bodies);

  final HttpServer _http;
  final Map<String, Uint8List> _bodies;

  int active = 0;
  int maxActive = 0;
  final ranges = <String?>[];
  Duration chunkDelay = const Duration(milliseconds: 12);

  /// Files to cut short: the server sends this many bytes (chunked, no stated
  /// length) and then closes the connection cleanly — what a flaky proxy or a
  /// load balancer's idle timeout looks like to a client.
  final cutAt = <String, int>{};

  static const _chunk = 16 * 1024;

  static Future<_Server> start(Map<String, Uint8List> bodies) async {
    final server = _Server._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      bodies,
    );
    server._http.listen(server._handle);
    return server;
  }

  String url(String name) => 'http://127.0.0.1:${_http.port}/$name';

  Future<void> _handle(HttpRequest request) async {
    active++;
    maxActive = math.max(maxActive, active);
    final name = request.uri.pathSegments.last;
    final body = _bodies[name]!;
    final end = cutAt[name] ?? body.length;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    ranges.add(range);
    var start = 0;
    if (range != null) {
      final m = RegExp(r'bytes=(\d+)-').firstMatch(range);
      if (m != null) start = int.parse(m.group(1)!);
    }
    try {
      request.response.statusCode = start > 0 ? 206 : 200;
      if (!cutAt.containsKey(name)) {
        request.response.contentLength = body.length - start;
      }
      if (start > 0) {
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${body.length - 1}/${body.length}',
        );
      }
      for (var o = start; o < end; o += _chunk) {
        request.response.add(body.sublist(o, math.min(o + _chunk, end)));
        await request.response.flush();
        await Future<void>.delayed(chunkDelay);
      }
      await request.response.close();
    } catch (_) {
      // The client hung up — a cancelled download.
    } finally {
      active--;
    }
  }

  Future<void> close() => _http.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding answers every HTTP request with a 400; these tests need a
  // real socket to a server they started themselves.
  setUpAll(() => HttpOverrides.global = null);

  const size = 320 * 1024;
  late _Server server;
  late Directory dir;
  late CloudCacheService cache;
  late Uint8List a;
  late Uint8List b;

  setUp(() async {
    a = _pattern(1, size);
    b = _pattern(2, size);
    server = await _Server.start({'a': a, 'b': b});
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('cloud_cache_test');
    cache = CloudCacheService(await SharedPreferences.getInstance());
    await cache.init(directory: dir);
  });

  tearDown(() async {
    await server.close();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('a track is cached byte for byte', () async {
    expect(await cache.preCacheTrack(server.url('a'), 'a', const {}), isTrue);
    expect(cache.isCached('a'), isTrue);
    expect(cache.cacheFile('a').readAsBytesSync(), a);
  });

  test('two tracks asked for at once use one connection, not two', () async {
    // What a track change does: the next track and the one after it.
    await Future.wait([
      cache.preCacheTrack(server.url('a'), 'a', const {}),
      cache.preCacheTrack(server.url('b'), 'b', const {}),
    ]);
    expect(server.maxActive, 1);
  });

  test('asking again for a track already downloading starts no second writer',
      () async {
    // The `ready` event fires again — a seek, a rebuffer — while the earlier
    // asks are still in flight. Nothing may open the same `.part` file twice.
    final first = cache.preCacheTrack(server.url('a'), 'a', const {});
    final other = cache.preCacheTrack(server.url('b'), 'b', const {});
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final again = cache.preCacheTrack(server.url('a'), 'a', const {});
    await Future.wait([first, other, again]);

    // What is on disk comes first: a duplicate writer is only worth a test if
    // it can damage the file.
    if (cache.isCached('a')) {
      expect(cache.cacheFile('a').readAsBytesSync(), a);
    }
    expect(server.maxActive, 1);
  });

  test('cancelling stops the download and the next ask resumes it intact',
      () async {
    final cancelled = cache.preCacheTrack(server.url('a'), 'a', const {});
    await Future<void>.delayed(const Duration(milliseconds: 70));
    cache.cancelActiveDownload();
    expect(await cancelled, isFalse);
    expect(cache.isCached('a'), isFalse);

    expect(await cache.preCacheTrack(server.url('a'), 'a', const {}), isTrue);
    expect(cache.cacheFile('a').readAsBytesSync(), a);
    // The second ask continued from the bytes already on disk.
    expect(server.ranges.whereType<String>(), isNotEmpty);
  });

  test('a response that ends early is not filed as the whole song', () async {
    // The connection closes cleanly after 100 KB of a 320 KB file. Nothing
    // errors, so "the stream ended" used to mean "the file is complete" — and
    // a half-song went into the cache to be played from disk ever after.
    server.cutAt['a'] = 100 * 1024;
    final ok = await cache.preCacheTrack(
      server.url('a'),
      'a',
      const {},
      expectedBytes: size,
    );
    expect(ok, isFalse);
    expect(cache.isCached('a'), isFalse);
    // What did arrive is kept, to resume from.
    expect(cache.partialSize('a'), 100 * 1024);

    server.cutAt.clear();
    expect(
      await cache.preCacheTrack(
        server.url('a'),
        'a',
        const {},
        expectedBytes: size,
      ),
      isTrue,
    );
    expect(cache.cacheFile('a').readAsBytesSync(), a);
  });

  group('which links belong in the cloud cache', () {
    test('drive files do', () {
      expect(
        isCloudCacheable('https://www.googleapis.com/drive/v3/files/x?alt=media'),
        isTrue,
      );
      expect(
        isCloudCacheable('https://uc1.dl.dropboxusercontent.com/cd/0/get/abc'),
        isTrue,
      );
    });

    test('YouTube streams, Discover streams and local files do not', () {
      expect(
        isCloudCacheable(
          'https://rr1---sn-abc.googlevideo.com/videoplayback?expire=1&itag=140',
        ),
        isFalse,
      );
      expect(isCloudCacheable('https://nowviba.com/stream/1'), isFalse);
      expect(isCloudCacheable('/storage/emulated/0/Music/a.mp3'), isFalse);
    });
  });
}
