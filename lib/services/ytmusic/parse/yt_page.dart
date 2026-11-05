/// Reading a catalog page — the shelves a mood, genre, artist or search
/// response is made of.
///
/// # One walk, every surface
///
/// A mood page, an artist page and a search response are the same construction:
/// shelves of items. They differ only in which of the three shelf renderers they
/// reach for and how deeply they bury them, so [parsePage] walks for the shelves
/// themselves rather than navigating an envelope. Measured on live responses: a
/// genre page is five `musicCarouselShelfRenderer`s, an artist page mixes one
/// `musicShelfRenderer` with eight carousels, and a filtered search is a single
/// `musicShelfRenderer` — the same reader serves all three, and no surface needs
/// its own path.
///
/// # Reading by meaning, not by position
///
/// Where a row states a fact varies by surface: search puts a song's album in
/// flexible column 1, a genre page puts it in column 2, and column 2 of a search
/// row is the play count instead. Every one of those runs, however, carries its
/// own `browseEndpoint` naming what it opens — so a run linking to an album *is*
/// the album, wherever it sits. Reading the link rather than the index is what
/// makes one parser correct on all of them.
///
/// # The rule that shapes everything here
///
/// **Nothing in this file may throw.** An unreadable item is skipped, an unknown
/// shelf is skipped, and a page we understand nothing of is *empty*, never an
/// error. YouTube reshaping one genre must cost that shelf, not Discover.
library;

import '../yt_models.dart';
import 'yt_json.dart';

/// YouTube's own word for what a browse id opens, hung off a `browseEndpoint`.
const _pageType =
    'browseEndpointContextSupportedConfigs'
    '/browseEndpointContextMusicConfig/pageType';

const _albumPage = 'MUSIC_PAGE_TYPE_ALBUM';
const _playlistPage = 'MUSIC_PAGE_TYPE_PLAYLIST';
const _artistPage = 'MUSIC_PAGE_TYPE_ARTIST';

/// A card's `musicVideoType`, stated on the watch endpoint it opens. The
/// list-row equivalent is [videoTypePath], which hangs off the play button.
const _cardVideoType =
    'watchEndpointMusicSupportedConfigs'
    '/watchEndpointMusicConfig/musicVideoType';

/// The label for the single-item shelf a search leads with. The card states no
/// heading of its own, and titling it after the item it holds would name the
/// result rather than the shelf.
const _topResult = 'Top result';

/// The top of an artist's page, or null when the page has none we can read.
///
/// Measured Oct 2026 (Patoranking): a `musicImmersiveHeaderRenderer` holding
/// the name, a 1080×450 banner, the bio, "1.93M subscribers", "3.21M monthly
/// audience" and YouTube's Shuffle and Mix buttons. Older and smaller pages
/// use `musicVisualHeaderRenderer`, which adds a round portrait in
/// `foregroundThumbnail` — read from either.
YtArtistHeader? parseArtistHeader(Object? json) {
  final header =
      ptr(json, 'header/musicImmersiveHeaderRenderer') ??
      ptr(json, 'header/musicVisualHeaderRenderer');
  final name = joinRuns(ptr(header, 'title/runs'));
  if (name == null) return null;
  final subscribe = ptr(header, 'subscriptionButton/subscribeButtonRenderer');
  return YtArtistHeader(
    name: name,
    banner: bestThumbnail(
      ptr(header, 'thumbnail/musicThumbnailRenderer/thumbnail/thumbnails'),
    ),
    avatar: bestThumbnail(
      ptr(
        header,
        'foregroundThumbnail/musicThumbnailRenderer/thumbnail/thumbnails',
      ),
    ),
    subscribers:
        joinRuns(ptr(subscribe, 'longSubscriberCountText/runs')) ??
        _withSubscribers(joinRuns(ptr(subscribe, 'subscriberCountText/runs'))),
    audience: joinRuns(ptr(header, 'monthlyListenerCount/runs')),
    description: joinRuns(ptr(header, 'description/runs')),
    shuffle: _watchRef(
      ptr(header, 'playButton/buttonRenderer/navigationEndpoint/watchEndpoint'),
    ),
    radio: _watchRef(
      ptr(
        header,
        'startRadioButton/buttonRenderer/navigationEndpoint/watchEndpoint',
      ),
    ),
  );
}

/// "1.93M" alone says nothing; the long form is "1.93M subscribers".
String? _withSubscribers(String? count) =>
    count == null ? null : '$count subscribers';

