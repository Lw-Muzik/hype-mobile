/// Presentational pieces shared by every album, playlist and artist page in the
/// app — the YouTube Music ones and the ones for the music on the phone.
///
/// Nothing here knows where its data comes from: artwork arrives as a widget,
/// text as strings, actions as callbacks. That is the point. The person
/// opening an album from their library and the person opening one from
/// YouTube Music should be looking at the same page, so the page is built once
/// and each source only says what goes in it.
///
/// The design (see `opened_list_page.dart` for the full account): the cover is
/// the page, drawn large and again behind everything, blurred; the title; who
/// made it; what it is and how long; three round buttons; then the tracks.
library;

import 'dart:math' as math;
import 'dart:ui' show FontFeature, ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../../themes/ember.dart';
import '../../../Themes/app_fonts.dart';
import 'yt_hero.dart';

/// Corner radius of artwork drawn at [size]: tiles are rounder than rows.
BorderRadius mediaArtRadius(double size, {bool circular = false}) =>
    circular
    ? BorderRadius.circular(size)
    : BorderRadius.circular(size < 80 ? 6 : 10);

/// The square a piece of artwork shows when it has no picture.
class MediaArtFallback extends StatelessWidget {
  const MediaArtFallback({
    super.key,
    required this.size,
    this.circular = false,
    this.icon = Icons.music_note_rounded,
  });

  final double size;
  final bool circular;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: mediaArtRadius(size, circular: circular),
      ),
      child: Icon(
        icon,
        size: size * 0.4,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
      ),
    );
  }
}

/// How tall a list page's header is — the cover, the facts and the buttons.
double mediaListHeroHeight(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  final top = MediaQuery.paddingOf(context).top;
  return mediaWide(width) ? top + 360 : top + math.min(width * 0.62, 260) + 300;
}

/// How tall an artist page's header is.
double mediaArtistHeroHeight(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  return MediaQuery.paddingOf(context).top + math.min(width * 0.82, 440);
}

/// Wide enough (a tablet, a phone on its side) for the cover to sit beside the
/// facts rather than above them.
bool mediaWide(double width) => width >= 680;

/// The frame every one of these pages shares: a pinned app bar over the
/// header, whose title fades in once the header has scrolled away, then
/// [slivers].
class MediaPageScaffold extends StatefulWidget {
  const MediaPageScaffold({
    super.key,
    required this.title,
    required this.heroHeight,
    required this.background,
    required this.slivers,
    this.controller,
    this.bottomBar,
  });

  final String title;
  final double Function(BuildContext context) heroHeight;

  /// The header, drawn behind the app bar and parallaxed away.
  final Widget background;
  final List<Widget> slivers;

  /// Supply one to scroll the page from outside; otherwise the page owns it.
  final ScrollController? controller;

  /// Pinned under the page — the mini player on the library pages.
  final Widget? bottomBar;

  @override
  State<MediaPageScaffold> createState() => _MediaPageScaffoldState();
}

class _MediaPageScaffoldState extends State<MediaPageScaffold> {
  ScrollController? _own;
  bool _collapsed = false;

  ScrollController get _scroll => widget.controller ?? (_own ??= ScrollController());

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant MediaPageScaffold old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      (old.controller ?? _own)?.removeListener(_onScroll);
      _scroll.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _own?.dispose();
    super.dispose();
  }

  void _onScroll() {
    final collapsed =
        _scroll.offset > widget.heroHeight(context) - kToolbarHeight - 24;
    if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ember.ground,
      bottomNavigationBar: widget.bottomBar,
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: widget.heroHeight(context),
            backgroundColor: Ember.ground,
            surfaceTintColor: Colors.transparent,
            foregroundColor: Ember.textPrimary,
            leading: const MediaBackButton(),
            title: AnimatedOpacity(
              duration: const Duration(milliseconds: 180),
              opacity: _collapsed ? 1 : 0,
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            flexibleSpace: FlexibleSpaceBar(
              collapseMode: CollapseMode.parallax,
              background: widget.background,
            ),
          ),
          ...widget.slivers,
        ],
      ),
    );
  }
}

