import 'package:flutter/widgets.dart';

/// Draws [child] from a picture of itself while [snapshotting] is true.
///
/// A moving page is rasterised once and only the picture is scaled and faded
/// each frame, instead of re-drawing every cover, clip and gradient in it. At
/// rest ([snapshotting] false) the live widget is drawn, so nothing looks
/// different and live content (art, waveform) resumes. Where a platform view
/// is present the snapshot quietly falls back to the live widget.
class LayerSnapshot extends StatefulWidget {
  const LayerSnapshot({
    super.key,
    required this.snapshotting,
    required this.child,
  });

  final bool snapshotting;
  final Widget child;

  @override
  State<LayerSnapshot> createState() => _LayerSnapshotState();
}

class _LayerSnapshotState extends State<LayerSnapshot> {
  late final SnapshotController _controller = SnapshotController(
    allowSnapshotting: widget.snapshotting,
  );
  LayerSnapshotScope? _outer;

  /// Throws the picture away so the next frame takes a fresh one; any layer
  /// snapshotting this one is refreshed too.
  void _invalidate() {
    _controller.clear();
    _outer?.invalidate();
  }

  @override
  void didUpdateWidget(LayerSnapshot old) {
    super.didUpdateWidget(old);
    _controller.allowSnapshotting = widget.snapshotting;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _outer = LayerSnapshotScope.maybeOf(context);
    return LayerSnapshotScope(
      invalidate: _invalidate,
      child: SnapshotWidget(
        controller: _controller,
        mode: SnapshotMode.permissive,
        child: widget.child,
      ),
    );
  }
}

/// Lets a widget inside a [LayerSnapshot] ask for its picture to be retaken
/// after the widget changes how it paints.
class LayerSnapshotScope extends InheritedWidget {
  const LayerSnapshotScope({
    super.key,
    required this.invalidate,
    required super.child,
  });

  final VoidCallback invalidate;

  /// The nearest scope, without depending on it (it never changes).
  static LayerSnapshotScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<LayerSnapshotScope>();

  @override
  bool updateShouldNotify(LayerSnapshotScope old) => false;
}
