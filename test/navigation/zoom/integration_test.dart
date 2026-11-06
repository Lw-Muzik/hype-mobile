import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:eq_app/Themes/AppThemes.dart';
import 'package:eq_app/controllers/app_controller.dart';
import 'package:eq_app/controllers/library_controller.dart';
import 'package:eq_app/data/library_database.dart';
import 'package:eq_app/data/library_repository.dart';
import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/motion/morph.dart';
import 'package:eq_app/navigation/playback_origin.dart';
import 'package:eq_app/navigation/zoom/zoom_step_list.dart';
import 'package:eq_app/navigation/zoom/zoom_steps.dart';
import 'package:eq_app/pages/albums.dart';
import 'package:eq_app/pages/songs.dart';
import 'package:eq_app/themes/ember.dart';
import 'package:eq_app/widgets/song_tile.dart';
import 'package:eq_app/services/library_scanner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'zoom_test_helpers.dart' show setSpan, startPinch;

class _Controller extends ChangeNotifier implements AppController {
  @override
  List<SongModel> songs = const [];
  @override
  int get songId => -1;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Paths extends PathProviderPlatform {
  _Paths(this.dir);
  final String dir;
  @override
  Future<String?> getTemporaryPath() async => dir;
}

class _StubHost implements NavHost {
  @override
  Future<void> toPlayer({Object? morphFrom}) async {}
  @override
  Future<void> toLibrary({PlaybackOrigin? landOn, Object? morphFrom}) async {}
  @override
  LibraryNavigatorController get library => throw UnimplementedError();
}

void main() {
  late LibraryDatabase db;
  late LibraryRepository repo;
  late LibraryController library;
  late SharedPreferences prefs;
  late Directory tmp;

  Future<void> build(Map<String, Object> saved) async {
    SharedPreferences.setMockInitialValues(saved);
    prefs = await SharedPreferences.getInstance();
    db = LibraryDatabase.forTesting(NativeDatabase.memory());
    repo = LibraryRepository(db);
    library = LibraryController(
      repo: repo,
      scanner: LibraryScanner(repo, querySongs: () async => []),
      prefs: prefs,
    );
  }

  setUp(() {
    AppNav.host = _StubHost();
    tmp = Directory.systemTemp.createTempSync('zoom_integration');
    PathProviderPlatform.instance = _Paths(tmp.path);
  });

  tearDown(() async {
    AppNav.host = null;
    library.dispose();
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Widget host(Widget page) => MultiProvider(
    providers: [
      ChangeNotifierProvider<AppController>.value(value: _Controller()),
      ChangeNotifierProvider<LibraryController>.value(value: library),
      Provider<LibraryRepository>.value(value: repo),
    ],
    child: MaterialApp(
      theme: AppThemes.darkTheme,
      home: Scaffold(body: page),
    ),
  );

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  /// Drift schedules a timer when a stream is cancelled; run it in the test.
  Future<void> unmount(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(milliseconds: 50));
  }

  Future<void> seed(WidgetTester t, int songs, {int albumEvery = 1}) =>
      t.runAsync(
        () => repo.upsertSongs([
          for (var i = 1; i <= songs; i++)
            SongsCompanion.insert(
              id: Value(i),
              data: 'http://lib/$i.mp3',
              title: Value('Track ${String.fromCharCode(64 + (i % 26) + 1)}$i'),
              artist: Value('Artist $i'),
              album: Value('Album ${i ~/ albumEvery}'),
            ),
        ]),
      );

  List<ZoomStep> stepsOf(WidgetTester t) =>
      t.widget<ZoomStepList>(find.byType(ZoomStepList)).steps;

  testWidgets('AllSongs: three grids then the list, opening on the list', (
    t,
  ) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await build({});
    await seed(t, 40);
    await t.pumpWidget(host(const AllSongs()));
    await settle(t);

    final list = t.widget<ZoomStepList>(find.byType(ZoomStepList));
    expect(list.steps, hasLength(4));
    expect(
      [for (final s in list.steps.take(3)) (s as GridZoomStep).maxTileExtent],
      [96.0, 140.0, 200.0],
    );
    expect(list.steps[3], isA<ListZoomStep>());
    expect(list.step, 3);
    await unmount(t);
  });

  testWidgets('AllSongs: the list step still carries the A-Z rail', (t) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await build({});
    await seed(t, 40);
    await t.pumpWidget(host(const AllSongs()));
    await settle(t);
    // Default sort is by title, which turns the rail on for 30+ rows.
    expect(find.text('Z'), findsOneWidget);
    expect(find.text('#'), findsOneWidget);
    await unmount(t);
  });

