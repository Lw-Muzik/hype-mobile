/// The trail of library pages that playback was started from.
///
/// Saved with the session so that, after a restart, going back from the player
/// can land on the same page the music came from instead of the top level.
library;

import 'package:flutter/foundation.dart';

import 'library_page_key.dart';

@immutable
class PlaybackOrigin {
  const PlaybackOrigin(this.path);

  final List<LibraryPageKey> path;

  Map<String, Object?> toJson() => {
    'path': [for (final key in path) key.toJson()],
  };

  /// Reads an origin back, or null when [json] holds nothing usable. Entries
  /// that no longer parse are dropped rather than failing the whole trail.
  static PlaybackOrigin? fromJson(Object? json) {
    if (json is! Map) return null;
    final raw = json['path'];
    if (raw is! List) return null;
    final path = <LibraryPageKey>[];
    for (final entry in raw) {
      final key = LibraryPageKey.fromJson(entry);
      if (key != null) path.add(key);
    }
    if (path.isEmpty) return null;
    return PlaybackOrigin(path);
  }

  @override
  bool operator ==(Object other) =>
      other is PlaybackOrigin && listEquals(other.path, path);

  @override
  int get hashCode => Object.hashAll(path);

  @override
  String toString() => 'PlaybackOrigin($path)';
}

/// The origin a queue that has just been installed starts with.
///
/// An origin belongs to one queue. A new queue therefore starts with none (the
/// list action that started it records its own afterwards), unless it is only
/// the old queue reshaped, which keeps its trail: every song in it was already
/// in the old queue (tapping an entry of the Now Playing list, a reorder).
PlaybackOrigin? originForInstall(
  PlaybackOrigin? current, {
  required Iterable<Object?> oldIds,
  required Iterable<Object?> newIds,
}) {
  if (current == null) return null;
  final old = oldIds.toSet();
  if (old.isEmpty) return null;
  return newIds.every(old.contains) ? current : null;
}
