import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/library_controller.dart';
import 'zoom_step_list.dart';
import 'zoom_steps.dart';

/// A [ZoomStepList] that remembers its level per list ([zoomKey]) in the
/// [LibraryController], and keeps the current step itself so pages need no
/// state of their own.
///
/// [steps] must be ordered zoomed-out first, with at most one trailing
/// [ListZoomStep]. A layout saved before zoom steps existed is a column count in
/// disguise, so it is mapped onto the ladder at the first layout, when the real
/// width is known, and stored once ([legacyZoomStep]).
class PersistedZoomList extends StatefulWidget {
  const PersistedZoomList({
    super.key,
    required this.zoomKey,
    required this.steps,
    required this.fallbackStep,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
    this.padding,
    this.listWrapper,
  });

  final String zoomKey;
  final List<ZoomStep> steps;

  /// Step used when nothing was saved for this list.
  final int fallbackStep;
  final int itemCount;
  final Widget Function(BuildContext context, int index, ZoomStep step)
  itemBuilder;
  final ScrollController? controller;
  final EdgeInsets? padding;
  final Widget Function(BuildContext, Widget list)? listWrapper;

  @override
  State<PersistedZoomList> createState() => _PersistedZoomListState();
}

class _PersistedZoomListState extends State<PersistedZoomList> {
  late final LibraryController _library = context.read<LibraryController>();
  late int _step = _library.zoomStepFor(
    widget.zoomKey,
    fallback: widget.fallbackStep,
    stepCount: widget.steps.length,
  );

  /// A pre-ladder saved extent still waiting for its first layout.
  late double? _legacy = _library.legacyZoomExtent(widget.zoomKey);

  void _migrate(BuildContext context, double width) {
    final legacy = _legacy;
    if (legacy == null || !width.isFinite) return;
    _legacy = null;
    _step = legacyZoomStep(
      widget.steps,
      legacyExtent: legacy,
      screenWidth: MediaQuery.sizeOf(context).width,
      width: width,
      padding: widget.padding ?? EdgeInsets.zero,
    );
    unawaited(_library.setZoomStep(widget.zoomKey, _step));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _migrate(context, constraints.maxWidth);
        return ZoomStepList(
          steps: widget.steps,
          step: _step,
          onStepChanged: (s) {
            setState(() => _step = s);
            unawaited(_library.setZoomStep(widget.zoomKey, s));
          },
          itemCount: widget.itemCount,
          itemBuilder: widget.itemBuilder,
          controller: widget.controller,
          padding: widget.padding,
          listWrapper: widget.listWrapper,
        );
      },
    );
  }
}
