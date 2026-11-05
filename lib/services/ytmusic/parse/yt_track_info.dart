/// What YouTube Music says about one track beyond what a list row carries —
/// for tagging a download: every credited artist, the album and its link,
/// the year, the art, and where its lyrics live.
///
/// Read from the `next` response for the track (the call a radio starts
/// with): its queue opens with the track itself, marked `selected`, and the
/// response's tabs hold the lyrics link. Measured Oct 2026:
///
/// * a song (`MUSIC_VIDEO_TYPE_ATV`) has a byline of
///   `Artist • Album • 2022`, the album run linking `MPREb…`, and square art
///   on a resizable `googleusercontent` URL;
/// * a music video has `Artist • 63M views • 249K likes` and a 16:9
///   `i.ytimg.com` thumbnail — unless the queue pairs it with its song
///   (a wrapper's counterpart), whose album, year and art are used instead.
///
/// Same rule as the rest of the folder: nothing here throws, and a shape it
/// can't read is null rather than an error.
library;

import '../yt_models.dart';
import 'yt_json.dart';

class YtTrackInfo {
  final String videoId;
  final String title;

  /// Every credited artist as YouTube writes them ("Burna Boy & Ed Sheeran").
  final String? artist;

  /// The same credits one by one, with each artist's channel where linked —
  /// what "Go to artist" opens.
  final List<YtArtistRef> artists;
  final String? album;

  /// The album's `MPREb…` browse id, for its track list and album artist.
  final String? albumId;
  final int? year;

  /// The largest art offered: square album art for a song, a 16:9 thumbnail
  /// for a video.
  final String? thumbnail;
  final double? durationSecs;

  /// The `MPLYt…` browse id of the lyrics, when YouTube has them.
  final String? lyricsId;

  /// A song (art track) rather than a video: its art is the album cover.
  final bool isSong;

  const YtTrackInfo({
    required this.videoId,
    required this.title,
    this.artist,
    this.artists = const [],
    this.album,
    this.albumId,
    this.year,
    this.thumbnail,
    this.durationSecs,
    this.lyricsId,
    this.isSong = false,
  });
}

/// The track [videoId] as the `next` response describes it, or null.
YtTrackInfo? parseTrackInfo(Object? json, String videoId) {
  final found = _findRow(json, videoId);
  if (found == null) return null;
  final (row, counterpart) = found;
  final own = _rowFacts(row);
  if (own == null) return null;
  // A video paired with its song: the song knows the album, year and cover.
  final song = counterpart == null ? null : _rowFacts(counterpart);
  final useSong = song != null && song.album != null && !own.isSong;
  return YtTrackInfo(
    videoId: videoId,
    title: own.title,
    artist: own.artist ?? song?.artist,
    artists: own.artists.isNotEmpty ? own.artists : (song?.artists ?? const []),
    album: useSong ? song.album : own.album,
    albumId: useSong ? song.albumId : own.albumId,
    year: own.year ?? (useSong ? song.year : null),
    thumbnail: useSong ? song.thumbnail : own.thumbnail,
    durationSecs: own.durationSecs ?? song?.durationSecs,
    lyricsId: _lyricsId(json),
    isSong: own.isSong || useSong,
  );
}

/// Lyrics as YouTube Music shows them, and who supplied them.
class YtLyrics {
  final String text;

  /// "Musixmatch", "LyricFind"…, when the page says.
  final String? source;

  const YtLyrics(this.text, {this.source});
}

/// The lyrics page (a `browse` of the `MPLYt…` id), or null.
YtLyrics? parseLyrics(Object? json) {
  final shelves = <Object?>[];
  _collect(json, 'musicDescriptionShelfRenderer', shelves);
  for (final shelf in shelves) {
    final text = joinRuns(ptr(shelf, 'description/runs'));
    if (text == null) continue;
    final footer = joinRuns(ptr(shelf, 'footer/runs'));
    final source = footer?.replaceFirst(RegExp(r'^Source:\s*'), '').trim();
    return YtLyrics(
      text,
      source: source == null || source.isEmpty ? null : source,
    );
  }
  return null;
}

// ---------------------------------------------------------------------------

class _Facts {
  final String title;
  final String? artist;
  final List<YtArtistRef> artists;
  final String? album;
  final String? albumId;
  final int? year;
  final String? thumbnail;
  final double? durationSecs;
  final bool isSong;

  const _Facts({
    required this.title,
    this.artist,
    this.artists = const [],
    this.album,
    this.albumId,
    this.year,
    this.thumbnail,
    this.durationSecs,
    this.isSong = false,
  });
}

