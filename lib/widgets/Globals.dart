import 'package:flutter/material.dart';

import '../controllers/app_controller.dart';
import 'artwork_widget.dart';

Widget bottomPlayer(AppController controller, BuildContext context) {
  // Callers gate on `hasNowPlaying`, but a queue can be replaced between that
  // check and this build, and an out-of-range read here throws on a surface the
  // user is only looking at.
  if (!controller.hasNowPlaying) return const SizedBox.shrink();
  final song = controller.songs[controller.songId];

  return Container(
    height: 64,
    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45)),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Row(
      children: [
        // Artwork thumbnail
        ArtworkWidget(
          songId: song.id,
          path: song.data,
          width: 42,
          height: 42,
          borderRadius: BorderRadius.circular(10),
        ),
        const SizedBox(width: 12),

        // Song info
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                song.title,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                song.artist ?? 'Unknown artist',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(width: 4),

        // Controls
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ControlButton(
              icon: Icons.skip_previous_rounded,
              onPressed: controller.prev,
              size: 22,
            ),
            ValueListenableBuilder<bool>(
              // A fading pause counts as paused — see `HypeAudioHandler.pausing`.
              valueListenable: controller.handler.pausing,
              builder: (context, pausing, _) => StreamBuilder<bool>(
                stream: controller.handler.player.playingStream,
                builder: (context, snapshot) {
                  final isPlaying = (snapshot.data ?? false) && !pausing;
                  return _ControlButton(
                    icon: isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    // Through the handler, not straight at the player. The handler
                    // is where `onBeforePlay` lives, and a session restored from
                    // disk holds its queue with the player still empty — so going
                    // straight to the player here started nothing at all.
                    onPressed: () => isPlaying
                        ? controller.handler.pause()
                        : controller.handler.play(),
                    size: 28,
                    prominent: true,
                  );
                },
              ),
            ),
            _ControlButton(
              icon: Icons.skip_next_rounded,
              onPressed: controller.next,
              size: 22,
            ),
          ],
        ),
      ],
    ),
  );
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final double size;
  final bool prominent;

  const _ControlButton({
    required this.icon,
    required this.onPressed,
    this.size = 22,
    this.prominent = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: IconButton(
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        icon: Icon(
          icon,
          size: size,
          color: prominent ? Colors.white : Colors.white.withValues(alpha: 0.8),
        ),
        splashRadius: 20,
      ),
    );
  }
}
