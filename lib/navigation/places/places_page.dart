/// The Library: every top-level destination, one block each in a grid.
///
/// The blocks are plain callbacks. Opening a place is the shell's business (it
/// owns the transition), so this page never navigates by itself.
library;

import 'dart:io';

import 'package:eq_app/navigation/motion/morph.dart';
import 'package:flutter/material.dart';

import '../../config/app_config.dart';
import '../../themes/app_fonts.dart';
import '../../themes/ember.dart';
import 'place_app_bar.dart';

enum PlaceId {
  forYou,
  songs,
  albums,
  artists,
  genres,
  folders,
  playlists,
  youtube,
  cloud,
}

/// The YouTube place's name: the full service name only in direct builds
/// (store builds keep it generic, see [AppConfig.directBuild]).
String youtubePlaceLabel({required bool directBuild}) =>
    directBuild ? 'YouTube Music' : 'Discover';

extension PlaceLabel on PlaceId {
  String get label => switch (this) {
    PlaceId.forYou => 'For You',
    PlaceId.songs => 'Songs',
    PlaceId.albums => 'Albums',
    PlaceId.artists => 'Artists',
    PlaceId.genres => 'Genres',
    PlaceId.folders => 'Folders',
    PlaceId.playlists => 'Playlists',
    PlaceId.youtube => youtubePlaceLabel(directBuild: AppConfig.directBuild),
    PlaceId.cloud => 'Cloud',
  };

  /// The icon this destination already wears today (library chips and the
  /// bottom bar).
  IconData get icon => switch (this) {
    PlaceId.forYou => Icons.home_rounded,
    PlaceId.songs => Icons.music_note_rounded,
    PlaceId.albums => Icons.album_rounded,
    PlaceId.artists => Icons.person_rounded,
    PlaceId.genres => Icons.category_rounded,
    PlaceId.folders => Icons.folder_rounded,
    PlaceId.playlists => Icons.queue_music_rounded,
    PlaceId.youtube => Icons.explore_rounded,
    PlaceId.cloud => Icons.cloud_rounded,
  };

  /// Each block's own colour: a wash across it, its icon chip and the large
  /// faint icon in its corner. One family (same saturation and lightness),
  /// different hues, readable on the dark ground.
  Color get tint => switch (this) {
    PlaceId.forYou => Ember.accent,
    PlaceId.songs => const Color(0xFFFB7185),
    PlaceId.albums => const Color(0xFFA78BFA),
    PlaceId.artists => const Color(0xFF2DD4BF),
    PlaceId.genres => const Color(0xFFE879F9),
    PlaceId.folders => const Color(0xFF818CF8),
    PlaceId.playlists => const Color(0xFF4ADE80),
    PlaceId.youtube => const Color(0xFFFB923C),
    PlaceId.cloud => const Color(0xFF38BDF8),
  };

  /// One short line under the name: what is behind the block.
  String get blurb => switch (this) {
    PlaceId.forYou => 'Mixes and picks',
    PlaceId.songs => 'Every track',
    PlaceId.albums => 'By record',
    PlaceId.artists => 'By who made it',
    PlaceId.genres => 'By sound',
    PlaceId.folders => 'On this device',
    PlaceId.playlists => 'Yours and saved',
    PlaceId.youtube => 'Charts, moods, new music',
    PlaceId.cloud => 'Drive and Dropbox',
  };

  /// Morph tag of this place's block; the page's title answers with the
  /// header tag of the place's page key.
  String get morphTag => 'place:$name';
}

/// Places in display order. Folders only exist where the file system is
/// browsable, i.e. not on iOS.
List<PlaceId> visiblePlaces({required bool isIos}) => [
  for (final id in PlaceId.values)
    if (!(isIos && id == PlaceId.folders)) id,
];

/// Wraps a block so the page it opens grows out of it and its title morphs
/// from it.
Widget placeMorphTag(Object tag, Widget child) =>
    MorphTag(tag: tag, child: child);

class PlacesPage extends StatelessWidget {
  const PlacesPage({
    super.key,
    required this.onOpen,
    required this.onMenu,
    required this.onSearch,
    this.fancy = false,
    this.isIos,
    this.menuKey,
    this.searchKey,
  });

  final void Function(BuildContext context, PlaceId id) onOpen;
  final VoidCallback onMenu;
  final VoidCallback onSearch;

  /// Transparent chrome over the app background, as the shell's fancy mode.
  final bool fancy;

  /// Overrides the platform check (tests).
  final bool? isIos;

  /// Keys on the bar's buttons so the first-run walkthrough can point at them.
  final Key? menuKey;
  final Key? searchKey;

  @override
  Widget build(BuildContext context) {
    final places = visiblePlaces(isIos: isIos ?? Platform.isIOS);
    return Scaffold(
      backgroundColor: fancy ? Colors.transparent : Ember.ground,
      appBar: PlaceAppBar(
        title: kLibraryTitle,
        onMenu: onMenu,
        onSearch: onSearch,
        fancy: fancy,
        menuKey: menuKey,
        searchKey: searchKey,
      ),
      body: GridView.builder(
        padding: const EdgeInsets.fromLTRB(
          Ember.gutter - 4,
          8,
          Ember.gutter - 4,
          24,
        ),
        // Two columns on a phone, more where there is room (a tablet shows
        // four), each block a little wider than tall.
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: kPlaceTileMaxExtent,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.3,
        ),
        itemCount: places.length,
        itemBuilder: (context, i) => PlaceTile(
          id: places[i],
          fancy: fancy,
          onTap: () => onOpen(context, places[i]),
        ),
      ),
    );
  }
}

/// The root page's title.
const String kLibraryTitle = 'Library';

/// The widest a block may get before another column fits.
const double kPlaceTileMaxExtent = 220.0;

/// One destination: its colour washed across a dark block, an icon chip at the
/// top, the name and a short line at the bottom, and the icon again, large and
/// faint, in the corner. The whole block is the morph tag, so the page it
/// opens grows out of it.
class PlaceTile extends StatelessWidget {
  const PlaceTile({
    super.key,
    required this.id,
    required this.onTap,
    this.fancy = false,
  });

  final PlaceId id;
  final VoidCallback onTap;

  /// Translucent over the app's cover backdrop, as the shell's fancy mode.
  final bool fancy;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(Ember.radiusTile + 4));
    final tint = id.tint;
    final base = fancy ? Ember.surface.withValues(alpha: 0.55) : Ember.surface;
    return placeMorphTag(
      id.morphTag,
      Material(
        color: base,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          splashColor: tint.withValues(alpha: 0.18),
          highlightColor: tint.withValues(alpha: 0.08),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  tint.withValues(alpha: 0.26),
                  tint.withValues(alpha: 0.05),
                ],
              ),
            ),
            child: Stack(
              children: [
                Positioned(
                  right: -14,
                  bottom: -16,
                  child: Icon(
                    id.icon,
                    size: 96,
                    color: tint.withValues(alpha: 0.12),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: tint.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(
                            Ember.radiusControl,
                          ),
                        ),
                        child: Icon(id.icon, size: 21, color: tint),
                      ),
                      const Spacer(),
                      Text(
                        id.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.displayStyle(
                          fontSize: 17,
                          color: Ember.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        id.blurb,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Ember.textPrimary.withValues(alpha: 0.55),
                        ),
                      ),
                    ],
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
