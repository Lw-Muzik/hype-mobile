import 'dart:ui';

import 'package:eq_app/Routes/routes.dart';
import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/widgets/artwork_widget.dart';
import 'package:eq_app/widgets/globals.dart';
import 'package:flutter/material.dart';

import '../player/remote/remote_mini_player.dart';
import '../player/remote/remote_scope.dart';
import '../services/connect/hype_connect.dart';
import '../themes/ember.dart';

import '../controllers/app_controller.dart';
import '../player/player_presence.dart';
import '../player/player_ui.dart';

class BottomPlayer extends StatefulWidget {
  final AppController controller;

  /// Replaces the default tap: the shell's own bar opens the player it owns.
  final VoidCallback? onTap;

  const BottomPlayer({super.key, required this.controller, this.onTap});

  /// The bar's height, and the gap under it above the system inset.
  static const double barHeight = 64;
  static const double barGap = 8;

  @override
  State<BottomPlayer> createState() => _BottomPlayerState();
}

class _BottomPlayerState extends State<BottomPlayer>
    with TickerProviderStateMixin {
  @override
  Widget build(BuildContext context) {
    // Its own Material: the shell shows this bar over its layers, where no
    // Scaffold sits above it, and Text without one draws the debug underline.
    return Material(type: MaterialType.transparency, child: _bar(context));
  }

  Widget _bar(BuildContext context) {
    final connect = HypeConnect.instanceOrNull;
    if (connect != null) {
      return RemoteBuilder(
        builder: (context, remote) => remote != null
            ? Padding(
                padding: EdgeInsets.only(
                  left: 12,
                  right: 12,
                  bottom: MediaQuery.of(context).padding.bottom + 8,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: ColoredBox(
                    color: Ember.surface,
                    child: RemoteMiniPlayer(remote: remote),
                  ),
                ),
              )
            : _local(context),
      );
    }
    return _local(context);
  }

  Widget _local(BuildContext context) {
    if (!widget.controller.hasNowPlaying) return const SizedBox.shrink();
    final song = widget.controller.songs[widget.controller.songId];
    // The cover, blurred, under the bar's row. The image itself is filtered
    // (edges clamped) rather than through a backdrop filter: a backdrop filter
    // reads back everything drawn under the bar on every frame, which the
    // library's moving pages pay for.
    final closed = SizedBox(
      width: MediaQuery.of(context).size.width - 24,
      height: BottomPlayer.barHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: 40,
                sigmaY: 40,
                tileMode: TileMode.clamp,
              ),
              child: ArtworkWidget(
                useSaved: true,
                path: song.data,
                songId: song.id,
                width: MediaQuery.of(context).size.width - 24,
                height: BottomPlayer.barHeight,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            bottomPlayer(widget.controller, context),
          ],
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        bottom: MediaQuery.of(context).padding.bottom + BottomPlayer.barGap,
      ),
      child: widget.onTap != null
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: closed,
            )
          : AppNav.host != null
          // Settings sits above the shell: close what is above it, then show
          // the player the shell owns.
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => AppNav.toPlayerFromOverlay(context),
              child: closed,
            )
          : PlayerPresence.isOpen
          // This page was opened from the player: going back to it beats
          // opening a second one on top.
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Routes.playerTo(context),
              child: closed,
            )
          : Routes.animateTo(
              closedWidget: closed,
              openWidget: const Player(),
              routeSettings: const RouteSettings(
                name: PlayerPresence.routeName,
              ),
            ),
    );
  }
}