class MediaBackButton extends StatelessWidget {
  const MediaBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.black.withValues(alpha: 0.28),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => Navigator.of(context).maybePop(),
          child: const SizedBox.square(
            dimension: 40,
            child: Icon(
              Icons.arrow_back_ios_new_rounded,
              size: 18,
              color: Ember.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

/// A list page's header: the cover large, and again blurred behind, then the
/// facts and the three buttons.
class MediaListHero extends StatelessWidget {
  const MediaListHero({
    super.key,
    required this.kicker,
    required this.title,
    required this.art,
    required this.actions,
    this.backdrop,
    this.credits,
    this.facts,
  });

  /// "ALBUM", "PLAYLIST", "EP".
  final String kicker;
  final String title;

  /// The cover at the size the header gives it.
  final Widget Function(double size) art;

  /// The same cover, to be blurred behind everything. Null: plain ground.
  final Widget? backdrop;

  /// Who made it — usually [MediaCredits].
  final Widget? credits;

  /// "2019 • 12 songs • 42 minutes".
  final String? facts;

  /// Left to right: the extra action, the main one (play), shuffle.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = mediaWide(width);
    final top = MediaQuery.paddingOf(context).top;
    final coverSize = wide ? 240.0 : math.min(width * 0.62, 260.0);

    final details = Column(
      crossAxisAlignment: wide
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          kicker,
          style: const TextStyle(
            color: Ember.accent,
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.6,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: wide ? TextAlign.start : TextAlign.center,
          style: AppFonts.displayStyle(
            color: Ember.textPrimary,
            fontSize: 26,
            height: 1.15,
            letterSpacing: -0.5,
          ),
        ),
        if (credits != null) ...[const SizedBox(height: 10), credits!],
        if (facts != null && facts!.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            facts!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Ember.textSecondary, fontSize: 13),
          ),
        ],
        const SizedBox(height: 18),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0) const SizedBox(width: 18),
              actions[i],
            ],
          ],
        ),
      ],
    );

    final cover = Container(
      width: coverSize,
      height: coverSize,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x99000000),
            blurRadius: 40,
            offset: Offset(0, 18),
          ),
        ],
      ),
      child: art(coverSize),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        if (backdrop != null) MediaBlurredBackdrop(sigma: 48, child: backdrop!),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Ember.ground.withValues(alpha: 0.25),
                Ember.ground.withValues(alpha: 0.55),
                Ember.ground,
              ],
              stops: const [0, 0.55, 1],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(24, top + kToolbarHeight, 24, 20),
          child: wide
              ? Row(
                  children: [
                    cover,
                    const SizedBox(width: 28),
                    Expanded(child: details),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [cover, const SizedBox(height: 20), details],
                ),
        ),
      ],
    );
  }
}

/// A cover smeared into colour: a still image, so `ImageFiltered` rather than a
/// live backdrop filter.
class MediaBlurredBackdrop extends StatelessWidget {
  const MediaBlurredBackdrop({
    super.key,
    required this.child,
    this.sigma = 48,
    this.opacity = 0.6,
  });

  final Widget child;
  final double sigma;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: Opacity(opacity: opacity, child: child),
    );
  }
}

/// Who made it, as a wrapped row of [MediaCreditChip]s.
class MediaCredits extends StatelessWidget {
  const MediaCredits({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.center,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 6,
    runSpacing: 6,
    children: children,
  );
}

/// A credit that links nowhere: plain text.
class MediaCreditText extends StatelessWidget {
  const MediaCreditText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      color: Ember.textPrimary,
      fontSize: 15,
      fontWeight: FontWeight.w600,
    ),
  );
}

/// One credited artist: a link to their page, with their portrait if there is
/// one. A null [onTap] is an artist with no page to go to.
class MediaCreditChip extends StatelessWidget {
  const MediaCreditChip({
    super.key,
    required this.name,
    this.portrait,
    this.onTap,
  });

  final String name;

  /// A 24 px circle.
  final Widget? portrait;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.08),
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(portrait == null ? 12 : 4, 4, 12, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (portrait != null) ...[portrait!, const SizedBox(width: 8)],
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Ember.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 2),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: Ember.textTertiary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A soft gold wash behind the row that is playing.
class MediaHighlight extends StatelessWidget {
  const MediaHighlight({super.key, required this.current, required this.child});