_Facts? _rowFacts(Object? row) {
  final title = joinRuns(ptr(row, 'title/runs'));
  if (title == null) return null;

  // "Artist, Artist & Artist • Album • 2022": the segments are split on the
  // " • " runs. The album is found by its link, not its place — a video puts
  // a view count where a song puts the album.
  final segments = <List<Object?>>[[]];
  final runs = ptr(row, 'longBylineText/runs');
  if (runs is List) {
    for (final run in runs) {
      final text = ptr(run, 'text');
      if (text is String && text.trim() == '•') {
        segments.add([]);
      } else {
        segments.last.add(run);
      }
    }
  }
  final artist = joinRuns(segments.first);
  String? album;
  String? albumId;
  int? year;
  for (final segment in segments.skip(1)) {
    for (final run in segment) {
      final id = ptrString(run, 'navigationEndpoint/browseEndpoint/browseId');
      if (id != null && id.startsWith('MPRE') && album == null) {
        album = ptrString(run, 'text');
        albumId = id;
      }
    }
    final text = joinRuns(segment);
    if (year == null && text != null && RegExp(r'^\d{4}$').hasMatch(text)) {
      year = int.parse(text);
    }
  }

  final videoType = ptrString(
    row,
    'navigationEndpoint/watchEndpoint/watchEndpointMusicSupportedConfigs'
    '/watchEndpointMusicConfig/musicVideoType',
  );
  final thumbs = ptr(row, 'thumbnail/thumbnails');
  return _Facts(
    title: title,
    artist: artist,
    artists: artistRefs(segments.first),
    album: album,
    albumId: albumId,
    year: year,
    thumbnail: bestThumbnail(thumbs),
    durationSecs: parseDuration(ptrString(row, 'lengthText/runs/0/text')),
    isSong:
        videoType == 'MUSIC_VIDEO_TYPE_ATV' ||
        (videoType == null && album != null && _square(thumbs)),
  );
}

bool _square(Object? thumbs) {
  if (thumbs is! List || thumbs.isEmpty) return false;
  final w = ptr(thumbs.last, 'width');
  final h = ptr(thumbs.last, 'height');
  return w is num && h is num && w == h;
}

/// The row for [videoId] — the selected one if it appears more than once —
/// and the song paired with it when it sits in a wrapper.
(Object?, Object?)? _findRow(Object? json, String videoId) {
  final rows = <(Object?, Object?)>[];
  void walk(Object? node) {
    if (node is Map) {
      final wrapper = node['playlistPanelVideoWrapperRenderer'];
      if (wrapper != null) {
        final primary = ptr(
          wrapper,
          'primaryRenderer/playlistPanelVideoRenderer',
        );
        final counterpart = ptr(
          wrapper,
          'counterpart/0/counterpartRenderer/playlistPanelVideoRenderer',
        );
        if (ptrString(primary, 'videoId') == videoId) {
          rows.add((primary, counterpart));
        } else if (ptrString(counterpart, 'videoId') == videoId) {
          rows.add((counterpart, null));
        }
        return;
      }
      final row = node['playlistPanelVideoRenderer'];
      if (row != null) {
        if (ptrString(row, 'videoId') == videoId) rows.add((row, null));
        return;
      }
      for (final value in node.values) {
        walk(value);
      }
    } else if (node is List) {
      for (final value in node) {
        walk(value);
      }
    }
  }

  walk(json);
  if (rows.isEmpty) return null;
  return rows.firstWhere(
    (r) => ptr(r.$1, 'selected') == true,
    orElse: () => rows.first,
  );
}

/// The lyrics tab's browse id, unless the tab is greyed out (no lyrics).
String? _lyricsId(Object? json) {
  final tabs = <Object?>[];
  _collect(json, 'tabRenderer', tabs);
  for (final tab in tabs) {
    final id = ptrString(tab, 'endpoint/browseEndpoint/browseId');
    if (id == null || !id.startsWith('MPLY')) continue;
    if (ptr(tab, 'unselectable') == true) return null;
    return id;
  }
  return null;
}

void _collect(Object? node, String key, List<Object?> out) {
  if (node is Map) {
    final hit = node[key];
    if (hit != null) {
      out.add(hit);
      return;
    }
    for (final value in node.values) {
      _collect(value, key, out);
    }
  } else if (node is List) {
    for (final value in node) {
      _collect(value, key, out);
    }
  }
}
