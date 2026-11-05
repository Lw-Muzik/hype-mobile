import 'dart:async';

import 'package:flutter/material.dart';

/// Holds the level Hype's own volume panel shows and when it hides again.
class VolumePanelController extends ChangeNotifier {
  static const hideAfter = Duration(milliseconds: 1500);

  Timer? _timer;
  double _level = 0;
  bool _visible = false;

  double get level => _level;
  bool get visible => _visible;

  /// Shows the panel at [level] (0…1) and restarts the 1.5 s hide timer.
  void show(double level) {
    _level = level.clamp(0.0, 1.0);
    _visible = true;
    _timer?.cancel();
    _timer = Timer(hideAfter, () {
      _visible = false;
      notifyListeners();
    });
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Hype's volume overlay: a small pill with the level, top centre.
/// Place it in a [Stack] over the app.
class VolumePanelOverlay extends StatelessWidget {
  const VolumePanelOverlay({super.key, required this.controller});

  final VolumePanelController controller;

  static const panelKey = ValueKey('volume-panel');

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final pct = (controller.level * 100).round();
        return Positioned.fill(
          child: IgnorePointer(
            child: SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: controller.visible
                        ? Container(
                            key: panelKey,
                            width: 220,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(24),
                              boxShadow: const [
                                BoxShadow(
                                  blurRadius: 12,
                                  color: Color(0x33000000),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  controller.level <= 0
                                      ? Icons.volume_off_rounded
                                      : Icons.volume_up_rounded,
                                  size: 20,
                                  color: scheme.primary,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: LinearProgressIndicator(
                                      value: controller.level,
                                      minHeight: 6,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  '$pct%',
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelMedium,
                                ),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
