/// The InnerTube calls behind Discover.
///
/// Five endpoints, no authentication of any kind. That is a deliberate
/// difference from hype-desktop, which browses with a captured cookie jar:
/// measured live against every surface this app uses, YouTube answers all of
/// them signed out — 38 mood categories, five shelves on a genre page, twenty
/// rows per search filter, a playlist's tracks, and a plaintext audio URL. So
/// mobile has no sign-in wall, nothing to expire, and nothing to keep secret.
///
/// # The client identities, and why there are four
///
/// * **WEB_REMIX** — browse, search, suggestions and radio. It is the client YT
///   Music's own web app presents, so its responses are the shapes the parsers
///   in `parse/` were written against.
/// * **VISIONOS** — stream resolution, and since 2026-08-20 the client that
///   leads for both audio and video. Its URLs are *plaintext* (no signature
///   cipher, no n-parameter JS) **and un-gated**: they serve a whole file to
///   one open-ended request. See [visionOsVersion].
/// * **ANDROID_VR** — what VISIONOS replaced, kept one step behind it. It led
///   this list until YouTube closed both sides of its 1.64 wall on the same
///   day: bot-checked below that version, proof-of-origin gated at and above
///   it. Every version in [androidVrVersions] is below the wall, so it now
///   fails *loudly* rather than resolving into silence — which is the only
///   reason it is still worth asking at all. See [androidVrVersions].
/// * **IOS** — video only, and only where AVPlayer leaves no choice: it is the
///   one client that ever offers an `hlsManifestUrl`. It is **not** an audio
///   fallback; see `YtWorker.audioClientOrder` for the measurement that took it
///   out of that list.
///
/// # `visitorData` is what makes a refused client worth asking twice
///
/// Measured live, ANDROID_VR answered `LOGIN_REQUIRED` — *"Sign in to confirm
/// you're not a bot"* — for six of seven videos. The obvious reading is that the
/// client is burned. It isn't: **the same request with a `visitorData` attached
/// answers `OK` and hands back a plaintext itag 140 url**, even on the older
/// client version. The refusal response itself carries a usable `visitorData` in
/// its `responseContext`, so one is always obtainable — [_visitorData] captures
/// it from every response and [player] asks again after learning one.
///
/// A token also *stops* being accepted, and that case is the one that bites: a
/// held token used to suppress the retry entirely, so one refusal turned into a
/// session that never resolved anything again. [player] now drops a token that
/// has been refused and earns a new one. See its doc comment.
///
/// # Why the order matters more than it looks
///
/// IOS urls are **PO-token prefix-gated: only the first ~1 MiB is ever served**,
/// whatever the Range. That is roughly 64 seconds of itag 140, after which every
/// request 403s — including the sequentially-next chunk. It is invisible to any
/// test that reads a small prefix, which is exactly how it survived a whole
/// round of "verified live" probes here. ANDROID_VR joined it behind that wall
/// on 2026-08-18 and lost its other side on 08-20; VISIONOS urls have no such
/// wall, which is the entire reason it leads.
///
/// # What rots
///
/// The client identities below are the thing that ages, and they age *fast*:
/// ANDROID_VR went from load-bearing to unusable in two days. When resolution
/// starts failing across the board, re-measure before suspecting anything
/// cleverer — a dead identity looks identical to a policy change.
///
/// Two rules, both learned the expensive way:
///
/// 1. **Only an open-ended `Range: bytes=0-` read past 1 MiB proves anything.**
///    A gated url answers every bounded range inside its first mebibyte, so a
///    64 KB probe reports health on a url that plays nothing. That trap has
///    cost this project three separate days.
/// 2. **Copy yt-dlp's `_DEFAULT_CLIENTS`, not its client table.** The table
///    still lists identities upstream keeps for authenticated or PO-token
///    users; on 2026-08-18 its `android_vr` pin was on the *wrong* side of the
///    wall, so following it was worse than following nothing.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// How long any one InnerTube call may take before it is abandoned.
///
/// Generous enough for a slow mobile connection, short enough that a dead
/// network surfaces as an error the user can retry rather than a spinner that
/// never resolves.
const _timeout = Duration(seconds: 20);

