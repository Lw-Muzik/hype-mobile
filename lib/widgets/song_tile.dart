import '/exports/exports.dart';
import '../models/track_extras.dart';
import '../helpers/index.dart';
import '../controllers/app_controller.dart';
import '../services/player_reveal_bus.dart';
import 'artwork_widget.dart';
import '../widgets/alphabet_fast_scroll.dart';
import 'package:eq_app/navigation/zoom/persisted_zoom_list.dart';
import 'package:eq_app/navigation/zoom/zoom_steps.dart';
import '../themes/ember.dart';
import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/motion/morph.dart';

/// Fixed row height so the songs list can use `itemExtent` (O(1) scroll math
/// for very large libraries) and the alphabet rail can jump precisely.
const double kSongTileExtent = 68.0;

/// Pinch-zoom ladder of every song list, zoomed-out first: three grids, then
/// the list. With the grid's 12 dp side padding and 10 dp gaps the grids show
/// 4, 3 and 2 columns on every phone from 360 to 430 dp, so each pinch step
/// changes the layout; the middle one is the three-column grid the old pinch
/// widget settled on.
const List<ZoomStep> kSongZoomSteps = [
  ZoomStep.grid(
    maxTileExtent: 96.0,
    childAspectRatio: 0.78,
    spacing: 10,
    padding: _kSongGridPadding,
  ),
  ZoomStep.grid(
    maxTileExtent: 140.0,
    childAspectRatio: 0.78,
    spacing: 10,
    padding: _kSongGridPadding,
  ),
  ZoomStep.grid(
    maxTileExtent: 200.0,
    childAspectRatio: 0.78,
    spacing: 10,
    padding: _kSongGridPadding,
  ),
  // No padding of its own: the list keeps inheriting the safe-area insets.
  ZoomStep.list(rowExtent: kSongTileExtent),
];

const EdgeInsets _kSongGridPadding = EdgeInsets.symmetric(
  horizontal: 12,
  vertical: 4,
);

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
                  child: MorphTag(
                    tag: trackTag(song.ytVideoId ?? song.id),
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
                child: MorphTag(
                  tag: trackTag(song.ytVideoId ?? song.id),
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

  /// Which saved zoom level this list uses (`songs`, `genre_songs`,
  /// `folder_songs`, `cloud_folder`, `search`).
  final String zoomKey;

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
    this.zoomKey = 'songs',
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

    return _ScrollHolder(
      builder: (context, scroll) => Consumer<AppController>(
        builder: (context, ctrl, _) {
          return PersistedZoomList(
            zoomKey: zoomKey,
            steps: kSongZoomSteps,
            // Song lists open as a list.
            fallbackStep: kSongZoomSteps.length - 1,
            itemCount: songs.length,
            controller: scroll,
            listWrapper: (context, list) => _buildRail(context, scroll, list),
            itemBuilder: (context, index, step) => step is ListZoomStep
                ? _buildRow(context, index)
                : _buildTile(context, index),
          );
        },
      ),
    );
  }

  int get _currentSongId =>
      controller.songId >= 0 && controller.songId < controller.songs.length
      ? controller.songs[controller.songId].id
      : -1;

  Widget _buildRail(BuildContext context, ScrollController scroll, Widget list) {
    return AlphabetFastScroll(
      itemCount: songs.length,
      itemExtent: kSongTileExtent,
      controller: scroll,
      // After a slide-down player dismissal, land this list on the
      // now-playing row.
      revealTick: PlayerRevealBus.tick,
      revealIndex: () {
        final current = _currentSongId;
        if (current == -1) return -1;
        return songs.indexWhere((s) => s.id == current);
      },
      sectionKeyOf: fastScrollKey == null
          ? null
          : (index) => fastScrollKey!(songs[index]),
      child: list,
    );
  }

  Widget _buildRow(BuildContext context, int index) {
    final song = songs[index];
    final isCurrent = song.id == _currentSongId;
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
  }

  Widget _buildTile(BuildContext context, int index) {
    final song = songs[index];
    return _SongGridTile(
      song: song,
      isCurrentTrack: song.id == _currentSongId,
      onTap: () => onTap?.call(song, index),
      onLongPress: onLongPress != null
          ? () => onLongPress!.call(song, index)
          : null,
    );
  }
}

/// Owns the scroll controller the zoom list and its alphabet rail share.
class _ScrollHolder extends StatefulWidget {
  const _ScrollHolder({required this.builder});
  final Widget Function(BuildContext context, ScrollController scroll) builder;

  @override
  State<_ScrollHolder> createState() => _ScrollHolderState();
}

class _ScrollHolderState extends State<_ScrollHolder> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _scroll);
}
