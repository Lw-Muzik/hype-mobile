// ignore_for_file: prefer_initializing_formals

/// The two scenes of the app and the three clocks that move between them.
///
/// The player and the library are scenes of one shell. A move between them runs
/// up to three independent clocks that start in the same frame:
///
/// * [list]: the two page layers (0 = player, 1 = library) and the shared art,
///   cos ease over 250 ms, or the finger;
/// * [container]: the player's controls band (0 = shown, 1 = hidden), quart ease
///   over 250 ms leaving the player and 500 ms entering it, copied 1:1 from the
///   list whenever a finger or the back key drives the move;
/// * [mini]: the mini player (0 = sunk, 1 = risen), quart over 500 ms, always
///   on its own.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../services/player_reveal_bus.dart';
import '../app_nav.dart';
import '../library/library_tags.dart';
import '../library_page_key.dart';
import '../motion/morph.dart';
import '../motion/motion_progress.dart';
import '../motion_spec.dart';
import '../playback_origin.dart';

enum Scene { player, library }

/// The shown position of a drag that went past either end: a soft pull rather
/// than a hard stop. Inside 0..1 the value is returned as is.
double softOverdrag(double x) {
  if (x >= 0 && x <= 1) return x;
  if (x < 0) return -0.3 * math.sqrt(0.3 * math.min(1.0, -x));
  return 1 + 0.3 * math.sqrt(0.3 * math.min(1.0, x - 1));
}

/// A progress seen the other way round (1 - value).
class _Inverted extends ChangeNotifier implements ValueListenable<double> {
  _Inverted(this._source) {
    _source.addListener(notifyListeners);
  }

  final ValueListenable<double> _source;

  @override
  double get value => 1 - _source.value;

  @override
  void dispose() {
    _source.removeListener(notifyListeners);
    super.dispose();
  }
}

class SceneController implements NavHost {
  SceneController({
    required TickerProvider vsync,
    required LibraryNavigatorController Function() libraryOf,
    Scene initial = Scene.library,
    PlaybackOrigin? Function()? origin,
    MorphScopeState? Function()? morph,
    Object? Function()? playingTrackTag,
    Size Function()? screenSize,
    VoidCallback? closeRoutesAbove,
  }) : _vsync = vsync,
       _libraryOf = libraryOf,
       _origin = origin,
       _morph = morph,
       _playingTrackTag = playingTrackTag,
       _screenSize = screenSize,
       _closeRoutesAbove = closeRoutesAbove,
       scene = ValueNotifier<Scene>(initial),
       list = MotionProgress(
         vsync: vsync,
         initial: initial == Scene.library ? 1 : 0,
       ),
       container = MotionProgress(
         vsync: vsync,
         initial: initial == Scene.library ? 1 : 0,
       ),
       mini = MotionProgress(
         vsync: vsync,
         initial: initial == Scene.library ? 1 : 0,
       ),
       playerMounted = ValueNotifier<bool>(initial == Scene.player) {
    list.addListener(_copyContainer);
  }

  final TickerProvider _vsync;
  final LibraryNavigatorController Function() _libraryOf;
  final PlaybackOrigin? Function()? _origin;
  final MorphScopeState? Function()? _morph;
  final Object? Function()? _playingTrackTag;
  final Size Function()? _screenSize;

  /// Closes every route the app has pushed over the shell, so the scenes below
  /// are what the user sees.
  final VoidCallback? _closeRoutesAbove;

  /// The scene a move is heading to (or resting on).
  final ValueNotifier<Scene> scene;

  /// True once a page was opened or popped through [library]: the user has
  /// started navigating.
  bool libraryTouched = false;

  /// 0 = player, 1 = library.
  final MotionProgress list;

  /// 0 = player chrome shown, 1 = hidden.
  final MotionProgress container;

  /// 0 = mini player sunk, 1 = risen.
  final MotionProgress mini;

  /// Whether the player widget exists. It is built only while it is needed, as
  /// the route used to be, so it does no work behind the library.
  final ValueNotifier<bool> playerMounted;