const _musicBase = 'https://music.youtube.com/youtubei/v1';
const _playerBase = 'https://youtubei.googleapis.com/youtubei/v1';

const _webRemixVersion = '1.20240403.01.00';
const _webRemixUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

// ---------------------------------------------------------------------------
// THE THING THAT ROTS — the ANDROID_VR identities the `player` call presents.

/// The ANDROID_VR client versions worth asking, in the order they are asked.
///
/// Measured 2026-08-18 on one session, one minute, one video, itag 140:
///
/// | clientVersion    | playabilityStatus | `Range: bytes=0-` |
/// |------------------|-------------------|-------------------|
/// | 1.62.20          | OK                | 206               |
/// | 1.63.24 / 1.63.29| LOGIN_REQUIRED    | —                 |
/// | 1.64.16 … 1.68.24| **OK**            | **403**           |
///
/// There is a wall on each side. **From 1.64 every url is proof-of-origin
/// gated**: it resolves `OK`, it serves a bounded slice, and it 403s the single
/// open-ended GET a player opens with — so the track resolves perfectly and
/// plays nothing, which is indistinguishable from a good resolve until
/// ExoPlayer says otherwise. That is what shipped as "every search result skips
/// straight to the next one": the app pinned 1.65.10.
///
/// Below 1.64 the urls are un-gated but the client is bot-checked, and *which*
/// version is refused moves — on one session 1.62.20 answered OK while 1.61.48
/// was refused. So no single version is dependable and they are asked in turn:
/// a different version is a genuinely different request, where asking the
/// refused one again is not. It costs one request to find out.
///
/// **Every version here has been measured serving an open-ended GET**, which is
/// the only probe that means anything: a gated url serves bounded ranges inside
/// its first mebibyte quite happily. Never add one without that measurement,
/// and never add one at or above 1.64 — it will resolve beautifully and play
/// silence. `test/ytmusic/yt_client_choice_test.dart` enforces the boundary;
/// `test/ytmusic/yt_resolve_live_test.dart` is the measurement.
const androidVrVersions = ['1.62.20', '1.63.24', '1.61.48', '1.60.19'];

// ---------------------------------------------------------------------------
// THE CLIENT THAT REPLACED IT — VISIONOS.

/// Measured 2026-08-20, when *both* ANDROID_VR walls closed at once and every
/// track began answering "Sign in to confirm you're not a bot":
///
/// | client                | playabilityStatus | `Range: bytes=0-` |
/// |-----------------------|-------------------|-------------------|
/// | ANDROID_VR <  1.64    | **LOGIN_REQUIRED**| —                 |
/// | ANDROID_VR >= 1.64    | OK                | **403**           |
/// | IOS / ANDROID         | OK                | **403**           |
/// | TVHTML5 / *_MUSIC     | **LOGIN_REQUIRED**| —                 |
/// | **VISIONOS**          | **OK**            | **206, whole file**|
///
/// Below 1.64 ANDROID_VR is now bot-checked wholesale rather than
/// occasionally, so the version rotation this file was built around has
/// nothing left to rotate *to*: every identity in [androidVrVersions] is
/// refused, and the four the app walks are what the user sees as four errors
/// and a skip. At and above 1.64 the url is proof-of-origin gated — the gate
/// is on the **byte offset**, exactly 1048576: `bytes=0-1048575` serves and
/// `bytes=1048576-` is 403, which is YouTube's PO-token "cold start"
/// allowance and not something a proxy or a smaller range can walk around.
///
/// VISIONOS is the one client left answering `OK` with a **plaintext** itag
/// 140 — no `signatureCipher`, no n-param JS to solve — whose url serves a
/// whole file to one open-ended GET. Verified 5/5 on fresh search results,
/// and corroborated upstream: yt-dlp 2026.08.19 moved its own defaults to
/// `('visionos', 'web')` and marked `android_vr` as PO-token-required.
///
/// There is no version list here on purpose. VISIONOS is a single published
/// identity rather than an app with a rolling version, so the second axis when
/// it is refused is the `visitorData` — see [_askPresenting].
const visionOsVersion = '1.02';

