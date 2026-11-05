/// Fetching a YouTube stream to a file, fast.
///
/// googlevideo throttles one plain GET of a stream to about twice its bitrate
/// — ~31 KB/s for itag 140, a minute and a half for a song (measured Oct
/// 2026) — but serves 256 KB range requests at full speed: a whole song in a
/// few seconds over a few connections. Smaller ranges trip the throttle on
/// some requests, and even at this size one in a few dozen stalls, so a range
/// taking far longer than the others is dropped and asked for again on a fresh
/// connection — "far longer" measured against the ranges so far, so a slow
/// network is not mistaken for a throttled request, and the last try has no
/// time limit at all (only a long silence ends it). A server that answers a
/// range with the whole file (200) is simply streamed.
///
/// Ranges are written into the file as they arrive, so memory stays at a few
/// ranges however long the track is (a DJ mix is an hour).
///
/// Used by the Download button ([YtDownloader]) and for the copies live stems
/// separate ([StemsStreamCache]).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// The fetch was stopped through its `cancel` future.
class YtStreamFetchCancelled implements Exception {
  const YtStreamFetchCancelled();

  @override
  String toString() => 'YtStreamFetchCancelled';
}

/// The server refused the stream — an expired or proof-gated URL. Asking the
/// same URL again won't help; resolving a fresh one might.
class YtStreamRefused extends HttpException {
  const YtStreamRefused(super.message, {this.statusCode, super.uri});

  /// The HTTP status, when there was one.
  final int? statusCode;
}

class YtStreamFetch {
  const YtStreamFetch({
    this.chunkBytes = 256 * 1024,
    this.parallel = 3,
    this.chunkTimeout = const Duration(seconds: 3),
    this.chunkAttempts = 4,
    this.httpClient,
  });

  /// Bytes per range request.
  final int chunkBytes;

  /// Range requests in flight at once.
  final int parallel;

  /// The least a range may take before it counts as throttled; the bar is
  /// four times the median range so far when that is longer. A throttled
  /// range is dropped and asked for again, up to [chunkAttempts] times, the
  /// last without a time limit. The same bar applies to connecting and to a
  /// response's headers.
  final Duration chunkTimeout;
  final int chunkAttempts;

  /// A response sending nothing for this long is dead, whatever the attempt.
  static const silence = Duration(seconds: 20);

  /// Makes the HTTP clients (one per connection); `HttpClient.new` if null.
  final HttpClient Function()? httpClient;

  /// Writes the stream at [uri] to [file], creating or truncating it.
  ///
  /// [onProgress] gets a 0–1 fraction. Throws [YtStreamFetchCancelled] once
  /// [cancel] completes, [YtStreamRefused] when the server says no, and an
  /// [IOException] or [TimeoutException] when the network gives out. A
  /// failed or cancelled fetch can leave a partial [file]: write to a
  /// temporary name and rename on success.
  Future<void> toFile(
    Uri uri,
    File file, {
    Map<String, String> headers = const {},
    void Function(double fraction)? onProgress,
    Future<void>? cancel,
  }) async {
    final transfer = _Transfer(this, uri, headers, cancel);
    try {
      await transfer.run(file, onProgress);
    } catch (e) {
      // A transfer closed by the cancel shows up as a socket error.
      if (transfer.cancelled) throw const YtStreamFetchCancelled();
      rethrow;
    } finally {
      transfer.closeAll();
    }
  }
}

/// One download: the first range finds the size (or that the server ignores
/// ranges), then a few workers take the remaining ranges in turn.
class _Transfer {
  _Transfer(this.options, this.uri, this.headers, Future<void>? cancel) {
    cancel?.then((_) {
      cancelled = true;
      closeAll();
    });
  }

  final YtStreamFetch options;
  final Uri uri;
  final Map<String, String> headers;
  final Set<HttpClient> _clients = {};
  bool cancelled = false;
  bool _closed = false;

  /// How long the ranges that arrived took (ms), to tell a throttled request
  /// from a slow network.
  final List<int> _rangeMs = [];

