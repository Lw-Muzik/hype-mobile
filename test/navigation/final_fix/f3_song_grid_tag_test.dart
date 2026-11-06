import 'dart:io';

import 'package:drift/native.dart';
import 'package:eq_app/Themes/AppThemes.dart';
import 'package:eq_app/controllers/app_controller.dart';
import 'package:eq_app/controllers/library_controller.dart';
import 'package:eq_app/data/library_database.dart';
import 'package:eq_app/data/library_repository.dart';
import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/motion/morph.dart';
import 'package:eq_app/services/library_scanner.dart';
import 'package:eq_app/widgets/song_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Controller extends ChangeNotifier implements AppController {
  @override
  List<SongModel> songs = const [];
  @override
  int get songId => -1;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

void main() {
  testWidgets('a song grid tile carries the same cover tag as a row', (
    t,
  ) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final tmp = Directory.systemTemp.createTempSync('f3_grid_tag');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );
    // Step 1 of the song ladder is a grid.
    SharedPreferences.setMockInitialValues({'library_zoom_songs': 1});
    final db = LibraryDatabase.forTesting(NativeDatabase.memory());
    final repo = LibraryRepository(db);
    final library = LibraryController(
      repo: repo,
      scanner: LibraryScanner(repo, querySongs: () async => []),
      prefs: await SharedPreferences.getInstance(),
    );
    addTearDown(() async {
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      library.dispose();
      await db.close();
      tmp.deleteSync(recursive: true);
    });

    await t.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppController>.value(value: _Controller()),
          ChangeNotifierProvider<LibraryController>.value(value: library),
        ],
        child: MaterialApp(
          theme: AppThemes.darkTheme,
          home: Scaffold(
            body: SongListView(
              songs: [
                for (var i = 0; i < 12; i++)
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
              controller: _Controller(),
            ),
          ),
        ),
      ),
    );
    await t.pump();
    final tags = [
      for (final m in t.widgetList<MorphTag>(find.byType(MorphTag))) m.tag,
    ];
    expect(tags, contains(trackTag(0)));
    expect(tags, contains(trackTag(1)));
    expect(tags.toSet().length, tags.length, reason: 'no tag is shared');
  });
}
