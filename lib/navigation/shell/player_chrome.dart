/// The player's controls band, hidden and shown on the container clock.
///
/// The shell owns that clock. A player built outside the shell has no scope
/// above it, so [PlayerChrome] then draws its child untouched.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../motion_spec.dart';

/// Carries the container clock (0 = chrome shown, 1 = hidden) down to the
/// player.
class PlayerChromeScope extends InheritedWidget {
  const PlayerChromeScope({
    super.key,
    required this.hidden,
    required super.child,
  });

  final ValueListenable<double> hidden;

  static ValueListenable<double>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerChromeScope>()?.hidden;

  @override
  bool updateShouldNotify(PlayerChromeScope oldWidget) =>
      hidden != oldWidget.hidden;
}

/// Fades [child] out and shrinks it to [MotionSpec.chromeHideScale] about its
/// own centre as the container clock goes from 0 to 1.
class PlayerChrome extends StatelessWidget {
  const PlayerChrome({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final hidden = PlayerChromeScope.maybeOf(context);
    if (hidden == null) return child;
    // One tree shape at every value, so nothing under it is ever remounted:
    // at rest the opacity is 1 and the scale 1.
    return ValueListenableBuilder<double>(
      valueListenable: hidden,
      child: child,
      builder: (context, h, child) {
        final scale = 1 - (1 - MotionSpec.chromeHideScale) * h;
        return IgnorePointer(
          ignoring: h >= 1,
          child: Opacity(
            opacity: (1 - h).clamp(0.0, 1.0),
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
    );
  }
}