const _visionOsUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/26.0 Safari/605.1.15';

String _androidVrUserAgent(String version) =>
    'com.google.android.apps.youtube.vr.oculus/$version '
    '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';
// ---------------------------------------------------------------------------

const _iosVersion = '20.10.4';
const _iosUserAgent =
    'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X; en_US)';

/// Which client identity a `player` call presents. See this file's header for
/// why there is more than one, and [visionOsVersion] for why VISIONOS leads.
enum YtPlayerClient { ios, androidVr, visionOs }

/// Raised when a call could not be completed. Carries a message fit to show.
class YtNetworkException implements Exception {
  final String message;
  const YtNetworkException(this.message);
  @override
  String toString() => message;
}

/// A thin InnerTube client.
///
/// Owns its [HttpClient] so that connections — and their TLS handshakes — are
/// pooled across calls. That is why this is a long-lived object living in the
/// worker isolate rather than something constructed per request: a fresh client
/// per tap would pay a full handshake every time.
class YtInnerTube {
  final HttpClient _http;

  YtInnerTube() : _http = HttpClient() {
    _http.connectionTimeout = const Duration(seconds: 10);
    // A small pool: Discover issues one call per interaction, and holding more
    // sockets open than that costs a phone radio for nothing.
    _http.maxConnectionsPerHost = 4;
    _http.autoUncompress = true;
    // The single most valuable line in this file. Measured on one connection:
    //
    //   cold  (TLS handshake) → 0.74 s
    //   reused                → 0.14 s
    //
    // The request itself is ~140 ms; everything else is the handshake. Dart's
    // default idle timeout is **15 seconds**, which is shorter than the time it
    // takes to read a shelf and decide what to tap — so without this, nearly
    // every play would pay a fresh handshake and feel like a five-times-slower
    // app than it is.
    _http.idleTimeout = const Duration(seconds: 90);
  }

  void close() => _http.close(force: true);

  /// A `browse` call — categories, category pages, artists, playlists, albums.
  Future<Map<String, dynamic>> browse({
    String? browseId,
    String? params,
    String? continuation,
  }) {
    // A continuation is addressed by query string, not by body: the body form
    // answers 200 with an empty section list, which reads as "this playlist
    // ended" and silently truncates it.
    final query = continuation == null
        ? ''
        : '&ctoken=${Uri.encodeQueryComponent(continuation)}'
              '&continuation=${Uri.encodeQueryComponent(continuation)}&type=next';
    return _post('$_musicBase/browse?prettyPrint=false$query', {
      'context': _webRemixContext,
      'browseId': ?browseId,
      'params': ?params,
    }, headers: _webRemixHeaders);
  }

  /// A `search` call. [params] is YouTube's opaque filter token, or null for
  /// the unfiltered mix of shelves.
  Future<Map<String, dynamic>> search(String query, {String? params}) => _post(
    '$_musicBase/search?prettyPrint=false',
    {'context': _webRemixContext, 'query': query, 'params': ?params},
    headers: _webRemixHeaders,
  );

  /// Type-ahead completions.
  Future<Map<String, dynamic>> suggestions(String query) => _post(
    '$_musicBase/music/get_search_suggestions?prettyPrint=false',
    {'context': _webRemixContext, 'input': query},
    headers: _webRemixHeaders,
  );

