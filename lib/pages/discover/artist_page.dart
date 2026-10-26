/// An artist's page: who they are, their top songs as rows, then their
/// albums, singles and videos as shelves.
///
/// # The header
///
/// YouTube Music's own: the artist's banner full-bleed with their name over
/// it, how many listen, and play, shuffle and radio — then their bio, folded
/// to three lines. A page with only a portrait (an older or smaller artist)
/// shows that, round, over itself blurred.
///
/// "Play" queues the rows only. The carousels are things to *open*, not
/// tracks, and flattening each of them would be dozens of requests for one play
/// button — which is the same call desktop makes, and what YouTube's own play
/// button does.
library;


import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/ytmusic/parse/yt_json.dart';
import '../../services/ytmusic/yt_models.dart';
import '../../services/ytmusic/yt_playback.dart';
import '../../services/ytmusic/yt_repository.dart';
import '../../themes/ember.dart';
import 'widgets/media_widgets.dart';
import 'widgets/yt_hero.dart';
import 'widgets/yt_widgets.dart';
import 'yt_open.dart';

class YtArtistPage extends StatefulWidget {
  final ExploreItem item;

  const YtArtistPage({super.key, required this.item});

  @override
  State<YtArtistPage> createState() => _YtArtistPageState();
}

class _YtArtistPageState extends State<YtArtistPage> {
  YtArtistHeader? _header;
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
      final page = await YtMusicRepository.instance.artistPage(widget.item.id);
      if (!mounted) return;
      setState(() {
        _header = page.header;
        _shelves = page.shelves;
        _loading = false;
      });
      YtMusicRepository.instance.prefetchAudio([
        for (final shelf in page.shelves)
          for (final item in shelf.items)
            if (item.isPlayable) item.id,
      ]);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is YtException ? e.message : 'Could not load that artist.';
      });
    }
  }

  String get _name => _header?.name ?? widget.item.title;

  /// A shelf's rows as tracks, credited to this artist where a row didn't
  /// link a credit — on their own page, an unlinked credit is them.
  List<YtTrack> _tracksOf(Iterable<ExploreItem> items) => [
    for (final item in items)
      if (item.isPlayable)
        item
            .asTrack(playlistId: widget.item.id, playlistTitle: _name)
            .copyWith(artist: item.artist ?? _name),
  ];

  /// Every playable row on the page.
  List<YtTrack> get _tracks =>
      _tracksOf([for (final shelf in _shelves) ...shelf.items]);

  void _radio() {
    final seed = _header?.radio;
    final tracks = _tracks;
    if (seed != null) {
      YtPlayback.startRadio(
        context,
        YtTrack(videoId: seed.videoId, title: _name, artist: _name),
      );
    } else if (tracks.isNotEmpty) {
      YtPlayback.startRadio(context, tracks.first);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tracks = _tracks;
    final header = _header;
    return MediaPageScaffold(
      title: _name,
      heroHeight: mediaArtistHeroHeight,
      background: _ArtistHero(
        name: _name,
        banner: header?.banner,
        portrait: header?.avatar ?? widget.item.thumbnail,
        stats: [?header?.subscribers, ?header?.audience].join(' • '),
      ),
      slivers: [
          if (_loading)
            const SliverFillRemaining(hasScrollBody: false, child: YtSkeleton())
          else if (_error case final String message)
            SliverFillRemaining(
              hasScrollBody: false,
              child: YtMessage(
                icon: Icons.error_outline_rounded,
                title: "That didn't load",
                body: message,
                onRetry: _load,
              ),
            )
          else if (_shelves.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: YtMessage(
                icon: Icons.inbox_rounded,
                title: 'Nothing listed',
                body: 'YouTube has no page for this artist right now.',
                onRetry: _load,
              ),
            )
          else ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Row(
                  children: [
                    YtRoundButton(
                      icon: Icons.play_arrow_rounded,
                      tooltip: 'Play',
                      size: 58,
                      primary: true,
                      onTap: tracks.isEmpty
                          ? null
                          : () => YtPlayback.play(context, tracks, 0),
                    ),
                    const SizedBox(width: 14),
                    YtRoundButton(
                      icon: Icons.shuffle_rounded,
                      tooltip: 'Shuffle',
                      onTap: tracks.isEmpty
                          ? null
                          : () => YtPlayback.play(
                              context,
                              [...tracks]..shuffle(),
                              0,
                            ),
                    ),
                    const SizedBox(width: 14),
                    YtRoundButton(
                      icon: Icons.radio_rounded,
                      tooltip: 'Radio',
                      onTap: header?.radio == null && tracks.isEmpty
                          ? null
                          : _radio,
                    ),
                  ],
                ),
              ),
            ),
            if (header?.description case final bio?)
              SliverToBoxAdapter(child: _About(text: bio)),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 110),
              sliver: SliverList.builder(
                itemCount: _shelves.length,
                itemBuilder: (context, index) {
                  final shelf = _shelves[index];
                  final rows = shelf.items.every(
                    (item) =>
                        item.kind == ExploreKind.song ||
                        item.kind == ExploreKind.video,
                  );
                  // Rows read as a list — "Top songs" — and carousels as
                  // carousels.
                  if (rows && index == 0) {
                    return _SongList(
                      title: shelf.title,
                      tracks: _tracksOf(shelf.items),
                    );
                  }
                  return YtShelfRow(
                    shelf: shelf,
                    onOpen: (item) =>
                        openExploreItem(context, item, siblings: shelf.items),
                    onHold: (item) => showTrackActions(context, item.asTrack()),
                  );
                },
              ),
            ),
          ],
      ],
    );
  }
}

