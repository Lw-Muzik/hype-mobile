import '/exports/exports.dart';
import '../helpers/index.dart';
import '../controllers/app_controller.dart';
import '../services/player_reveal_bus.dart';
import 'artwork_widget.dart';
import '../widgets/alphabet_fast_scroll.dart';
import '../widgets/pinch_zoom_grid.dart';
import '../themes/ember.dart';

/// Fixed row height so the songs list can use `itemExtent` (O(1) scroll math
/// for very large libraries) and the alphabet rail can jump precisely.
const double kSongTileExtent = 68.0;

// ---------------------------------------------------------------------------
// SongTile — list-mode row
// ---------------------------------------------------------------------------

class SongTile extends StatelessWidget {
  final SongModel song;
  final int index;
  final bool isCurrentTrack;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onOptions;
  final bool showTrackNumber;
  final bool showDuration;
  final bool showOptionsIcon;

  const SongTile({
    super.key,
    required this.song,
    required this.index,
    required this.isCurrentTrack,
    required this.onTap,
    this.onLongPress,
    this.onOptions,
    this.showTrackNumber = true,
    this.showDuration = true,
    this.showOptionsIcon = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = theme.colorScheme.primary;
    final onSurface = theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Ember.gutter - 6),
      child: Material(
        // The playing row is tinted rather than outlined: a border on one row
        // of a long list reads as a selection the user made, and this is the
        // app telling them where they are.
        color: isCurrentTrack
            ? accentColor.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(Ember.radiusTile),
        child: InkWell(
          borderRadius: BorderRadius.circular(Ember.radiusTile),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: Row(
              children: [
                // Accent bar for active track
                Container(
                  width: 3,
                  height: 40,
                  decoration: BoxDecoration(
                    color: isCurrentTrack ? accentColor : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 4),
                // Track number
                if (showTrackNumber)
                  SizedBox(
                    width: 22,
                    child: isCurrentTrack
                        ? Icon(
                            Icons.bar_chart_rounded,
                            color: accentColor,
                            size: 18,
                          )
                        : Text(
                            '${index + 1}',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: onSurface.withValues(alpha: 0.35),
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                  ),
                if (showTrackNumber) const SizedBox(width: 8),
                // Artwork
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: ArtworkWidget(
                        width: 48,
                        height: 48,
                        size: 200,
                        quality: 50,
                        songId: song.id,
                        type: ArtworkType.AUDIO,
                        path: song.data,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                // Title + Artist
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCurrentTrack ? accentColor : onSurface,
                          fontSize: 15,
                          fontWeight: isCurrentTrack
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        song.artist ?? 'Unknown artist',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCurrentTrack
                              ? accentColor.withValues(alpha: 0.6)
                              : onSurface.withValues(alpha: 0.5),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Duration
                if (showDuration)
                  Text(
                    formatTime(Duration(milliseconds: song.duration ?? 0)),
                    style: TextStyle(
                      color: onSurface.withValues(alpha: 0.35),
                      fontSize: 12,
                    ),
                  ),
                // Options button — now actually opens the track menu
                // (was a decorative icon with no tap handler).
                if (showOptionsIcon)
                  InkWell(
                    onTap: onOptions ?? onLongPress,
                    customBorder: const CircleBorder(),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.more_vert_rounded,
                        size: 18,
                        color: onSurface.withValues(alpha: 0.5),
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

// ---------------------------------------------------------------------------
// _SongGridTile — grid-mode card
// ---------------------------------------------------------------------------

class _SongGridTile extends StatelessWidget {
  final SongModel song;
  final bool isCurrentTrack;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _SongGridTile({
    required this.song,
    required this.isCurrentTrack,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = theme.colorScheme.primary;
    final onSurface = theme.colorScheme.onSurface;

    return Material(
      color: isCurrentTrack
          ? accentColor.withValues(alpha: 0.10)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Artwork
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ArtworkWidget(
                        size: 400,
                        quality: 80,
                        songId: song.id,
                        type: ArtworkType.AUDIO,
                        path: song.data,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      if (isCurrentTrack)
                        Positioned(
                          bottom: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: accentColor,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.bar_chart_rounded,
                              color: Colors.white,
                              size: 14,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            // Title
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isCurrentTrack ? accentColor : onSurface,
                  fontSize: 13,
                  fontWeight: isCurrentTrack
                      ? FontWeight.w600
                      : FontWeight.w500,
                ),
              ),
            ),
            // Artist
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                song.artist ?? 'Unknown',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isCurrentTrack
                      ? accentColor.withValues(alpha: 0.6)
                      : onSurface.withValues(alpha: 0.45),
                  fontSize: 11,
                ),
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// SongListView — pinch-to-zoom between list and responsive grid
// ---------------------------------------------------------------------------

class SongListView extends StatelessWidget {
  final List<SongModel> songs;
  final AppController controller;
  final bool showTrackNumbers;
  final bool showDuration;
  final bool showOptionsIcon;
  final void Function(SongModel song, int index)? onTap;
  final void Function(SongModel song, int index)? onLongPress;
  final void Function(SongModel song, int index)? onOptions;

  /// First-letter accessor that turns on the alphabet fast-scroll rail. Supply
  /// it only when the list is in an alphabetical order (title/artist); leave
  /// null for date/duration sorts or short detail lists.
  final String Function(SongModel song)? fastScrollKey;

  const SongListView({
    super.key,
    required this.songs,
    required this.controller,
    this.showTrackNumbers = false,
    this.showDuration = true,
    this.showOptionsIcon = true,
    this.onTap,
    this.onLongPress,
    this.onOptions,
    this.fastScrollKey,
  });

  @override
  Widget build(BuildContext context) {
    if (songs.isEmpty) {
      return Center(
        child: Text(
          "No songs found",
          style: Theme.of(context).textTheme.titleMedium,
        ),
      );
    }

    return Consumer<AppController>(
      builder: (context, ctrl, _) {
        return PinchZoomGrid(
          initialExtent: ctrl.songGridExtent,
          minExtent: 80.0,
          maxExtent: 300.0,
          listModeExtent: 260.0,
          onExtentChanged: (e) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              ctrl.songGridExtent = e;
            });
          },
          listBuilder: _buildList(context),
          gridBuilder: (extent) => _buildGrid(context, extent),
        );
      },
    );
  }

  Widget _buildList(BuildContext context) {
    final currentSongId =
        controller.songId >= 0 && controller.songId < controller.songs.length
        ? controller.songs[controller.songId].id
        : -1;

    return AlphabetFastScroll(
      itemCount: songs.length,
      itemExtent: kSongTileExtent,
      // After a slide-down player dismissal, land this list on the
      // now-playing row.
      revealTick: PlayerRevealBus.tick,
      revealIndex: () {
        final current =
            controller.songId >= 0 &&
                controller.songId < controller.songs.length
            ? controller.songs[controller.songId].id
            : -1;
        if (current == -1) return -1;
        return songs.indexWhere((s) => s.id == current);
      },
      sectionKeyOf: fastScrollKey == null
          ? null
          : (index) => fastScrollKey!(songs[index]),
      itemBuilder: (context, index) {
        final song = songs[index];
        final isCurrent = song.id == currentSongId;
        return SongTile(
          song: song,
          index: index,
          isCurrentTrack: isCurrent,
          showTrackNumber: showTrackNumbers,
          showDuration: showDuration,
          showOptionsIcon: showOptionsIcon,
          onTap: () => onTap?.call(song, index),
          onLongPress: onLongPress != null
              ? () => onLongPress!.call(song, index)
              : null,
          onOptions: onOptions != null
              ? () => onOptions!.call(song, index)
              : null,
        );
      },
    );
  }

  Widget _buildGrid(BuildContext context, double extent) {
    final currentSongId =
        controller.songId >= 0 && controller.songId < controller.songs.length
        ? controller.songs[controller.songId].id
        : -1;

    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: extent,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 0.78,
      ),
      itemCount: songs.length,
      itemBuilder: (context, index) {
        final song = songs[index];
        final isCurrent = song.id == currentSongId;
        return _SongGridTile(
          song: song,
          isCurrentTrack: isCurrent,
          onTap: () => onTap?.call(song, index),
          onLongPress: onLongPress != null
              ? () => onLongPress!.call(song, index)
              : null,
        );
      },
    );
  }
}