  /// True while the layers use the leaving-the-player mapping. Chosen when a
  /// move starts from rest and kept through any interruption, so reversing
  /// replays the same mapping instead of jumping.
  final ValueNotifier<bool> leaving = ValueNotifier<bool>(true);

  /// True while the library layer follows a rightward swipe at its root: it
  /// shrinks to half about a point one screen width to the right of its centre,
  /// so it drifts away to the right as the player arrives.
  final ValueNotifier<bool> swipeMapping = ValueNotifier<bool>(false);

  /// Where the player layer zooms about: the centre of the cover.
  final ValueNotifier<Offset> playerPivot = ValueNotifier<Offset>(Offset.zero);

  late final _Inverted _toPlayerProgress = _Inverted(list);

  int _token = 0;
  bool _lockContainer = false;
  bool _disposed = false;

  late final LibraryNavigatorController _shellLibrary = _ShellLibrary(this);

  /// The library as pages see it: opening a page while the player is showing
  /// first moves the player away.
  @override
  LibraryNavigatorController get library => _shellLibrary;

  LibraryNavigatorController get _raw => _libraryOf();

  Scene get target => scene.value;

  /// Starts a new move: whatever the previous one was doing is over, and its
  /// flights that never got going must not stay hidden behind a stand-in.
  int _newToken() {
    _morph?.call()?.abortUnstartedFlights(this);
    return ++_token;
  }

  /// Whether anything is moving between the scenes.
  bool get inTransition =>
      list.isAnimating ||
      list.isFingerDriven ||
      (list.value > 0 && list.value < 1);

  void _copyContainer() {
    if (_lockContainer) container.dragTo(list.value, clamp: false);
  }

  // Layer scales for the current mapping, used to turn a rectangle measured
  // inside a scaled layer back into where it rests.
  double libraryScale(double p) => (leaving.value || swipeMapping.value)
      ? MotionSpec.libraryEnterFrom + 0.5 * p
      : 1.5 - 0.5 * p;

  double _playerScale(double p) => leaving.value ? 1 + 0.25 * p : 1 - 0.25 * p;

  Offset get _screenCenter {
    final s = _screenSize?.call();
    return s == null ? Offset.zero : Offset(s.width / 2, s.height / 2);
  }

  /// The pivot the player layer really uses: the cover's centre once known,
  /// else the plain screen centre.
  Offset get playerPivotOrCenter =>
      playerPivot.value == Offset.zero ? _screenCenter : playerPivot.value;

  /// The point the library layer scales about.
  Offset get libraryPivot {
    final s = _screenSize?.call();
    if (s == null) return Offset.zero;
    return Offset(
      s.width / 2 + (swipeMapping.value ? s.width : 0),
      s.height / 2,
    );
  }

  static Rect _resting(Rect measured, double scale, Offset pivot) {
    if (scale == 1 || scale == 0) return measured;
    // The measured top-left is where the corner is drawn; the size is the laid
    // out one. Only the corner needs mapping back.
    final topLeft = pivot + (measured.topLeft - pivot) / scale;
    return topLeft & measured.size;
  }

  Rect? _restingLibraryRect(Object tag) {
    final r = _morph?.call()?.rectOf(tag);
    if (r == null) return null;
    return _resting(r, libraryScale(list.value), libraryPivot);
  }

  Rect? _restingPlayerRect(Object tag) {
    final r = _morph?.call()?.rectOf(tag);
    if (r == null) return null;
    return _resting(r, _playerScale(list.value), playerPivotOrCenter);
  }

  /// Puts the pivot on the cover's centre, once the player is laid out, and
  /// returns the cover's resting rectangle as measured before the pivot moved
  /// (the rectangle a flight must end on).
  Rect? _updatePivot() {
    final art = _restingPlayerRect(kNowPlayingArtTag);
    if (art != null) playerPivot.value = art.center;
    return art;
  }

