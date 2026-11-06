/// Names of the shared elements that fly between library pages.
///
/// A list row or tile that opens a page wears the item tag of the page's key;
/// the page's own header wears the header tag of the same key. Both are plain
/// strings built from the key's data, so any widget can compute them without
/// knowing about the navigator.
library;

import 'dart:convert';

import '../library_page_key.dart';

/// The part of a key that says which thing the page shows. Two keys for the
/// same album differ in display extras (cover, counts), so tags compare only
/// this, and a page can name itself from its own fields.
Map<String, Object?> _identity(LibraryPageKey key) {
  final a = key.args;
  Map<String, Object?> pick(List<String> names) => {
    for (final n in names)
      if (a.containsKey(n)) n: a[n],
  };
  return switch (key.kind) {
    'album' => pick(['albumId']),
    'artist' => pick(['artistId']),
    'genre' => pick(['genreId']),
    'folder' => pick(['path']),
    'playlist' => pick(['playlistId']),
    'mix' => pick(['id']),
    'ytList' || 'ytArtist' => pick(['id']),
    'ytCategory' => pick(['params']),
    'cloudFolder' => pick(['folderName', 'provider']),
    _ => a,
  };
}

String _name(String prefix, LibraryPageKey key) =>
    '$prefix:${key.kind}:${jsonEncode(_identity(key))}';

/// Tag for the row or tile that opens the page with [key].
Object itemTag(LibraryPageKey key) => _name('item', key);

/// Tag for the header of the page with [key].
Object headerTag(LibraryPageKey key) => _name('header', key);

/// Tag for a song's cover wherever it is listed.
Object trackTag(Object songId) => 'track:$songId';

/// Tag for the player's own cover, the other end of every cover flight between
/// the player and a list row.
const Object kNowPlayingArtTag = 'now-playing-art';