  /// How long a range may take before it is asked for again: generous until
  /// a range has been timed, then four times the median (at least
  /// `chunkTimeout`).
  Duration _stallAfter() {
    final floor = options.chunkTimeout;
    if (_rangeMs.isEmpty) return floor * 3;
    final sorted = [..._rangeMs]..sort();
    final bar = Duration(milliseconds: sorted[sorted.length ~/ 2] * 4);
    return bar > floor ? bar : floor;
  }

  HttpClient _open() {
    _checkCancelled();
    final c = (options.httpClient ?? HttpClient.new)();
    _clients.add(c);
    return c;
  }

  void _drop(HttpClient c) {
    _clients.remove(c);
    c.close(force: true);
  }

  void closeAll() {
    _closed = true;
    for (final c in _clients.toList()) {
      c.close(force: true);
    }
    _clients.clear();
  }

  void _checkCancelled() {
    if (cancelled || _closed) throw const YtStreamFetchCancelled();
  }

  /// Runs [attempt] up to `chunkAttempts` times (`last` on the final one): a
  /// refusal or a cancel ends it at once, anything else (throttled, cut off,
  /// short) is asked again.
  Future<T> _retrying<T>(Future<T> Function(bool last) attempt) async {
    for (var n = 1; ; n++) {
      try {
        return await attempt(n >= options.chunkAttempts);
      } on YtStreamRefused {
        rethrow;
      } on YtStreamFetchCancelled {
        rethrow;
      } catch (_) {
        _checkCancelled();
        if (n >= options.chunkAttempts) rethrow;
      }
    }
  }

  Future<void> run(File file, void Function(double)? onProgress) async {
    final step = options.chunkBytes;
    // The size is usually in the URL (`clen`); the first range confirms it
    // either way, and tells a server that ignores ranges apart.
    final first = await _retrying(
      (last) => _firstRange(file, step, onProgress, last: last),
    );
    if (first == null) return; // streamed whole: the server ignored the range
    final (head, total) = first;

    final raf = await file.open(mode: FileMode.write);
    // One file, one operation at a time. Each writer awaits its own write and
    // sees its own error; the chain itself never fails, and once the transfer
    // is over (one range refused, say, while others are still arriving) late
    // ranges are not written at all — the file is about to be closed.
    var stopping = false;
    var writes = Future<void>.value();
    Future<void> write(int at, Uint8List bytes) {
      if (stopping) return Future<void>.value();
      final done = writes.then((_) async {
        await raf.setPosition(at);
        await raf.writeFrom(bytes);
      });
      writes = done.catchError((Object _) {});
      return done;
    }

    try {
      await write(0, head);
      var received = head.length;
      onProgress?.call((received / total).clamp(0.0, 1.0));

      final count = (total + step - 1) ~/ step;
      var nextIndex = 1;
      Future<void> worker() async {
        var client = _open();
        try {
          while (true) {
            _checkCancelled();
            final i = nextIndex++;
            if (i >= count) return;
            final start = i * step;
            final end = (start + step < total ? start + step : total) - 1;
            final bytes = await _retrying((last) async {
              try {
                return await _range(client, start, end, last: last);
              } on YtStreamRefused {
                rethrow;
              } catch (_) {
                // A fresh connection for the next try.
                _drop(client);
                client = _open();
                rethrow;
              }
            });
            await write(start, bytes);
            received += bytes.length;
            onProgress?.call((received / total).clamp(0.0, 1.0));
          }
        } finally {
          _drop(client);
        }
      }

      final workers = options.parallel < count - 1
          ? options.parallel
          : count - 1;
      await Future.wait([
        for (var w = 0; w < workers; w++) worker(),
      ], eagerError: true);
      await writes;
      await raf.flush();
    } catch (_) {
      closeAll(); // stop the workers still fetching
      rethrow;
    } finally {
      stopping = true;
      await writes; // a write in flight finishes before the file closes
      await raf.close();
    }
    if (cancelled) throw const YtStreamFetchCancelled();
  }

