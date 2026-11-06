import 'package:drift/native.dart';
import 'package:eq_app/controllers/library_controller.dart';
import 'package:eq_app/data/library_database.dart';
import 'package:eq_app/data/library_repository.dart';
import 'package:eq_app/services/library_scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late LibraryDatabase db;
  late LibraryController library;

  Future<void> build(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    db = LibraryDatabase.forTesting(NativeDatabase.memory());
    final repo = LibraryRepository(db);
    library = LibraryController(
      repo: repo,
      scanner: LibraryScanner(repo, querySongs: () async => []),
      prefs: await SharedPreferences.getInstance(),
    );
  }

  tearDown(() async {
    library.dispose();
    await db.close();
  });

  int read(String key, {int fallback = 1}) =>
      library.zoomStepFor(key, fallback: fallback, stepCount: 4);

  // How a saved extent becomes a step needs the list's width, so it is tested
  // with the shipped ladders in test/navigation/final_fix/f3_zoom_ladder_test.dart.
  test('the controller hands a saved legacy extent to the list as it is', () async {
    await build({'library_extent_albums': 200.0});
    expect(library.legacyZoomExtent('albums'), 200.0);
    expect(read('albums', fallback: 2), 2);
  });

  test('the shared songs extent reaches only the song lists', () async {
    await build({'songGridExtent': 120.0});
    expect(library.legacyZoomExtent('songs'), 120.0);
    expect(library.legacyZoomExtent('genre_songs'), 120.0);
    expect(library.legacyZoomExtent('albums'), isNull);
    expect(read('albums', fallback: 1), 1);
  });

  test('nothing saved gives the fallback and no legacy extent', () async {
    await build({});
    expect(library.legacyZoomExtent('artists'), isNull);
    expect(read('artists', fallback: 0), 0);
    expect(read('songs', fallback: 3), 3);
  });

  test('a stored step wins over legacy values and persists', () async {
    await build({'library_extent_albums': 300.0});
    await library.setZoomStep('albums', 0);
    expect(read('albums'), 0);
    expect(library.legacyZoomExtent('albums'), isNull);
  });

  test('a stored step is clamped to the ladder', () async {
    await build({'library_zoom_albums': 9});
    expect(read('albums'), 3);
  });

  test('the older songGridScale becomes the extent it stood for', () async {
    // 0 = list, 1 = two columns, 2 = three columns.
    for (final (scale, extent) in [(0, 300.0), (1, 180.0), (2, 120.0)]) {
      await build({'songGridScale': scale});
      expect(library.legacyZoomExtent('songs'), extent, reason: 'scale $scale');
      library.dispose();
      await db.close();
    }
    await build({});
  });
}
