/// The root of the app: the player and the library as two scenes of one shell.
///
/// The library scene is today's drawer around a nested navigator whose root is
/// the Places list; the player scene is today's player; the mini player sits
/// above both on its own clock. [SceneController] owns the moves between them.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_zoom_drawer/flutter_zoom_drawer.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../controllers/drawer_controller.dart';
import '../../models/track_extras.dart';
import '../../onboarding/coach_marks.dart';
import '../../onboarding/home_guide.dart';
import '../../pages/equalizer.dart';
import '../../widgets/bottom_player.dart';
import '../../pages/menu_screen.dart';
import '../../pages/search_page.dart';
import '../../player/player_ui.dart';
import '../../services/update/update_service.dart';
import '../../themes/ember.dart';
import '../../widgets/body.dart';
import '../app_nav.dart';
import '../library/library_navigator.dart';
import '../library/library_tags.dart';
import '../library_page_key.dart';
import '../motion/morph.dart';
import '../motion/page_layer.dart';
import '../motion_spec.dart';
import '../places/place_scaffold.dart';
import '../places/places_page.dart';
import 'player_chrome.dart';
import 'scene_controller.dart';

/// How the shell reaches the library's navigator. The default builds the real
/// [LibraryNavigator]; tests hand in a stand-in.
abstract class LibraryHost {
  /// Builds the navigator with [root] as its first page. The swipe callbacks
  /// are the shell's hold on a rightward swipe at the root.
  Widget build(
    BuildContext context,
    Widget root, {
    bool Function()? onRootSwipeStart,
    ValueChanged<double>? onRootSwipeUpdate,
    ValueChanged<double>? onRootSwipeEnd,
  });

  LibraryNavigatorController get controller;

  /// Called when a swipe at the root is cancelled rather than released. The
  /// shell sets it; a host that never uses it just ignores cancels.
  VoidCallback? onRootSwipeCancel;

  /// The open pages, empty while the navigator is not mounted.
  List<LibraryPageKey> get pathOrEmpty => controller.path;

  /// Lets the library answer system back gestures (only while it is on screen).
  void setSystemBack(bool enabled) {}
}

class _RealLibraryHost implements LibraryHost {
  @override
  VoidCallback? onRootSwipeCancel;

  final GlobalKey<LibraryNavigatorState> key =
      GlobalKey<LibraryNavigatorState>();

  @override
  Widget build(
    BuildContext context,
    Widget root, {
    bool Function()? onRootSwipeStart,
    ValueChanged<double>? onRootSwipeUpdate,
    ValueChanged<double>? onRootSwipeEnd,
  }) => LibraryNavigator(
    key: key,
    root: root,
    onRootSwipeStart: onRootSwipeStart,
    onRootSwipeUpdate: onRootSwipeUpdate,
    onRootSwipeEnd: onRootSwipeEnd,
    onRootSwipeCancel: onRootSwipeCancel,
  );

  @override
  LibraryNavigatorController get controller => key.currentState!;

  @override
  List<LibraryPageKey> get pathOrEmpty => key.currentState?.path ?? const [];

  @override
  void setSystemBack(bool enabled) {
    key.currentState?.systemBackEnabled = enabled;
  }
}

class MotionShell extends StatefulWidget {
  const MotionShell({
    super.key,
    this.libraryHost,
    this.playerBuilder,
    this.equalizerBuilder,
    this.miniPlayerBuilder,
    this.libraryFrame,
    this.announceShellReady = true,
  });

  final LibraryHost? libraryHost;

  /// Replace today's player, equalizer and mini player (tests).
  final WidgetBuilder? playerBuilder;
  final WidgetBuilder? equalizerBuilder;
  final Widget Function(BuildContext context, AppController controller)?
  miniPlayerBuilder;

  /// Replaces the drawer, backdrop and first-run guide around the library
  /// (tests).
  /// Tells the update service that notices may be shown (off in tests).
  final bool announceShellReady;

