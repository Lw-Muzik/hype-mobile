/// The video that follows you around the app.
///
/// # Why this exists
///
/// Leaving the player screen should not end the video any more than it ends the
/// song. The audio never stops — it is the same player inside the same
/// background service — but the picture has nowhere to be drawn once the player
/// screen is gone. This gives it somewhere: a small window over whatever the
/// user browses to next, draggable out of the way and dismissible.
///
/// # It appears only when the user asks for it
///
/// Mounted for the whole life of the app, but hidden until someone taps the
/// pop-out control on the player's video card. It used to decide for itself —
/// show whenever the current track is a video and no other host has claimed
/// the surface — and that reasoning had a failure mode with no floor: when the
/// card did not claim (for any reason at all, including a bug), this window
/// concluded it was needed and drew itself over the transport controls. A
/// fallback that appoints itself is indistinguishable from a fallback that is
/// broken, so the appointment is now the user's.
///
/// The other two conditions remain, because they are about correctness rather
/// than intent: it stays hidden while the card or the full-screen route is
/// showing the same texture — two views of one stream would be two hosts
/// competing for it — and while the current track has no picture at all.
library;

import 'package:eq_app/navigation/app_nav.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../services/video/video_registry.dart';
import 'video_stage.dart';
import 'video_surface.dart';

/// Whether the user has asked for the floating window.
///
/// Separate from [VideoSurface] on purpose: that tracks which host *may* draw
/// the picture, which is a question about the decoder. This tracks whether the
/// user wants a floating window at all, which is a question about intent. The
/// old code had only the first and inferred the second from it.
///
/// The request outlives a single track — someone who popped the video out to
/// keep browsing has said what they want, and having it vanish at the next
/// track would make them ask again every few minutes. It ends when they close
/// the window, or when nothing with a picture is playing any more.
class VideoPopout extends ChangeNotifier {
  static final VideoPopout instance = VideoPopout._();

  VideoPopout._();

  bool _requested = false;

  bool get requested => _requested;

  void request() {
    if (_requested) return;
    _requested = true;
    notifyListeners();
  }

  void dismiss() {
    if (!_requested) return;
    _requested = false;
    notifyListeners();
  }
}

class VideoMiniPlayer extends StatefulWidget {
  const VideoMiniPlayer({super.key});

  @override
  State<VideoMiniPlayer> createState() => _VideoMiniPlayerState();
}

class _VideoMiniPlayerState extends State<VideoMiniPlayer> {
  static const _width = 190.0;
  static const _margin = 12.0;

  /// Where the user last put it, or null for the default corner.
  Offset? _position;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // The registry is in here because `isVideo` flips asynchronously; without
      // it this window can only notice a track gained a picture if something
      // else happens to rebuild it.
      listenable: Listenable.merge([
        VideoSurface.instance,
        VideoPopout.instance,
        VideoRegistry.instance,
      ]),
      builder: (context, _) => Consumer<AppController>(
        builder: (context, controller, _) {
          final song = controller.songs.isEmpty
              ? null
              : controller.songs[controller.songId.clamp(
                  0,
                  controller.songs.length - 1,
                )];
          final isVideo =
              song != null && VideoRegistry.instance.isVideo(song.id);

          final hidden =
              !VideoPopout.instance.requested ||
              !isVideo ||
              VideoSurface.instance.claimedByOther(VideoHost.mini);
          if (hidden) return const SizedBox.shrink();

          final media = MediaQuery.of(context);
          final height = _width * 9 / 16;
          final defaultPosition = Offset(
            media.size.width - _width - _margin,
            media.size.height - height - media.padding.bottom - 92,
          );
          final position = _position ?? defaultPosition;

          return Positioned(
            left: position.dx.clamp(0.0, media.size.width - _width),
            top: position.dy.clamp(
              media.padding.top,
              media.size.height - height - media.padding.bottom,
            ),
            child: StreamBuilder<bool>(
              stream: controller.handler.player.playingStream,
              initialData: controller.handler.player.playing,
              builder: (context, snapshot) => _MiniWindow(
                width: _width,
                height: height,
                title: song.title,
                playing: snapshot.data ?? false,
                onDrag: (delta) => setState(() {
                  _position = (_position ?? defaultPosition) + delta;
                }),
                onTap: () => AppNav.toPlayer(context, recordOrigin: false),
                onClose: VideoPopout.instance.dismiss,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MiniWindow extends StatelessWidget {
  final double width;
  final double height;
  final String title;
  final bool playing;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const _MiniWindow({
    required this.width,
    required this.height,
    required this.title,
    required this.playing,
    required this.onDrag,
    required this.onTap,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanUpdate: (details) => onDrag(details.delta),
      onTap: onTap,
      child: Material(
        elevation: 10,
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const VideoStage(host: VideoHost.mini),
              Positioned(
                top: 0,
                right: 0,
                child: GestureDetector(
                  onTap: onClose,
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(10),
                      ),
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(8, 10, 8, 5),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.7),
                      ],
                    ),
                  ),
                  // Transport lives in the strip rather than over the picture,
                  // so tapping the window itself still means "give me the
                  // player back" — the thing someone does far more often than
                  // pausing from a thumbnail.
                  child: Row(
                    children: [
                      _MiniButton(
                        icon: playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        semanticLabel: playing ? 'Pause' : 'Play',
                        onTap: playing
                            ? AppController.instance.handler.pause
                            : AppController.instance.handler.play,
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                      _MiniButton(
                        icon: Icons.skip_next_rounded,
                        semanticLabel: 'Next',
                        onTap: AppController.instance.next,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One control in the floating window's strip.
///
/// Sized to 32 logical pixels rather than the 48 the guidelines ask for: the
/// whole window is 190 wide, and a compliant target would leave no room for the
/// title. The window is a convenience over the real player, which is one tap
/// away and has full-size controls.
class _MiniButton extends StatelessWidget {
  final IconData icon;
  final String semanticLabel;
  final VoidCallback onTap;

  const _MiniButton({
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 32,
          height: 26,
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}
