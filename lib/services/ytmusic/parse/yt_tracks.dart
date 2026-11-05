/// Reading the track list behind one playlist or album.
///
/// Both arrive from the same `browse` call and are built from the same
/// `musicResponsiveListItemRenderer` rows — verified live against a playlist
/// (68 rows) and an album (7 rows). What differs is what the columns *mean*, and
/// that difference is the reason [TrackListKind] exists rather than one blind
/// reader:
///
/// | column | on a playlist | on an album |
/// |---|---|---|
/// | flex 1 | artist | artist |
/// | flex 2 | **album** | **"720K plays"** |
/// | thumbnail | per row | absent — the cover stands in |
///
/// Reading flex 2 as the album on both is how "720K plays" ends up printed as an
/// album name. Where the row links its album the link wins regardless; the kind
/// only decides the fallback.
///
/// Nothing here throws. A row it cannot read is skipped.
library;

import '../yt_models.dart';
import 'yt_json.dart';

/// Which surface a track list came from.
enum TrackListKind { playlist, album }

/// A playlist or album, opened.
class YtTrackList {
  final String title;
  final String? artist;

  /// The same credit artist by artist, with their channels — what the page's
  /// artist line opens.
  final List<YtArtistRef> artists;

  /// The first credited artist's portrait, beside their name.
  final String? artistThumbnail;
  final String? thumbnail;

  /// What it is and when: "Album • 2019", "EP • 2024", "Playlist • 2025".
  final String? subtitle;

  /// Its size: "12 songs • 42 minutes".
  final String? stats;
  final List<YtTrack> tracks;

  /// The token for the next page, if this one has a successor.
  final String? continuation;

  const YtTrackList({
    required this.title,
    required this.tracks,
    this.artist,
    this.artists = const [],
    this.artistThumbnail,
    this.thumbnail,
    this.subtitle,
    this.stats,
    this.continuation,
  });
}

/// Reads one page of a playlist or album response.
YtTrackList parseTrackList(
  Object? json, {
  required String id,
  required TrackListKind kind,
  String fallbackTitle = '',
}) {
  final header = _findFirst(json, 'musicResponsiveHeaderRenderer');
  final title = ptrString(header, 'title/runs/0/text') ?? fallbackTitle;
  final artist = joinRuns(ptr(header, 'straplineTextOne/runs'));
  final cover = bestThumbnail(
    ptr(header, 'thumbnail/musicThumbnailRenderer/thumbnail/thumbnails'),
  );

  final rows = _trackRows(json);
  final tracks = <YtTrack>[];
  for (final row in rows) {
    final track = _parseTrackRow(
      row,
      kind: kind,
      listId: id,
      listTitle: title,
      listArtist: artist,
      listCover: cover,
    );
    if (track != null) tracks.add(track);
  }

  return YtTrackList(
    title: title,
    artist: artist,
    artists: artistRefs(ptr(header, 'straplineTextOne/runs')),
    artistThumbnail: bestThumbnail(
      ptr(
        header,
        'straplineThumbnail/musicThumbnailRenderer/thumbnail/thumbnails',
      ),
    ),
    thumbnail: cover,
    subtitle: joinRuns(ptr(header, 'subtitle/runs')),
    stats: joinRuns(ptr(header, 'secondSubtitle/runs')),
    tracks: tracks,
    continuation: nextPageToken(json),
  );
}

/// The rows of the shelf that holds the tracks.
///
/// Prefers the track shelf over a blind walk, because a playlist page also
/// carries a "related" carousel — those are cards rather than rows today, but
/// scoping to the shelf means a future reshape can't quietly append somebody
/// else's rows to the queue. Falls back to walking when no shelf is recognised,
/// so an unfamiliar envelope still yields its tracks.
List<Object?> _trackRows(Object? json) {
  for (final key in const [
    'musicPlaylistShelfRenderer',
    'musicShelfRenderer',
  ]) {
    final shelf = _findFirst(json, key);
    final contents = ptr(shelf, 'contents');
    if (contents is List && contents.isNotEmpty) {
      return [
        for (final entry in contents)
          if (ptr(entry, 'musicResponsiveListItemRenderer') != null)
            ptr(entry, 'musicResponsiveListItemRenderer'),
      ];
    }
  }
  final rows = <Object?>[];
  _collect(json, 'musicResponsiveListItemRenderer', rows);
  return rows;
}