  /// The first [step] bytes and the stream's total size, or null after
  /// streaming the whole file because the server answered 200 to a range.
  Future<(Uint8List, int)?> _firstRange(
    File file,
    int step,
    void Function(double)? onProgress, {
    required bool last,
  }) async {
    final client = _open();
    try {
      final clen = int.tryParse(uri.queryParameters['clen'] ?? '');
      final end = (clen != null && clen > 0 && clen < step ? clen : step) - 1;
      final watch = Stopwatch()..start();
      final response = await _get(client, 'bytes=0-$end', last: last);
      if (response.statusCode == HttpStatus.ok) {
        await _streamWhole(response, file, onProgress);
        return null;
      }
      final total =
          _totalFromContentRange(response.headers.value('content-range')) ??
          clen;
      if (total == null || total <= 0) {
        await response.drain<void>().catchError((_) {});
        throw YtStreamRefused('no stream length', uri: uri);
      }
      final bytes = await _collect(response, last: last);
      if (bytes.length != end + 1 && bytes.length != total) {
        throw HttpException('short range', uri: uri);
      }
      _rangeMs.add(watch.elapsedMilliseconds);
      return (bytes, total);
    } finally {
      _drop(client);
    }
  }

  Future<Uint8List> _range(
    HttpClient client,
    int start,
    int end, {
    required bool last,
  }) async {
    final watch = Stopwatch()..start();
    final response = await _get(client, 'bytes=$start-$end', last: last);
    if (response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>().catchError((_) {});
      throw YtStreamRefused(
        'HTTP ${response.statusCode}',
        statusCode: response.statusCode,
        uri: uri,
      );
    }
    final bytes = await _collect(response, last: last);
    if (bytes.length != end - start + 1) {
      throw HttpException('short range', uri: uri);
    }
    _rangeMs.add(watch.elapsedMilliseconds);
    return bytes;
  }

  /// Sends a GET for [range]; anything but 200 or 206 is a refusal.
  Future<HttpClientResponse> _get(
    HttpClient client,
    String range, {
    required bool last,
  }) async {
    _checkCancelled();
    final wait = last ? YtStreamFetch.silence : _stallAfter();
    final request = await client.getUrl(uri).timeout(wait);
    headers.forEach(request.headers.set);
    request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close().timeout(wait);
    final code = response.statusCode;
    if (code != HttpStatus.ok && code != HttpStatus.partialContent) {
      await response.drain<void>().catchError((_) {});
      throw YtStreamRefused('HTTP $code', statusCode: code, uri: uri);
    }
    return response;
  }

  /// The body of a range: within [_stallAfter], or on the last try with no
  /// limit but [YtStreamFetch.silence] between bytes.
  Future<Uint8List> _collect(
    HttpClientResponse response, {
    required bool last,
  }) async {
    final builder = BytesBuilder(copy: false);
    final body = response.timeout(YtStreamFetch.silence).forEach((chunk) {
      _checkCancelled();
      builder.add(chunk);
    });
    await (last ? body : body.timeout(_stallAfter()));
    return builder.takeBytes();
  }

  Future<void> _streamWhole(
    HttpClientResponse response,
    File file,
    void Function(double)? onProgress,
  ) async {
    final sink = file.openWrite();
    try {
      final total = response.contentLength;
      var received = 0;
      await for (final chunk in response) {
        _checkCancelled();
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call((received / total).clamp(0.0, 1.0));
      }
      await sink.flush();
      if (total > 0 && received != total) {
        throw HttpException('short read ($received of $total)', uri: uri);
      }
    } finally {
      await sink.close();
    }
  }

  /// `bytes 0-262143/3526797` → 3526797.
  static int? _totalFromContentRange(String? value) {
    if (value == null) return null;
    final slash = value.lastIndexOf('/');
    return slash < 0 ? null : int.tryParse(value.substring(slash + 1).trim());
  }
}
