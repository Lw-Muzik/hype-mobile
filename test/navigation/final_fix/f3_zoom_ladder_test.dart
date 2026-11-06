import 'dart:io';

import 'package:drift/native.dart';
import 'package:eq_app/controllers/library_controller.dart';
import 'package:eq_app/data/library_database.dart';
import 'package:eq_app/data/library_repository.dart';
import 'package:eq_app/navigation/zoom/persisted_zoom_list.dart';
import 'package:eq_app/navigation/zoom/zoom_steps.dart';
import 'package:eq_app/services/library_scanner.dart';
import 'package:eq_app/widgets/song_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The library grids ship these ladders (private in their pages; the numbers
// are checked against the page sources below so the copies cannot drift).
const _albums = [
  ZoomStep.grid(maxTileExtent: 100.0, childAspectRatio: 0.75, spacing: 12),
  ZoomStep.grid(maxTileExtent: 150.0, childAspectRatio: 0.75, spacing: 12),
  ZoomStep.grid(maxTileExtent: 200.0, childAspectRatio: 0.75, spacing: 12),
  ZoomStep.list(rowExtent: 68),
];
const _artists = [
  ZoomStep.grid(
    maxTileExtent: 80.0,
    childAspectRatio: 0.75,
    crossAxisSpacing: 8,
    mainAxisSpacing: 12,
  ),
  ZoomStep.grid(
    maxTileExtent: 140.0,
    childAspectRatio: 0.75,
    crossAxisSpacing: 8,
    mainAxisSpacing: 12,
  ),
  ZoomStep.grid(
    maxTileExtent: 300.0,
    childAspectRatio: 0.75,
    crossAxisSpacing: 8,
    mainAxisSpacing: 12,
  ),
  ZoomStep.list(rowExtent: 68),
];

int _columns(ZoomStep s, double width, [EdgeInsets? pad]) => ZoomGeometry(
  s,
  width: width,
  padding: s.padding ?? pad ?? EdgeInsets.zero,
).columns;

/// What the old pinch widget saved for `cols` columns on a screen `w` wide.
double _oldExtent(double w, int cols) => (w - 24) / cols;

