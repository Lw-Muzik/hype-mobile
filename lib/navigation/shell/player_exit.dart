/// One way for the player to leave itself, shell or not.
library;

import 'package:flutter/widgets.dart';

import '../app_nav.dart';

/// Sends the player away to the library. Under the shell this runs the
/// player-to-library move; without one it pops the player's route as before.
void leavePlayer(BuildContext context) {
  if (AppNav.host != null) {
    AppNav.toLibrary(context);
  } else {
    Navigator.of(context).maybePop();
  }
}