  /// Drops a root swipe that a tap move (or a new drag) overtakes. The swipe's
  /// pending settle then resolves as interrupted and does nothing.
  void _cancelSwipe() {
    final swipe = _swipe;
    if (swipe == null) return;
    _swipe = null;
    swipe.dispose();
    _lockContainer = false;
  }

  /// The art box side a drag of the cover is measured against: the smaller of
  /// the width and the height the player has to work with. Null until the
  /// screen is known.
  double? artBoxSide() {
    final s = _screenSize?.call();
    return s == null ? null : math.min(s.width, s.height);
  }

  /// Shows the player at once, without a move (a session restored while the
  /// shell is still opening).
  void showPlayerNow() {
    _newToken();
    leaving.value = false;
    playerMounted.value = true;
    scene.value = Scene.player;
    list.jumpTo(0);
    container.jumpTo(0);
    mini.jumpTo(0);
  }

  // ---------------------------------------------------------------- tap moves

  Future<void> _afterFrame() {
    WidgetsBinding.instance.scheduleFrame();
    return WidgetsBinding.instance.endOfFrame;
  }

  /// Whether [rect] (resting, in scope coordinates) is on screen.
  bool _onScreen(Rect? rect) {
    if (rect == null) return false;
    final size = _screenSize?.call();
    return size == null || rect.overlaps(Offset.zero & size);
  }

  /// The tag of the playing song's cover in lists, or null.
  Object? get _playingTag => _playingTrackTag?.call();

  @override
  Future<void> toLibrary({PlaybackOrigin? landOn, Object? morphFrom}) =>
      _toLibrary(landOn: landOn);

  Future<void> _toLibrary({
    PlaybackOrigin? landOn,
    Future<void> Function()? afterShowPath,
  }) async {
    if (scene.value == Scene.library) {
      // Already there, or already on the way.
      if (!inTransition && landOn != null) await _raw.showPath(landOn.path);
      return;
    }
    final fromRest = !inTransition;
    _cancelSwipe();
    final token = _newToken();
    scene.value = Scene.library;
    final origin = landOn ?? _origin?.call();
    await _raw.showPath(origin?.path ?? const []);
    if (_disposed || token != _token) return;
    if (fromRest) {
      leaving.value = true;
      swipeMapping.value = false;
    }
    _lockContainer = false;
    if (afterShowPath != null) unawaited(afterShowPath());

    // The row the cover flies into must exist and sit still before it is
    // measured: reveal it at once (the library is still invisible, so nothing
    // may scroll under the zoom), let one frame pass, and measure.
    Rect? row;
    final tag = _playingTag;
    if (fromRest && afterShowPath == null && tag != null) {
      // One frame first, so the layers are drawn with the mapping that is
      // current now; both measurements then undo the same transform.
      await _afterFrame();
      if (_disposed || token != _token) return;
      final before = _restingLibraryRect(tag);
      PlayerRevealBus.revealNowPlaying(instant: true);
      await _afterFrame();
      if (_disposed || token != _token) return;
      final after = _restingLibraryRect(tag);
      if (before != null &&
          after != null &&
          (before.top - after.top).abs() < 1 &&
          _onScreen(after)) {
        row = after;
      }
    }
    if (fromRest && list.value == 0) {
      final cover = _updatePivot();
      if (row != null && cover != null) _flyToRow(tag!, cover, row);
    }
    final done = list.run(to: 1, duration: MotionSpec.listPage, curve: cosEase);
    unawaited(
      container.run(
        to: 1,
        duration: MotionSpec.containerLeavePlayer,
        curve: quartOut,
      ),
    );
    unawaited(
      mini.run(to: 1, duration: MotionSpec.miniPlayer, curve: quartOut),
    );
    final reached = await done;
    if (reached && token == _token) _settleInLibrary();
  }

