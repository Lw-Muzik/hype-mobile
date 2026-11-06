// ignore_for_file: library_private_types_in_public_api, depend_on_referenced_packages
import 'package:eq_app/Themes/app_fonts.dart';

import 'dart:async';

import 'package:rxdart/rxdart.dart';
import 'package:flutter/gestures.dart'
    show DeviceGestureSettings, DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '/services/player_reveal_bus.dart';

import '../global/index.dart';
import 'player_body.dart';
import 'widgets/controls.dart';
import 'widgets/header.dart';
import '../controllers/app_controller.dart';
import '../helpers/index.dart';
import '/widgets/common.dart';
import 'swipe_animation.dart';
import 'lyrics_view.dart';
import 'video/video_fullscreen.dart';
import 'video/video_mini_player.dart';
import 'video/video_stage.dart';
import 'video/video_surface.dart';
import '../onboarding/coach_marks.dart';
import '../services/video/video_registry.dart';
import '../navigation/app_nav.dart';
import '../navigation/library/library_tags.dart' show kNowPlayingArtTag;
import '../navigation/motion/morph.dart' show MorphScope;
import '../navigation/motion_spec.dart';
import '../navigation/playback_origin.dart';
import '../navigation/shell/cover_drag.dart';
import '../navigation/shell/player_chrome.dart';
import '../navigation/shell/player_exit.dart';
import '../navigation/shell/scene_controller.dart';
import 'player_presence.dart';
import 'remote/remote_player.dart';
import 'remote/remote_scope.dart';
import '../services/connect/hype_connect.dart';
import '../themes/ember.dart';

// Main Player Widget
class Player extends StatefulWidget {
  const Player({super.key});

  @override
  _PlayerState createState() => _PlayerState();
}

class _PlayerState extends State<Player> with TickerProviderStateMixin {
  AnimationController? _animationController;
  Animation<double>? _animation;
  final GlobalKey<AnimatedPlayerCardState> _cardKey = GlobalKey();

