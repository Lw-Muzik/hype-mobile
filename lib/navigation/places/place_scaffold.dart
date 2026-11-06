/// One place, full page: the shared app bar over the place's own body.
library;

import 'package:flutter/material.dart';

import '../../pages/albums.dart';
import '../../pages/artists.dart';
import '../../pages/cloud/cloud_view.dart';
import '../../pages/discover/discover_view.dart';
import '../../pages/folders.dart';
import '../../pages/genres.dart';
import '../../pages/home/home_surface.dart';
import '../../pages/play_list_view.dart';
import '../../pages/songs.dart';
import '../../themes/ember.dart';
import '../library/library_tags.dart';
import '../library_page_key.dart';
import 'place_app_bar.dart';
import 'places_page.dart';

/// The existing, unchanged widget behind each place.
Widget placeBody(PlaceId id) => switch (id) {
  PlaceId.forYou => const HomeSurface(),
  PlaceId.songs => const AllSongs(),
  PlaceId.albums => const Albums(),
  PlaceId.artists => const Artists(),
  PlaceId.genres => const Genres(),
  PlaceId.folders => const Folders(),
  PlaceId.playlists => const PlayListView(),
  PlaceId.youtube => const DiscoverView(),
  PlaceId.cloud => const CloudView(),
};

class PlaceScaffold extends StatelessWidget {
  const PlaceScaffold({
    super.key,
    required this.id,
    required this.onBack,
    required this.onMenu,
    required this.onSearch,
    this.fancy = false,
    this.body,
  });

  final PlaceId id;
  final VoidCallback onBack;
  final VoidCallback onMenu;
  final VoidCallback onSearch;
  final bool fancy;

  /// Replaces [placeBody] (tests, or a shell that keeps bodies alive itself).
  final Widget? body;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: fancy ? Colors.transparent : Ember.ground,
      appBar: PlaceAppBar(
        title: id.label,
        titleMorphTag: headerTag(LibraryPageKey.place(id.name)),
        onBack: onBack,
        onMenu: onMenu,
        onSearch: onSearch,
        fancy: fancy,
      ),
      body: body ?? placeBody(id),
    );
  }
}