void main() {
  group('song ladder', () {
    final grids = kSongZoomSteps.whereType<GridZoomStep>().toList();

    for (final w in [360.0, 393.0, 412.0, 430.0]) {
      test('every grid step has its own column count at $w dp', () {
        final counts = [for (final s in grids) _columns(s, w)];
        expect(counts.toSet().length, counts.length, reason: '$counts');
        // Zoomed-out first: strictly fewer columns as the index grows.
        for (var i = 1; i < counts.length; i++) {
          expect(counts[i], lessThan(counts[i - 1]), reason: '$counts');
        }
        expect(counts, contains(3), reason: 'the old 3-column snap, $counts');
      });
    }

    for (final w in [600.0, 800.0]) {
      test('tablet width $w lays out sensibly', () {
        final counts = [for (final s in grids) _columns(s, w)];
        expect(
          counts.every((c) => c >= 2 && c <= 10),
          isTrue,
          reason: '$counts',
        );
        expect(counts.toSet().length, counts.length, reason: '$counts');
        for (final s in kSongZoomSteps) {
          zoomLayout(s, itemCount: 40, width: w);
        }
      });
    }
  });

  group('legacy extents map by column count', () {
    for (final w in [360.0, 393.0, 412.0]) {
      test('albums: 3 saved columns stay 3 at $w dp', () {
        // The page pads its list by 8 on each side.
        final step = legacyZoomStep(
          _albums,
          legacyExtent: _oldExtent(w, 3),
          screenWidth: w,
          width: w - 16,
        );
        expect(_columns(_albums[step], w - 16), 3);
      });
    }

    test('albums: 2 saved columns stay 2 at 360 dp', () {
      final step = legacyZoomStep(
        _albums,
        legacyExtent: _oldExtent(360, 2),
        screenWidth: 360,
        width: 344,
      );
      expect(_columns(_albums[step], 344), 2);
    });

    for (final w in [384.0, 393.0, 412.0]) {
      test('artists: 2 saved columns stay 2 at $w dp', () {
        final step = legacyZoomStep(
          _artists,
          legacyExtent: _oldExtent(w, 2),
          screenWidth: w,
          width: w,
        );
        expect(_columns(_artists[step], w), 2);
      });

      test('artists: 4 saved columns go to the nearest count at $w dp', () {
        // The shipped artists ladder has no 4-column step on a phone (3 or 5),
        // so the neighbour is the best that can be done.
        final step = legacyZoomStep(
          _artists,
          legacyExtent: _oldExtent(w, 4),
          screenWidth: w,
          width: w,
        );
        expect((_columns(_artists[step], w) - 4).abs(), 1);
      });
    }

    for (final w in [360.0, 393.0, 412.0]) {
      test('songs: the old 3-column value stays 3 at $w dp', () {
        // songGridExtent 120 / songGridScale 2.
        final step = legacyZoomStep(
          kSongZoomSteps,
          legacyExtent: 120,
          screenWidth: w,
          width: w,
        );
        expect(_columns(kSongZoomSteps[step], w), 3);
      });
    }

    test('an extent at the list threshold maps to the list step', () {
      expect(
        legacyZoomStep(
          _albums,
          legacyExtent: 260,
          screenWidth: 360,
          width: 344,
        ),
        3,
      );
      expect(
        legacyZoomStep(
          kSongZoomSteps,
          legacyExtent: 300,
          screenWidth: 360,
          width: 360,
        ),
        kSongZoomSteps.length - 1,
      );
    });

    test('with no matching count the nearest one wins', () {
      // 10 saved columns do not exist on a phone: the most zoomed-out step.
      final step = legacyZoomStep(
        _albums,
        legacyExtent: 30,
        screenWidth: 360,
        width: 344,
      );
      expect(step, 0);
    });
  });

  group('shipped ladders match the copies above', () {
    List<double> extents(String file) =>
        RegExp(r'maxTileExtent:\s*([\d.]+)')
            .allMatches(File('lib/pages/$file').readAsStringSync())
            .map((m) => double.parse(m.group(1)!))
            .toList();

    test('albums', () => expect(extents('albums.dart'), [100, 150, 200]));
    test('artists', () => expect(extents('artists.dart'), [80, 140, 300]));
  });

  group('PersistedZoomList migrates at first layout', () {
    late LibraryDatabase db;
    late LibraryController library;
    late SharedPreferences prefs;

    Future<void> build(Map<String, Object> values) async {
      SharedPreferences.setMockInitialValues(values);
      db = LibraryDatabase.forTesting(NativeDatabase.memory());
      final repo = LibraryRepository(db);
      prefs = await SharedPreferences.getInstance();
      library = LibraryController(
        repo: repo,
        scanner: LibraryScanner(repo, querySongs: () async => []),
        prefs: prefs,
      );
    }

    tearDown(() async {
      library.dispose();
      await db.close();
    });

    Widget app(double w, {required String key}) => ChangeNotifierProvider.value(
      value: library,
      child: MediaQuery(
        data: MediaQueryData(size: Size(w, 800)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: PersistedZoomList(
              zoomKey: key,
              steps: _albums,
              fallbackStep: 2,
              itemCount: 40,
              itemBuilder: (c, i, s) => SizedBox(key: ValueKey('item$i')),
            ),
          ),
        ),
      ),
    );

    testWidgets('3 saved columns come up as 3 columns and are saved once', (
      t,
    ) async {
      await build({'library_extent_albums': _oldExtent(360, 3)});
      await t.binding.setSurfaceSize(const Size(360, 800));
      await t.pumpWidget(app(360, key: 'albums'));
      await t.pump();
      // Column count = items sharing the first row.
      final first = t.getTopLeft(find.byKey(const ValueKey('item0'))).dy;
      var cols = 0;
      for (var i = 0; i < 12; i++) {
        if (t.getTopLeft(find.byKey(ValueKey('item$i'))).dy == first) cols++;
      }
      expect(cols, 3);
      expect(prefs.getInt('library_zoom_albums'), 1);
      await t.binding.setSurfaceSize(null);
    });

    testWidgets('a stored step is left alone', (t) async {
      await build({
        'library_extent_albums': _oldExtent(360, 3),
        'library_zoom_albums': 0,
      });
      await t.binding.setSurfaceSize(const Size(360, 800));
      await t.pumpWidget(app(360, key: 'albums'));
      await t.pump();
      expect(prefs.getInt('library_zoom_albums'), 0);
      await t.binding.setSurfaceSize(null);
    });
  });
}