  testWidgets('AllSongs: a saved songGridExtent of 120 opens a grid step', (
    t,
  ) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await build({'songGridExtent': 120.0});
    await seed(t, 40);
    await t.pumpWidget(host(const AllSongs()));
    await settle(t);
    // The old value was a three-column grid: the middle step of the ladder.
    expect(t.widget<ZoomStepList>(find.byType(ZoomStepList)).step, 1);
    expect(find.text('Z'), findsNothing);
    await unmount(t);
  });

  testWidgets('Albums: ladder, default step, and a pinch-out persists', (
    t,
  ) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await build({});
    await seed(t, 12);
    await t.pumpWidget(host(const Albums()));
    await settle(t);

    final steps = stepsOf(t);
    expect(steps, hasLength(4));
    expect(
      [for (final s in steps.take(3)) (s as GridZoomStep).maxTileExtent],
      [100.0, 150.0, 200.0],
    );
    expect(steps[0], isA<GridZoomStep>());
    expect((steps[0] as GridZoomStep).childAspectRatio, 0.75);
    expect(steps[3], isA<ListZoomStep>());
    expect(t.widget<ZoomStepList>(find.byType(ZoomStepList)).step, 2);

    // Spread the fingers: one step up (bigger items), saved when it lands.
    final g = await startPinch(t, 100, centre: const Offset(200, 300));
    await setSpan(t, g, 140, centre: const Offset(200, 300));
    await setSpan(t, g, 300, centre: const Offset(200, 300));
    await g.$1.up();
    await g.$2.up();
    await t.pump();
    await t.pump(const Duration(seconds: 2));
    await t.pump(const Duration(seconds: 2));

    expect(t.widget<ZoomStepList>(find.byType(ZoomStepList)).step, 3);
    expect(prefs.getInt('library_zoom_albums'), 3);
    await unmount(t);
  });

  testWidgets('Albums: saved extents open the matching step', (t) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    for (final (saved, step) in [(300.0, 3), (200.0, 2), (150.0, 1)]) {
      await build({'library_extent_albums': saved});
      await seed(t, 12);
      await t.pumpWidget(host(const Albums()));
      await settle(t);
      // 300 was list mode in the old widget.
      expect(
        t.widget<ZoomStepList>(find.byType(ZoomStepList)).step,
        step,
        reason: 'saved $saved',
      );
      await unmount(t);
      library.dispose();
      await db.close();
    }
    await build({});
  });

  testWidgets('Albums: list to grid morph keeps every row tagged', (t) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await build({'library_zoom_albums': 3});
    await seed(t, 6);
    await t.pumpWidget(host(const Albums()));
    await settle(t);
    final before = t.widgetList<MorphTag>(find.byType(MorphTag)).length;
    expect(before, greaterThan(0));

    final g = await startPinch(t, 300);
    await setSpan(t, g, 250);
    await setSpan(t, g, 200);
    // Mid-pinch every shared item is a positioned morph item, still tagged.
    expect(find.byKey(const ValueKey('zoom-item-0')), findsOneWidget);
    expect(find.byType(MorphTag), findsWidgets);
    final tags = {
      for (final m in t.widgetList<MorphTag>(find.byType(MorphTag))) m.tag,
    };
    expect(tags.length, greaterThanOrEqualTo(6));
    await g.$1.up();
    await g.$2.up();
    await t.pump(const Duration(seconds: 2));
    await t.pump(const Duration(seconds: 2));
    expect(t.widget<ZoomStepList>(find.byType(ZoomStepList)).step, 2);
    await unmount(t);
  });

  testWidgets('AllSongs: the outer edge of a list row still takes taps', (
    t,
  ) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await build({});
    await seed(t, 40);
    final tapped = <int>[];
    final controller = _Controller();
    await t.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppController>.value(value: controller),
          ChangeNotifierProvider<LibraryController>.value(value: library),
        ],
        child: MaterialApp(
          theme: AppThemes.darkTheme,
          home: Scaffold(
            body: SongListView(
              songs: [
                for (var i = 0; i < 40; i++)
                  SongModel({
                    '_id': i,
                    '_data': 'x/$i.mp3',
                    'title': 'T$i',
                    'artist': 'A',
                    'duration': 1000,
                    '_display_name': '$i.mp3',
                    '_display_name_wo_ext': '$i',
                    '_size': 0,
                    'file_extension': 'mp3',
                    'is_music': true,
                  }),
              ],
              controller: controller,
              onTap: (s, i) => tapped.add(i),
            ),
          ),
        ),
      ),
    );
    await t.pump();
    final top = t.getTopLeft(find.byType(SongTile).first);
    expect(top.dx, 0);
    // Just inside the row's own side gutter: with the old full-width
    // widening this strip belonged to nobody.
    await t.tapAt(Offset(Ember.gutter - 6 + 2, top.dy + 30));
    await t.pump();
    expect(tapped, [0]);
  });

  testWidgets('no padding given: the list inherits safe-area padding', (
    t,
  ) async {
    await build({}); // the shared tearDown expects one
    await t.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(padding: EdgeInsets.only(bottom: 40)),
          child: SizedBox(
            width: 400,
            height: 600,
            child: ZoomStepList(
              steps: const [
                ZoomStep.grid(maxTileExtent: 200, childAspectRatio: 1),
                ZoomStep.list(rowExtent: 50),
              ],
              step: 1,
              onStepChanged: (_) {},
              itemCount: 30,
              itemBuilder: (c, i, s) => const SizedBox(),
            ),
          ),
        ),
      ),
    );
    final list = t.widget<ListView>(find.byType(ListView));
    expect(list.padding, isNull);
    // 30 rows of 50 plus the 40 inherited at the bottom, minus the 600 view.
    final pos = t.state<ScrollableState>(find.byType(Scrollable)).position;
    expect(pos.maxScrollExtent, 30 * 50 + 40 - 600);
  });
}
