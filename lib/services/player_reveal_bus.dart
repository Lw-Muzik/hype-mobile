import 'package:flutter/foundation.dart';

/// Fired when the player is dismissed with the slide-down gesture. Song lists
/// listen and scroll themselves to the now-playing row, so the gesture lands
/// the user back "where the current song is" instead of
/// wherever the list happened to be scrolled.
class PlayerRevealBus {
  PlayerRevealBus._();

  static final ValueNotifier<int> tick = ValueNotifier<int>(0);

  static void revealNowPlaying() => tick.value++;
}
