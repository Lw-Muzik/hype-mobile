/// Tells a page which library pages sit above it.
library;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';

import 'library_page_key.dart';

/// Carries the trail of pages leading to the subtree below it.
///
/// Whoever opens a page wraps it in a scope whose path is the parent's path
/// plus the new page's key. Anything inside, such as a song tap that opens the
/// player, can then read where it is without knowing the navigator.
class LibraryPathScope extends InheritedWidget {
  const LibraryPathScope({super.key, required this.path, required super.child});

  final List<LibraryPageKey> path;

  /// The path at [context], or an empty list outside any scope.
  static List<LibraryPageKey> of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<LibraryPathScope>();
    return scope?.path ?? const [];
  }

  @override
  bool updateShouldNotify(LibraryPathScope oldWidget) =>
      !listEquals(oldWidget.path, path);
}
