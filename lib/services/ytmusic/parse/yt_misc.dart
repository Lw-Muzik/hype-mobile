/// The three small parsers: mood categories, search suggestions, and radio.
///
/// Same rule as the rest of the folder — nothing here throws, and a shape it
/// cannot read is empty rather than an error. For a type-ahead in particular
/// that matters: one reshaped response must cost the suggestions, never replace
/// them with an error.
library;

import '../yt_models.dart';
import 'yt_json.dart';

// ---------------------------------------------------------------------------
// Mood & genre categories
// ---------------------------------------------------------------------------

/// The mood and genre rows YouTube offers ("Moods & moments", "Genres").
///
/// Each button carries the opaque `params` that opens its category. A button
/// missing either its label or its params is skipped: a category we can name but
/// not open is a tile that does nothing.
List<ExploreSection> parseCategories(Object? json) {
  final sections = <ExploreSection>[];
  final grids = <Object?>[];
  _collect(json, 'gridRenderer', grids);

  for (final grid in grids) {
    final title = ptrString(
      grid,
      'header/gridHeaderRenderer/title/runs/0/text',
    );
    final buttons = <Object?>[];
    _collect(ptr(grid, 'items'), 'musicNavigationButtonRenderer', buttons);

    final categories = <ExploreCategory>[];
    for (final button in buttons) {
      final label = ptrString(button, 'buttonText/runs/0/text');
      final params = ptrString(button, 'clickCommand/browseEndpoint/params');
      if (label == null || params == null) continue;
      categories.add(ExploreCategory(title: label, params: params));
    }
    if (categories.isEmpty) continue;
    sections.add(
      ExploreSection(title: title ?? 'Browse', categories: categories),
    );
  }
  return sections;
}

// ---------------------------------------------------------------------------
// Search suggestions
// ---------------------------------------------------------------------------

/// The completions YouTube offers for a partial query.
List<String> parseSuggestions(Object? json) {
  final renderers = <Object?>[];
  _collect(json, 'searchSuggestionRenderer', renderers);
  final out = <String>[];
  for (final renderer in renderers) {
    // A suggestion's runs are its own text split for bold highlighting —
    // "burna " + "boy" — so joining them is the whole of reading one, and
    // reading a single run would return half a word.
    final text = joinRuns(ptr(renderer, 'suggestion/runs'));
    if (text != null && !out.contains(text)) out.add(text);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Radio ("up next")
// ---------------------------------------------------------------------------

/// Reads a first radio page and a continuation page alike.
RadioBatch parseRadioPage(Object? json) {
  final rows = <Object?>[];
  _collectRadioRows(json, rows);
  final tracks = <YtTrack>[];
  for (final row in rows) {
    final track = _parseRadioRow(row);
    if (track != null) tracks.add(track);
  }
  return RadioBatch(tracks: tracks, continuation: _nextRadioToken(json));
}

/// Every track row in the panel, wrappers unwrapped to their primary rendition.
void _collectRadioRows(Object? node, List<Object?> out) {
  if (node is Map) {
    final wrapper = node['playlistPanelVideoWrapperRenderer'];
    if (wrapper != null) {
      // A wrapper is a song/video pair; the counterpart is the same track in its
      // other rendition, so only the primary is a row. Reading both would
      // duplicate every wrapped track in the queue — 42 of 50 rows in a real
      // capture are wrapped.
      final primary = ptr(
        wrapper,
        'primaryRenderer/playlistPanelVideoRenderer',
      );
      if (primary != null) out.add(primary);
      return;
    }
    final row = node['playlistPanelVideoRenderer'];
    if (row != null) {
      out.add(row);
      return;
    }
    for (final value in node.values) {
      _collectRadioRows(value, out);
    }
    return;
  }
  if (node is List) {
    for (final value in node) {
      _collectRadioRows(value, out);
    }
  }
}

/// One panel row → a queueable track; null for rows the queue must not hold.
YtTrack? _parseRadioRow(Object? row) {
  // Grey rows are listed but unplayable — a queue entry that can't stream.
  if (ptr(row, 'unplayableText') != null) return null;
  // The seed comes back first, marked `selected` — the queue already has it.
  if (ptr(row, 'selected') == true) return null;

  final videoId = ptrString(row, 'videoId');
  if (videoId == null) return null;
  final title = joinRuns(ptr(row, 'title/runs'));
  if (title == null) return null;

  final byline = ptr(row, 'longBylineText/runs');
  final artist =
      (byline is List && byline.isNotEmpty
          ? ptr(byline.first, 'text') as String?
          : null) ??
      joinRuns(ptr(row, 'shortBylineText/runs'));

  // The byline reads "Artist • Album • 2021" — but the album is found by its
  // *link* (album browse ids start "MPRE"), not its position: videos put a view
  // count where songs put the album, and years and views are plain text.
  String? album;
  if (byline is List) {
    for (final run in byline.skip(2)) {
      final id = ptrString(run, 'navigationEndpoint/browseEndpoint/browseId');
      if (id == null || !id.startsWith('MPRE')) continue;
      final text = ptr(run, 'text');
      if (text is String && text.isNotEmpty) {
        album = text;
        break;
      }
    }
  }

  final videoType = ptr(
    row,
    'navigationEndpoint/watchEndpoint/watchEndpointMusicSupportedConfigs'
    '/watchEndpointMusicConfig/musicVideoType',
  ) as String?;

  return YtTrack(
    videoId: videoId,
    title: title,
    artist: artist,
    album: album,
    durationSecs: parseDuration(ptrString(row, 'lengthText/runs/0/text')),
    thumbnail: bestThumbnail(ptr(row, 'thumbnail/thumbnails')),
    playlistId:
        ptrString(row, 'navigationEndpoint/watchEndpoint/playlistId') ?? '',
    playlistTitle: 'Radio',
    hasVideo: hasVideo(videoType),
  );
}

/// The token for the next radio page.
///
/// Radio panels use `nextRadioContinuationData`; plain queue panels use
/// `nextContinuationData`, which this deliberately does not follow — those
/// queues are finite and following one would end the endlessness.
String? _nextRadioToken(Object? json) {
  final found = <Object?>[];
  _collect(json, 'nextRadioContinuationData', found);
  for (final entry in found) {
    final token = ptrString(entry, 'continuation');
    if (token != null) return token;
  }
  return null;
}

// ---------------------------------------------------------------------------

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