YtTrack? _parseTrackRow(
  Object? row, {
  required TrackListKind kind,
  required String listId,
  required String listTitle,
  String? listArtist,
  String? listCover,
}) {
  // No video id → nothing to stream, whatever else the row says.
  final videoId = ptrString(row, 'playlistItemData/videoId');
  if (videoId == null) return null;

  final title = flexText(row, 0);
  if (title == null) return null;
  // A removed track keeps its row but not its identity.
  if (title == 'Song deleted') return null;

  final videoType = ptr(row, videoTypePath) as String?;
  if (!isMusic(videoType)) return null;

  // YT Music greys out region-blocked and removed rows. They stay listed so the
  // list matches what the user would see on YouTube, but can't be played.
  final displayPolicy = ptr(row, 'musicItemRendererDisplayPolicy');
  final isAvailable =
      displayPolicy != 'MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT';

  final album = switch (kind) {
    // An album's own title is the album, and its flex 2 is a play count.
    TrackListKind.album => listTitle.isEmpty ? null : listTitle,
    TrackListKind.playlist => flexText(row, 2),
  };

  return YtTrack(
    videoId: videoId,
    title: title,
    artist: flexText(row, 1) ?? listArtist,
    album: album,
    durationSecs: _rowDuration(row),
    // Album rows carry no art of their own — the cover is the art, which is
    // what an album *is* and what the queue wants anyway.
    thumbnail:
        bestThumbnail(
          ptr(row, 'thumbnail/musicThumbnailRenderer/thumbnail/thumbnails'),
        ) ??
        listCover,
    playlistId: listId,
    playlistTitle: listTitle,
    isAvailable: isAvailable,
    hasVideo: hasVideo(videoType),
  );
}

/// A row's running time, from the fixed column playlists and albums both use.
double? _rowDuration(Object? row) {
  final text = ptr(
    row,
    'fixedColumns/0/musicResponsiveListItemFixedColumnRenderer/text',
  );
  final raw = joinRuns(ptr(text, 'runs')) ?? ptr(text, 'simpleText');
  return parseDuration(raw is String ? raw : null);
}

/// The token for the next page, in either shape YouTube issues it.
///
/// Older responses hang it off `nextContinuationData`, newer ones off a trailing
/// `continuationItemRenderer` sibling of the rows. Both are looked for because
/// which one arrives is not ours to choose, and a missing token simply means
/// this was the last page.
String? nextPageToken(Object? json) {
  final legacy = <Object?>[];
  _collect(json, 'nextContinuationData', legacy);
  for (final entry in legacy) {
    final token = ptrString(entry, 'continuation');
    if (token != null) return token;
  }
  final modern = <Object?>[];
  _collect(json, 'continuationItemRenderer', modern);
  for (final entry in modern) {
    final token = ptrString(
      entry,
      'continuationEndpoint/continuationCommand/token',
    );
    if (token != null) return token;
  }
  return null;
}

/// The first value stored under [key] anywhere in the tree.
Object? _findFirst(Object? node, String key) {
  if (node is Map) {
    final direct = node[key];
    if (direct != null) return direct;
    for (final value in node.values) {
      final found = _findFirst(value, key);
      if (found != null) return found;
    }
    return null;
  }
  if (node is List) {
    for (final value in node) {
      final found = _findFirst(value, key);
      if (found != null) return found;
    }
  }
  return null;
}

/// Every value stored under [key] anywhere in the tree.
void _collect(Object? node, String key, List<Object?> out) {
  if (node is Map) {
    final direct = node[key];
    if (direct != null) {
      out.add(direct);
      return;
    }
    for (final value in node.values) {
      _collect(value, key, out);
    }
    return;
  }
  if (node is List) {
    for (final value in node) {
      _collect(value, key, out);
    }
  }
}