  final Widget Function(
    BuildContext context,
    ZoomDrawerController drawer,
    Widget content,
  )?
  libraryFrame;

  @override
  State<MotionShell> createState() => _MotionShellState();
}

class _MotionShellState extends State<MotionShell>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final ZoomDrawerController _drawerController = ZoomDrawerController();
  final GlobalKey<MorphScopeState> _morphKey = GlobalKey<MorphScopeState>();

  /// Keeps the drawer (and its state) alive across equalizer-only and music
  /// mode, wherever the frame ends up in the tree.
  final GlobalKey _drawerKey = GlobalKey();

  /// Keeps the mini player's bar alive as it moves between its two homes: the
  /// overlay above both layers, and the drawer's card.
  final GlobalKey _miniKey = GlobalKey();

  /// True while the drawer is closed; the bar rides the overlay then.
  final ValueNotifier<bool> _drawerClosed = ValueNotifier<bool>(true);
  ValueNotifier<DrawerState>? _watchedDrawer;
  bool? _wasEq;
  final _menuKey = GlobalKey();
  final _searchKey = GlobalKey();
  final _coachController = CoachMarkController('home');
  late final LibraryHost _library = widget.libraryHost ?? _RealLibraryHost();
  late final SceneController _scenes;
  late final AppController _app;
  bool _predictiveBack = false;
  bool _backBusy = false;
  bool _moved = false;
  late final DateTime _openedAt;

  @override
  void initState() {
    super.initState();
    _openedAt = DateTime.now();
    _app = context.read<AppController>();
    _scenes = SceneController(
      vsync: this,
      libraryOf: () => _library.controller,
      initial: _app.hasMiniPlayer ? Scene.player : Scene.library,
      origin: () => _app.playbackOrigin,
      morph: () => _morphKey.currentState,
      playingTrackTag: _playingTrackTag,
      screenSize: () => MediaQuery.sizeOf(context),
      closeRoutesAbove: _closeRoutesAbove,
    );
    _scenes.scene.addListener(() {
      _moved = true;
      _syncSystemBack();
    });
    if (!_app.isEqMode) AppNav.host = _scenes;
    WidgetsBinding.instance.addObserver(this);
    _library.onRootSwipeCancel = () =>
        unawaited(_scenes.endBackToPlayer(commit: false));
    _app.addListener(_onApp);
    // The main shell is up: update notices may now be shown.
    if (widget.announceShellReady) UpdateService.instance.markShellReady();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<DrawerProvider>().setController(_drawerController);
      _watchDrawer();
      _syncSystemBack();
    });
  }

  Object? _playingTrackTag() {
    if (!_app.hasNowPlaying) return null;
    final song = _app.songs[_app.songId];
    // The same id scheme the rows use: a YouTube track is its video id.
    return trackTag(song.ytVideoId ?? song.id);
  }

  ModalRoute<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Depending on the route re-runs this when another route covers the shell
    // or uncovers it again.
    _route = ModalRoute.of(context);
    _syncSystemBack();
  }

  /// Pops the pages over the shell's own route on the navigator it lives in
  /// (Settings, lyrics), stopping at a popup: a sheet or dialog on top was
  /// opened by the same tap that shows the player (Hype Connect's "play it
  /// here?"), and closing it would answer it. The popup stays over the player.
  void _closeRoutesAbove() {
    final route = _route;
    if (route == null || route.isCurrent || !mounted) return;
    Navigator.of(
      context,
    ).popUntil((r) => identical(r, route) || r is PopupRoute);
  }

  /// The shell may answer back gestures only while its route is the current
  /// one: a page pushed over it (Settings, lyrics) owns the gesture.
  bool get _routeCurrent => _route?.isCurrent ?? true;

  /// Follows whichever state notifier the drawer controller holds now (it
  /// changes if the drawer is ever rebuilt).
  void _watchDrawer() {
    final n = _drawerController.stateNotifier;
    if (identical(n, _watchedDrawer)) return;
    _unwatchDrawer();
    _watchedDrawer = n;
    n?.addListener(_onDrawerState);
    _onDrawerState();
  }

  void _unwatchDrawer() {
    try {
      _watchedDrawer?.removeListener(_onDrawerState);
    } catch (_) {
      // The drawer was torn down first and took its notifier with it.
    }
    _watchedDrawer = null;
  }

  void _onDrawerState() {
    final n = _watchedDrawer;
    _drawerClosed.value = n == null || n.value == DrawerState.closed;
    _syncSystemBack();
  }

  void _syncSystemBack() {
    _library.setSystemBack(
      _routeCurrent && _scenes.scene.value == Scene.library && !_drawerOpen,
    );
  }

  /// A saved session can arrive a moment after the shell opens. If nothing was
  /// touched meanwhile, the app still opens on the player.
  void _onApp() {
    if (_moved || _scenes.scene.value != Scene.library) return;
    if (_app.isEqMode || !_app.hasMiniPlayer) return;
    // Any library navigation counts as the user having moved on: the player
    // must not snap in over a page they opened.
    if (_scenes.libraryTouched || _library.pathOrEmpty.isNotEmpty) return;
    if (DateTime.now().difference(_openedAt) > const Duration(seconds: 4)) {
      return;
    }
    _scenes.showPlayerNow();
    _moved = false;
  }

  @override
  void dispose() {
    _app.removeListener(_onApp);
    _unwatchDrawer();
    _drawerClosed.dispose();
    WidgetsBinding.instance.removeObserver(this);
    if (identical(AppNav.host, _scenes)) AppNav.host = null;
    _scenes.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------- back

  bool get _drawerOpen {
    final n = _drawerController.stateNotifier;
    return n != null && n.value != DrawerState.closed;
  }

  Future<void> _back() async {
    if (_drawerOpen) {
      _drawerController.close?.call();
      return;
    }
    if (_scenes.scene.value == Scene.player) return;
    if (_backBusy) return;
    _backBusy = true;
    try {
      final lib = _library.controller;
      if (lib.canPop) {
        await lib.pop();
      } else if (_app.hasMiniPlayer) {
        await _scenes.toPlayerByBackKey();
      } else {
        await SystemNavigator.pop();
      }
    } finally {
      _backBusy = false;
    }
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    // The equalizer-only app has no scenes (and no library to ask).
    if (_app.isEqMode ||
        !_routeCurrent ||
        _backBusy ||
        _scenes.scene.value != Scene.library ||
        _scenes.inTransition ||
        _drawerOpen ||
        !_app.hasMiniPlayer ||
        _library.controller.canPop) {
      return false;
    }
    _predictiveBack = true;
    _scenes.beginBackToPlayer();
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (_predictiveBack) _scenes.updateBackToPlayer(backEvent.progress);
  }

  @override
  void handleCommitBackGesture() {
    if (!_predictiveBack) return;
    _predictiveBack = false;
    unawaited(_scenes.endBackToPlayer(commit: true));
  }

  @override
  void handleCancelBackGesture() {
    if (!_predictiveBack) return;
    _predictiveBack = false;
    unawaited(_scenes.endBackToPlayer(commit: false));
  }

  // ----------------------------------------------------------------- places

  void _openPlace(BuildContext context, PlaceId id, bool fancy) {
    AppNav.openPage(
      context,
      PlaceScaffold(
        id: id,
        fancy: fancy,
        onBack: () => unawaited(_library.controller.pop()),
        onMenu: () => context.read<DrawerProvider>().toggleDrawer(),
        onSearch: _openSearch,
      ),
      key: LibraryPageKey.place(id.name),
      morphFrom: id.morphTag,
    );
  }

  void _openSearch() {
    AppNav.openPage(
      context,
      const SearchPage(),
      key: const LibraryPageKey('search'),
      sibling: true,
    );
  }

  Future<void> _tryShowCoachMarks() async {
    if (_app.isEqMode) return;
    if (await _coachController.hasBeenShown() || !mounted) return;
    // Let layout settle before measuring anything.
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!mounted || _scenes.scene.value != Scene.library) return;
    if (_library.controller.canPop) return;
    _coachController.start(context, [
      CoachStep(
        targetKey: _searchKey,
        title: 'Search everything',
        description:
            'One box across your library, your drive and YouTube. Tap a result '
            'to play it and build a station from it.',
        icon: Icons.search_rounded,
        tooltipPosition: TooltipPosition.below,
      ),
      CoachStep(
        targetKey: _menuKey,
        title: 'Settings & EQ',
        description:
            'Open the menu for Settings, Equalizer, Visualizer, and more.',
        icon: Icons.tune_rounded,
        tooltipPosition: TooltipPosition.below,
      ),
    ]);
  }

  // ------------------------------------------------------------------ build

  /// The drawer, the backdrop and the first-run guide around [content]: the
  /// frame every top-level screen has always had, the library and the
  /// equalizer-only app alike.
  Widget _frame(BuildContext context, Widget content, bool fancy) {
    final framed = widget.libraryFrame;
    if (framed != null) {
      return KeyedSubtree(
        key: _drawerKey,
        child: framed(context, _drawerController, content),
      );
    }
    final drawer = ZoomDrawer(
      controller: _drawerController,
      menuScreen: MenuScreen(),
      menuBackgroundColor: Colors.black,
      mainScreen: HomeGuide(
        onComplete: _tryShowCoachMarks,
        // The blurred cover backdrop only shows in fancy mode (pages are
        // opaque otherwise), and its blur is costly to redraw every frame.
        child: fancy
            ? Body(child: content)
            : ColoredBox(color: Ember.ground, child: content),
      ),
      borderRadius: 24.0,
      showShadow: true,
      angle: -12.0,
      slideWidth: MediaQuery.sizeOf(context).width * 0.85,
      shadowLayer2Color: Colors.black.withAlpha(100),
    );
    return KeyedSubtree(key: _drawerKey, child: drawer);
  }

  @override
  Widget build(BuildContext context) {
    final mode = context.select<AppController, ({bool eq, bool fancy})>(
      (c) => (eq: c.isEqMode, fancy: c.isFancy),
    );
    if (_wasEq != mode.eq) {
      _wasEq = mode.eq;
      // The frame and the library mount in this build: hook them up after it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _watchDrawer();
        _syncSystemBack();
      });
    }
    if (mode.eq) {
      // Equalizer-only app: no scenes to move between, so nothing may drive
      // them either.
      if (identical(AppNav.host, _scenes)) AppNav.host = null;
      return _frame(
        context,
        widget.equalizerBuilder?.call(context) ?? const Equalizer(),
        // The equalizer's pages are not all opaque: keep its backdrop.
        true,
      );
    }
    AppNav.host ??= _scenes;
    return ListenableBuilder(
      listenable: Listenable.merge([_scenes.scene, _scenes.list]),
      builder: (context, child) => PopScope(
        // Back leaves the app only from a player that has settled: a second
        // press while the player is still arriving must not exit.
        canPop: _scenes.scene.value == Scene.player && !_scenes.inTransition,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_back());
        },
        child: child!,
      ),
      child: MorphScope(
        key: _morphKey,
        child: LayoutBuilder(
          builder: (context, box) {
            final center = Offset(box.maxWidth / 2, box.maxHeight / 2);
            return Stack(
              fit: StackFit.expand,
              children: [
                // The incoming layer is drawn over the outgoing one: the
                // library over the player when leaving it, the player over
                // the library when entering it. Keys keep both alive when
                // they swap places.
                ListenableBuilder(
                  listenable: _scenes.leaving,
                  builder: (context, _) {
                    final library = KeyedSubtree(
                      key: const ValueKey('library-layer'),
                      child: _libraryLayer(center, mode.fancy),
                    );
                    final player = KeyedSubtree(
                      key: const ValueKey('player-layer'),
                      child: _playerLayer(center),
                    );
                    return Stack(
                      fit: StackFit.expand,
                      children: _scenes.leaving.value
                          ? [player, library]
                          : [library, player],
                    );
                  },
                ),
                // The mini player above both layers, on its own clock, while
                // the drawer is closed.
                Positioned.fill(child: _miniHost(overlay: true)),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The library, with the mini player riding inside its card so that the
  /// drawer carries both together.
  Widget _libraryContent(BuildContext context, bool fancy) {
    final root = PlacesPage(
      fancy: fancy,
      menuKey: _menuKey,
      searchKey: _searchKey,
      onOpen: (ctx, id) => _openPlace(ctx, id, fancy),
      onMenu: () => context.read<DrawerProvider>().toggleDrawer(),
      onSearch: _openSearch,
    );
    return Selector<AppController, bool>(
      selector: (_, c) => c.hasMiniPlayer,
      builder: (context, hasMini, _) {
        final mq = MediaQuery.of(context);
        final inset = mq.padding.bottom;
        final pad =
            inset +
            (hasMini ? BottomPlayer.barHeight + BottomPlayer.barGap : 0);
        return Stack(
          fit: StackFit.expand,
          children: [
            // The padding is room for the mini player; whatever of it the
            // keyboard covers is not taken off the pages a second time.
            MediaQuery(
              data: mq.copyWith(
                padding: mq.padding.copyWith(bottom: 0),
                viewPadding: mq.viewPadding.copyWith(bottom: 0),
                viewInsets: mq.viewInsets.copyWith(
                  bottom: math.max(0.0, mq.viewInsets.bottom - pad),
                ),
              ),
              child: Padding(
                padding: EdgeInsets.only(bottom: pad),
                child: _library.build(
                  context,
                  root,
                  onRootSwipeStart: hasMini ? _scenes.beginRootSwipe : null,
                  onRootSwipeUpdate: hasMini ? _scenes.updateRootSwipe : null,
                  onRootSwipeEnd: hasMini
                      ? (v) => _scenes.endRootSwipe(v, width: mq.size.width)
                      : null,
                ),
              ),
            ),
            if (hasMini) Positioned.fill(child: _miniHost(overlay: false)),
          ],
        );
      },
    );
  }

  Widget _libraryLayer(Offset center, bool fancy) {
    final layer = _frame(context, _libraryContent(context, fancy), fancy);
    return ListenableBuilder(
      listenable: Listenable.merge([
        _scenes.leaving,
        _scenes.scene,
        _scenes.swipeMapping,
      ]),
      builder: (context, _) {
        final leaving = _scenes.leaving.value || _scenes.swipeMapping.value;
        final swipe = _scenes.swipeMapping.value;
        return ValueListenableBuilder<double>(
          valueListenable: _scenes.list,
          child: layer,
          builder: (context, p, child) {
            final hidden = p <= 0 && _scenes.scene.value == Scene.player;
            return Offstage(
              offstage: hidden,
              child: TickerMode(
                enabled: !hidden,
                child: IgnorePointer(
                  // Not while the layer is still invisible, before a move to
                  // it has started.
                  ignoring: _scenes.scene.value != Scene.library || p <= 0,
                  child: PageLayer(
                    progress: _scenes.list,
                    scaleAt0: leaving
                        ? MotionSpec.libraryEnterFrom
                        : MotionSpec.libraryExitTo,
                    scaleAt1: 1,
                    opacityAt0: 0,
                    opacityAt1: 1,
                    // A root swipe zooms about a point a screen width to the
                    // right of the centre, so the library drifts away.
                    pivot: swipe ? center.translate(center.dx * 2, 0) : center,
                    child: child!,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _playerLayer(Offset center) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        _scenes.playerMounted,
        _scenes.leaving,
        _scenes.playerPivot,
        _scenes.scene,
      ]),
      builder: (context, _) {
        if (!_scenes.playerMounted.value) return const SizedBox.shrink();
        final leaving = _scenes.leaving.value;
        final layer = IgnorePointer(
          ignoring: _scenes.scene.value != Scene.player,
          child: PageLayer(
            progress: _scenes.list,
            scaleAt0: 1,
            scaleAt1: leaving
                ? MotionSpec.playerExitScale
                : MotionSpec.playerEnterFrom,
            opacityAt0: 1,
            opacityAt1: 0,
            pivot: _scenes.playerPivotOrCenter,
            child: PlayerChromeScope(
              hidden: _scenes.container,
              child: widget.playerBuilder?.call(context) ?? const Player(),
            ),
          ),
        );
        // Fully hidden behind the library (opacity 0): nothing in it ticks
        // until a move toward the player starts.
        return ValueListenableBuilder<double>(
          valueListenable: _scenes.list,
          child: layer,
          builder: (context, p, child) => TickerMode(
            enabled: !(p >= 1 && _scenes.scene.value == Scene.library),
            child: child!,
          ),
        );
      },
    );
  }

  /// The mini player's bar. One widget, kept alive by a key as it changes
  /// homes. It follows the track through the controller, as the old bottom bar
  /// did.
  Widget _miniBar() {
    return KeyedSubtree(
      key: _miniKey,
      // The same floating bar as Settings: the blurred cover under rounded
      // corners, its own inset below.
      child: RepaintBoundary(
        child: Consumer<AppController>(
          builder: (context, controller, _) =>
              widget.miniPlayerBuilder?.call(context, controller) ??
              BottomPlayer(
                controller: controller,
                onTap: () => AppNav.toPlayer(context, recordOrigin: false),
              ),
        ),
      ),
    );
  }

  /// The bar sits above the drawer's card, which used to hold it: a rightward
  /// flick that starts on it opens the drawer as before. (The card does not
  /// follow the finger here, as it does for a drag on the pages; the drawer
  /// opens on its own animation once the flick ends.)
  Widget _drawerSwipe(Widget bar) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (d) {
        if (d.velocity.pixelsPerSecond.dx > 300) {
          _drawerController.open?.call();
        }
      },
      child: bar,
    );
  }

  /// One of the mini player's two homes. The bar moves on its own clock only
  /// (record T1/T2): it rises 74 dp fading in, and sinks the same way, over
  /// the layers while the drawer is closed. Once the drawer starts to open it
  /// moves into the drawer's card (which is at rest then) so it travels with
  /// it.
  Widget _miniHost({required bool overlay}) {
    return Selector<AppController, bool>(
      selector: (_, c) => c.hasMiniPlayer,
      builder: (context, hasMini, _) {
        if (!hasMini) return const SizedBox.shrink();
        return ValueListenableBuilder<bool>(
          valueListenable: _drawerClosed,
          builder: (context, closed, _) {
            if (closed != overlay) return const SizedBox.shrink();
            return ValueListenableBuilder<bool>(
              valueListenable: HomeGuide.visible,
              builder: (context, guide, _) {
                // Not over the first-run guide's scrim and its buttons.
                if (guide) return const SizedBox.shrink();
                return ValueListenableBuilder<Scene>(
                  valueListenable: _scenes.scene,
                  builder: (context, scene, _) => IgnorePointer(
                    ignoring: scene != Scene.library,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: _MiniRise(
                        mini: _scenes.mini,
                        child: overlay ? _drawerSwipe(_miniBar()) : _miniBar(),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

/// Raises its child by the mini player's rise distance times what is left of
/// the clock, fading with it. The child is built once.
class _MiniRise extends StatelessWidget {
  const _MiniRise({required this.mini, required this.child});

  final ValueListenable<double> mini;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: mini,
      child: child,
      builder: (context, m, child) => m <= 0
          ? const SizedBox.shrink()
          : Opacity(
              opacity: m.clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(0, (1 - m) * MotionSpec.miniPlayerRise),
                child: child,
              ),
            ),
    );
  }
}
