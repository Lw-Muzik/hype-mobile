import 'package:animations/animations.dart';
import '/pages/index_page.dart';
import 'package:flutter/material.dart';

import '../pages/equalizer.dart';
import '../navigation/app_nav.dart';
import '../pages/loader.dart';
import '../player/player_presence.dart';
import '../player/player_ui.dart';

class Routes {
  static String home = "/";
  static String equalizer = "/equalizer";
  static String loader = "/assetLoader";

  static void routeTo(
    Widget page,
    BuildContext context, {
    bool animate = true,
  }) {
    if (!animate) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) {
            return page;
          },
          fullscreenDialog: true,
        ),
      );
    } else {
      Navigator.of(context).push(
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 500),
          reverseTransitionDuration: const Duration(milliseconds: 500),
          pageBuilder: (context, animation, secondaryAnimation) {
            return DualTransitionBuilder(
              animation: animation,
              forwardBuilder: (context, anim, x) =>
                  FadeTransition(opacity: animation, child: page),
              reverseBuilder: (context, reverse, y) =>
                  ScaleTransition(scale: reverse, child: page),
            );
          },
        ),
      );
    }
  }

  static Widget animateTo({
    required Widget closedWidget,
    required Widget openWidget,
    Duration duration = const Duration(milliseconds: 500),
    RouteSettings? routeSettings,
  }) {
    return OpenContainer(
      routeSettings: routeSettings,
      closedElevation: 0,
      openElevation: 0,
      closedColor: Colors.transparent,
      openColor: Colors.black,
      transitionDuration: duration,
      transitionType: ContainerTransitionType.fade,
      closedBuilder: (context, fn) => closedWidget,
      openBuilder: (context, fn) => openWidget,
    );
  }

  /// Opens the player. Under the shell that is a scene change (see
  /// `navigation/shell`); this route is what a tree without the shell gets.
  /// It slides up from the list on open and back DOWN on pop, so
  /// the drag-to-dismiss gesture in the player hands off into the pop
  /// transition without a direction change. The list beneath
  /// is painted by the framework for the whole reverse transition, which is
  /// what makes the "player slides away revealing the list" read work.
  ///
  /// With a player already open — something opened from it started playing —
  /// this goes back to that one rather than stacking a second; see
  /// [PlayerPresence].
  static void playerTo(BuildContext context) {
    // Under the shell the player is a scene, not a route.
    final host = AppNav.host;
    if (host != null) {
      host.toPlayer();
      return;
    }
    final navigator = Navigator.of(context);
    if (PlayerPresence.isOpen) {
      navigator.popUntil(
        (route) =>
            route.settings.name == PlayerPresence.routeName || route.isFirst,
      );
      return;
    }
    navigator.push(
      PageRouteBuilder(
        settings: const RouteSettings(name: PlayerPresence.routeName),
        transitionDuration: const Duration(milliseconds: 350),
        reverseTransitionDuration: const Duration(milliseconds: 280),
        pageBuilder: (context, animation, secondaryAnimation) =>
            const Player(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final slide = Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(animation);
          // No cross-fade. The cover flies between the mini player and the
          // card as a hero, and fading the page it is landing on makes the
          // flight read as two images dissolving rather than one object moving.
          return SlideTransition(position: slide, child: child);
        },
      ),
    );
  }

  /// Premium detail-page transition: shared-axis Z (scale + fade)
  static void scaleTo(Widget page, BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
        reverseTransitionDuration: const Duration(milliseconds: 350),
        pageBuilder: (context, animation, secondaryAnimation) => page,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return SharedAxisTransition(
            animation: animation,
            secondaryAnimation: secondaryAnimation,
            transitionType: SharedAxisTransitionType.scaled,
            child: child,
          );
        },
      ),
    );
  }

  static void pop(BuildContext context) {
    Navigator.of(context).pop();
  }

  static Map<String, Widget Function(dynamic context)> routes() {
    return {
      equalizer: (context) => const Equalizer(),
      home: (context) => const IndexPage(),
      loader: (context) => const AssetLoader(),
    };
  }
}