YtWatchRef? _watchRef(Object? endpoint) {
  final videoId = ptrString(endpoint, 'videoId');
  if (videoId == null) return null;
  return YtWatchRef(videoId, playlistId: ptrString(endpoint, 'playlistId'));
}

/// Every shelf on a mood, genre, artist or search page.
///
/// Walks for the shelf renderers instead of navigating to them: a search nests
/// them under `tabbedSearchResultsRenderer`, an artist page under
/// `singleColumnBrowseResultsRenderer`, and a mood page under a plain section
/// list. None of that matters if you look for the shelves themselves.
List<ExploreShelf> parsePage(Object? json) {
  final shelves = <ExploreShelf>[];
  _collectShelves(json, shelves);
  return shelves;
}

void _collectShelves(Object? node, List<ExploreShelf> out) {
  if (node is Map) {
    // Shelves don't nest, so a hit ends this subtree.
    final carousel = node['musicCarouselShelfRenderer'];
    if (carousel != null) {
      _pushShelf(_carouselTitle(carousel), ptr(carousel, 'contents'), out);
      return;
    }
    final shelf = node['musicShelfRenderer'];
    if (shelf != null) {
      _pushShelf(_shelfTitle(shelf), ptr(shelf, 'contents'), out);
      return;
    }
    final card = node['musicCardShelfRenderer'];
    if (card != null) {
      final parsed = _parseCardShelf(card);
      if (parsed != null) out.add(parsed);
      return;
    }
    for (final value in node.values) {
      _collectShelves(value, out);
    }
    return;
  }
  if (node is List) {
    for (final value in node) {
      _collectShelves(value, out);
    }
  }
}

/// Files a shelf, unless it has no title or nothing we can open.
///
/// A shelf we can title but not fill is one whose every item we failed to read,
/// which is worth nothing to show and better dropped than rendered empty.
void _pushShelf(String? title, Object? contents, List<ExploreShelf> out) {
  if (title == null) return;
  final items = _parseItems(contents);
  if (items.isEmpty) return;
  out.add(ExploreShelf(title: title, items: items));
}

String? _carouselTitle(Object? shelf) => ptrString(
  shelf,
  'header/musicCarouselShelfBasicHeaderRenderer/title/runs/0/text',
);

String? _shelfTitle(Object? shelf) => ptrString(shelf, 'title/runs/0/text');

/// The single-item shelf a search leads with: the card itself, then the rows it
/// carries underneath — which is what YouTube renders there.
ExploreShelf? _parseCardShelf(Object? shelf) {
  final items = <ExploreItem>[];
  final card = _parseCard(shelf);
  if (card != null) items.add(card);
  items.addAll(_parseItems(ptr(shelf, 'contents')));
  if (items.isEmpty) return null;
  return ExploreShelf(title: _topResult, items: items);
}

/// The top-result card. Shaped like neither renderer around it: its title and
/// thumbnail sit at the top level and its destination on `onTap`.
ExploreItem? _parseCard(Object? card) {
  final endpoint =
      ptr(card, 'onTap') ?? ptr(card, 'title/runs/0/navigationEndpoint');
  if (endpoint == null) return null;
  final title = ptrString(card, 'title/runs/0/text');
  if (title == null) return null;
  final subtitleRuns = ptr(card, 'subtitle/runs');
  return _open(
    endpoint: endpoint,
    title: title,
    subtitle: joinRuns(subtitleRuns),
    thumbnail: bestThumbnail(
      ptr(card, 'thumbnail/musicThumbnailRenderer/thumbnail/thumbnails'),
    ),
    byline: [?subtitleRuns],
  );
}

List<ExploreItem> _parseItems(Object? contents) {
  if (contents is! List) return const [];
  final items = <ExploreItem>[];
  for (final entry in contents) {
    final item = _parseContent(entry);
    if (item != null) items.add(item);
  }
  return items;
}

/// One shelf entry, whichever of the two item renderers holds it.
///
/// Carousels carry cards, list shelves carry rows, and a genre page's *Songs*
/// carousel carries rows — so which renderer appears is not a property of the
/// shelf. A card-only filter here is what silently emptied twenty genre pages of
/// their songs on desktop.
ExploreItem? _parseContent(Object? node) {
  final card = ptr(node, 'musicTwoRowItemRenderer');
  if (card != null) return _parseItem(card);
  final row = ptr(node, 'musicResponsiveListItemRenderer');
  if (row == null) return null;
  return parseRow(row);
}

