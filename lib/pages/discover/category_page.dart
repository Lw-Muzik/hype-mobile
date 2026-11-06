/// One mood or genre, opened: its shelves of songs, playlists, videos and
/// albums.
///
/// Measured on the African genre page, this is five shelves holding 226 items,
/// arriving as 1.9 MB of JSON. All of that decoding and walking happened in the
/// worker isolate before this screen was ever built — what it receives is a
/// short list of value objects.
library;

import 'package:flutter/material.dart';

import '../../services/ytmusic/yt_models.dart';
import '../../services/ytmusic/yt_repository.dart';
import 'widgets/yt_widgets.dart';
import 'yt_open.dart';

import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/motion/morph.dart';
import 'package:eq_app/navigation/yt_page_keys.dart';

class YtCategoryPage extends StatefulWidget {
  final ExploreCategory category;

  const YtCategoryPage({super.key, required this.category});

  @override
  State<YtCategoryPage> createState() => _YtCategoryPageState();
}

class _YtCategoryPageState extends State<YtCategoryPage> {
  List<ExploreShelf> _shelves = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final shelves = await YtMusicRepository.instance.categoryPage(
        widget.category,
      );
      if (!mounted) return;
      setState(() {
        _shelves = shelves;
        _loading = false;
      });
      YtMusicRepository.instance.prefetchAudio([
        for (final shelf in shelves)
          for (final item in shelf.items)
            if (item.isPlayable) item.id,
      ]);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is YtException ? e.message : 'Could not load that category.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: MorphTag(
          tag: headerTag(ytCategoryKey(widget.category)),
          child: Text(widget.category.title),
        ),
        titleTextStyle: Theme.of(context).textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
      body: switch ((_loading, _error, _shelves.isEmpty)) {
        (true, _, _) => const YtSkeleton(),
        (_, final String message, _) => YtMessage(
          icon: Icons.error_outline_rounded,
          title: "That didn't load",
          body: message,
          onRetry: _load,
        ),
        (_, _, true) => YtMessage(
          icon: Icons.inbox_rounded,
          title: 'Nothing here yet',
          body:
              'YouTube has nothing listed under '
              '"${widget.category.title}" right now.',
          onRetry: _load,
        ),
        _ => ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 90),
          itemCount: _shelves.length,
          itemBuilder: (context, index) => YtShelfRow(
            shelf: _shelves[index],
            onOpen: (item) =>
                openExploreItem(context, item, siblings: _shelves[index].items),
            onHold: (item) => showTrackActions(context, item.asTrack()),
          ),
        ),
      },
    );
  }
}
