/// The horizontal rails the Home surface is made of.
///
/// One header treatment and three card shapes. Kept together because the thing
/// that makes a page of shelves read as one page is that its shelves agree —
/// the same gutter, the same header, the same rail height — and that agreement
/// is easiest to keep when it is written once.
library;

import '../../../models/track_extras.dart';

import 'package:eq_app/Themes/app_fonts.dart';
import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';

import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/motion/morph.dart';

import '../../../data/library_repository.dart';
import '../../../services/mixes/daily_mix_service.dart';
import '../../../themes/ember.dart';
import '../../../widgets/artwork_widget.dart';

/// Header shared by every shelf: small, wide-tracked, quiet.
///
/// The shelf's *contents* are the loud part of a music page. A header that
/// competes with them makes a page that is all labels.
class ShelfHeader extends StatelessWidget {
  const ShelfHeader({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Ember.gutter, 0, Ember.gutter, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Ember.shelfTitle(context)),
          if (subtitle case final text?) ...[
            const SizedBox(height: 2),
            Text(
              text,
              style: TextStyle(color: Ember.textTertiary, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

/// A rail of daily mixes.
///
/// The cards carry a colour derived from the mix's name rather than from
/// artwork: a mix has no single cover, and a colour that arrives when an image
/// finishes decoding is a card that flickers into its own identity.
class MixShelf extends StatelessWidget {
  const MixShelf({
    super.key,
    required this.title,
    required this.mixes,
    required this.onTap,
    this.onSave,
  });

  final String title;
  final List<ResolvedMix> mixes;
  final void Function(ResolvedMix) onTap;

  /// Long-press keeps a mix as a playlist. A long press rather than a visible
  /// button because the card's job is to be tapped and played; keeping one is
  /// the rarer intent and does not deserve to compete for the same space.
  final void Function(ResolvedMix)? onSave;

  static const _cardSize = 168.0;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Ember.shelfGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShelfHeader(title: title),
          SizedBox(
            height: _cardSize + 46,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Ember.gutter),
              itemCount: mixes.length,
              itemBuilder: (context, index) {
                final mix = mixes[index];
                final accent = Ember.accentFor(mix.name);
                return Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: GestureDetector(
                    onTap: () => onTap(mix),
                    onLongPress: onSave == null ? null : () => onSave!(mix),
                    child: SizedBox(
                      width: _cardSize,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: _cardSize,
                            height: _cardSize,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(
                                Ember.radiusCard,
                              ),
                              boxShadow: Ember.lift,
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  accent,
                                  Color.lerp(accent, Ember.ground, 0.55)!,
                                ],
                              ),
                            ),
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Icon(
                                  Icons.auto_awesome_rounded,
                                  size: 18,
                                  color: Colors.white.withValues(alpha: 0.75),
                                ),
                                Text(
                                  mix.descriptor.toUpperCase(),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppFonts.displayStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    height: 1.1,
                                    letterSpacing: -0.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            mix.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Ember.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Row(
                            children: [
                              Text(
                                '${mix.length} tracks',
                                style: TextStyle(
                                  color: Ember.textTertiary,
                                  fontSize: 11,
                                ),
                              ),
                              // Said plainly, because playing this one will use
                              // data and the user should know before they tap.
                              if (mix.hasRemote) ...[
                                const SizedBox(width: 5),
                                Icon(
                                  Icons.cloud_outlined,
                                  size: 11,
                                  color: Ember.textTertiary,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  'streams',
                                  style: TextStyle(
                                    color: Ember.textTertiary,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A rail of the user's own playlists.
class PlaylistShelf extends StatelessWidget {
  const PlaylistShelf({
    super.key,
    required this.title,
    required this.playlists,
    required this.onTap,
  });

  final String title;
  final List<PlaylistSummary> playlists;
  final void Function(PlaylistSummary) onTap;

  static const _cardSize = 132.0;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Ember.shelfGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShelfHeader(title: title),
          SizedBox(
            height: _cardSize + 46,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Ember.gutter),
              itemCount: playlists.length,
              itemBuilder: (context, index) {
                final playlist = playlists[index];
                return Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: MorphTag(
                    tag: itemTag(LibraryPageKey('mix', {'id': playlist.id})),
                    child: GestureDetector(
                      onTap: () => onTap(playlist),
                      child: SizedBox(
                        width: _cardSize,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: _cardSize,
                              height: _cardSize,
                              decoration: BoxDecoration(
                                color: Ember.surfaceHigh,
                                borderRadius: BorderRadius.circular(
                                  Ember.radiusTile,
                                ),
                                border: Border.all(color: Ember.outline),
                              ),
                              child: Icon(
                                Icons.queue_music_rounded,
                                size: 34,
                                color: Ember.accent,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              playlist.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Ember.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '${playlist.trackCount} tracks',
                              style: TextStyle(
                                color: Ember.textTertiary,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A rail of individual tracks.
class SongShelf extends StatelessWidget {
  const SongShelf({
    super.key,
    required this.title,
    required this.songs,
    required this.onTap,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final List<SongModel> songs;
  final void Function(SongModel song, List<SongModel> list) onTap;

  static const _cardSize = 132.0;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Ember.shelfGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShelfHeader(title: title, subtitle: subtitle),
          SizedBox(
            height: _cardSize + 46,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Ember.gutter),
              itemCount: songs.length,
              itemBuilder: (context, index) {
                final song = songs[index];
                return Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: GestureDetector(
                    onTap: () => onTap(song, songs),
                    child: SizedBox(
                      width: _cardSize,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          MorphTag(
                            tag: trackTag(song.ytVideoId ?? song.id),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(
                                Ember.radiusTile,
                              ),
                              child: ArtworkWidget(
                                songId: song.id,
                                path: song.data,
                                type: ArtworkType.AUDIO,
                                width: _cardSize,
                                height: _cardSize,
                                borderRadius: BorderRadius.circular(
                                  Ember.radiusTile,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Ember.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            song.artist ?? 'Unknown',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Ember.textTertiary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