  /// A `next` call — the endless "up next" YT Music derives from one song.
  ///
  /// The playlist id is `RDAMVM<videoId>` with the **raw** id and no `VL`
  /// prefix: `next` is the opposite of `browse` on this, and prefixing it here
  /// is an empty panel rather than an error.
  Future<Map<String, dynamic>> next(String videoId, {String? continuation}) =>
      _post('$_musicBase/next?prettyPrint=false', {
        'context': _webRemixContext,
        'videoId': videoId,
        'playlistId': 'RDAMVM$videoId',
        'isAudioOnly': true,
        'continuation': ?continuation,
      }, headers: _webRemixHeaders);

  /// A later page of the station, addressed the way [browse] addresses one.
  ///
  /// The token goes in the **query string**, not the body. That is the same
  /// lesson `browse` above carries: the body form answers 200 with an empty
  /// panel, which reads as "the station ended" and quietly stops an endless
  /// queue at its first page.
  ///
  /// The body still carries the seed, because the wire format re-posts the full
  /// request rather than the token alone.
  Future<Map<String, dynamic>> nextContinuation(
    String videoId,
    String continuation,
  ) => _post(
    '$_musicBase/next?prettyPrint=false'
    '&ctoken=${Uri.encodeQueryComponent(continuation)}'
    '&continuation=${Uri.encodeQueryComponent(continuation)}&type=next',
    {
      'context': _webRemixContext,
      'videoId': videoId,
      'playlistId': 'RDAMVM$videoId',
      'isAudioOnly': true,
    },
    headers: _webRemixHeaders,
  );

  /// The `player` call that resolves a video id to streams.
  ///
  /// A refusal is answered by changing something and asking again, because that
  /// is the whole of what separates "ANDROID_VR is bot-gated" from "ANDROID_VR
  /// works" — see this file's header. There are two things worth changing, and
  /// this walks both:
  ///
  /// * the **session**, since a `visitorData` YouTube has stopped accepting is
  ///   precisely the one that needs replacing — holding it used to make a
  ///   refusal permanent for the life of the app;
  /// * the **client version**, since which of them is bot-checked moves from
  ///   session to session (see [androidVrVersions]).
  ///
  /// Each identity is asked at most twice, so a resolve that is refused
  /// everywhere costs `2 * androidVrVersions.length` requests and then stops.
  /// The last refusal is returned rather than thrown: the caller turns it into
  /// something the user can read.
  Future<Map<String, dynamic>> player(
    String videoId, {
    YtPlayerClient client = YtPlayerClient.androidVr,
  }) async {
    if (client != YtPlayerClient.androidVr) {
      return _askPresenting(videoId, client, null);
    }

    late Map<String, dynamic> response;
    for (final version in androidVrVersions) {
      response = await _askPresenting(videoId, client, version);
      if (!_refused(response)) return response;
    }
    return response;
  }

  /// One identity, asked with the token held and — if refused — once more with
  /// a genuinely different one.
  ///
  /// A refusal always carries a `visitorData` in its `responseContext`, which
  /// [_post] harvests. So the second ask is either "the same identity, on the
  /// session that refusal just minted" or, when nothing new came back, a cold
  /// one — which is the only remaining way to make the request differ, and
  /// mints a fresh session out of its own refusal for whoever asks next.
  Future<Map<String, dynamic>> _askPresenting(
    String videoId,
    YtPlayerClient client,
    String? version,
  ) async {
    final presented = _visitorData;
    final response = await playerOnce(videoId, client, version: version);
    if (!_refused(response)) return response;

    final learned = _visitorData;
    if (learned != null && learned != presented) {
      return playerOnce(videoId, client, version: version);
    }
    if (presented == null) return response;

    _visitorData = null;
    return playerOnce(videoId, client, version: version);
  }

  static bool _refused(Map<String, dynamic> response) {
    final status = response['playabilityStatus'];
    return status is Map && status['status'] != 'OK';
  }