  void _flyToRow(Object tag, Rect from, Rect row) {
    final morph = _morph?.call();
    if (morph == null) return;
    unawaited(
      morph.fly(
        from: kNowPlayingArtTag,
        to: tag,
        progress: list,
        fromRect: from,
        toRect: row,
        owner: this,
      ),
    );
  }

  /// The list has landed. The mini player is not touched: it keeps its own
  /// clock to the end.
  void _settleInLibrary() {
    container.jumpTo(1);
    playerMounted.value = false;
  }

  @override
  Future<void> toPlayer({Object? morphFrom}) {
    // Whatever sits over the shell (Settings, the equalizer) goes first, so
    // callers that live above it (the mini players) reach the player.
    _closeRoutesAbove?.call();
    return _toPlayer(morphFrom: morphFrom);
  }

  /// The back key at the root list: the container copies the list's clock
  /// instead of running its own.
  Future<void> toPlayerByBackKey() => _toPlayer(lockContainer: true);

  Future<void> _toPlayer({
    Object? morphFrom,
    bool lockContainer = false,
  }) async {
    // During a root swipe's finger phase or settle the scene already reads
    // player; a tap then takes the move over and completes it.
    if (scene.value == Scene.player && _swipe == null) return;
    final fromRest = !inTransition;
    // The row to fly from is the one playing now: a queue being installed can
    // report its first track for a moment, and mounting the player below waits
    // a frame.
    final source = morphFrom ?? _playingTag;
    _cancelSwipe();
    final token = _newToken();
    scene.value = Scene.player;
    if (fromRest) {
      leaving.value = false;
      swipeMapping.value = false;
    }
    // The container copies the list only when the back key starts the move
    // from rest; pressed during a running move it is a plain retarget.
    final lock = lockContainer && fromRest;
    _lockContainer = lock;
    if (lock) container.dragTo(list.value);
    if (!playerMounted.value) {
      playerMounted.value = true;
      await _afterFrame();
      if (_disposed || token != _token) return;
    }
    if (fromRest && list.value == 1) {
      _flyFromRow(source, _updatePivot());
    }
    final done = list.run(to: 0, duration: MotionSpec.listPage, curve: cosEase);
    if (!lock) {
      unawaited(
        container.run(
          to: 0,
          duration: MotionSpec.containerEnterPlayer,
          curve: quartOut,
        ),
      );
    }
    unawaited(
      mini.run(to: 0, duration: MotionSpec.miniPlayer, curve: quartOut),
    );
    final reached = await done;
    if (reached && token == _token && lock) {
      _lockContainer = false;
      container.jumpTo(0);
    }
  }

  /// The cover flies out of the playing song's row or cell when it is on
  /// screen; otherwise the player just zooms in place.
  void _flyFromRow(Object? tag, Rect? to) {
    final morph = _morph?.call();
    if (morph == null || tag == null) return;
    final from = _restingLibraryRect(tag);
    if (to == null || !_onScreen(from)) return;
    unawaited(
      morph.fly(
        from: tag,
        to: kNowPlayingArtTag,
        progress: _toPlayerProgress,
        fromRect: from,
        toRect: to,
        owner: this,
      ),
    );
  }

  /// A page opened while the player is showing (go to album, go to artist):
  /// the player moves away and the page lands on top of where the music came
  /// from.
  Future<void> _openFromPlayer(
    Widget page, {
    required LibraryPageKey key,
    Object? morphFrom,
    required bool sibling,
  }) {
    final shown = Completer<void>();
    var hooked = false;
    unawaited(
      _toLibrary(
        afterShowPath: () async {
          hooked = true;
          try {
            // The origin may already end on this very page: nothing to push.
            final path = _raw.path;
            if (path.isNotEmpty && path.last == key) {
              if (!shown.isCompleted) shown.complete();
              return;
            }
            await _raw.openPage(
              page,
              key: key,
              morphFrom: null,
              sibling: sibling,
            );
            if (!shown.isCompleted) shown.complete();
          } catch (error, stack) {
            if (!shown.isCompleted) shown.completeError(error, stack);
          }
        },
      ).whenComplete(() {
        // Another move took over before the page could be pushed.
        if (!hooked && !shown.isCompleted) shown.complete();
      }),
    );
    return shown.future;
  }

