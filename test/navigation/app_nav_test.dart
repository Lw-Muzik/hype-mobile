import 'package:eq_app/controllers/app_controller.dart';
import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/library_path.dart';
import 'package:eq_app/navigation/playback_origin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _FakeController extends ChangeNotifier implements AppController {
  @override
  PlaybackOrigin? playbackOrigin;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Spy extends NavigatorObserver {
  _Spy(this.pushed);
  final List<Route<dynamic>> pushed;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previous) =>
      pushed.add(route);
}

class _FakeLibrary implements LibraryNavigatorController {
  final opened = <LibraryPageKey>[];
  bool? sibling;

  @override
  Future<void> openPage(
    Widget page, {
    required LibraryPageKey key,
    Object? morphFrom,
    bool sibling = false,
  }) async {
    opened.add(key);
    this.sibling = sibling;
  }

  @override
  bool get canPop => false;
  @override
  Future<bool> pop() async => false;
  @override
  List<LibraryPageKey> get path => const [];
  @override
  Future<void> showPath(List<LibraryPageKey> path) async {}
}

class _FakeHost implements NavHost {
  int players = 0;
  @override
  final _FakeLibrary library = _FakeLibrary();
  @override
  Future<void> toPlayer({Object? morphFrom}) async => players++;
  @override
  Future<void> toLibrary({PlaybackOrigin? landOn, Object? morphFrom}) async {}
}

void main() {
  late _FakeController controller;

  setUp(() {
    controller = _FakeController();
    AppNav.host = null;
  });
  tearDown(() => AppNav.host = null);

  Future<BuildContext> pumpApp(WidgetTester t) async {
    late BuildContext ctx;
    await t.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(
          home: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    return ctx;
  }

  testWidgets('legacy openPage scopes the path; toPlayer records it', (
    t,
  ) async {
    final ctx = await pumpApp(t);
    List<LibraryPageKey>? seen;
    late BuildContext inner;
    const parent = LibraryPageKey('album', {'id': 1});
    const child = LibraryPageKey('artist', {'id': 2});

    AppNav.openPage(
      ctx,
      Builder(
        builder: (c) {
          inner = c;
          seen = LibraryPathScope.of(c);
          return const SizedBox();
        },
      ),
      key: parent,
    );
    await t.pumpAndSettle();
    expect(seen, [parent]);

    // A page opened from inside that page extends the trail.
    AppNav.openPage(
      inner,
      Builder(
        builder: (c) {
          seen = LibraryPathScope.of(c);
          inner = c;
          return const SizedBox();
        },
      ),
      key: child,
    );
    await t.pumpAndSettle();
    expect(seen, [parent, child]);

    expect(LibraryPathScope.of(inner), [parent, child]);
  });

  testWidgets('legacy toPlayer pushes the player route and records origin', (
    t,
  ) async {
    final pushed = <Route<dynamic>>[];
    late BuildContext inner;
    const key = LibraryPageKey('album', {'id': 1});
    await t.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(
          navigatorObservers: [_Spy(pushed)],
          home: LibraryPathScope(
            path: const [key],
            child: Builder(
              builder: (c) {
                inner = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    pushed.clear();
    // The real Player cannot be built here; the push is observed and the
    // resulting build error is not the subject.
    AppNav.toPlayer(inner);
    expect(controller.playbackOrigin, const PlaybackOrigin([key]));
    expect(pushed, hasLength(1));
    expect(pushed.single.settings.name, '/player');
    t.takeException();
  });

  testWidgets('recordOrigin: true outside any scope clears the origin; false '
      'leaves it', (t) async {
    final host = _FakeHost();
    AppNav.host = host;
    final ctx = await pumpApp(t);
    const stale = PlaybackOrigin([
      LibraryPageKey('album', {'id': 1}),
    ]);
    controller.playbackOrigin = stale;

    await AppNav.toPlayer(ctx, recordOrigin: false);
    expect(controller.playbackOrigin, stale);

    await AppNav.toPlayer(ctx);
    expect(controller.playbackOrigin, isNull);
    expect(host.players, 2);
  });

  testWidgets('toPlayer outside any page records nothing', (t) async {
    final host = _FakeHost();
    AppNav.host = host;
    final ctx = await pumpApp(t);
    await AppNav.toPlayer(ctx);
    expect(host.players, 1);
    expect(controller.playbackOrigin, isNull);
  });

  testWidgets('with a host, calls are forwarded and no route is pushed', (
    t,
  ) async {
    final host = _FakeHost();
    AppNav.host = host;
    final ctx = await pumpApp(t);
    const key = LibraryPageKey('genre', {'id': 9});
    late BuildContext inner;
    await AppNav.openPage(ctx, const SizedBox(), key: key, sibling: true);
    expect(host.library.opened, [key]);
    expect(host.library.sibling, isTrue);

    await t.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(
          home: LibraryPathScope(
            path: const [key],
            child: Builder(
              builder: (c) {
                inner = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    await AppNav.toPlayer(inner);
    expect(host.players, 1);
    expect(controller.playbackOrigin, const PlaybackOrigin([key]));
    expect(Navigator.of(inner).canPop(), isFalse);
  });
}