  /// One `player` request, exactly as presented to YouTube.
  ///
  /// Separated from [player] so the retry sequence above can be tested without
  /// a network: the interesting behaviour is *which* visitorData each attempt
  /// presents, which is invisible from outside a single call.
  @visibleForTesting
  Future<Map<String, dynamic>> playerOnce(
    String videoId,
    YtPlayerClient client, {
    String? version,
  }) {
    final vrVersion = version ?? androidVrVersions.first;
    final identity = clientIdentity(client, version: vrVersion);
    final visitor = _visitorData;
    return _post(
      '$_playerBase/player?prettyPrint=false',
      {
        'context': {
          'client': {...identity, 'visitorData': ?visitor},
        },
        'videoId': videoId,
        'contentCheckOk': true,
        'racyCheckOk': true,
      },
      headers: {
        ...switch (client) {
          YtPlayerClient.ios => const {'User-Agent': _iosUserAgent},
          YtPlayerClient.visionOs => const {'User-Agent': _visionOsUserAgent},
          YtPlayerClient.androidVr => {
            'User-Agent': _androidVrUserAgent(vrVersion),
          },
        },
        'X-YouTube-Client-Name': switch (client) {
          YtPlayerClient.ios => '5',
          YtPlayerClient.visionOs => '101',
          YtPlayerClient.androidVr => '28',
        },
        'X-YouTube-Client-Version': switch (client) {
          YtPlayerClient.ios => _iosVersion,
          YtPlayerClient.visionOs => visionOsVersion,
          YtPlayerClient.androidVr => vrVersion,
        },
        'X-Goog-Visitor-Id': ?visitor,
      },
    );
  }

  /// The visitor id YouTube has issued this session.
  ///
  /// Captured from *any* response — browse, search and refusals all carry one in
  /// `responseContext`. Held for the life of the worker isolate; nothing about
  /// it is worth persisting, since one is always obtainable from the next call.
  String? _visitorData;

  /// Exposed for the live tests, which assert one is actually being learned.
  String? get visitorData => _visitorData;

  /// Only for tests standing in for [_post]'s harvest of `responseContext`.
  @visibleForTesting
  set visitorData(String? value) => _visitorData = value;

  /// Forgets the session, so the next call mints a new one.
  ///
  /// The token is not merely an identifier: YouTube decides **when it is
  /// minted** whether that session's stream urls will require a proof-of-origin
  /// token, and about four sessions in ten currently get one that does. Those
  /// urls resolve with `playabilityStatus: OK` and then refuse to serve a byte,
  /// so nothing before playback can tell the difference.
  ///
  /// Since the verdict belongs to the session and this object outlives the app's
  /// whole listening, a bad draw is otherwise permanent: every track fails, and
  /// asking again on the same token only produces another url that will not
  /// play. Drawing again is the only move — see [YtOp.resetSession].
  void resetSession() => _visitorData = null;

  /// The headers a URL resolved by [client] should be fetched with.
  ///
  /// googlevideo has been observed serving these targets to a bare request as
  /// well, but it checks the User-Agent against the resolving client when it
  /// chooses to — so sending them costs nothing and removes a way to 403.
  static Map<String, String> playbackHeaders(YtPlayerClient client) =>
      switch (client) {
        YtPlayerClient.ios => const {'User-Agent': _iosUserAgent},
        YtPlayerClient.visionOs => const {'User-Agent': _visionOsUserAgent},
        YtPlayerClient.androidVr => {
          'User-Agent': _androidVrUserAgent(androidVrVersions.first),
        },
      };

  /// Playback headers for a URL whose resolving client isn't known.
  ///
  /// The audio player receives tracks as plain URLs — the queue model has no
  /// room for the client that produced each one — so it needs one answer.
  /// [YtPlayerClient.ios] is that answer because it resolves nearly everything
  /// (see this file's header), and because googlevideo has been measured
  /// serving these targets to a request with no User-Agent at all: the header
  /// removes a way to fail rather than being the thing that makes it work.
  static const audioPlaybackHeaders = {'User-Agent': _iosUserAgent};

