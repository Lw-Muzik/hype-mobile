/// Turns a finger pulling the player's cover down into a [SceneController]
/// drag: nothing happens until the finger passes the slop, then progress is the
/// travel beyond it over the art box side.
library;

import '../motion_spec.dart';
import 'scene_controller.dart';

class CoverDrag {
  CoverDrag(this.scene, {required this.fallbackExtent});

  final SceneController scene;

  /// Used when the screen size is not known.
  final double Function() fallbackExtent;

  double _startY = 0;
  bool _active = false;
  bool _blocked = false;
  double _extent = 360;

  bool get isActive => _active;

  void start(double globalY) {
    _startY = globalY;
    _active = false;
    _blocked = false;
  }

  /// A move already running (or a drag that never got hold) leaves the cover
  /// alone: the gesture is ignored until the next touch.
  void _begin() {
    _extent = scene.artBoxSide() ?? fallbackExtent();
    _active = scene.beginPlayerDrag();
    _blocked = !_active;
  }

  void update(double globalY) {
    if (_blocked) return;
    final dy = globalY - _startY;
    if (!_active) {
      if (dy <= MotionSpec.dragSlop) return;
      _begin();
    }
    scene.dragPlayer((dy - MotionSpec.dragSlop) / _extent);
  }

  /// Returns true when the gesture was a downward pull (so it must not fall
  /// through to opening the lyrics).
  bool end(double velocityY) {
    if (!_active && !_blocked && velocityY >= MotionSpec.flingVelocity) {
      // A fling too short to cross the slop still counts.
      _begin();
    }
    if (_active) {
      _active = false;
      scene.endPlayerDrag(velocityY / _extent, extent: _extent);
      return true;
    }
    return velocityY > 200;
  }
}
