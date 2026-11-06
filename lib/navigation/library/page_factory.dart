/// Rebuilds library pages from their keys, for restoring a trail.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../library_page_key.dart';
import 'library_pages.dart';

/// Builds the page for a key. May look things up (a playlist, a cloud folder);
/// returns null when the page can no longer be built.
///
/// [context] is any context under the app's providers (the navigator's own);
/// builders that need a repository read it before their first await.
typedef LibraryPageBuilder = FutureOr<Widget?> Function(
  LibraryPageKey key,
  BuildContext? context,
);

final Map<String, LibraryPageBuilder> _builders =
    <String, LibraryPageBuilder>{};
bool _seeded = false;

void _seed() {
  if (_seeded) return;
  _seeded = true;
  for (final entry in defaultLibraryPages().entries) {
    _builders.putIfAbsent(entry.key, () => entry.value);
  }
}

/// Registers (or replaces) the builder for pages of [kind].
void registerLibraryPage(String kind, LibraryPageBuilder build) {
  _seed();
  _builders[kind] = build;
}

/// Empties the registry, defaults included (tests register their own).
@visibleForTesting
void clearLibraryPages() {
  _builders.clear();
  _seeded = true;
}

/// Back to the defaults only.
@visibleForTesting
void resetLibraryPages() {
  _builders.clear();
  _seeded = false;
}

/// The page for [key], or null when nothing is registered for its kind or the
/// builder cannot produce it (including when it throws).
Future<Widget?> buildLibraryPage(
  LibraryPageKey key, {
  BuildContext? context,
}) async {
  _seed();
  final build = _builders[key.kind];
  if (build == null) return null;
  try {
    return await build(key, context);
  } catch (e, st) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: e,
        stack: st,
        library: 'library navigation',
        context: ErrorDescription('while rebuilding a ${key.kind} page'),
      ),
    );
    return null;
  }
}
