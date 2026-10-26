/// The pieces every Discover screen is built from.
///
/// # The performance rules these encode
///
/// * **Thumbnails are requested at the size they are drawn.** YouTube serves art
///   through a resizing CDN, so a 56 px row asks for 56 px rather than
///   downloading the 544 px original and throwing 90% of it away. On a shelf of
///   fifty tiles that is the difference between a smooth scroll and a stuttering
///   one.
/// * **Every list is `builder`-based with a fixed extent**, so a hundred-track
///   playlist mounts the dozen rows on screen rather than a hundred.
/// * **Shelves scroll horizontally with a bounded cache extent**, so scrolling
///   down the page doesn't quietly decode fifty images per shelf.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../services/ytmusic/parse/yt_json.dart';
import '../../../services/ytmusic/yt_models.dart';
import 'media_widgets.dart';

/// Artwork, fetched at the size it will be drawn.
class YtArtwork extends StatelessWidget {
  final String? url;
  final double size;
  final bool circular;
  final IconData placeholder;

  const YtArtwork({
    super.key,
    required this.url,
    required this.size,
    this.circular = false,
    this.placeholder = Icons.music_note_rounded,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = mediaArtRadius(size, circular: circular);
    final devicePixels =
        (size * MediaQuery.devicePixelRatioOf(context)).round();

    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: radius,
      ),
      child: Icon(
        placeholder,
        size: size * 0.4,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
      ),
    );

    final source = url;
    if (source == null || source.isEmpty) return fallback;

    return ClipRRect(
      borderRadius: radius,
      child: CachedNetworkImage(
        imageUrl: thumbnailAt(source, devicePixels),
        width: size,
        height: size,
        fit: BoxFit.cover,
        // Decoding at the drawn size keeps the image cache in kilobytes rather
        // than megabytes — the single biggest memory lever on these screens.
        memCacheWidth: devicePixels,
        memCacheHeight: devicePixels,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}

/// One card in a shelf: art above two lines of text.
class YtTile extends StatelessWidget {
  final ExploreItem item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double width;

  const YtTile({
    super.key,
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.width = 132,
  });

  @override
  Widget build(BuildContext context) {
    final circular = item.kind == ExploreKind.artist;
    return MediaTile(
      width: width,
      circular: circular,
      title: item.title,
      subtitle: item.subtitle,
      onTap: onTap,
      onLongPress: onLongPress,
      art: YtArtwork(
        url: item.thumbnail,
        size: width,
        circular: circular,
        placeholder: switch (item.kind) {
          ExploreKind.artist => Icons.person_rounded,
          ExploreKind.album => Icons.album_rounded,
          ExploreKind.playlist => Icons.queue_music_rounded,
          ExploreKind.video => Icons.play_circle_outline_rounded,
          ExploreKind.song => Icons.music_note_rounded,
        },
      ),
      badge: item.kind == ExploreKind.video
          ? Positioned(
              right: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(
                  Icons.videocam_rounded,
                  size: 13,
                  color: Colors.white,
                ),
              ),
            )
          : null,
    );
  }
}

/// One horizontal shelf — a title and a row of cards.
class YtShelfRow extends StatelessWidget {
  final ExploreShelf shelf;
  final void Function(ExploreItem item) onOpen;

  /// Held on a tile that names something playable — the shelf equivalent of a
  /// row's overflow, since a carousel card has no room for one.
  final void Function(ExploreItem item)? onHold;

  const YtShelfRow({
    super.key,
    required this.shelf,
    required this.onOpen,
    this.onHold,
  });

  @override
  Widget build(BuildContext context) {
    return MediaShelf(
      title: shelf.title,
      count: shelf.items.length,
      builder: (context, index, width) {
        final item = shelf.items[index];
        return YtTile(
          item: item,
          width: width,
          onTap: () => onOpen(item),
          onLongPress: onHold != null && item.isPlayable
              ? () => onHold!(item)
              : null,
        );
      },
    );
  }
}

/// One track in a list.
class YtTrackRow extends StatelessWidget {
  final YtTrack track;
  final VoidCallback onTap;
  final VoidCallback? onMore;
  final int? position;

  /// Fixed so the lists that hold these can use `itemExtent` — the difference
  /// between a hundred-track playlist laying out a dozen rows and all hundred.
  static const height = MediaTrackRow.height;

  const YtTrackRow({
    super.key,
    required this.track,
    required this.onTap,
    this.onMore,
    this.position,
  });

  @override
  Widget build(BuildContext context) {
    return MediaTrackRow(
      art: YtArtwork(url: track.thumbnail, size: 44),
      title: track.title,
      byline: _byline,
      duration: mediaClock(track.durationSecs),
      hasVideo: track.hasVideo,
      dimmed: !track.isAvailable,
      position: position,
      onTap: onTap,
      onMore: onMore,
    );
  }

  String? get _byline {
    final artist = track.artist;
    final album = track.album;
    if (artist != null && album != null && album != artist) {
      return '$artist • $album';
    }
    return artist ?? album;
  }
}

/// The one message widget every screen uses for empty, error and offline.
class YtMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? body;
  final VoidCallback? onRetry;

  const YtMessage({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 40,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (body != null) ...[
              const SizedBox(height: 6),
              Text(
                body!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 18),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The stand-in a track list shows while it loads.
///
/// Rows at the real [YtTrackRow.height], so the list doesn't jump when the
/// tracks arrive.
class YtTrackSkeleton extends StatelessWidget {
  final int rows;

  const YtTrackSkeleton({super.key, this.rows = 8});

  @override
  Widget build(BuildContext context) {
    final block = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      itemCount: rows,
      itemExtent: YtTrackRow.height,
      itemBuilder: (context, index) => Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: block,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  // Uneven widths read as text rather than as a bar chart.
                  width: 120.0 + (index % 3) * 46,
                  height: 11,
                  decoration: BoxDecoration(
                    color: block,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: 80.0 + (index % 4) * 24,
                  height: 9,
                  decoration: BoxDecoration(
                    color: block.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The shimmer stand-in a screen shows while its first load is in flight.
class YtSkeleton extends StatelessWidget {
  final int shelves;

  const YtSkeleton({super.key, this.shelves = 3});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final block = theme.colorScheme.surfaceContainerHighest;
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: shelves,
      itemBuilder: (context, _) => Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 120,
              height: 14,
              decoration: BoxDecoration(
                color: block,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 168,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: 4,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (_, _) => Container(
                  width: 132,
                  height: 132,
                  decoration: BoxDecoration(
                    color: block,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