  final bool current;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: current
            ? Ember.accent.withValues(alpha: 0.09)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }
}

/// "3:07" from a length in seconds; null when there is none to show.
String? mediaClock(num? seconds) {
  if (seconds == null || seconds <= 0) return null;
  final total = seconds.round();
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
}

/// "1 hr 12 min" / "42 minutes" — how long a whole list runs.
String mediaTotalLength(num seconds) {
  final minutes = (seconds / 60).round();
  if (minutes < 1) return '${seconds.round()} seconds';
  if (minutes < 60) return minutes == 1 ? '1 minute' : '$minutes minutes';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h hr' : '$h hr $m min';
}

/// A track on an album: its number — or, playing, the bars — then its title,
/// any guests, and its length.
class MediaAlbumRow extends StatelessWidget {
  const MediaAlbumRow({
    super.key,
    required this.number,
    required this.title,
    required this.current,
    required this.playing,
    required this.onTap,
    required this.onMore,
    this.byline,
    this.duration,
    this.hasVideo = false,
    this.dimmed = false,
    this.onLongPress,
  });

  final int number;
  final String title;
  final String? byline;
  final String? duration;
  final bool hasVideo;
  final bool dimmed;
  final bool current;

  /// Whether the player is playing — the bars stand still while paused.
  final Stream<bool> playing;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    return MediaHighlight(
      current: current,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: dimmed ? null : onTap,
        onLongPress: dimmed ? null : onLongPress,
        child: Opacity(
          opacity: dimmed ? 0.4 : 1,
          child: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 34,
                  child: Center(
                    child: current
                        ? StreamBuilder<bool>(
                            stream: playing,
                            builder: (context, snap) =>
                                NowPlayingBars(playing: snap.data ?? true),
                          )
                        : Text(
                            '$number',
                            style: TextStyle(
                              color: Ember.textTertiary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: current ? Ember.accent : Ember.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (byline != null)
                        Text(
                          byline!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Ember.textSecondary,
                            fontSize: 12.5,
                          ),
                        ),
                    ],
                  ),
                ),
                if (hasVideo)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(
                      Icons.videocam_rounded,
                      size: 15,
                      color: Ember.textTertiary,
                    ),
                  ),
                if (duration != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Text(
                      duration!,
                      style: TextStyle(
                        color: Ember.textTertiary,
                        fontSize: 12.5,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                IconButton(
                  icon: const Icon(Icons.more_vert_rounded, size: 19),
                  color: Ember.textSecondary,
                  visualDensity: VisualDensity.compact,
                  onPressed: onMore,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One track in a list, with its own art.
class MediaTrackRow extends StatelessWidget {
  const MediaTrackRow({
    super.key,
    required this.art,
    required this.title,
    required this.onTap,
    this.byline,
    this.duration,
    this.hasVideo = false,
    this.dimmed = false,
    this.position,
    this.onMore,
    this.onLongPress,
  });

  /// A 44 px square.
  final Widget art;
  final String title;
  final String? byline;
  final String? duration;
  final bool hasVideo;
  final bool dimmed;
  final int? position;
  final VoidCallback onTap;
  final VoidCallback? onMore;
  final VoidCallback? onLongPress;

  /// Fixed so the lists that hold these can use `itemExtent` — the difference
  /// between a hundred-track playlist laying out a dozen rows and all hundred.
  static const height = 60.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: height,
      child: InkWell(
        onTap: dimmed ? null : onTap,
        onLongPress: dimmed ? null : onLongPress,
        child: Opacity(
          opacity: dimmed ? 0.4 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                if (position case final index?) ...[
                  SizedBox(
                    width: 24,
                    child: Text(
                      '$index',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.4,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
                art,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (byline != null)
                        Text(
                          byline!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.55,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (hasVideo)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(
                      Icons.videocam_rounded,
                      size: 15,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                if (duration != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      duration!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                  ),
                if (onMore != null)
                  IconButton(
                    icon: const Icon(Icons.more_vert_rounded, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: onMore,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One card in a shelf: art above two lines of text.
class MediaTile extends StatelessWidget {
  const MediaTile({
    super.key,
    required this.art,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.onLongPress,
    this.width = 132,
    this.circular = false,
    this.badge,
  });

  /// A square of [width].
  final Widget art;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double width;
  final bool circular;

  /// Laid over the art's corner, e.g. the video mark.
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(children: [art, ?badge]),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: circular ? TextAlign.center : TextAlign.start,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
            if (subtitle case final subtitle?)
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: circular ? TextAlign.center : TextAlign.start,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A shelf's title in the style of the artist page's headings.
class MediaShelfTitle extends StatelessWidget {
  const MediaShelfTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
    child: Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    ),
  );
}

/// The heading above a list of rows — "TOP SONGS".
class MediaListTitle extends StatelessWidget {
  const MediaListTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
    child: Text(title.toUpperCase(), style: Ember.shelfTitle(context)),
  );
}

/// "Show all 24" / "Show less".
class MediaShowAllButton extends StatelessWidget {
  const MediaShowAllButton({
    super.key,
    required this.all,
    required this.total,
    required this.onPressed,
  });

  final bool all;
  final int total;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(foregroundColor: Ember.textPrimary),
    child: Text(all ? 'Show less' : 'Show all $total'),
  );
}

/// One horizontal shelf — a title and a row of cards.
class MediaShelf extends StatelessWidget {
  const MediaShelf({
    super.key,
    required this.title,
    required this.count,
    required this.builder,
  });

  final String title;
  final int count;
  final Widget Function(BuildContext context, int index, double width) builder;

  static const tileWidth = 132.0;
  static const rowHeight = 196.0;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MediaShelfTitle(title),
        SizedBox(
          height: rowHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            // Bounded so scrolling the page doesn't decode a shelf's worth of
            // images that were never on screen.
            scrollCacheExtent: const ScrollCacheExtent.pixels(tileWidth * 2),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            itemCount: count,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) => builder(context, index, tileWidth),
          ),
        ),
      ],
    );
  }
}

/// An artist page's header: the banner full-bleed, or a round portrait over
/// itself blurred, with the name over it.
class MediaArtistHero extends StatelessWidget {
  const MediaArtistHero({
    super.key,
    required this.name,
    required this.stats,
    this.banner,
    this.backdrop,
    this.portrait,
    this.washWhenEmpty = false,
  });

  final String name;
  final String stats;

  /// With neither a banner nor a backdrop: draw the artist's colour wash
  /// instead of nothing.
  final bool washWhenEmpty;

  /// A wide image drawn full-bleed (`BoxFit.cover`).
  final Widget? banner;

  /// The portrait, to be blurred behind everything when there is no banner.
  final Widget? backdrop;

  /// The portrait itself, a 132 px circle, shown when there is no banner.
  final Widget? portrait;

  @override
  Widget build(BuildContext context) {
    // Until the banner arrives, a wash in the artist's own colour rather than a
    // black hole at the top of the page.
    final tint = Ember.accentFor(name);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (banner != null)
          banner!
        else if (backdrop != null)
          MediaBlurredBackdrop(sigma: 40, opacity: 0.55, child: backdrop!)
        else if (washWhenEmpty)
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color.lerp(tint, Colors.black, 0.2)!, Ember.ground],
              ),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.35),
                Colors.transparent,
                Ember.ground.withValues(alpha: 0.6),
                Ember.ground,
              ],
              stops: const [0, 0.3, 0.72, 1],
            ),
          ),
        ),
        if (banner == null && portrait != null)
          Align(
            alignment: const Alignment(0, -0.1),
            child: Container(
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Color(0x99000000),
                    blurRadius: 30,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: portrait,
            ),
          ),
        Positioned(
          left: 20,
          right: 20,
          bottom: 18,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.displayStyle(
                  color: Ember.textPrimary,
                  fontSize: 36,
                  height: 1.05,
                  letterSpacing: -1,
                  shadows: const [
                    Shadow(color: Color(0x66000000), blurRadius: 18),
                  ],
                ),
              ),
              if (stats.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  stats,
                  style: TextStyle(
                    color: Ember.textPrimary.withValues(alpha: 0.78),
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