  /// Whether a URL is one this layer resolved off YouTube's CDN.
  ///
  /// The player uses it to decide that a URL must be streamed directly, with
  /// [audioPlaybackHeaders] and no caching: these targets are single-use, state
  /// their own expiry, and 403 without the User-Agent that resolved them.
  static bool isStreamUrl(String url) => url.contains('googlevideo.com');

  // -------------------------------------------------------------------------

  static const _webRemixContext = {
    'client': {
      'clientName': 'WEB_REMIX',
      'clientVersion': _webRemixVersion,
      'hl': 'en',
      'gl': 'US',
    },
  };

  static const _webRemixHeaders = {
    'User-Agent': _webRemixUserAgent,
    'Origin': 'https://music.youtube.com',
    'X-YouTube-Client-Name': '67',
    'X-YouTube-Client-Version': _webRemixVersion,
  };

  static Map<String, dynamic> _androidVrClient(String version) => {
    'clientName': 'ANDROID_VR',
    'clientVersion': version,
    'androidSdkVersion': 32,
    'userAgent': _androidVrUserAgent(version),
    'deviceMake': 'Oculus',
    'deviceModel': 'Quest 3',
    'osName': 'Android',
    'osVersion': '12L',
    'hl': 'en',
    'gl': 'US',
  };

  /// The VISIONOS identity, field for field as measured. `deviceModel` and
  /// `osName` are not decoration: an identity YouTube cannot place is answered
  /// exactly like a bot, which is the failure this client exists to avoid.
  static const _visionOsClient = {
    'clientName': 'VISIONOS',
    'clientVersion': visionOsVersion,
    'deviceMake': 'Apple',
    'deviceModel': 'RealityDevice17,1',
    'userAgent': _visionOsUserAgent,
    'osName': 'visionOS',
    'osVersion': '26.5.23O471',
    'hl': 'en',
    'gl': 'US',
  };

  /// The identity [playerOnce] would present, so a test can assert on the
  /// exact wire shape without a network.
  @visibleForTesting
  static Map<String, dynamic> clientIdentity(
    YtPlayerClient client, {
    String? version,
  }) => switch (client) {
    YtPlayerClient.ios => _iosClient,
    YtPlayerClient.visionOs => _visionOsClient,
    YtPlayerClient.androidVr => _androidVrClient(
      version ?? androidVrVersions.first,
    ),
  };

  static const _iosClient = {
    'clientName': 'IOS',
    'clientVersion': _iosVersion,
    'deviceMake': 'Apple',
    'deviceModel': 'iPhone16,2',
    'osName': 'iPhone',
    'osVersion': '18.3.2.22D82',
    'hl': 'en',
    'gl': 'US',
    'utcOffsetMinutes': 0,
  };

  Future<Map<String, dynamic>> _post(
    String url,
    Map<String, dynamic> body, {
    required Map<String, String> headers,
  }) async {
    try {
      final request = await _http
          .postUrl(Uri.parse(url))
          .timeout(
            _timeout,
            onTimeout: () => throw const YtNetworkException(
              'YouTube took too long to answer.',
            ),
          );
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
      headers.forEach(request.headers.set);
      request.add(utf8.encode(jsonEncode(body)));

      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200) {
        // Drain so the connection returns to the pool instead of being torn
        // down and re-handshaked on the next call.
        await response.drain<void>();
        throw YtNetworkException('YouTube answered ${response.statusCode}.');
      }
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_timeout);
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return <String, dynamic>{};
      final visitor = decoded['responseContext'];
      if (visitor is Map && visitor['visitorData'] is String) {
        _visitorData = visitor['visitorData'] as String;
      }
      return decoded;
    } on YtNetworkException {
      rethrow;
    } on SocketException {
      throw const YtNetworkException('No connection to YouTube.');
    } on FormatException {
      // A body that isn't JSON is a shape problem, not an outage — and the
      // parsers downstream would read it as "nothing found" anyway.
      throw const YtNetworkException("YouTube's answer couldn't be read.");
    } catch (e) {
      throw YtNetworkException('Could not reach YouTube: $e');
    }
  }
}