  // ------------------------------------------------------- finger: art drag

  Future<void>? _dragPrepared;

  /// The finger took hold of the player's cover. Returns false (and takes
  /// nothing) while a move is already running.
  bool beginPlayerDrag() {
    // A root swipe still settling owns the move: grabbing the cover then must
    // not leave the clocks half-way and finger-driven.
    if (_swipe != null) return false;
    if (scene.value != Scene.player || inTransition || _disposed) return false;
    _updatePivot();
    _newToken();
    leaving.value = true;
    swipeMapping.value = false;
    list.beginDrag();
    container.beginDrag();
    _lockContainer = true;
    final origin = _origin?.call();
    final prepared = _raw.showPath(origin?.path ?? const []);
    _dragPrepared = prepared;
    unawaited(_prepareDragFlight(prepared));
    return true;
  }

  Future<void> _prepareDragFlight(Future<void> prepared) async {
    await prepared;
    final tag = _playingTag;
    if (_disposed || !list.isFingerDriven || tag == null) return;
    // One frame first, so the layers are drawn with the mapping and progress
    // that are current now (see _toLibrary).
    await _afterFrame();
    if (_disposed || !list.isFingerDriven) return;
    final before = _restingLibraryRect(tag);
    PlayerRevealBus.revealNowPlaying(instant: true);
    await _afterFrame();
    if (_disposed || !list.isFingerDriven) return;
    final row = _restingLibraryRect(tag);
    if (before == null ||
        row == null ||
        (before.top - row.top).abs() >= 1 ||
        !_onScreen(row)) {
      return;
    }
    final cover = _updatePivot();
    if (cover != null) _flyToRow(tag, cover, row);
  }

  /// [raw] is the unclamped progress: finger travel beyond the slop over the
  /// real cover side.
  void dragPlayer(double raw) {
    if (!list.isFingerDriven) return;
    list.dragTo(softOverdrag(raw), clamp: false);
  }

  /// The finger lifted. [velocityPerSecond] is in progress per second (positive
  /// toward the library); [extent] is the cover side the progress was measured
  /// against.
  Future<void> endPlayerDrag(
    double velocityPerSecond, {
    required double extent,
  }) async {
    if (!list.isFingerDriven) return;
    final token = _token;
    await _dragPrepared;
    if (_disposed || token != _token) return;
    final committed = await list.release(
      velocityPerSecond: velocityPerSecond,
      rules: ReleaseRules.artDrag.forExtent(extent),
    );
    if (_disposed || token != _token) return;
    _lockContainer = false;
    if (committed == true) {
      scene.value = Scene.library;
      _settleInLibrary();
      // The mini player starts only now, after the move has landed.
      unawaited(
        mini.run(to: 1, duration: MotionSpec.miniPlayer, curve: quartOut),
      );
    } else if (committed == false) {
      container.jumpTo(0);
    }
  }

  // ------------------------------------------- finger: swipe at the root list

  /// The swipe's own progress (0 = at the library, 1 = at the player). The
  /// list clock mirrors it, so the release rules can run on it as written.
  MotionProgress? _swipe;

