import 'package:flutter/foundation.dart';

/// Fired when the player is pulled away or sent back to the library. Song lists
/// listen and scroll themselves to the now-playing row, so the gesture lands
/// the user back "where the current song is" instead of
/// wherever the list happened to be scrolled.
class PlayerRevealBus {
  PlayerRevealBus._();

  static final ValueNotifier<int> tick = ValueNotifier<int>(0);

  /// Whether the last reveal should jump instead of scrolling (the list is
  /// not on screen yet, so nothing may animate under a zooming page).
  static bool instant = false;

  static void revealNowPlaying({bool instant = false}) {
    PlayerRevealBus.instant = instant;
    tick.value++;
  }
}
