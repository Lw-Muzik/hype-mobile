/// Keys for YouTube Music pages, carrying the whole item the page is built from.
///
/// The page takes an [ExploreItem] rather than an id, so a key that held only
/// the id could not rebuild it. [exploreItemFromArgs] is the way back.
library;

import '../services/ytmusic/yt_models.dart';
import 'library_page_key.dart';

Map<String, Object?> exploreItemToArgs(ExploreItem item) => {
  'id': item.id,
  'kind': item.kind.name,
  'title': item.title,
  if (item.subtitle != null) 'subtitle': item.subtitle,
  if (item.thumbnail != null) 'thumbnail': item.thumbnail,
  if (item.artist != null) 'artist': item.artist,
  if (item.album != null) 'album': item.album,
  if (item.durationSecs != null) 'durationSecs': item.durationSecs,
  'hasVideo': item.hasVideo,
};

/// The item described by [args], or null when it is missing what it needs.
ExploreItem? exploreItemFromArgs(Map<String, Object?> args) {
  final id = args['id'];
  final title = args['title'];
  final kindName = args['kind'];
  if (id is! String || title is! String || kindName is! String) return null;
  final kind = ExploreKind.values.asNameMap()[kindName];
  if (kind == null) return null;
  return ExploreItem(
    id: id,
    kind: kind,
    title: title,
    subtitle: args['subtitle'] as String?,
    thumbnail: args['thumbnail'] as String?,
    artist: args['artist'] as String?,
    album: args['album'] as String?,
    durationSecs: (args['durationSecs'] as num?)?.toDouble(),
    hasVideo: args['hasVideo'] == true,
  );
}

LibraryPageKey ytListKey(ExploreItem item, {String? highlightVideoId}) =>
    LibraryPageKey('ytList', {
      ...exploreItemToArgs(item),
      'highlightVideoId': ?highlightVideoId,
    });

LibraryPageKey ytArtistKey(ExploreItem item) =>
    LibraryPageKey('ytArtist', exploreItemToArgs(item));

LibraryPageKey ytCategoryKey(ExploreCategory category) => LibraryPageKey(
  'ytCategory',
  {'title': category.title, 'params': category.params},
);
