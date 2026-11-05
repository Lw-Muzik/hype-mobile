/// Small readers for YouTube's renderer JSON.
///
/// Shared by every parser in this folder. All of them return null rather than
/// throwing, and that is the whole point: the bug this port exists to avoid is
/// insisting on a shape and destroying an entire response when reality differs.
library;

import '../yt_models.dart';

/// Walks a decoded JSON tree by a `/a/b/0/c` path.
///
/// A JSON-pointer stand-in, because Dart has none and the Rust this is ported
/// from is written entirely in pointers. Any wrong turn — absent key, index off
/// the end, a scalar where an object was expected — is null, never a throw.
Object? ptr(Object? node, String path) {
  var current = node;
  for (final segment in path.split('/')) {
    if (segment.isEmpty) continue;
    if (current is Map) {
      current = current[segment];
    } else if (current is List) {
      final index = int.tryParse(segment);
      if (index == null || index < 0 || index >= current.length) return null;
      current = current[index];
    } else {
      return null;
    }
    if (current == null) return null;
  }
  return current;
}

/// [ptr] narrowed to a non-empty string.
String? ptrString(Object? node, String path) {
  final value = ptr(node, path);
  return value is String && value.isNotEmpty ? value : null;
}

/// [ptr] narrowed to a list.
List<Object?>? ptrList(Object? node, String path) {
  final value = ptr(node, path);
  return value is List ? value : null;
}

