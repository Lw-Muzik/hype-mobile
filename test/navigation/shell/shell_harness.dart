import 'dart:async';

import 'package:eq_app/controllers/app_controller.dart';
import 'package:eq_app/controllers/drawer_controller.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/motion/morph.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/playback_origin.dart';
import 'package:eq_app/navigation/shell/motion_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zoom_drawer/flutter_zoom_drawer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Just enough of the app controller for the shell.
class FakeApp extends ChangeNotifier implements AppController {
  bool eqMode = false;
  bool playing = true;

  @override
  PlaybackOrigin? playbackOrigin;

  @override
  bool get isEqMode => eqMode;

  @override
  bool get isFancy => false;

  @override
  bool get hasMiniPlayer => playing;

  @override
  bool get hasNowPlaying => queue.isNotEmpty;

  /// The queue; empty unless a test wants the playing row's tag.
  List<SongModel> queue = [];

  @override
  List<SongModel> get songs => queue;

  @override
  int get songId => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A library whose stack is a list of keys. [popGate] holds a pop open the way
/// a running animation would.
class FakeLibrary implements LibraryNavigatorController {
  final List<LibraryPageKey> stack = [];
  final List<List<LibraryPageKey>> shown = [];
  Completer<void>? popGate;
  int pops = 0;

  @override
  List<LibraryPageKey> get path => List.of(stack);

  @override
  bool get canPop => stack.isNotEmpty;

  @override
  Future<void> openPage(
    Widget page, {
    required LibraryPageKey key,
    Object? morphFrom,
    bool sibling = false,
  }) async => stack.add(key);

  @override
  Future<void> showPath(List<LibraryPageKey> path) async {
    shown.add(List.of(path));
    stack
      ..clear()
      ..addAll(path);
  }

  @override
  Future<bool> pop() async {
    if (stack.isEmpty) return false;
    pops++;
    await popGate?.future;
    if (stack.isNotEmpty) stack.removeLast();
    return true;
  }
}

class FakeHost extends LibraryHost {
  FakeHost(this.library, {this.rowTag, this.rowRect, this.onBuild});

  final FakeLibrary library;

  /// A song row's cover to put in the library, when a flight is under test.
  final Object? rowTag;
  final Rect? rowRect;
  final void Function(BuildContext context)? onBuild;
  bool? systemBack;
  bool Function()? swipeStart;
  ValueChanged<double>? swipeUpdate;
  ValueChanged<double>? swipeEnd;

  @override
  void setSystemBack(bool enabled) => systemBack = enabled;

  @override
  Widget build(
    BuildContext context,
    Widget root, {
    bool Function()? onRootSwipeStart,
    ValueChanged<double>? onRootSwipeUpdate,
    ValueChanged<double>? onRootSwipeEnd,
  }) {
    swipeStart = onRootSwipeStart;
    swipeUpdate = onRootSwipeUpdate;
    swipeEnd = onRootSwipeEnd;
    if (rowTag == null) {
      return Builder(
        builder: (ctx) {
          onBuild?.call(ctx);
          return root;
        },
      );
    }
    return Stack(
      children: [
        root,
        Positioned.fromRect(
          rect: rowRect!,
          child: MorphTag(
            tag: rowTag!,
            child: const ColoredBox(color: Colors.green),
          ),
        ),
      ],
    );
  }

  @override
  LibraryNavigatorController get controller => library;
}

const kPlayerKey = Key('player');
const kMiniKey = Key('mini');
const kEqKey = Key('eq');

const kFrameKey = Key('frame');
const kCoverRect = Rect.fromLTWH(50, 100, 300, 300);
const kRowRect = Rect.fromLTWH(20, 300, 40, 40);

SongModel song(Object id, {String? videoId}) => SongModel({
  '_id': id,
  '_data': '/x/$id.mp3',
  'title': 't$id',
  'artist': 'a',
  'album': 'al',
  'duration': 1000,
  '_display_name': '$id.mp3',
  '_display_name_wo_ext': '$id',
  '_size': 0,
  'file_extension': 'mp3',
  'is_music': true,
  if (videoId != null) 'hype_video_id': videoId,
});

/// Pumps the shell as a route over a base page. Returns the navigator key.
Future<GlobalKey<NavigatorState>> pumpShell(
  WidgetTester tester, {
  required FakeApp app,
  required FakeLibrary library,
  FakeHost? host,
  WidgetBuilder? playerBuilder,
  ValueNotifier<DrawerState>? drawerState,
  Widget Function(BuildContext context, FakeApp app)? miniBuilder,
  Widget Function()? frameProbe,
  VoidCallback? onDrawerOpen,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(() => AppNav.host = null);
  final navKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: app),
        ChangeNotifierProvider(create: (_) => DrawerProvider()),
      ],
      child: MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: Text('base')),
      ),
    ),
  );
  unawaited(
    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => MotionShell(
          libraryHost: host ?? FakeHost(library),
          announceShellReady: false,
          playerBuilder:
              playerBuilder ??
              (_) => const ColoredBox(key: kPlayerKey, color: Colors.black),
          equalizerBuilder: (_) =>
              const ColoredBox(key: kEqKey, color: Colors.red),
          miniPlayerBuilder: (ctx, _) =>
              miniBuilder?.call(ctx, app) ??
              const SizedBox(key: kMiniKey, height: 60),
          libraryFrame: (_, drawer, content) {
            drawer.stateNotifier = drawerState;
            drawer.open = onDrawerOpen == null
                ? null
                : () {
                    onDrawerOpen();
                    return null;
                  };
            return KeyedSubtree(
              key: kFrameKey,
              child: Column(
                children: [
                  if (frameProbe != null) frameProbe(),
                  Expanded(child: content),
                ],
              ),
            );
          },
        ),
      ),
    ),
  );
  // Not pumpAndSettle: a remote player never stops animating.
  await tester.pump();
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return navKey;
}

/// Pumps [ms] in 10 ms frames.
Future<void> advance(WidgetTester tester, int ms) async {
  await tester.pump();
  for (var t = 0; t < ms; t += 10) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}
