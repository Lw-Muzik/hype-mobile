/// Watching a video with the whole screen.
///
/// # What the gestures are, and why these
///
/// Every one of them is a gesture people already have muscle memory for, taken
/// from the players they use daily rather than invented here:
///
/// * **Double tap** at the left or right edge seeks ten seconds, in the middle
///   plays or pauses.
/// * **Vertical drag** on the left half sets screen brightness, on the right
///   half sets volume — the arrangement every mobile video player has used since
///   MX Player.
/// * **Long press** plays at double speed until released.
/// * **Pinch** switches between fitting the video inside the screen and filling
///   the screen with it, which is the only thing a pinch can usefully mean when
///   the source resolution is fixed.
/// * **Swipe down** leaves.
///
/// # The controls hide themselves
///
/// Three seconds after the last touch, because a full-screen video with a
/// permanent bar across it is not full screen. Tapping once brings them back.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio/video.dart';

import '../../controllers/app_controller.dart';
import '../../services/screen_brightness.dart';
import 'picture_in_picture.dart';
import 'video_quality_sheet.dart';
import 'video_stage.dart';
import 'video_surface.dart';

/// Opens the full-screen video route.
Future<void> openFullscreenVideo(BuildContext context) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: true,
      pageBuilder: (_, _, _) => const VideoFullscreenPage(),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
      transitionDuration: const Duration(milliseconds: 250),
    ),
  );
}

class VideoFullscreenPage extends StatefulWidget {
  const VideoFullscreenPage({super.key});

  @override
  State<VideoFullscreenPage> createState() => _VideoFullscreenPageState();
}

class _VideoFullscreenPageState extends State<VideoFullscreenPage> {
  static const _seekStep = Duration(seconds: 10);
  static const _controlsLinger = Duration(seconds: 3);

  bool _controlsVisible = true;
  BoxFit _fit = BoxFit.contain;
  Timer? _hideTimer;

  /// Set while a long press is holding double speed, so releasing restores the
  /// speed the user actually chose rather than assuming it was 1.0.
  double? _speedBeforeHold;

  /// The transient readout shown while a drag is adjusting something.
  ({IconData icon, double value, String label})? _feedback;
  Timer? _feedbackTimer;

  double _brightness = 0.5;
  double _volume = 1;

  /// Open only until the decoder reports the picture's dimensions. See
  /// [_applyOrientation].
  StreamSubscription<VideoState>? _sizeSub;

  AppController get _controller => AppController.instance;
  AudioPlayer get _player => _controller.handler.currentTrackPlayer;
  VideoOutput get _video => _controller.handler.video;

  /// What the screen was set to before this route touched it, so leaving puts
  /// it back. Load-bearing on iOS, where brightness is a device setting rather
  /// than a per-window override and would otherwise outlive the video.
  double? _brightnessOnEntry;

  @override
  void initState() {
    super.initState();
    _volume = _controller.handler.trackGainOf(_player).clamp(0.0, 1.0);
    unawaited(_readBrightness());
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Subscribed before the first check so a size arriving in between is not
    // missed; [_applyOrientation] closes it as soon as it has an answer.
    _sizeSub = _video.stateStream.listen(_applyOrientation);
    _applyOrientation(_video.state);
    _restartHideTimer();
  }