/// The banner full-bleed, the name over it.
class _ArtistHero extends StatelessWidget {
  const _ArtistHero({
    required this.name,
    required this.banner,
    required this.portrait,
    required this.stats,
  });

  final String name;
  final String? banner;
  final String? portrait;
  final String stats;

  @override
  Widget build(BuildContext context) {
    final banner = this.banner;
    final portrait = this.portrait;
    // Until the banner arrives (a 1080 px image), a wash in the artist's own
    // colour rather than a black hole at the top of the page.
    final tint = Ember.accentFor(name);
    final waiting = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(tint, Colors.black, 0.2)!, Ember.ground],
        ),
      ),
    );
    return MediaArtistHero(
      name: name,
      stats: stats,
      banner: banner == null
          ? null
          : CachedNetworkImage(
              imageUrl: banner,
              fit: BoxFit.cover,
              alignment: const Alignment(0, -0.35),
              fadeInDuration: const Duration(milliseconds: 350),
              placeholder: (_, _) => waiting,
              errorWidget: (_, _, _) => waiting,
            ),
      backdrop: portrait == null
          ? null
          : CachedNetworkImage(
              imageUrl: thumbnailAt(portrait, 160),
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => const SizedBox.shrink(),
            ),
      portrait: portrait == null
          ? null
          : YtArtwork(
              url: portrait,
              size: 132,
              circular: true,
              placeholder: Icons.person_rounded,
            ),
    );
  }
}

/// The bio, folded to three lines until asked for.
class _About extends StatefulWidget {
  const _About({required this.text});

  final String text;

  @override
  State<_About> createState() => _AboutState();
}

class _AboutState extends State<_About> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Material(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(Ember.radiusCard),
        child: InkWell(
          borderRadius: BorderRadius.circular(Ember.radiusCard),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'ABOUT',
                  style: TextStyle(
                    color: Ember.accent,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.6,
                  ),
                ),
                const SizedBox(height: 8),
                AnimatedSize(
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: Text(
                    widget.text,
                    maxLines: _open ? null : 3,
                    overflow: _open ? null : TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Ember.textSecondary,
                      fontSize: 14,
                      height: 1.45,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _open ? 'Less' : 'More',
                  style: const TextStyle(
                    color: Ember.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
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

/// The page's song rows — "Top songs" — five at a time.
class _SongList extends StatefulWidget {
  const _SongList({required this.title, required this.tracks});

  final String title;
  final List<YtTrack> tracks;

  @override
  State<_SongList> createState() => _SongListState();
}

class _SongListState extends State<_SongList> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final tracks = widget.tracks;
    final shown = _all ? tracks : tracks.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MediaListTitle(widget.title),
        AnimatedSize(
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Column(
            children: [
              for (var i = 0; i < shown.length; i++)
                YtTrackRow(
                  track: shown[i],
                  position: i + 1,
                  onTap: () => YtPlayback.play(context, tracks, i),
                  onMore: () => showTrackActions(context, shown[i]),
                ),
            ],
          ),
        ),
        if (tracks.length > 5)
          MediaShowAllButton(
            all: _all,
            total: tracks.length,
            onPressed: () => setState(() => _all = !_all),
          ),
      ],
    );
  }
}