  // Coach marks
  final _coachController = CoachMarkController('player');
  final _cardDeckKey = GlobalKey();
  final _controlsKey = GlobalKey();
  final _actionBarKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    PlayerPresence.opened();
    _initializeAnimationController();
    // Detect current audio output device for display
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppController>().detectAndApplyDevicePreset();
    });
    // Show coach marks on first visit (delayed to let UI settle)
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      _coachController.hasBeenShown().then((shown) {
        final remote = HypeConnect.instanceOrNull?.session?.isRemote ?? false;
        if (!shown && mounted && !remote) {
          _coachController.start(context, [
            CoachStep(
              targetKey: _cardDeckKey,
              title: 'Album Artwork',
              description: 'Swipe left or right to change tracks. Long press for track details.',
              icon: Icons.swipe_rounded,
              tooltipPosition: TooltipPosition.below,
            ),
            CoachStep(
              targetKey: _controlsKey,
              title: 'Playback Controls',
              description: 'Play, pause, skip tracks, shuffle, and repeat.',
              icon: Icons.play_circle_outline_rounded,
              tooltipPosition: TooltipPosition.above,
            ),
            CoachStep(
              targetKey: _actionBarKey,
              title: 'Quick Actions',
              description: 'Tap EQ for equalizer, Lyrics for synced lyrics, Visual for visualizer, Queue to manage your playlist.',
              icon: Icons.dashboard_customize_rounded,
              tooltipPosition: TooltipPosition.above,
            ),
          ]);
        }
      });
    });
  }

  void _initializeAnimationController() {
    _animationController = AnimationController(
      vsync: this,
      value: 1,
      duration: const Duration(milliseconds: 800),
    );

    _animation = Tween<double>(
      begin: 0.98,
      end: 1,
    ).animate(_animationController!);
  }

  // ── Pull-the-card-down ───────────────────────────────────
  // Under the shell a downward drag on the card moves the player away with the
  // finger: progress is the travel past the slop over the real cover side. The
  // release rules and the move itself live in `SceneController`. Without a
  // shell (a bare player route) the older distance rule pops the route.
  double _dragDy = 0;
  CoverDrag? _coverDrag;

  CoverDrag? get _drag {
    final host = AppNav.host;
    if (host is! SceneController) return null;
    return _coverDrag ??= CoverDrag(
      host,
      fallbackExtent: () => MediaQuery.sizeOf(context).width * 0.8,
    );
  }

  void _handleDismissDragStart(DragStartDetails details) {
    _dragDy = 0;
    _drag?.start(details.globalPosition.dy);
  }

  void _handleDismissDragUpdate(DragUpdateDetails details) {
    final drag = _drag;
    if (drag == null) {
      _dragDy += details.delta.dy;
      return;
    }
    drag.update(details.globalPosition.dy);
  }

  /// Returns true if the gesture was handled as a downward drag (moved away, or
  /// a small downward move that should NOT fall through to "open lyrics").
  /// Returns false for an upward/neutral gesture so the caller can open lyrics.
  bool _handleDismissDragEnd(DragEndDetails details) {
    final vy = details.velocity.pixelsPerSecond.dy;
    final drag = _drag;
    if (drag != null) return drag.end(vy);
    final commit =
        _dragDy > MediaQuery.of(context).size.height * 0.18 || vy > 700;
    final wasDownward = _dragDy > 8 || vy > 200;
    _dragDy = 0;
    if (commit) {
      HapticFeedback.lightImpact();
      PlayerRevealBus.revealNowPlaying();
      Navigator.of(context).pop();
      return true;
    }
    return wasDownward;
  }

  @override
  void dispose() {
    PlayerPresence.closed();
    _coachController.dispose();
    _animationController?.dispose();
    super.dispose();
  }

  // Both buttons just change the track. The card deck watches `songId` and
  // animates toward whatever it becomes, so a button, a swipe, a crossfade, a
  // track ending and the notification all produce the same movement without
  // any of them knowing the deck exists.
  void _onControlNext() {
    final ctrl = context.read<AppController>();
    if (ctrl.songs.isEmpty) return;
    ctrl.next();
  }

  void _onControlPrev() {
    final ctrl = context.read<AppController>();
    if (ctrl.songs.isEmpty) return;
    ctrl.prev();
  }

  @override
  Widget build(BuildContext context) {
    // Another device is the player: this screen becomes its remote.
    return RemoteBuilder(
      builder: (context, remote) {
        if (remote != null) return RemotePlayerView(remote: remote);
        if (!context.read<AppController>().hasNowPlaying) {
          // Remote mode ended with nothing of our own to show.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            final host = AppNav.host;
            if (host != null) {
              // Nothing left to show: the library, at its top level.
              host.toLibrary(landOn: const PlaybackOrigin([]));
            } else {
              Navigator.of(context).maybePop();
            }
          });
          return const Scaffold(backgroundColor: Ember.ground);
        }
        return _buildLocal(context);
      },
    );
  }

  Widget _buildLocal(BuildContext context) {
    return Scaffold(
      body: Consumer<AppController>(
        builder: (context, controller, child) {
          final player = controller.handler.player;
          // Re-key ONLY when the underlying player instance changes (crossfade
          // A/B swap), NOT on every songId change — otherwise the whole
          // subtree (incl. the visualizer) is torn down and rebuilt per track,
          // which used to leak a native FFT tap on each advance.
          final playerKey = identityHashCode(player);

          return StreamBuilder(
            key: ValueKey(playerKey),
            stream: player.playingStream,
            builder: (context, snapshot) {
              final isPlaying = snapshot.data ?? false;

              if (isPlaying) {
                _animationController?.forward();
              } else {
                _animationController?.reverse();
              }

              return PlayerBody(
                controller: controller,
                child: Stack(
                  children: [
                    if (controller.playerVisual && isPlaying)
                      playerVisual(controller),
                    _PlayerLayout(
                      controller: controller,
                      animation: _animation!,
                      cardKey: _cardKey,
                      onControlNext: _onControlNext,
                      onControlPrev: _onControlPrev,
                      cardDeckKey: _cardDeckKey,
                      controlsKey: _controlsKey,
                      actionBarKey: _actionBarKey,
                      onDismissDragStart: _handleDismissDragStart,
                      onDismissDragUpdate: _handleDismissDragUpdate,
                      onDismissDragEnd: _handleDismissDragEnd,
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Main layout of the player screen — portrait or landscape.
class _PlayerLayout extends StatelessWidget {
  final AppController controller;
  final Animation<double> animation;
  final GlobalKey<AnimatedPlayerCardState> cardKey;
  final VoidCallback onControlNext;
  final VoidCallback onControlPrev;
  final GlobalKey cardDeckKey;
  final GlobalKey controlsKey;
  final GlobalKey actionBarKey;
  final void Function(DragStartDetails)? onDismissDragStart;
  final void Function(DragUpdateDetails)? onDismissDragUpdate;
  final bool Function(DragEndDetails)? onDismissDragEnd;

  const _PlayerLayout({
    required this.controller,
    required this.animation,
    required this.cardKey,
    required this.onControlNext,
    required this.onControlPrev,
    required this.cardDeckKey,
    required this.controlsKey,
    required this.actionBarKey,
    this.onDismissDragStart,
    this.onDismissDragUpdate,
    this.onDismissDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final isLandscape = mq.orientation == Orientation.landscape;

    if (isLandscape) {
      return _buildLandscape(context, mq);
    }
    return _buildPortrait(context, mq);
  }

  // ── Portrait (original vertical stack) ──────────────────────────────────

  Widget _buildPortrait(BuildContext context, MediaQueryData mq) {
    final topPadding = mq.padding.top;
    final bottomPadding = mq.padding.bottom;
    final h = mq.size.height;
    final gap = (h * 0.015).clamp(6.0, 16.0);

    return SizedBox(
      height: h,
      width: mq.size.width,
      child: Column(
        children: [
          SizedBox(height: topPadding),
          const PlayerChrome(child: Header()),
          _CardDeck(
            controller: controller,
            animation: animation,
            cardKey: cardKey,
            spotlightKey: cardDeckKey,
            onDismissDragStart: onDismissDragStart,
            onDismissDragUpdate: onDismissDragUpdate,
            onDismissDragEnd: onDismissDragEnd,
          ),
          _TrackInfo(controller: controller),
          SizedBox(height: gap),
          PlayerChrome(child: _WaveformProgress(controller: controller)),
          SizedBox(height: gap * 1.4),
          PlayerChrome(
            child: KeyedSubtree(
              key: controlsKey,
              child: Controls(
                onNextPressed: onControlNext,
                onPrevPressed: onControlPrev,
              ),
            ),
          ),
          SizedBox(height: gap * 1.4),
          PlayerChrome(
            child: KeyedSubtree(
              key: actionBarKey,
              child: playerActionBar(controller, context),
            ),
          ),
          SizedBox(height: bottomPadding + gap),
        ],
      ),
    );
  }

  // ── Landscape (artwork left, controls right) ────────────────────────────

  Widget _buildLandscape(BuildContext context, MediaQueryData mq) {
    final topPadding = mq.padding.top;
    final bottomPadding = mq.padding.bottom;
    final leftPadding = mq.padding.left;
    final rightPadding = mq.padding.right;
    final h = mq.size.height;
    final gap = (h * 0.02).clamp(6.0, 14.0);

    return SizedBox(
      height: h,
      width: mq.size.width,
      child: Column(
        children: [
          SizedBox(height: topPadding),
          const PlayerChrome(child: Header()),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Left: artwork card deck + track info ──
                Expanded(
                  flex: 5,
                  child: Padding(
                    padding: EdgeInsets.only(left: leftPadding + 8),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _CardDeck(
                          controller: controller,
                          animation: animation,
                          cardKey: cardKey,
                          landscape: true,
                          spotlightKey: cardDeckKey,
                          onDismissDragStart: onDismissDragStart,
                          onDismissDragUpdate: onDismissDragUpdate,
                          onDismissDragEnd: onDismissDragEnd,
                        ),
                        _TrackInfo(controller: controller),
                      ],
                    ),
                  ),
                ),
                // ── Right: seekbar, controls, action bar ──
                Expanded(
                  flex: 5,
                  child: Padding(
                    padding: EdgeInsets.only(right: rightPadding + 8),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        PlayerChrome(
                          child: _WaveformProgress(controller: controller),
                        ),
                        SizedBox(height: gap * 1.4),
                        PlayerChrome(
                          child: KeyedSubtree(
                            key: controlsKey,
                            child: Controls(
                              onNextPressed: onControlNext,
                              onPrevPressed: onControlPrev,
                            ),
                          ),
                        ),
                        SizedBox(height: gap * 1.4),
                        PlayerChrome(
                          child: KeyedSubtree(
                            key: actionBarKey,
                            child: playerActionBar(controller, context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: bottomPadding),
        ],
      ),
    );
  }
}

/// The swiping card deck section.
class _CardDeck extends StatelessWidget {
  final AppController controller;
  final Animation<double> animation;
  final GlobalKey<AnimatedPlayerCardState> cardKey;
  final bool landscape;
  final GlobalKey? spotlightKey;
  final void Function(DragStartDetails)? onDismissDragStart;
  final void Function(DragUpdateDetails)? onDismissDragUpdate;
  final bool Function(DragEndDetails)? onDismissDragEnd;

  const _CardDeck({
    required this.controller,
    required this.animation,
    required this.cardKey,
    this.landscape = false,
    this.spotlightKey,
    this.onDismissDragStart,
    this.onDismissDragUpdate,
    this.onDismissDragEnd,
  });

  void _openLyrics(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (_, _, _) => const LyricsView(),
        transitionsBuilder: (_, anim, _, child) {
          return SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
                .animate(
                  CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
                ),
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 350),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cardContent = GestureDetector(
      behavior: HitTestBehavior.translucent,
      // Downward drag/fling pops the player (route slides it down) and returns
      // to the now-playing list; a fast upward fling opens lyrics.
      dragStartBehavior: DragStartBehavior.down,
      onVerticalDragStart: onDismissDragStart,
      onVerticalDragUpdate: onDismissDragUpdate,
      onVerticalDragEnd: (details) {
        final consumed = onDismissDragEnd?.call(details) ?? false;
        if (!consumed && details.velocity.pixelsPerSecond.dy < -300) {
          _openLyrics(context);
        }
      },
      child: Column(
        children: [
          Expanded(
            // Rebuilt when the registry changes, not only when the queue does.
            // A track becomes a video asynchronously — `adopt` resolves a
            // stream and stages a manifest first — so `isVideo` below can flip
            // long after this card was built. Without this the card kept the
            // still cover it chose before the answer arrived, and the video had
            // nowhere to go but the floating window meant for when the card
            // cannot host it.
            child: ListenableBuilder(
              listenable: VideoRegistry.instance,
              builder: (context, _) => _DeckDuringArtFlight(
                child: AnimatedPlayerCard(
                  key: cardKey,
                  itemCount: controller.songs.length,
                  currentSongId: controller.songId,
                  onPageChanged: (page) {
                    if (page > controller.songId) {
                      controller.next();
                    } else if (page < controller.songId) {
                      // Skip the >3s restart check — card already animated,
                      // user explicitly chose previous track. Through the
                      // controller, which fades the change like any other skip
                      // and keeps a gapless queue whole; loading the track here
                      // directly cut, and dropped the rest of the queue.
                      controller.skipTo(page);
                    }
                  },
                  itemBuilder: (context, index, {bool isActive = false}) {
                    // A video occupies the card where the artwork would be — the
                    // player screen is where playback lives, and a video is a track
                    // being played, not a place to navigate to. Only the track
                    // actually playing gets it: there is one surface, and the cards
                    // either side are previews of things not yet started.
                    final isVideo =
                        index == controller.songId &&
                        VideoRegistry.instance.isVideo(
                          controller.songs[index].id,
                        );
                    if (isVideo) {
                      return GestureDetector(
                        // Opaque, not the default `deferToChild`. When the stage
                        // is not the surface owner it draws nothing, and a child
                        // with no hit area meant this tap fell straight through
                        // to the card stacked behind — whose own handler pops the
                        // player. Tapping a video to go full screen closed the
                        // screen instead.
                        behavior: HitTestBehavior.opaque,
                        onTap: () => openFullscreenVideo(context),
                        onLongPress: () => showTrackInfo(context, controller),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: ClipRRect(
                            borderRadius: const BorderRadius.all(
                              Radius.circular(14),
                            ),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                const VideoStage(
                                  host: VideoHost.card,
                                  // Opaque, so the card cannot show the deck
                                  // through itself. Without this the stage was
                                  // transparent whenever it was not the owner
                                  // and the *next* track's card showed through,
                                  // which reads exactly like the player having
                                  // the wrong artwork.
                                  placeholder: ColoredBox(color: Colors.black),
                                ),
                                // The only way the floating window is ever opened.
                                // It used to open itself whenever a video played
                                // and the card was not hosting it, which put an
                                // undismissed window over the transport controls.
                                Positioned(
                                  top: 6,
                                  right: 6,
                                  child: _PopOutButton(
                                    onTap: () {
                                      VideoPopout.instance.request();
                                      leavePlayer(context);
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }
                    return InkWell(
                      // Tap the cover to return to the now-playing list (tap OR
                      // swipe-down both go back to the current category).
                      onTap: () {
                        // Under the shell the move reveals the row itself, at
                        // once, before the library zooms in.
                        if (AppNav.host == null) {
                          PlayerRevealBus.revealNowPlaying();
                        }
                        leavePlayer(context);
                      },
                      onLongPress: () => showTrackInfo(context, controller),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: playerCard(
                          animation,
                          context,
                          controller,
                          songIndex: index,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          if (controller.currentLyrics != null || controller.lyricsLoading)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Icon(
                Icons.keyboard_arrow_up_rounded,
                color: Colors.white.withValues(alpha: 0.25),
                size: 20,
              ),
            ),
        ],
      ),
    );

    // Under the shell the card drag starts after an 8 dp slop on every
    // platform (iOS defaults to a wider one).
    final mq = MediaQuery.of(context);
    final slopped = AppNav.host == null
        ? cardContent
        : MediaQuery(
            data: mq.copyWith(
              gestureSettings: const DeviceGestureSettings(
                touchSlop: MotionSpec.dragSlop,
              ),
            ),
            child: cardContent,
          );
    final card = spotlightKey != null
        ? KeyedSubtree(key: spotlightKey, child: slopped)
        : slopped;

    // In landscape the parent Column is centered — use a constrained size
    // instead of Expanded so mainAxisAlignment: center can work.
    if (landscape) {
      final availableHeight =
          MediaQuery.of(context).size.height -
          MediaQuery.of(context).padding.top -
          MediaQuery.of(context).padding.bottom -
          48; // header height
      // Card takes ~60% of available height, leaves room for track info
      final cardHeight = (availableHeight * 0.65).clamp(120.0, 400.0);
      return SizedBox(height: cardHeight, child: card);
    }

    return Expanded(child: card);
  }
}

/// Track title, artist, and album — shown below the card deck.
/// Long text auto-scrolls horizontally (marquee).
class _TrackInfo extends StatelessWidget {
  final AppController controller;
  const _TrackInfo({required this.controller});

  static const _deviceInfo = <String, (IconData, String)>{
    'speaker': (Icons.speaker_rounded, 'Speaker'),
    'bluetooth': (Icons.bluetooth_audio_rounded, 'Bluetooth'),
    'wired_headphone': (Icons.headphones_rounded, 'Headphones'),
    'usb_audio': (Icons.usb_rounded, 'USB Audio'),
  };

  @override
  Widget build(BuildContext context) {
    final song = controller.songs[controller.songId];
    final duration = formatTime(Duration(milliseconds: song.duration ?? 0));
    final ext = song.fileExtension.toUpperCase();
    final device = controller.lastOutputDevice;
    final (deviceIcon, deviceLabel) =
        _deviceInfo[device] ?? (Icons.speaker_rounded, 'Speaker');

    final dimStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.4),
      fontSize: 12,
      fontWeight: FontWeight.w400,
    );
    final dotStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.3),
      fontSize: 12,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Material transparency: a bare Text here has no DefaultTextStyle
          // ancestor.
          Padding(
            padding: EdgeInsets.zero,
            child: Material(
              type: MaterialType.transparency,
              child: _MarqueeText(
                text: song.title,
                style: AppFonts.displayStyle(
                  color: Colors.white,
                  fontSize: 20,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: EdgeInsets.zero,
            child: Material(
              type: MaterialType.transparency,
              child: _MarqueeText(
                text: song.artist ?? 'Unknown artist',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              if (song.album != null &&
                  song.album!.isNotEmpty &&
                  !song.album!.startsWith('http')) ...[
                Flexible(
                  child: Text(
                    song.album!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: dimStyle,
                  ),
                ),
                Text('  \u2022  ', style: dotStyle),
              ],
              Text(duration, style: dimStyle),
              if (ext.isNotEmpty) ...[
                Text('  \u2022  ', style: dotStyle),
                Text(ext, style: dimStyle),
              ],
              Text('  \u2022  ', style: dotStyle),
              Icon(
                deviceIcon,
                size: 13,
                color: Colors.white.withValues(alpha: 0.45),
              ),
              const SizedBox(width: 3),
              Text(deviceLabel, style: dimStyle),
            ],
          ),
        ],
      ),
    );
  }
}

/// Auto-scrolling text that scrolls when the text overflows.
class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _MarqueeText({required this.text, required this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final ScrollController _scrollController;
  bool _overflows = false;
  AnimationController? _anim;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
  }

  @override
  void didUpdateWidget(_MarqueeText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _anim?.stop();
      _anim?.dispose();
      _anim = null;
      _scrollController.jumpTo(0);
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
    }
  }

  void _checkOverflow() {
    if (!mounted) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final overflows = maxScroll > 0;
    if (overflows != _overflows) {
      setState(() => _overflows = overflows);
    }
    if (overflows) {
      _startScroll(maxScroll);
    }
  }

  void _startScroll(double maxScroll) {
    _anim?.dispose();
    // Speed: ~30px/s — adjust duration based on overflow distance.
    final durationMs = (maxScroll / 30 * 1000).round().clamp(2000, 15000);
    _anim =
        AnimationController(
          vsync: this,
          duration: Duration(milliseconds: durationMs),
        )..addListener(() {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(_anim!.value * maxScroll);
          }
        });

    // Pause 1.5s → scroll to end → pause 1.5s → jump back → repeat
    Future.doWhile(() async {
      if (!mounted) return false;
      await Future.delayed(const Duration(milliseconds: 1500));
      if (!mounted) return false;
      await _anim!.forward(from: 0);
      if (!mounted) return false;
      await Future.delayed(const Duration(milliseconds: 1500));
      if (!mounted || !_scrollController.hasClients) return false;
      _scrollController.jumpTo(0);
      return mounted;
    });
  }

  @override
  void dispose() {
    _anim?.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.style.fontSize! * 1.4,
      child: SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: Text(
          widget.text,
          maxLines: 1,
          softWrap: false,
          style: widget.style,
        ),
      ),
    );
  }
}

/// Waveform progress bar — uses [currentTrackPlayer] which always returns
/// the player that has the latest track loaded, even during crossfade.
class _WaveformProgress extends StatelessWidget {
  final AppController controller;

  const _WaveformProgress({required this.controller});

  @override
  Widget build(BuildContext context) {
    // currentTrackPlayer returns the incoming player during crossfade,
    // and the active player otherwise — so the waveform always tracks
    // the new track from the moment crossfade begins.
    final trackPlayer = controller.handler.currentTrackPlayer;
    final streamKey = Object.hash(
      controller.songId,
      identityHashCode(trackPlayer),
    );

    return StreamBuilder<bool>(
      key: ValueKey('playing_$streamKey'),
      stream: trackPlayer.playingStream,
      builder: (context, playingSnap) {
        final isPlaying = playingSnap.data ?? false;
        return StreamBuilder<PositionData>(
          key: ValueKey(streamKey),
          stream:
              Rx.combineLatest3<Duration, Duration, Duration?, PositionData>(
                trackPlayer.positionStream,
                trackPlayer.bufferedPositionStream,
                trackPlayer.durationStream,
                (position, bufferedPosition, duration) => PositionData(
                  position,
                  bufferedPosition,
                  duration ?? Duration.zero,
                ),
              ),
          builder: (context, snapshot) {
            final data = snapshot.data;
            return WaveformSeekBar(
              key: ValueKey('waveform_$streamKey'),
              duration: data?.duration ?? Duration.zero,
              position: data?.position ?? Duration.zero,
              bufferedPosition: data?.bufferedPosition ?? Duration.zero,
              isPlaying: isPlaying,
              // Through the handler, which fades the jump in and settles a
              // crossfade first.
              onChangeEnd: (position) => controller.handler.seek(position),
            );
          },
        );
      },
    );
  }
}

/// The control that opens the floating window.
///
/// Deliberately small and low-contrast: it sits over the picture, and a video
/// is the one thing on this screen that is meant to be looked at. It is the
/// only route to the pop-out window — see [VideoPopout] for why that window no
/// longer decides for itself.
class _PopOutButton extends StatelessWidget {
  final VoidCallback onTap;

  const _PopOutButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Pop out video',
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(
            Icons.picture_in_picture_alt_rounded,
            color: Colors.white,
            size: 18,
          ),
        ),
      ),
    );
  }
}

/// While the cover flies between the player and a list row the stand-in is
/// the cover. The deck hides with it: its other cards sit stacked behind the
/// tagged one (and the old card fades out on a track change), and would show
/// where the cover was.
class _DeckDuringArtFlight extends StatelessWidget {
  const _DeckDuringArtFlight({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = MorphScope.maybeOf(context);
    if (scope == null) return child;
    return ValueListenableBuilder<Set<Object>>(
      valueListenable: scope.hiddenTags,
      child: child,
      builder: (context, hidden, child) => Opacity(
        opacity: hidden.contains(kNowPlayingArtTag) ? 0 : 1,
        child: child,
      ),
    );
  }
}