/// A card: an album, playlist or artist to open, or a music video to play.
ExploreItem? _parseItem(Object? card) {
  // Cards state their destination twice — on the item and on the title's first
  // run — and the two agree wherever both exist. The item is the reliable one: a
  // music-video card carries a watch endpoint there and nothing at all on the
  // title run.
  final endpoint =
      ptr(card, 'navigationEndpoint') ??
      ptr(card, 'title/runs/0/navigationEndpoint');
  if (endpoint == null) return null;
  final title = ptrString(card, 'title/runs/0/text');
  if (title == null) return null;
  final subtitleRuns = ptr(card, 'subtitle/runs');
  return _open(
    endpoint: endpoint,
    title: title,
    subtitle: joinRuns(subtitleRuns),
    thumbnail: bestThumbnail(
      ptr(
        card,
        'thumbnailRenderer/musicThumbnailRenderer/thumbnail/thumbnails',
      ),
    ),
    byline: [?subtitleRuns],
  );
}

/// Builds an item from whatever [endpoint] opens.
///
/// [byline] is every runs array that may credit an artist or album; each run's
/// own link decides what it is, so the caller hands over all of them without
/// having to know which one carries what.
ExploreItem? _open({
  required Object? endpoint,
  required String title,
  required String? subtitle,
  required String? thumbnail,
  required List<Object?> byline,
}) {
  final browse = ptr(endpoint, 'browseEndpoint');
  if (browse != null) {
    final id = ptrString(browse, 'browseId');
    if (id == null) return null;
    final kind = _classify(id, ptr(browse, _pageType) as String?);
    if (kind == null) return null;
    return ExploreItem(
      kind: kind,
      id: kind == ExploreKind.playlist ? playlistBrowseId(id) : id,
      title: title,
      subtitle: subtitle,
      thumbnail: thumbnail,
      artist: _linkedRuns(byline, _artistPage),
      album: _linkedRuns(byline, _albumPage),
    );
  }

  // A watch endpoint names something to play rather than a page to open.
  final watch = ptr(endpoint, 'watchEndpoint');
  if (watch == null) return null;
  final videoId = ptrString(watch, 'videoId');
  if (videoId == null) return null;
  final videoType = ptr(watch, _cardVideoType) as String?;
  if (!isMusic(videoType)) return null;
  return ExploreItem(
    kind: _kindOf(videoType),
    id: videoId,
    title: title,
    subtitle: subtitle,
    thumbnail: thumbnail,
    artist: _linkedRuns(byline, _artistPage),
    album: _linkedRuns(byline, _albumPage),
    durationSecs: _durationOf(byline),
    hasVideo: hasVideo(videoType),
  );
}

/// A list row.
///
/// Rows come two ways and which one a shelf holds is not stated anywhere: a
/// *Songs* shelf lists things to play, carrying a video id under
/// `playlistItemData` and no navigation endpoint at all, while an *Artists* or
/// *Albums* shelf lists pages to open, carrying a `browseEndpoint` and no video
/// id. The two are told apart by which of those is present, since neither ever
/// carries the other's.
ExploreItem? parseRow(Object? row) {
  final videoId = ptrString(row, 'playlistItemData/videoId');
  if (videoId == null) {
    // No video id: a row that names a page rather than a track.
    final endpoint = ptr(row, 'navigationEndpoint');
    if (endpoint == null) return null;
    final title = flexText(row, 0);
    if (title == null) return null;
    final subtitleRuns = ptr(row, 'subtitle/runs');
    return _open(
      endpoint: endpoint,
      title: title,
      subtitle: flexText(row, 1) ?? joinRuns(subtitleRuns),
      thumbnail: bestThumbnail(
        ptr(row, 'thumbnail/musicThumbnailRenderer/thumbnail/thumbnails'),
      ),
      byline: bylineRuns(row),
    );
  }

  final title = flexText(row, 0);
  if (title == null) return null;
  // A removed track keeps its row but not its identity.
  if (title == 'Song deleted') return null;
  final videoType = ptr(row, videoTypePath) as String?;
  if (!isMusic(videoType)) return null;

  final byline = bylineRuns(row);
  return ExploreItem(
    kind: _kindOf(videoType),
    id: videoId,
    title: title,
    // Column 1 is what YouTube prints under the title on every surface, and the
    // columns after it vary (an album here, a play count there), so the one
    // column is the honest subtitle and the linked runs below carry the rest.
    subtitle: flexText(row, 1),
    thumbnail: bestThumbnail(
      ptr(row, 'thumbnail/musicThumbnailRenderer/thumbnail/thumbnails'),
    ),
    artist: _linkedRuns(byline, _artistPage),
    album: _linkedRuns(byline, _albumPage),
    durationSecs: _durationOf(byline) ?? _fixedDuration(row),
    hasVideo: hasVideo(videoType),
  );
}

