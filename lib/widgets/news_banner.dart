import 'dart:async';

import 'package:flutter/material.dart';

import '../Themes/app_fonts.dart';
import '../Themes/ember.dart';

/// Handle to a banner on screen.
class NewsBannerHandle {
  NewsBannerHandle._(this._dismiss);
  final VoidCallback _dismiss;
  void dismiss() => _dismiss();
}

/// Slides a [NewsBanner] in at the top of [overlay]; it hides itself after
/// [duration] (6 s) or when tapped (after calling [onTap]).
NewsBannerHandle presentNewsBanner(
  OverlayState overlay, {
  required String title,
  required String body,
  required VoidCallback onTap,
  Duration duration = const Duration(seconds: 6),
}) {
  late final OverlayEntry entry;
  Timer? timer;
  var gone = false;
  void dismiss() {
    if (gone) return;
    gone = true;
    timer?.cancel();
    entry.remove();
  }

  entry = OverlayEntry(
    builder: (_) => Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: NewsBanner(
            title: title,
            body: body,
            onTap: () {
              dismiss();
              onTap();
            },
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  timer = Timer(duration, dismiss);
  return NewsBannerHandle._(dismiss);
}

/// In-app banner for a news push: gold accent rule, Clash Display title,
/// Satoshi body, on the Ember surface.
class NewsBanner extends StatelessWidget {
  const NewsBanner({
    super.key,
    required this.title,
    required this.body,
    required this.onTap,
  });

  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          decoration: BoxDecoration(
            color: Ember.surfaceHigh,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Ember.outline),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8)),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 4, color: Ember.accent),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (title.isNotEmpty)
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppFonts.displayStyle(
                                fontSize: 17, color: Ember.textPrimary),
                          ),
                        if (body.isNotEmpty) ...[
                          if (title.isNotEmpty) const SizedBox(height: 3),
                          Text(
                            body,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: AppFonts.body,
                              fontSize: 14,
                              height: 1.35,
                              color: Ember.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