  /// A rightward swipe at the library root (or predictive back at Places)
  /// takes hold: the player starts coming in with the finger. False when a
  /// move is already running.
  bool beginRootSwipe() {
    if (scene.value != Scene.library || inTransition || _disposed) return false;
    // The player may not be laid out yet (it mounts below): its cover is
    // measured now if it is, and again after the frame that lays it out.
    _updatePivot();
    final token = _newToken();
    leaving.value = false;
    swipeMapping.value = true;
    scene.value = Scene.player;
    playerMounted.value = true;
    list.beginDrag();
    container.beginDrag();
    _lockContainer = true;
    final swipe = MotionProgress(vsync: _vsync)..beginDrag();
    swipe.addListener(() => list.dragTo(1 - swipe.value));
    _swipe = swipe;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed && token == _token) _updatePivot();
    });
    return true;
  }

  /// [p] is 0..1: the finger's travel beyond the slop over the list width.
  void updateRootSwipe(double p) => _swipe?.dragTo(p);

  /// The finger lifted. [velocityPerSecond] is in progress per second (positive
  /// to the right); [width] is the list width the progress was measured on.
  Future<void> endRootSwipe(
    double velocityPerSecond, {
    required double width,
  }) async {
    final swipe = _swipe;
    if (swipe == null) return;
    final token = _token;
    final committed = await swipe.release(
      velocityPerSecond: velocityPerSecond,
      rules: ReleaseRules.backSwipe.forExtent(width),
    );
    _finishRootSwipe(swipe, token, committed);
  }

  /// Predictive back at Places moves the player in with the finger too.
  void beginBackToPlayer() => beginRootSwipe();

  /// [swipe] is 0..1, the share of the width the back gesture has travelled.
  void updateBackToPlayer(double swipe) =>
      updateRootSwipe(swipe.clamp(0.0, 1.0));

  /// The system decided: finish the move on the timed settle.
  Future<void> endBackToPlayer({required bool commit}) async {
    final swipe = _swipe;
    if (swipe == null) return;
    final token = _token;
    final p = swipe.value;
    final reached = await swipe.run(
      to: commit ? 1 : 0,
      duration: commit
          ? _max(MotionSpec.settleMinCommit, MotionSpec.settleCommit * (1 - p))
          : _max(MotionSpec.settleMinCancel, MotionSpec.settleCancel * p),
      curve: cosEase,
    );
    _finishRootSwipe(swipe, token, reached ? commit : null);
  }

  void _finishRootSwipe(MotionProgress swipe, int token, bool? committed) {
    if (_disposed || token != _token || committed == null) return;
    if (!identical(_swipe, swipe)) return;
    _swipe = null;
    swipe.dispose();
    _lockContainer = false;
    if (committed) {
      list.jumpTo(0);
      container.jumpTo(0);
      // The mini player starts only now, after the move has landed.
      unawaited(
        mini.run(to: 0, duration: MotionSpec.miniPlayer, curve: quartOut),
      );
    } else {
      scene.value = Scene.library;
      list.jumpTo(1);
      container.jumpTo(1);
      playerMounted.value = false;
      swipeMapping.value = false;
    }
  }

  static Duration _max(Duration a, Duration b) => a >= b ? a : b;

  void dispose() {
    _disposed = true;
    list.removeListener(_copyContainer);
    _toPlayerProgress.dispose();
    _swipe?.dispose();
    list.dispose();
    container.dispose();
    mini.dispose();
    scene.dispose();
    playerMounted.dispose();
    leaving.dispose();
    swipeMapping.dispose();
    playerPivot.dispose();
  }
}

/// The library as pages see it.
class _ShellLibrary implements LibraryNavigatorController {
  _ShellLibrary(this._owner);

  final SceneController _owner;

  LibraryNavigatorController get _raw => _owner._raw;

  @override
  Future<void> openPage(
    Widget page, {
    required LibraryPageKey key,
    Object? morphFrom,
    bool sibling = false,
  }) {
    _owner.libraryTouched = true;
    if (_owner.scene.value == Scene.player) {
      return _owner._openFromPlayer(
        page,
        key: key,
        morphFrom: morphFrom,
        sibling: sibling,
      );
    }
    return _raw.openPage(
      page,
      key: key,
      morphFrom: morphFrom,
      sibling: sibling,
    );
  }

  @override
  Future<void> showPath(List<LibraryPageKey> path) => _raw.showPath(path);

  @override
  bool get canPop => _raw.canPop;

  @override
  Future<bool> pop() {
    _owner.libraryTouched = true;
    return _raw.pop();
  }

  @override
  List<LibraryPageKey> get path => _raw.path;
}
