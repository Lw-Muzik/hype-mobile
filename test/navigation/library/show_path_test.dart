import 'package:eq_app/controllers/app_controller.dart';
import 'package:eq_app/data/library_repository.dart';
import 'package:eq_app/models/cloud_file.dart';
import 'package:eq_app/navigation/library/library_navigator.dart';
import 'package:eq_app/navigation/library/library_pages.dart';
import 'package:eq_app/navigation/library/page_factory.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/motion/morph.dart';
import 'package:eq_app/pages/cloud/cloud_folder_songs.dart';
import 'package:eq_app/pages/home/mix_playlist_page.dart';
import 'package:eq_app/services/cloud_cache_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library_harness.dart';

class _FakeRepo extends Fake implements LibraryRepository {
  _FakeRepo(this.lists);
  final List<PlaylistSummary> lists;

  @override
  Future<List<PlaylistSummary>> playlists() async => lists;
}

class _FakeApp extends Fake implements AppController {
  _FakeApp(this._cache);
  final CloudCacheService _cache;

  @override
  CloudCacheService get cloudCache => _cache;
}

/// Stands in for a real page, keeping the real builder's resolve-or-null rule.
void _stub(String kind, {Map<String, LibraryPageBuilder>? real}) {
  registerLibraryPage(kind, (key, context) async {
    final inner = real?[kind];
    if (inner != null) {
      final w = await inner(key, context);
      if (w == null) return null;
    }
    return Scaffold(body: Text('${key.kind}:${key.args}'));
  });
}

void main() {
  setUp(() {
    clearLibraryPages();
    _stub('place');
    _stub('album');
  });
  tearDown(resetLibraryPages);

  testWidgets('showPath builds both pages with no animation running', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    await nav.currentState!.showPath([
      LibraryPageKey.place('albums'),
      const LibraryPageKey('album', {'albumId': 5}),
    ]);
    await tester.pump();
    expect(nav.currentState!.path.length, 2);
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.textContaining('album:'), findsOneWidget);
  });

  testWidgets('an unknown kind truncates to the deepest buildable page', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    await nav.currentState!.showPath([
      LibraryPageKey.place('albums'),
      const LibraryPageKey('ytList', {'id': 'x'}), // nothing registered
      const LibraryPageKey('album', {'albumId': 5}),
    ]);
    await tester.pump();
    expect(nav.currentState!.path, [LibraryPageKey.place('albums')]);
  });

  testWidgets('showPath reuses the shared prefix and trims the rest', (
    tester,
  ) async {
    final nav = await pumpNavigator(tester);
    final s = nav.currentState!;
    await s.showPath([
      LibraryPageKey.place('albums'),
      const LibraryPageKey('album', {'albumId': 5}),
    ]);
    await tester.pump();
    await s.showPath([LibraryPageKey.place('albums')]);
    await tester.pump();
    expect(s.path, [LibraryPageKey.place('albums')]);
    expect(tester.hasRunningAnimations, isFalse);
  });

  group('id-only keys are resolved when the trail is rebuilt', () {
    setUp(() => Provider.debugCheckInvalidValueType = null);
    late CloudCacheService cache;
    late BuildContext ctx;

    Future<void> pumpWith(
      WidgetTester tester, {
      List<PlaylistSummary> playlists = const [],
    }) async {
      SharedPreferences.setMockInitialValues({});
      cache = CloudCacheService(await SharedPreferences.getInstance());
      final key = GlobalKey<LibraryNavigatorState>();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<LibraryRepository>.value(value: _FakeRepo(playlists)),
            Provider<AppController>.value(value: _FakeApp(cache)),
          ],
          child: MaterialApp(
            home: MorphScope(
              child: Builder(
                builder: (c) {
                  ctx = c;
                  return LibraryNavigator(key: key, root: rootList());
                },
              ),
            ),
          ),
        ),
      );
      navKey = key;
    }

    testWidgets('mix: found -> page, missing -> null', (tester) async {
      await pumpWith(
        tester,
        playlists: const [PlaylistSummary(id: 7, name: 'Mix', trackCount: 3)],
      );
      final build = defaultLibraryPages()['mix']!;
      final page = await build(const LibraryPageKey('mix', {'id': 7}), ctx);
      expect(page, isA<MixPlaylistPage>());
      expect(await build(const LibraryPageKey('mix', {'id': 8}), ctx), isNull);
    });

    testWidgets('mix: showPath truncates when the playlist is gone', (
      tester,
    ) async {
      await pumpWith(
        tester,
        playlists: const [PlaylistSummary(id: 7, name: 'Mix', trackCount: 3)],
      );
      _stub('mix', real: defaultLibraryPages());
      await navKey.currentState!.showPath([
        LibraryPageKey.place('forYou'),
        const LibraryPageKey('mix', {'id': 7}),
      ]);
      await tester.pump();
      expect(navKey.currentState!.path.length, 2);
      await navKey.currentState!.showPath([
        LibraryPageKey.place('forYou'),
        const LibraryPageKey('mix', {'id': 99}),
      ]);
      await tester.pump();
      expect(navKey.currentState!.path, [LibraryPageKey.place('forYou')]);
    });

    testWidgets('cloudFolder: cached folder -> page, otherwise null', (
      tester,
    ) async {
      await pumpWith(tester);
      cache.saveFileList(CloudProvider.googleDrive, [
        CloudFile(
          provider: CloudProvider.googleDrive,
          fileId: 'a',
          name: 'a.mp3',
          folderPath: '/Music/Rock',
          size: 1,
          mimeType: 'audio/mpeg',
        ),
      ]);
      final build = defaultLibraryPages()['cloudFolder']!;
      final page = await build(
        const LibraryPageKey('cloudFolder', {
          'folderName': 'Rock',
          'provider': 'googleDrive',
        }),
        ctx,
      );
      expect(page, isA<CloudFolderSongs>());
      expect(
        await build(
          const LibraryPageKey('cloudFolder', {
            'folderName': 'Jazz',
            'provider': 'googleDrive',
          }),
          ctx,
        ),
        isNull,
      );
      expect(
        await build(
          const LibraryPageKey('cloudFolder', {
            'folderName': 'Rock',
            'provider': 'dropbox',
          }),
          ctx,
        ),
        isNull,
      );
    });

    testWidgets('cloudFolder: showPath truncates when the folder is gone', (
      tester,
    ) async {
      await pumpWith(tester);
      _stub('cloudFolder', real: defaultLibraryPages());
      await navKey.currentState!.showPath([
        LibraryPageKey.place('cloud'),
        const LibraryPageKey('cloudFolder', {
          'folderName': 'Gone',
          'provider': 'googleDrive',
        }),
      ]);
      await tester.pump();
      expect(navKey.currentState!.path, [LibraryPageKey.place('cloud')]);
    });
  });
}

late GlobalKey<LibraryNavigatorState> navKey;
