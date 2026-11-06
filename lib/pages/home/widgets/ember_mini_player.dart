/// The mini player that sits above the nav bar.
///
/// A separate widget from `BottomPlayer` rather than a reuse of it, for one
/// reason: `BottomPlayer` blurs its own artwork with a `BackdropFilter`, which
/// re-reads whatever is behind it and recomputes every frame. Behind it, here,
/// is a scrolling list. See the note in `themes/ember.dart`.
///
/// So this one is opaque. It also routes its transport through the *handler*
/// rather than the player — that is where the hook lives that loads a session
/// restored from disk, and going straight at the player starts nothing at all.
library;

import 'package:eq_app/navigation/app_nav.dart';
import 'package:flutter/material.dart';

import '../../../controllers/app_controller.dart';
import '../../../themes/ember.dart';
import '../../../widgets/artwork_widget.dart';
import '../../../player/remote/connect_device_picker.dart';
import '../../../player/remote/remote_mini_player.dart';
import '../../../player/remote/remote_scope.dart';
import '../../../services/connect/hype_connect.dart';

class EmberMiniPlayer extends StatelessWidget {
  const EmberMiniPlayer({super.key, required this.controller});

  final AppController controller;

  static const height = 60.0;

  @override
  Widget build(BuildContext context) {
    // Callers gate on this too, but a queue can be replaced between that check
    // and this build, and an out-of-range read throws.
    // Another device is the player: show and drive that one.
    final connect = HypeConnect.instanceOrNull;
    if (connect != null) {
      return RemoteBuilder(
        builder: (context, remote) =>
            remote != null ? RemoteMiniPlayer(remote: remote) : _local(context),
      );
    }
    return _local(context);
  }

  Widget _local(BuildContext context) {
    if (!controller.hasNowPlaying) return const SizedBox.shrink();
    final song = controller.songs[controller.songId];

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => AppNav.toPlayer(context, recordOrigin: false),
        child: SizedBox(
          height: height,
          child: Row(
            children: [
              const SizedBox(width: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: ArtworkWidget(
                  songId: song.id,
                  path: song.data,
                  width: 42,
                  height: 42,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Material transparency: a bare Text here has no
                    // DefaultTextStyle ancestor.
                    Padding(
                      padding: EdgeInsets.zero,
                      child: Material(
                        type: MaterialType.transparency,
                        child: Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Ember.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Padding(
                      padding: EdgeInsets.zero,
                      child: Material(
                        type: MaterialType.transparency,
                        child: Text(
                          song.artist ?? 'Unknown artist',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Ember.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const ConnectPickerButton(size: 20),
              _Control(
                icon: Icons.skip_previous_rounded,
                onPressed: controller.prev,
                size: 22,
              ),
              ValueListenableBuilder<bool>(
                // A fading pause counts as paused — see
                // `HypeAudioHandler.pausing`.
                valueListenable: controller.handler.pausing,
                builder: (context, pausing, _) => StreamBuilder<bool>(
                  stream: controller.handler.player.playingStream,
                  builder: (context, snapshot) {
                    final playing = (snapshot.data ?? false) && !pausing;
                    return _Control(
                      icon: playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      // Through the handler: a session restored from disk holds
                      // its queue with the player still empty, and `onBeforePlay`
                      // is what loads it.
                      onPressed: () => playing
                          ? controller.handler.pause()
                          : controller.handler.play(),
                      size: 28,
                      prominent: true,
                    );
                  },
                ),
              ),
              _Control(
                icon: Icons.skip_next_rounded,
                onPressed: controller.next,
                size: 22,
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

class _Control extends StatelessWidget {
  const _Control({
    required this.icon,
    required this.onPressed,
    this.size = 22,
    this.prominent = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final double size;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: IconButton(
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        splashRadius: 20,
        icon: Icon(
          icon,
          size: size,
          color: prominent ? Ember.textPrimary : Ember.textSecondary,
        ),
      ),
    );
  }
}
