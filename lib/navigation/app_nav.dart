/// The one door every page uses to move between the library and the player.
///
/// Pages never push routes for these moves themselves. They ask [AppNav], which
/// hands the request to the shell once it is installed ([AppNav.host]) and
/// otherwise falls back to the navigator-based behaviour the app had before the
/// shell existed, so both worlds work from the same call sites.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../routes/routes.dart';
import '../services/connect/remote/connect_play_router.dart';
import 'library_page_key.dart';
import 'library_path.dart';
import 'playback_origin.dart';

/// The stack of library pages owned by the shell.
abstract interface class LibraryNavigatorController {
  /// Opens [page] on top of the stack. [sibling] marks a page that replaces
  /// the current top rather than going deeper (for example a search opened
  /// from a top-level place).
  Future<void> openPage(
    Widget page, {
    required LibraryPageKey key,
    Object? morphFrom,
    bool sibling = false,
  });

  /// Rebuilds the stack so it ends on [path].
  Future<void> showPath(List<LibraryPageKey> path);

  bool get canPop;

  Future<bool> pop();

  List<LibraryPageKey> get path;
}

/// What the shell offers to pages.
abstract interface class NavHost {
  Future<void> toPlayer({Object? morphFrom});

  Future<void> toLibrary({PlaybackOrigin? landOn, Object? morphFrom});

  LibraryNavigatorController get library;
}

abstract final class AppNav {
  /// Installed by the shell; null until then, which selects the legacy path.
  static NavHost? host;

  /// Opens the player.
  ///
  /// With [recordOrigin] (the default) the caller is starting a queue, so the
  /// trail of the page it sits in becomes the queue's origin; outside any page
  /// the origin is cleared so an old one cannot outlive its queue. Pass false
  /// when only showing the player for a queue that is already running. Call it
  /// after the queue has been installed: installing a queue drops the previous
  /// origin. While another device is the player nothing is recorded, the local
  /// queue did not change.
  static Future<void> toPlayer(
    BuildContext context, {
    Object? morphFrom,
    bool recordOrigin = true,
  }) {
    if (recordOrigin && ConnectPlayRouter.target == null) {
      final path = LibraryPathScope.of(context);
      try {
        Provider.of<AppController>(context, listen: false).playbackOrigin =
            path.isEmpty ? null : PlaybackOrigin(List.of(path));
      } on ProviderNotFoundException {
        // No controller above this context (a bare test tree).
      }
    }
    final h = host;
    if (h != null) return h.toPlayer(morphFrom: morphFrom);
    Routes.playerTo(context);
    return Future.value();
  }

  /// Opens the player at once for a queue that [start] is still building (a
  /// mix resolves its first playable track before anything is queued), and
  /// gives that queue the origin of [context]'s page once it exists.
  ///
  /// The origin is only attached when [start] installed exactly one queue
  /// (the controller's generation moved by one): if it installed none, the old
  /// queue keeps its own trail, and if something else got in between, the
  /// origin would belong to the wrong queue.
  static Future<void> toPlayerWhileStarting(
    BuildContext context,
    AppController controller,
    Future<void> Function() start,
  ) async {
    final path = LibraryPathScope.of(context);
    final origin = path.isEmpty || ConnectPlayRouter.target != null
        ? null
        : PlaybackOrigin(List.of(path));
    final before = controller.queueGeneration;
    unawaited(toPlayer(context, recordOrigin: false));
    await start();
    if (origin != null && controller.queueGeneration == before + 1) {
      controller.playbackOrigin = origin;
    }
  }

  /// Shows the player from a route that sits above the shell (Settings): pops
  /// everything above the shell first, then opens the player the shell owns.
  static Future<void> toPlayerFromOverlay(BuildContext context) {
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
    return toPlayer(context, recordOrigin: false);
  }

  static Future<void> toLibrary(
    BuildContext context, {
    PlaybackOrigin? landOn,
  }) {
    final h = host;
    if (h != null) return h.toLibrary(landOn: landOn);
    Navigator.of(context).popUntil((route) => route.isFirst);
    return Future.value();
  }

  /// Opens a library page. In the legacy path the page is wrapped in a
  /// [LibraryPathScope] holding the parent's trail plus [key].
  static Future<void> openPage(
    BuildContext context,
    Widget page, {
    required LibraryPageKey key,
    Object? morphFrom,
    bool sibling = false,
  }) {
    final h = host;
    if (h != null) {
      return h.library.openPage(
        page,
        key: key,
        morphFrom: morphFrom,
        sibling: sibling,
      );
    }
    final parent = LibraryPathScope.of(context);
    Routes.scaleTo(
      LibraryPathScope(path: [...parent, key], child: page),
      context,
    );
    return Future.value();
  }
}