/// The runs of every flexible column after the title.
///
/// Column 0 is the title on every surface measured; the rest are the byline, and
/// *which* of them carries what varies (search credits the album in column 1, a
/// genre page in column 2, and a search row's column 2 is the play count). All
/// of them are handed to the link readers, which take only the runs that name
/// themselves — so the variation never has to be modelled.
///
/// The title is excluded rather than searched because it is the one column whose
/// text is arbitrary: a song called "9:41" would otherwise state a duration.
List<Object?> bylineRuns(Object? row) {
  final runs = <Object?>[];
  for (var column = 1; ; column++) {
    final found = ptr(
      row,
      'flexColumns/$column/musicResponsiveListItemFlexColumnRenderer/text/runs',
    );
    if (found == null) break;
    runs.add(found);
  }
  return runs;
}

/// Every run in [byline] whose link opens [pageType], joined.
///
/// Joined with ", ": YouTube's own separator runs sit *between* the linked ones
/// and aren't links themselves, so keeping them would mean reading by position
/// again.
String? _linkedRuns(List<Object?> byline, String pageType) {
  final names = <String>[];
  for (final runs in byline) {
    if (runs is! List) continue;
    for (final run in runs) {
      final linked = ptr(run, 'navigationEndpoint/browseEndpoint');
      if (linked == null) continue;
      if (ptr(linked, _pageType) != pageType) continue;
      final text = ptr(run, 'text');
      if (text is String && text.trim().isNotEmpty) names.add(text);
    }
  }
  return names.isEmpty ? null : names.join(', ');
}

/// The byline run that states a running time.
///
/// Requires a colon: a bare number is a year on an album's byline and a view
/// count everywhere else, and [parseDuration] would read "2020" as thirty-three
/// minutes. A duration in these bylines is always `M:SS` or `H:MM:SS`, so
/// demanding the separator costs nothing and rules the rest out.
double? _durationOf(List<Object?> byline) {
  for (final runs in byline) {
    if (runs is! List) continue;
    for (final run in runs) {
      final text = ptr(run, 'text');
      if (text is! String || !text.contains(':')) continue;
      final seconds = parseDuration(text);
      if (seconds != null) return seconds;
    }
  }
  return null;
}

/// Duration as a playlist or album row states it: in the first fixed column, as
/// runs or a bare string. Search and genre rows have no fixed columns at all.
double? _fixedDuration(Object? row) {
  final text = ptr(
    row,
    'fixedColumns/0/musicResponsiveListItemFixedColumnRenderer/text',
  );
  if (text == null) return null;
  final raw = joinRuns(ptr(text, 'runs')) ?? ptr(text, 'simpleText');
  return parseDuration(raw is String ? raw : null);
}

/// Song or video, on YouTube's own marker rather than on which shelf or filter
/// produced the row. `ATV` is an audio entity: its "video" is a square still of
/// the cover art, so it is a song.
ExploreKind _kindOf(String? videoType) =>
    hasVideo(videoType) ? ExploreKind.video : ExploreKind.song;

/// What a browse id opens.
///
/// [pageType] is YouTube's own answer and settles it — including when the answer
/// is something this view doesn't offer (a podcast, a user channel), which is a
/// reason to skip the item rather than to go guessing from its prefix. The
/// prefix rule is the fallback for surfaces that state no type.
ExploreKind? _classify(String browseId, String? pageType) {
  switch (pageType) {
    case _albumPage:
      return ExploreKind.album;
    case _playlistPage:
      return ExploreKind.playlist;
    case _artistPage:
      return ExploreKind.artist;
    case null:
      if (browseId.startsWith('MPREb')) return ExploreKind.album;
      if (browseId.startsWith('VL')) return ExploreKind.playlist;
      if (browseId.startsWith('UC')) return ExploreKind.artist;
      return null;
    default:
      // A stated type we don't offer — a podcast, a user channel. Skip it rather
      // than guessing from the prefix: podcast channels are `UC…` too.
      return null;
  }
}
