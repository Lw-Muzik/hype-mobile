/// The Places list: every top-level destination, one row each.
///
/// The rows are plain callbacks. Opening a place is the shell's business (it
/// owns the transition), so this page never navigates by itself.
library;

import 'dart:io';

import 'package:eq_app/navigation/motion/morph.dart';
import 'package:flutter/material.dart';

import '../../config/app_config.dart';
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

  /// Morph tag of this place's list row; the page's title answers with the
  /// header tag of the place's page key.
  String get morphTag => 'place:$name';
}

/// Places in display order. Folders only exist where the file system is
/// browsable, i.e. not on iOS.
List<PlaceId> visiblePlaces({required bool isIos}) => [
  for (final id in PlaceId.values)
    if (!(isIos && id == PlaceId.folders)) id,
];

/// Wraps a row's icon and title so the page it opens can morph from them.
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
        title: 'Places',
        onMenu: onMenu,
        onSearch: onSearch,
        fancy: fancy,
        menuKey: menuKey,
        searchKey: searchKey,
      ),
      body: ListView.builder(
        padding: const EdgeInsets.only(top: 4),
        itemExtent: kPlaceRowExtent,
        itemCount: places.length,
        itemBuilder: (context, i) =>
            PlaceRow(id: places[i], onTap: () => onOpen(context, places[i])),
      ),
    );
  }
}

/// Same height as a library list row, so Places and the lists it opens share
/// one rhythm.
const double kPlaceRowExtent = 72.0;

class PlaceRow extends StatelessWidget {
  const PlaceRow({super.key, required this.id, required this.onTap});

  final PlaceId id;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(Ember.radiusTile));
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Ember.gutter - 6),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            child: Row(
              children: [
                Expanded(
                  // Tag only the icon and title, so a flight starts from them
                  // and not from a stretched whole-row stand-in.
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: placeMorphTag(
                      id.morphTag,
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest
                                  .withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(
                                Ember.radiusTile,
                              ),
                            ),
                            child: Icon(
                              id.icon,
                              size: 26,
                              color: onSurface.withValues(alpha: 0.45),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Flexible(
                            child: Text(
                              id.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
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
