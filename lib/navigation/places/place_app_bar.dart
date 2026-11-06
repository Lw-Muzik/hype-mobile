/// The app bar every place wears. Same look as the shell's own bar (menu or
/// back on the left, title in the display face, search on the right); a place
/// page adds its own actions between the title and search.
library;

import 'package:eq_app/Themes/app_fonts.dart';
import 'package:eq_app/navigation/motion/morph.dart';
import 'package:flutter/material.dart';

import '../../themes/ember.dart';

class PlaceAppBar extends StatelessWidget implements PreferredSizeWidget {
  const PlaceAppBar({
    super.key,
    required this.title,
    this.titleMorphTag,
    this.onBack,
    this.onMenu,
    required this.onSearch,
    this.actions = const [],
    this.fancy = false,
    this.menuKey,
    this.searchKey,
  });

  final String title;

  /// When set, the title is a morph target for the matching Places row.
  final Object? titleMorphTag;

  /// When non-null a back chevron replaces the hamburger.
  final VoidCallback? onBack;
  final VoidCallback? onMenu;
  final VoidCallback onSearch;
  final List<Widget> actions;

  /// Transparent bar (the app's fancy background mode).
  final bool fancy;

  /// Optional keys so the shell can keep pointing its walkthrough at them.
  final Key? menuKey;
  final Key? searchKey;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    Widget titleText = Text(
      title,
      style: AppFonts.displayStyle(
        fontSize: 22,
        letterSpacing: -0.5,
        color: Ember.textPrimary,
      ),
    );
    if (titleMorphTag != null) {
      titleText = MorphTag(tag: titleMorphTag!, child: titleText);
    }

    return AppBar(
      backgroundColor: fancy ? Colors.transparent : Ember.ground,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      titleSpacing: Ember.gutter,
      leading: onBack != null
          ? IconButton(
              key: menuKey,
              tooltip: 'Back',
              icon: const Icon(Icons.chevron_left_rounded, size: 28),
              color: Ember.textPrimary,
              onPressed: onBack,
            )
          : IconButton(
              key: menuKey,
              icon: const Icon(Icons.menu_rounded),
              color: Ember.textPrimary,
              onPressed: onMenu,
            ),
      title: titleText,
      actions: [
        ...actions,
        IconButton(
          key: searchKey,
          icon: const Icon(Icons.search_rounded, size: 22),
          color: Ember.textPrimary,
          onPressed: onSearch,
        ),
        const SizedBox(width: 8),
      ],
    );
  }
}
