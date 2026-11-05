import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:vector_math/vector_math_64.dart' show Vector3;

import '/exports/exports.dart';
import 'package:rxdart/rxdart.dart';

import '../controllers/app_controller.dart';
import '../Themes/app_fonts.dart';
import '../models/lyrics_model.dart';
import '../widgets/artwork_widget.dart';
import '../widgets/common.dart';
import 'widgets/lyrics_editor.dart';
import 'widgets/word_fill_text.dart';
import '/pages/settings.dart';

class LyricsView extends StatefulWidget {
  const LyricsView({super.key});

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView>
    with TickerProviderStateMixin {
  late final AnimationController _entranceController;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _playingSub;
  int _currentLineIndex = -1;

  /// The lyric clock (position + LRC offset, ms). Read by the active line's
  /// word fill, which repaints from it without rebuilding the view.
  final ValueNotifier<int> _lyricClockMs = ValueNotifier<int>(0);

  /// Drives [_lyricClockMs] every frame while playing — `positionStream` only
  /// ticks every ~200 ms, too coarse for a word-by-word fill. Stopped while
  /// paused so an open lyrics page doesn't keep the GPU awake.
  late final Ticker _clock = createTicker((_) => _syncClock());
  bool _playing = false;
  bool _userScrolling = false;
  Timer? _userScrollTimer;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _entranceController,
            curve: Curves.easeOutCubic,
          ),
        );
    _fadeAnimation = CurvedAnimation(
      parent: _entranceController,
      curve: Curves.easeOut,
    );
    _entranceController.forward();
    _bindPosition();
  }

  void _bindPosition() {
    final controller = context.read<AppController>();
    // Seeks while paused still move the line.
    _positionSub = controller.handler.currentTrackPlayer.positionStream.listen(
      (_) => _syncClock(),
    );
    // The handler's state follows whichever player is live across crossfades.
    _playingSub = controller.handler.playbackState
        .map((s) => s.playing)
        .distinct()
        .listen((playing) {
          _playing = playing;
          _updateClock();
          _syncClock();
        });
  }

  /// Runs the frame clock only while playing synced lyrics.
  void _updateClock() {
    final lyrics = AppController.instance.currentLyrics;
    final want = _playing && lyrics != null && lyrics.isSynced;
    if (want && !_clock.isActive) {
      _clock.start();
    } else if (!want && _clock.isActive) {
      _clock.stop();
    }
  }

  void _syncClock() {
    if (!mounted) return;
    final controller = AppController.instance;
    final lyrics = controller.currentLyrics;
    if (lyrics == null || !lyrics.isSynced) {
      _updateClock();
      return;
    }

    // just_audio interpolates `position` between platform updates.
    final adjusted =
        controller.handler.currentTrackPlayer.position +
        Duration(milliseconds: lyrics.offsetMs);
    _lyricClockMs.value = adjusted.inMilliseconds;

    final idx = activeLineIndex(lyrics.lines, adjusted);
    if (idx != _currentLineIndex) {
      setState(() => _currentLineIndex = idx);
    }
  }

  void _onUserScroll() {
    _userScrolling = true;
    _userScrollTimer?.cancel();
    _userScrollTimer = Timer(const Duration(seconds: 4), () {
      _userScrolling = false;
      // Trigger a rebuild so _SyncedLyrics.didUpdateWidget sees
      // userScrolling changed and can snap back to the current line.
      if (mounted && _currentLineIndex >= 0) setState(() {});
    });
  }

  void _seekToLine(int index) {
    final controller = context.read<AppController>();
    final lyrics = controller.currentLyrics;
    if (lyrics == null || index < 0 || index >= lyrics.lines.length) return;
    final ts = lyrics.lines[index].timestamp;
    if (ts != null) {
      controller.handler.seek(ts);
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _playingSub?.cancel();
    _clock.dispose();
    _lyricClockMs.dispose();
    _userScrollTimer?.cancel();
    _scrollController.dispose();
    _entranceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, controller, _) {
        if (controller.songs.isEmpty) {
          return const Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(
              child: Text(
                'No track playing',
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
            ),
          );
        }
        final song = controller.songs[controller.songId];
        final lyrics = controller.currentLyrics;
        final loading = controller.lyricsLoading;
        final size = MediaQuery.of(context).size;
        final topPad = MediaQuery.of(context).padding.top;
        final bottomPad = MediaQuery.of(context).padding.bottom;

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              // Blurred artwork background
              SizedBox(
                height: size.height,
                width: size.width,
                child: ArtworkWidget(
                  height: size.height,
                  width: size.width,
                  songId: song.id,
                  size: 2000,
                  type: ArtworkType.AUDIO,
                  path: song.data,
                ),
              ),
              BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                child: Container(
                  height: size.height,
                  width: size.width,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.black.withValues(alpha: 0.50),
                        Colors.black.withValues(alpha: 0.70),
                        Colors.black.withValues(alpha: 0.90),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0.0, 0.4, 1.0],
                    ),
                  ),
                ),
              ),
              // Content
              FadeTransition(
                opacity: _fadeAnimation,
                child: SlideTransition(
                  position: _slideAnimation,
                  child: _buildContent(
                    context,
                    song: song,
                    controller: controller,
                    lyrics: lyrics,
                    loading: loading,
                    topPad: topPad,
                    bottomPad: bottomPad,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildContent(
    BuildContext context, {
    required SongModel song,
    required AppController controller,
    required LyricsData? lyrics,
    required bool loading,
    required double topPad,
    required double bottomPad,
  }) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final leftPad = MediaQuery.of(context).padding.left;
    final rightPad = MediaQuery.of(context).padding.right;

    final lyricsBody = _buildLyricsBody(
      loading: loading,
      lyrics: lyrics,
      controller: controller,
    );

    if (isLandscape) {
      return Column(
        children: [
          SizedBox(height: topPad + 4),
          _Header(song: song, controller: controller),
          const SizedBox(height: 4),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Left: lyrics
                Expanded(
                  flex: 6,
                  child: Padding(
                    padding: EdgeInsets.only(left: leftPad),
                    child: lyricsBody,
                  ),
                ),
                // Right: mini controls centered
                Expanded(
                  flex: 4,
                  child: Padding(
                    padding: EdgeInsets.only(right: rightPad),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [_MiniControls(controller: controller)],
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: bottomPad + 4),
        ],
      );
    }

    // Portrait
    return Column(
      children: [
        SizedBox(height: topPad + 8),
        _Header(song: song, controller: controller),
        const SizedBox(height: 8),
        Expanded(child: lyricsBody),
        _MiniControls(controller: controller),
        SizedBox(height: bottomPad + 8),
      ],
    );
  }

  Widget _buildLyricsBody({
    required bool loading,
    required LyricsData? lyrics,
    required AppController controller,
  }) {
    if (loading) {
      return const _LyricsSkeleton();
    }
    if (lyrics == null) {
      return _EmptyState(onAdd: () => _openEditor(controller));
    }
    if (lyrics.isSynced) {
      // Lyrics can finish loading while the page is open and playing.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateClock();
      });
      return _SyncedLyrics(
        lyrics: lyrics,
        currentLineIndex: _currentLineIndex,
        lyricClockMs: _lyricClockMs,
        userScrolling: _userScrolling,
        scrollController: _scrollController,
        onUserScroll: _onUserScroll,
        onLineTap: _seekToLine,
      );
    }
    return _UnsyncedLyrics(lyrics: lyrics);
  }

  void _openEditor(AppController controller) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LyricsEditor(controller: controller),
    );
  }
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  final SongModel song;
  final AppController controller;
  const _Header({required this.song, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // Close button
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: Colors.white70,
              size: 32,
            ),
          ),
          const SizedBox(width: 12),
          // Small artwork
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ArtworkWidget(
              height: 48,
              width: 48,
              songId: song.id,
              size: 200,
              type: ArtworkType.AUDIO,
              path: song.data,
            ),
          ),
          const SizedBox(width: 12),
          // Title + Artist
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (song.artist != null)
                  Text(
                    song.artist!,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          // Edit button
          if (controller.currentLyrics != null)
            GestureDetector(
              onTap: () {
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => LyricsEditor(controller: controller),
                );
              },
              child: const Icon(
                Icons.edit_rounded,
                color: Colors.white54,
                size: 22,
              ),
            ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const Settings())),
            child: Icon(
              Icons.settings_rounded,
              color: Colors.white.withValues(alpha: 0.4),
              size: 20,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Synced lyrics display
// ---------------------------------------------------------------------------

class _SyncedLyrics extends StatefulWidget {
  final LyricsData lyrics;
  final int currentLineIndex;
  final ValueListenable<int> lyricClockMs;
  final bool userScrolling;
  final ScrollController scrollController;
  final VoidCallback onUserScroll;
  final ValueChanged<int> onLineTap;

  const _SyncedLyrics({
    required this.lyrics,
    required this.currentLineIndex,
    required this.lyricClockMs,
    required this.userScrolling,
    required this.scrollController,
    required this.onUserScroll,
    required this.onLineTap,
  });

  @override
  State<_SyncedLyrics> createState() => _SyncedLyricsState();
}

class _SyncedLyricsState extends State<_SyncedLyrics> {
  late List<GlobalKey> _lineKeys;

  @override
  void initState() {
    super.initState();
    _lineKeys = List.generate(widget.lyrics.lines.length, (_) => GlobalKey());
  }

  @override
  void didUpdateWidget(covariant _SyncedLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Recreate keys when lyrics change (different song)
    if (widget.lyrics.lines.length != _lineKeys.length) {
      _lineKeys = List.generate(widget.lyrics.lines.length, (_) => GlobalKey());
    }
    // Auto-scroll when current line changes
    if (widget.currentLineIndex != oldWidget.currentLineIndex &&
        widget.currentLineIndex >= 0 &&
        !widget.userScrolling) {
      _scrollAfterLayout(widget.currentLineIndex);
    }
    // Snap back when user stops scrolling
    if (oldWidget.userScrolling &&
        !widget.userScrolling &&
        widget.currentLineIndex >= 0) {
      _scrollAfterLayout(widget.currentLineIndex);
    }
  }

  void _scrollAfterLayout(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToLine(index);
    });
  }

  void _scrollToLine(int index) {
    if (index < 0 || index >= _lineKeys.length) return;
    if (!widget.scrollController.hasClients) return;

    final ctx = _lineKeys[index].currentContext;
    if (ctx == null) return;

    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeInOutCubic,
    );
  }

  List<TimedWord>? _cachedWords;
  int _cachedWordsIndex = -1;
  LyricsData? _cachedWordsLyrics;

  /// Timed words for the active line, computed once per line change.
  List<TimedWord> _wordsFor(int index) {
    if (_cachedWords != null &&
        _cachedWordsIndex == index &&
        identical(_cachedWordsLyrics, widget.lyrics)) {
      return _cachedWords!;
    }
    final lines = widget.lyrics.lines;
    final next = index + 1 < lines.length ? lines[index + 1].timestamp : null;
    _cachedWordsIndex = index;
    _cachedWordsLyrics = widget.lyrics;
    return _cachedWords = timedWords(
      lines[index],
      endMs: next?.inMilliseconds,
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewportHeight = MediaQuery.of(context).size.height;

    return ShaderMask(
      shaderCallback: (bounds) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          Colors.white,
          Colors.white,
          Colors.transparent,
        ],
        stops: [0.0, 0.08, 0.86, 1.0],
      ).createShader(bounds),
      blendMode: BlendMode.dstIn,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is UserScrollNotification) {
            widget.onUserScroll();
          }
          return false;
        },
        child: SingleChildScrollView(
          controller: widget.scrollController,
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: viewportHeight * 0.45,
            bottom: viewportHeight * 0.45,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: List.generate(widget.lyrics.lines.length, (index) {
              final isCurrent = index == widget.currentLineIndex;
              final isPast =
                  widget.currentLineIndex >= 0 &&
                  index < widget.currentLineIndex;
              final distance = widget.currentLineIndex >= 0
                  ? (index - widget.currentLineIndex).abs()
                  : 0;

              // Same depth falloff as the desktop lyrics view.
              final double alpha;
              if (isCurrent) {
                alpha = 1.0;
              } else if (distance == 1) {
                alpha = 0.6;
              } else if (distance == 2) {
                alpha = 0.42;
              } else {
                alpha = isPast ? 0.22 : 0.3;
              }

              final line = widget.lyrics.lines[index];
              return LyricLineTile(
                key: _lineKeys[index],
                text: line.text,
                isCurrent: isCurrent,
                alpha: alpha,
                words: isCurrent ? _wordsFor(index) : null,
                lyricClockMs: widget.lyricClockMs,
                onTap: () => widget.onLineTap(index),
              );
            }),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Individual lyric line — shimmer reveal + stretch (Apple Music style)
// ---------------------------------------------------------------------------

@visibleForTesting
class LyricLineTile extends StatelessWidget {
  final String text;
  final bool isCurrent;
  final double alpha;
  final List<TimedWord>? words;
  final ValueListenable<int> lyricClockMs;
  final VoidCallback onTap;

  const LyricLineTile({
    super.key,
    required this.text,
    required this.isCurrent,
    required this.alpha,
    required this.words,
    required this.lyricClockMs,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: isCurrent ? 1.0 : 0.0),
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
        builder: (context, t, child) {
          // Stretch effect: current line expands vertically, past lines compress
          final scaleX = 0.97 + 0.03 * t;
          final scaleY = 0.94 + 0.06 * t;
          return Transform(
            transform: Matrix4.identity()
              ..scaleByVector3(Vector3(scaleX, scaleY, 1.0)),
            alignment: Alignment.centerLeft,
            child: child,
          );
        },
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.symmetric(vertical: isCurrent ? 16 : 8),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOutCubic,
            // MERGED into the ambient style: a DefaultTextStyle replaces it
            // outright, and a bare TextStyle has no family, so lines used to
            // fall back to the platform font. Clash Display for every line,
            // 600 for the current one and 500 for the rest (it ships no
            // other weights) so the family never changes mid-animation.
            style: DefaultTextStyle.of(context).style.merge(
              AppFonts.displayStyle(
                fontSize: isCurrent ? 28 : 20,
                weight: isCurrent ? AppFonts.semibold : AppFonts.medium,
                color: Colors.white.withValues(alpha: alpha),
                height: 1.3,
                letterSpacing: isCurrent ? -0.5 : 0,
                shadows: isCurrent
                    ? [
                        Shadow(
                          color: Colors.white.withValues(alpha: 0.25),
                          blurRadius: 24,
                        ),
                      ]
                    : [const Shadow(color: Colors.transparent, blurRadius: 0)],
              ),
            ),
            child: isCurrent && words != null && words!.isNotEmpty
                ? WordFillText(words: words!, positionMs: lyricClockMs)
                : Text(text),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Unsynced lyrics display
// ---------------------------------------------------------------------------

class _UnsyncedLyrics extends StatelessWidget {
  final LyricsData lyrics;
  const _UnsyncedLyrics({required this.lyrics});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Text(
        lyrics.lines.map((l) => l.text).join('\n'),
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 18,
          height: 1.6,
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.lyrics_rounded,
            size: 64,
            color: Colors.white.withValues(alpha: 0.15),
          ),
          const SizedBox(height: 16),
          const Text(
            'No lyrics available',
            style: TextStyle(color: Colors.white54, fontSize: 16),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded, size: 20),
            label: const Text('Add Lyrics'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white70,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mini controls
// ---------------------------------------------------------------------------

class _MiniControls extends StatelessWidget {
  final AppController controller;
  const _MiniControls({required this.controller});

  @override
  Widget build(BuildContext context) {
    final player = controller.handler.currentTrackPlayer;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Waveform seek bar
          StreamBuilder<bool>(
            stream: player.playingStream,
            builder: (context, playingSnap) {
              final isPlaying = playingSnap.data ?? false;
              return StreamBuilder<PositionData>(
                stream:
                    Rx.combineLatest3<
                      Duration,
                      Duration,
                      Duration?,
                      PositionData
                    >(
                      player.positionStream,
                      player.bufferedPositionStream,
                      player.durationStream,
                      (pos, buf, dur) =>
                          PositionData(pos, buf, dur ?? Duration.zero),
                    ),
                builder: (context, snapshot) {
                  final data = snapshot.data;
                  return WaveformSeekBar(
                    duration: data?.duration ?? Duration.zero,
                    position: data?.position ?? Duration.zero,
                    bufferedPosition: data?.bufferedPosition ?? Duration.zero,
                    isPlaying: isPlaying,
                    onChangeEnd: (position) =>
                        controller.handler.seek(position),
                  );
                },
              );
            },
          ),
          const SizedBox(height: 4),
          // Transport buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(
                  Icons.skip_previous_rounded,
                  color: Colors.white,
                  size: 28,
                ),
                onPressed: controller.prev,
              ),
              const SizedBox(width: 16),
              StreamBuilder<PlayerState>(
                stream: player.playerStateStream,
                builder: (context, snapshot) {
                  final playing = snapshot.data?.playing ?? false;
                  return IconButton(
                    icon: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 36,
                    ),
                    onPressed: playing ? player.pause : player.play,
                  );
                },
              ),
              const SizedBox(width: 16),
              IconButton(
                icon: const Icon(
                  Icons.skip_next_rounded,
                  color: Colors.white,
                  size: 28,
                ),
                onPressed: controller.next,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LyricsSkeleton extends StatefulWidget {
  const _LyricsSkeleton();

  @override
  State<_LyricsSkeleton> createState() => _LyricsSkeletonState();
}

class _LyricsSkeletonState extends State<_LyricsSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer;

  // Widths as fractions to mimic varied lyric line lengths
  static const _lines = [
    0.75,
    0.55,
    0.85,
    0.6,
    0.7,
    0.5,
    0.8,
    0.45,
    0.65,
    0.55,
  ];

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _shimmer,
      builder: (context, _) {
        final t = _shimmer.value;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (int i = 0; i < _lines.length; i++)
                Padding(
                  padding: EdgeInsets.only(bottom: i == 2 ? 20 : 12),
                  child: _bar(_lines[i], i, t),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _bar(double widthFrac, int index, double t) {
    // Stagger the shimmer per line
    final phase = ((t + index * 0.08) % 1.0);
    final opacity = 0.06 + 0.08 * (0.5 + 0.5 * (1 - (2 * phase - 1).abs()));
    final height = index == 0 ? 26.0 : 18.0;
    final radius = height / 2;

    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFrac,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: opacity),
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}
