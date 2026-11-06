/// Discover — YouTube Music's own catalog.
///
/// The landing screen is the mood and genre grid, and it is deliberately the
/// cheapest screen in the app to open: the categories come off disk first, so
/// something is painted before any network call has been made. That matters
/// more than it looks like it should, because it is one of the places the user
/// reaches in a single tap from the Places list.
///
/// The revalidation behind it is silent. If YouTube has added a genre since last
/// time the grid updates in place; if the network is down, the user still has a
/// working screen rather than a spinner.
library;

import 'package:eq_app/navigation/yt_page_keys.dart';
import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:flutter/material.dart';

import '../../services/ytmusic/yt_models.dart';
import '../../services/ytmusic/yt_repository.dart';
import 'category_page.dart';
import 'widgets/yt_widgets.dart';
import 'yt_search_page.dart';
import '../../services/radio/radio_queue.dart';

import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/motion/morph.dart';

class DiscoverView extends StatefulWidget {
  const DiscoverView({super.key});

  @override
  State<DiscoverView> createState() => _DiscoverViewState();
}

class _DiscoverViewState extends State<DiscoverView>
    with AutomaticKeepAliveClientMixin {
  List<ExploreSection> _sections = const [];
  bool _loading = true;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    // The Autoplay preference is read once, here, because this is the first
    // screen that can lead to playback.
    RadioQueue.instance.loadPreference();
  }

  Future<void> _load() async {
    final repo = YtMusicRepository.instance;

    // Disk first: paint, then check.
    final cached = await repo.cachedCategories();
    if (!mounted) return;
    if (cached != null && cached.isNotEmpty) {
      setState(() {
        _sections = cached;
        _loading = false;
        _error = null;
      });
    }

    try {
      final fresh = await repo.categories();
      if (!mounted || fresh.isEmpty) return;
      setState(() {
        _sections = fresh;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      // A failed refresh behind a cached grid is invisible on purpose — the
      // screen already works, and an error over working content is noise.
      if (_sections.isNotEmpty) return;
      setState(() {
        _loading = false;
        _error = e is YtException ? e.message : 'Could not reach YouTube.';
      });
    }
  }

  Future<void> _refresh() async {
    setState(() => _error = null);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);

    if (_loading && _sections.isEmpty) {
      return const _CategorySkeleton();
    }

    if (_sections.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          children: [
            SizedBox(height: MediaQuery.sizeOf(context).height * 0.2),
            YtMessage(
              icon: Icons.cloud_off_rounded,
              title: 'Discover is offline',
              body: _error ?? 'Check your connection and try again.',
              onRetry: _refresh,
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _SearchBar()),
          for (final section in _sections) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
                child: Text(
                  section.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  mainAxisExtent: 64,
                ),
                delegate: SliverChildBuilderDelegate(
                  childCount: section.categories.length,
                  (context, index) => _CategoryTile(
                    category: section.categories[index],
                    // Two palettes, one per section, so moods and genres read as
                    // different families without needing per-category colours
                    // that YouTube doesn't give us.
                    seed: _sections.indexOf(section) * 7 + index,
                  ),
                ),
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 90)),
        ],
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: MorphTag(
        tag: itemTag(const LibraryPageKey('ytSearch')),
        child: GestureDetector(
          onTap: () => AppNav.openPage(
            context,
            const YtSearchPage(),
            key: const LibraryPageKey('ytSearch'),
            morphFrom: itemTag(const LibraryPageKey('ytSearch')),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.search_rounded,
                  size: 20,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                ),
                const SizedBox(width: 10),
                Text(
                  'Songs, artists, albums…',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
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

class _CategoryTile extends StatelessWidget {
  final ExploreCategory category;
  final int seed;

  const _CategoryTile({required this.category, required this.seed});

  /// A fixed palette walked by index. YouTube states no colour for a category,
  /// so inventing a stable one per position beats a grid of identical grey
  /// rectangles — and being deterministic means a category doesn't change
  /// colour between launches.
  static const _palette = [
    Color(0xFF1E6F5C),
    Color(0xFF8E3B46),
    Color(0xFF2C4A7C),
    Color(0xFF7A5C2E),
    Color(0xFF4A2E6B),
    Color(0xFF2E6B63),
    Color(0xFF6B2E4A),
  ];

  @override
  Widget build(BuildContext context) {
    final colour = _palette[seed % _palette.length];
    return Material(
      color: colour.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: MorphTag(
        tag: itemTag(ytCategoryKey(category)),
        child: InkWell(
          onTap: () => AppNav.openPage(
            context,
            YtCategoryPage(category: category),
            key: ytCategoryKey(category),
            morphFrom: itemTag(ytCategoryKey(category)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                category.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  height: 1.2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CategorySkeleton extends StatelessWidget {
  const _CategorySkeleton();

  @override
  Widget build(BuildContext context) {
    final block = Theme.of(context).colorScheme.surfaceContainerHighest;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 68, 12, 12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        mainAxisExtent: 64,
      ),
      itemCount: 12,
      itemBuilder: (_, _) => DecoratedBox(
        decoration: BoxDecoration(
          color: block,
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }
}
