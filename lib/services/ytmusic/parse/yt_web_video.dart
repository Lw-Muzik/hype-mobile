/// Choosing the rendition a browser can play on its own.
///
/// # Why this exists (Hype Connect v1.3)
///
/// While the phone plays a music video, the web remote shows the same picture,
/// muted, in a plain `<video src>`. A browser cannot read the DASH manifest this
/// app builds for ExoPlayer, and it cannot send headers, so it needs one URL to
/// one *video-only* file it can decode: H.264 in MP4. YouTube's adaptive
/// formats include exactly that (the same `avc1` renditions the manifest
/// lists); this picks one of them. googlevideo serves these URLs to a client
/// with no User-Agent, so no header has to travel with it.
///
/// Nothing here changes what the phone plays; it only remembers one more fact
/// about the response the phone already has.
library;

import '../yt_models.dart';
import 'yt_json.dart';

/// The tallest rendition the web remote is offered. A browser tile is small and
/// the phone is paying for the bytes only if someone is watching.
const int webVideoMaxHeight = 720;

/// Picks the best web-playable rendition from YouTube's `adaptiveFormats`.
///
/// * H.264 in MP4 (`video/mp4` + `avc1`) only: it is the one codec every
///   browser decodes. VP9/AV1 and the audio-only formats are ignored.
/// * A plain `url` is required; a format hidden behind a signature cipher
///   cannot be handed to a browser.
/// * The highest height not above [webVideoMaxHeight]; when every rendition is
///   taller than that, the lowest one available.
/// * Among equals the higher bitrate wins.
///
/// Null when [formats] is not a list or holds nothing usable.
WebVideoRendition? pickWebVideo(Object? formats) {
  if (formats is! List) return null;
  final candidates = <WebVideoRendition>[];
  final bitrates = <WebVideoRendition, int>{};
  for (final format in formats) {
    final mime = ptrString(format, 'mimeType') ?? '';
    if (!mime.startsWith('video/mp4') || !mime.contains('avc1')) continue;
    final url = ptrString(format, 'url');
    if (url == null) continue;
    final height = ptr(format, 'height');
    final width = ptr(format, 'width');
    if (height is! num || height <= 0) continue;
    final rendition = WebVideoRendition(
      url: url,
      mimeType: mime,
      width: width is num ? width.toInt() : null,
      height: height.toInt(),
      expiresAt: expireOfUrl(url),
    );
    final bitrate = ptr(format, 'bitrate');
    bitrates[rendition] = bitrate is num ? bitrate.toInt() : 0;
    candidates.add(rendition);
  }
  if (candidates.isEmpty) return null;

  int bitrateOf(WebVideoRendition r) => bitrates[r] ?? 0;
  final within = [
    for (final c in candidates)
      if (c.height <= webVideoMaxHeight) c,
  ];
  if (within.isNotEmpty) {
    within.sort((a, b) {
      final byHeight = b.height.compareTo(a.height);
      return byHeight != 0 ? byHeight : bitrateOf(b).compareTo(bitrateOf(a));
    });
    return within.first;
  }
  candidates.sort((a, b) {
    final byHeight = a.height.compareTo(b.height);
    return byHeight != 0 ? byHeight : bitrateOf(b).compareTo(bitrateOf(a));
  });
  return candidates.first;
}

/// Reads `expire=` (Unix seconds) out of a googlevideo URL; null when absent.
int? expireOfUrl(String url) {
  final match = RegExp(r'[?&/]expire[=/](\d+)').firstMatch(url);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}
