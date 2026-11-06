/// Identity of one page inside the library stack.
///
/// A page is a [kind] plus whatever [args] are needed to build it again. Keys
/// are plain data on purpose: they are compared, saved to disk with the
/// playback session, and used to rebuild a trail of pages later, so they must
/// not hold widgets or other live objects.
library;

import 'package:flutter/foundation.dart';

@immutable
class LibraryPageKey {
  const LibraryPageKey(this.kind, [this.args = const {}]);

  /// The top-level place with the given id (home, songs, albums, ...).
  factory LibraryPageKey.place(String placeId) =>
      LibraryPageKey('place', {'id': placeId});

  /// Kinds a page can have. Anything else read back from disk is rejected so a
  /// save from a different build can never produce a key nothing can rebuild.
  static const Set<String> kinds = {
    'place',
    'album',
    'artist',
    'genre',
    'folder',
    'playlist',
    'mix',
    'ytList',
    'ytCategory',
    'ytArtist',
    'ytSearch',
    'cloudFolder',
    'search',
    'songsAll',
  };

  final String kind;
  final Map<String, Object?> args;

  Map<String, Object?> toJson() => {
    'kind': kind,
    if (args.isNotEmpty) 'args': args,
  };

  static LibraryPageKey? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = json['kind'];
    if (kind is! String || !kinds.contains(kind)) return null;
    final rawArgs = json['args'];
    final args = <String, Object?>{};
    if (rawArgs is Map) {
      for (final entry in rawArgs.entries) {
        final key = entry.key;
        if (key is String) args[key] = entry.value;
      }
    }
    return LibraryPageKey(kind, args);
  }

  @override
  bool operator ==(Object other) =>
      other is LibraryPageKey &&
      other.kind == kind &&
      mapEquals(other.args, args);

  @override
  int get hashCode => Object.hash(
    kind,
    Object.hashAllUnordered(
      args.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );

  @override
  String toString() => 'LibraryPageKey($kind, $args)';
}