  /// Turns the phone to match the picture.
  ///
  /// # Why this forces rather than permits
  ///
  /// This used to offer landscape *and* portrait, which meant a handset held
  /// upright stayed upright: tapping a 16:9 music video filled a third of the
  /// screen and left the viewer to rotate the phone themselves. Full screen is
  /// a request to see the picture as large as it goes, and for a wide video
  /// that means landscape — so the orientation is set, not suggested.
  ///
  /// It is driven by the decoder's own dimensions rather than assumed, because
  /// a vertical video forced into landscape would be the same mistake pointing
  /// the other way: pillarboxed, smaller than it was, and now sideways as well.
  ///
  /// Dimensions are not known until the first frame is decoded, which is
  /// usually after this route opens. Until then [VideoState.hasVideo] is false
  /// and nothing is decided; the subscription delivers the answer when it
  /// exists and is closed on the spot, so a later rendition change cannot
  /// rotate the phone under someone mid-watch.
  void _applyOrientation(VideoState state) {
    // Only a *measured* portrait picture keeps the phone upright. Unknown
    // counts as landscape, which is not a guess so much as the same assumption
    // [VideoStage] already makes when it lays out at 1600x900 for a decoder
    // that has not reported yet.
    //
    // It has to work this way here, because on Android the dimensions may
    // never arrive at all: the Dart side subscribes to
    // `com.ryanheise.just_audio.video.<id>` before the native VideoOutput for
    // that id exists, so the subscription dies with a MissingPluginException
    // and `hasVideo` stays false for the life of the track. An earlier version
    // of this method returned early in that case, which meant full screen
    // silently stayed portrait and letterboxed every music video on the
    // device. Waiting for a fact that never comes is not a safe default.
    final vertical = state.hasVideo && state.height > state.width;
    if (state.hasVideo) {
      _sizeSub?.cancel();
      _sizeSub = null;
    }
    SystemChrome.setPreferredOrientations(
      vertical
          ? const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]
          : const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ],
    );
  }

  Future<void> _readBrightness() async {
    final current = await ScreenBrightness.get();
    if (!mounted || current == null) return;
    setState(() {
      _brightnessOnEntry = current;
      _brightness = current;
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _feedbackTimer?.cancel();
    _sizeSub?.cancel();
    // Whatever the hold was doing, it does not survive the screen.
    if (_speedBeforeHold != null) _player.setSpeed(_speedBeforeHold!);
    // Put the screen back. On Android clearing the override is enough; on iOS
    // there is nothing to clear, so the value found on the way in is written
    // back explicitly.
    final entry = _brightnessOnEntry;
    if (entry != null) {
      unawaited(ScreenBrightness.set(entry));
    } else {
      unawaited(ScreenBrightness.clear());
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    super.dispose();
  }

  void _restartHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_controlsLinger, () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _restartHideTimer();
  }

  void _showFeedback(IconData icon, double value, String label) {
    setState(() => _feedback = (icon: icon, value: value, label: label));
    _feedbackTimer?.cancel();
    _feedbackTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _feedback = null);
    });
  }

  // ---- Gestures ----

  void _onDoubleTapAt(Offset position, Size size) {
    final third = size.width / 3;
    if (position.dx < third) {
      _seekBy(-_seekStep);
    } else if (position.dx > size.width - third) {
      _seekBy(_seekStep);
    } else {
      _player.playing ? _player.pause() : _player.play();
    }
  }

  void _seekBy(Duration delta) {
    final target = _player.position + delta;
    final duration = _player.duration ?? Duration.zero;
    _player.seek(
      target < Duration.zero
          ? Duration.zero
          : (duration > Duration.zero && target > duration ? duration : target),
    );
    _showFeedback(
      delta.isNegative ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
      -1,
      '${delta.isNegative ? '−' : '+'}${delta.inSeconds.abs()}s',
    );
  }

  void _onVerticalDrag(DragUpdateDetails details, Size size) {
    // A full screen height of travel covers the whole range; the delta is
    // negated because dragging up should raise, and screen coordinates grow
    // downwards.
    final change = -details.primaryDelta! / size.height;
    if (details.globalPosition.dx < size.width / 2) {
      _brightness = (_brightness + change).clamp(0.0, 1.0);
      unawaited(ScreenBrightness.set(_brightness));
      _showFeedback(
        Icons.brightness_6_rounded,
        _brightness,
        '${(_brightness * 100).round()}%',
      );
    } else {
      _volume = (_volume + change).clamp(0.0, 1.0);
      _controller.handler.setTrackGain(_player, _volume);
      _showFeedback(
        _volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
        _volume,
        '${(_volume * 100).round()}%',
      );
    }
  }

  void _onLongPressStart() {
    _speedBeforeHold = _player.speed;
    _player.setSpeed(2);
    _showFeedback(Icons.speed_rounded, -1, '2×');
  }

  void _onLongPressEnd() {
    final previous = _speedBeforeHold;
    if (previous == null) return;
    _speedBeforeHold = null;
    _player.setSpeed(previous);
    setState(() => _feedback = null);
  }

  void _onScaleEnd(ScaleEndDetails details, double scale) {
    if (scale > 1.15 && _fit != BoxFit.cover) {
      setState(() => _fit = BoxFit.cover);
      _showFeedback(Icons.crop_free_rounded, -1, 'Fill');
    } else if (scale < 0.9 && _fit != BoxFit.contain) {
      setState(() => _fit = BoxFit.contain);
      _showFeedback(Icons.fit_screen_rounded, -1, 'Fit');
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    var scale = 1.0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        onDoubleTapDown: (details) =>
            _onDoubleTapAt(details.localPosition, size),
        // `onDoubleTap` still has to exist for `onDoubleTapDown` to fire; the
        // position is what this screen actually needs, and only the *Down*
        // callback carries it.
        onDoubleTap: () {},
        onLongPressStart: (_) => _onLongPressStart(),
        onLongPressEnd: (_) => _onLongPressEnd(),
        onVerticalDragUpdate: (details) => _onVerticalDrag(details, size),
        onVerticalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) > 700) Navigator.of(context).pop();
        },
        onScaleUpdate: (details) => scale = details.scale,
        onScaleEnd: (details) => _onScaleEnd(details, scale),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: VideoStage(host: VideoHost.fullscreen, fit: _fit),
            ),
            if (_feedback != null) _FeedbackBadge(feedback: _feedback!),
            AnimatedOpacity(
              opacity: _controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: _FullscreenControls(
                  controller: _controller,
                  player: _player,
                  video: _video,
                  onInteraction: _restartHideTimer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The transient readout shown while a gesture is adjusting something.
class _FeedbackBadge extends StatelessWidget {
  final ({IconData icon, double value, String label}) feedback;

  const _FeedbackBadge({required this.feedback});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(feedback.icon, color: Colors.white, size: 30),
            const SizedBox(height: 8),
            Text(
              feedback.label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            // A bar only where there is a range to show: a seek jump has no
            // position on a scale, and drawing an empty one implies otherwise.
            if (feedback.value >= 0) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: 120,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: feedback.value,
                    minHeight: 4,
                    backgroundColor: Colors.white24,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FullscreenControls extends StatelessWidget {
  final AppController controller;
  final AudioPlayer player;
  final VideoOutput video;
  final VoidCallback onInteraction;

  const _FullscreenControls({
    required this.controller,
    required this.player,
    required this.video,
    required this.onInteraction,
  });

  @override
  Widget build(BuildContext context) {
    final song = controller.songs.isEmpty
        ? null
        : controller.songs[controller.songId.clamp(
            0,
            controller.songs.length - 1,
          )];

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.55),
            Colors.transparent,
            Colors.black.withValues(alpha: 0.75),
          ],
          stops: const [0, 0.45, 1],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: Colors.white,
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: Text(
                    song?.title ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (PictureInPicture.instance.isSupported)
                  IconButton(
                    tooltip: 'Picture-in-picture',
                    icon: const Icon(
                      Icons.picture_in_picture_alt_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                    onPressed: () async {
                      onInteraction();
                      final state = video.state;
                      await PictureInPicture.instance.enter(
                        width: state.hasVideo ? state.width : null,
                        height: state.hasVideo ? state.height : null,
                      );
                    },
                  ),
                StreamBuilder<VideoState>(
                  stream: video.stateStream,
                  initialData: video.state,
                  builder: (context, snapshot) {
                    final state = snapshot.data ?? const VideoState();
                    return TextButton.icon(
                      onPressed: () {
                        onInteraction();
                        showVideoQualitySheet(context, video);
                      },
                      icon: const Icon(
                        Icons.high_quality_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                      label: Text(
                        state.selected?.label ?? 'Auto',
                        style: const TextStyle(color: Colors.white),
                      ),
                    );
                  },
                ),
              ],
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  iconSize: 38,
                  icon: const Icon(
                    Icons.skip_previous_rounded,
                    color: Colors.white,
                  ),
                  onPressed: () {
                    onInteraction();
                    controller.prev();
                  },
                ),
                const SizedBox(width: 20),
                StreamBuilder<bool>(
                  stream: player.playingStream,
                  initialData: player.playing,
                  builder: (context, snapshot) {
                    final playing = snapshot.data ?? false;
                    return IconButton(
                      iconSize: 62,
                      icon: Icon(
                        playing
                            ? Icons.pause_circle_filled_rounded
                            : Icons.play_circle_filled_rounded,
                        color: Colors.white,
                      ),
                      onPressed: () {
                        onInteraction();
                        playing ? player.pause() : player.play();
                      },
                    );
                  },
                ),
                const SizedBox(width: 20),
                IconButton(
                  iconSize: 38,
                  icon: const Icon(
                    Icons.skip_next_rounded,
                    color: Colors.white,
                  ),
                  onPressed: () {
                    onInteraction();
                    controller.next();
                  },
                ),
              ],
            ),
            const Spacer(),
            _Scrubber(player: player, onInteraction: onInteraction),
          ],
        ),
      ),
    );
  }
}

class _Scrubber extends StatelessWidget {
  final AudioPlayer player;
  final VoidCallback onInteraction;

  const _Scrubber({required this.player, required this.onInteraction});

  static String _clock(Duration d) {
    final hours = d.inHours;
    final minutes = (d.inMinutes % 60).toString().padLeft(
      hours > 0 ? 2 : 1,
      '0',
    );
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      initialData: player.position,
      builder: (context, snapshot) {
        final duration = player.duration ?? Duration.zero;
        final position = snapshot.data ?? Duration.zero;
        final max = duration.inMilliseconds.toDouble();
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Row(
            children: [
              Text(
                _clock(position),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Expanded(
                child: Slider(
                  value: max <= 0
                      ? 0
                      : position.inMilliseconds.toDouble().clamp(0, max),
                  max: max <= 0 ? 1 : max,
                  onChanged: (value) {
                    onInteraction();
                    player.seek(Duration(milliseconds: value.round()));
                  },
                ),
              ),
              Text(
                _clock(duration),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }
}
