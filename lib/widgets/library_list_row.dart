import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../themes/ember.dart';
import 'artwork_widget.dart';

/// Fixed row height so list-mode category pages can use `itemExtent` (cheap
/// scroll math, same as the songs list).
const double kLibraryRowExtent = 72.0;

/// Shared list-mode row for the Albums / Artists / Genres / Folders tabs —
/// what a grid card collapses into when the user pinches in far enough to
/// cross into list mode (zoom levels per category). Deliberately NO Hero
/// here: the matching grid card carries the Hero, and during the pinch
/// crossfade both layouts are mounted at once, so duplicate tags would
/// collide.
class LibraryListRow extends StatelessWidget {
  const LibraryListRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onLongPress,
    this.artworkId,
    this.artworkType = ArtworkType.ALBUM,
    this.artworkName = '',
    this.artworkPath = '',
    this.circular = false,
    this.fallbackIcon = Icons.album_rounded,
    this.leadingColor,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  final int? artworkId;
  final ArtworkType artworkType;
  final String artworkName;
  final String artworkPath;

  /// Round leading (artists) vs rounded-square (albums/genres/folders).
  final bool circular;
  final IconData fallbackIcon;
  final Color? leadingColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    // Ember's tile radius, so a row's leading art and a grid card's art are
    // visibly the same object at two sizes rather than two different shapes.
    final radius = circular
        ? BorderRadius.circular(28)
        : BorderRadius.circular(Ember.radiusTile);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Ember.gutter - 6),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(Ember.radiusTile),
        child: InkWell(
          borderRadius: BorderRadius.circular(Ember.radiusTile),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: radius,
                  child: SizedBox(
                    width: 52,
                    height: 52,
                    child: artworkId != null
                        ? ArtworkWidget(
                            width: 52,
                            height: 52,
                            songId: artworkId!,
                            type: artworkType,
                            other: artworkName,
                            path: artworkPath,
                            borderRadius: radius,
                          )
                        : Container(
                            color:
                                (leadingColor ??
                                        theme
                                            .colorScheme
                                            .surfaceContainerHighest)
                                    .withValues(alpha: 0.6),
                            child: Icon(
                              fallbackIcon,
                              size: 26,
                              color: onSurface.withValues(alpha: 0.45),
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: onSurface.withValues(alpha: 0.45),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: onSurface.withValues(alpha: 0.3),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