/// A renderer's `runs` array flattened to its text ("Album • A Pass • 2019").
///
/// Joined rather than indexed: YouTube varies the number of runs (a subtitle may
/// be `["Playlist", " • ", "12 songs"]` or a bare `["YouTube Music"]`), and
/// reading a fixed index is what made desktop's upstream report `"Made for "` as
/// a playlist's author.
String? joinRuns(Object? runs) {
  if (runs is! List) return null;
  final buffer = StringBuffer();
  for (final run in runs) {
    final text = ptr(run, 'text');
    if (text is String) buffer.write(text);
  }
  final trimmed = buffer.toString().trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// The largest thumbnail in a `thumbnails` array.
///
/// Largest rather than first because YouTube orders them smallest-first and the
/// small ones are unusably soft on a phone's pixel ratio. [thumbnailAt] shrinks
/// it back down at request time, which costs nothing and downloads far less.
String? bestThumbnail(Object? thumbs) {
  if (thumbs is! List) return null;
  String? best;
  var bestArea = -1;
  for (final thumb in thumbs) {
    final url = ptr(thumb, 'url');
    if (url is! String || url.isEmpty) continue;
    final width = ptr(thumb, 'width');
    final height = ptr(thumb, 'height');
    final area =
        (width is num ? width.toInt() : 0) *
        (height is num ? height.toInt() : 0);
    if (area > bestArea) {
      bestArea = area;
      best = url;
    }
  }
  return best;
}

/// The artists a byline credits, each with their channel where it links one.
///
/// [runs] is the artist part of a byline — `Burna Boy`, ` & `, `Ed Sheeran` —
/// as YouTube splits it: one run per artist, separators as runs of their own. A
/// run linking a channel (`UC…`) is an artist; so is any other run that isn't
/// a separator, because YouTube leaves some credits unlinked. A run linking
/// anything else (an album, a playlist) is not a credit.
List<YtArtistRef> artistRefs(Object? runs) {
  if (runs is! List) return const [];
  final out = <YtArtistRef>[];
  for (final run in runs) {
    final text = ptrString(run, 'text')?.trim();
    if (text == null || text.isEmpty || _creditSeparator.hasMatch(text)) {
      continue;
    }
    final id = ptrString(run, 'navigationEndpoint/browseEndpoint/browseId');
    if (id != null && !id.startsWith('UC')) continue;
    out.add(YtArtistRef(text, id: id));
  }
  return out;
}

final _creditSeparator = RegExp(
  r'^(,|&|•|x|×|and|feat\.?|ft\.?|with)$',
  caseSensitive: false,
);

/// Seconds from a `M:SS` or `H:MM:SS` running time.
///
/// Anything else is null — including a bare number, which is a year on an
/// album's byline and a view count everywhere else.
double? parseDuration(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  var seconds = 0;
  var parts = 0;
  for (final part in trimmed.split(':')) {
    final value = int.tryParse(part.trim());
    if (value == null || value < 0) return null;
    seconds = seconds * 60 + value;
    parts++;
    if (parts > 3) return null;
  }
  return parts >= 1 ? seconds.toDouble() : null;
}

/// The text of one flexible column of a list row.
String? flexText(Object? row, int column) => joinRuns(
  ptr(
    row,
    'flexColumns/$column/musicResponsiveListItemFlexColumnRenderer'
    '/text/runs',
  ),
);

/// Where a list row states what kind of video it is: hung off the play button
/// in its thumbnail overlay.
const videoTypePath =
    'overlay/musicItemThumbnailOverlayRenderer/content/musicPlayButtonRenderer'
    '/playNavigationEndpoint/watchEndpoint/watchEndpointMusicSupportedConfigs'
    '/watchEndpointMusicConfig/musicVideoType';

/// Whether a row belongs in a music app at all.
///
/// Podcasts and privately-owned uploads are listed by YouTube but are not what
/// this catalog is for.
bool isMusic(String? videoType) =>
    videoType != 'MUSIC_VIDEO_TYPE_PODCAST_EPISODE' &&
    videoType != 'MUSIC_VIDEO_TYPE_PRIVATELY_OWNED_TRACK';

/// Whether this row has footage, as opposed to a song rendered as a still.
///
/// `ATV` is YouTube's marker for an audio entity. It still has "video"
/// renditions, but they're a square 1080×1080 still at ~95 kbps — the cover art
/// again. Everything else that reaches here (OMV, UGC, …) is real video.
///
/// Null means the row didn't carry a type, which is *not* the same as being a
/// song — so it earns false (offer no watch action we might not be able to fill)
/// while [isMusic] independently answers true (keep the row). Two questions with
/// two different safe answers is why this takes a nullable string and not a
/// defaulted one: collapsing them behind one default is what hid a broken
/// pointer for an entire desktop release.
bool hasVideo(String? videoType) =>
    videoType != null && videoType != 'MUSIC_VIDEO_TYPE_ATV';

/// A playlist browse id, `VL`-prefixed.
///
/// Browse sends `browseId` verbatim; measured live on desktop, the bare `PL…`
/// form answers `HTTP 400 Request contains an invalid argument` while the same
/// id prefixed returns its rows. Every catalog surface measured sends the prefix
/// already, so this only ever adds what is missing — being idempotent is the
/// point, since prepending blindly would break the ids that were already right.
String playlistBrowseId(String id) => id.startsWith('VL') ? id : 'VL$id';

/// A YouTube image URL asked for at the size it will actually be drawn.
///
/// YouTube serves art through a resizing CDN whose dimensions are a suffix on
/// the path (`=w544-h544-l90-rj`) or query (`googleusercontent`-style hosts vary,
/// hence handling both). A 64 px tile that asks for the 544 px original
/// downloads roughly ten times what it can display, which on a shelf of fifty
/// tiles is the difference between a smooth scroll and a stuttering one.
///
/// An URL in a shape this doesn't recognise is returned unchanged — a slightly
/// oversized image is a cost, a broken one is a bug.
String thumbnailAt(String url, int pixels) {
  if (pixels <= 0) return url;
  final marker = url.lastIndexOf('=');
  // The suffix form: everything after the last '=' is the parameter list.
  if (marker > 0 && marker < url.length - 1) {
    final params = url.substring(marker + 1);
    if (params.startsWith('w') || params.startsWith('s')) {
      return '${url.substring(0, marker)}=w$pixels-h$pixels-l90-rj';
    }
  }
  // i.ytimg.com serves fixed-name renditions; leave those alone.
  return url;
}
