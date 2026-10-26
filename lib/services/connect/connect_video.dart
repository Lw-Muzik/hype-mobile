/// Answering the `video` rpc (contract v1.3).
///
/// While this phone shows a music video, a browser controller shows the same
/// picture, muted: the sound stays here. The browser plays a raw URL in a plain
/// `<video>` element, so it asks and the phone hands out the video-only H.264
/// rendition it kept when it resolved the video. Nothing is proxied: the URL
/// needs no headers (googlevideo serves it to a client with no User-Agent), and
/// the phone never touches the bytes.
///
/// # Answer, never block
///
/// The hub gives an rpc 15 s. After [videoAnswerWindow] the answer is
/// `found:false` now; the controller asks again later.
///
/// # Stale URLs
///
/// A rendition whose `expire=` has passed (or is within a minute of passing, or
/// was never stated, which is not guessed at) is `found:false`; the source may
/// first try to resolve the video again, inside the same window.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';

import 'package:eq_app/services/connect/connect_protocol.dart';
import 'package:eq_app/services/ytmusic/yt_models.dart';

/// How long a lookup may take before the answer is `found:false`.
const Duration videoAnswerWindow = Duration(seconds: 10);

/// Headroom before a URL's stated expiry, so a controller is not handed one
/// that dies while it connects.
const Duration videoExpiryHeadroom = Duration(seconds: 60);

/// The registry of videos, as the rpc handler reads it.
abstract interface class ConnectVideoSource {
  /// Whether the player is showing [song]'s picture right now.
  bool showsPicture(SongModel? song);

  /// The web rendition for [song] when [showsPicture] is true, else null. May
  /// resolve a stale video again; the caller stops waiting after a window.
  Future<WebVideoRendition?> renditionFor(SongModel song);
}

/// The wire form of [rendition] for [track]: `found:false` unless it is usable
/// and not stale at [now].
VideoResult videoResultOf(
  TrackRef? track,
  WebVideoRendition? rendition, {
  DateTime? now,
}) {
  if (rendition == null) return VideoResult.none(track);
  final expires = rendition.expiresAt;
  if (expires == null) return VideoResult.none(track);
  // The hub rejects anything else with `failed`; found:false is the answer.
  if (!rendition.url.startsWith('https://') ||
      rendition.url.length > 8192 ||
      rendition.mimeType.length > 200) {
    return VideoResult.none(track);
  }
  final expiresMs = expires * 1000;
  final deadline = (now ?? clock.now()).millisecondsSinceEpoch +
      videoExpiryHeadroom.inMilliseconds;
  if (expiresMs <= deadline) return VideoResult.none(track);
  return VideoResult(
    track: track,
    found: true,
    url: rendition.url,
    mimeType: rendition.mimeType,
    width: rendition.width,
    height: rendition.height,
    expiresAt: expiresMs,
  );
}

/// Looks up [song]'s picture and maps it, never waiting longer than [window].
Future<VideoResult> answerVideo({
  required TrackRef? track,
  required SongModel? song,
  required ConnectVideoSource source,
  Duration window = videoAnswerWindow,
}) async {
  if (song == null) return const VideoResult.none(null);
  try {
    if (!source.showsPicture(song)) return VideoResult.none(track);
    final rendition = await source.renditionFor(song).timeout(window);
    return videoResultOf(track, rendition);
  } on TimeoutException {
    return VideoResult.none(track);
  } catch (e) {
    debugPrint('Hype Connect: video lookup failed: $e');
    return VideoResult.none(track);
  }
}
