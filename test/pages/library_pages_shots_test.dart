/// Renders the library pages (and the YouTube ones' shared pieces) to PNGs so
/// they can be looked at without a device. Opt in:
///
///     LIBRARY_PAGES_SHOTS=/some/dir flutter test test/pages/library_pages_shots_test.dart
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:eq_app/Themes/AppThemes.dart';
import 'package:eq_app/controllers/app_controller.dart';
import 'package:eq_app/data/library_database.dart';
import 'package:eq_app/data/library_repository.dart';
import 'package:eq_app/pages/album_songs.dart';
import 'package:eq_app/pages/artist_songs.dart';
import 'package:eq_app/pages/discover/widgets/media_widgets.dart';
import 'package:eq_app/pages/discover/widgets/yt_hero.dart';
import 'package:eq_app/pages/discover/widgets/yt_widgets.dart';
import 'package:eq_app/pages/playlist_songs.dart';
import 'package:eq_app/services/ytmusic/yt_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';

import 'library_pages_test.dart';

Future<void> loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(
      Future.value(ByteData.sublistView(File(f).readAsBytesSync())),
    );
  }
  await loader.load();
}

/// A square cover in a colour of its own, as a PNG on disk.
Future<void> cover(String path, Color a, Color b) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  const s = 400.0;
  c.drawRect(
    const Rect.fromLTWH(0, 0, s, s),
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, const Offset(s, s), [a, b]),
  );
  c.drawCircle(
    const Offset(s * .62, s * .4),
    s * .22,
    Paint()..color = Colors.white.withValues(alpha: .25),
  );
  final img = await rec.endRecording().toImage(s.toInt(), s.toInt());
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  final out = Platform.environment['LIBRARY_PAGES_SHOTS'];
  if (out == null) return;
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
      '/opt/homebrew/share/flutter';
  final fonts = '$flutterRoot/bin/cache/artifacts/material_fonts';

  late LibraryDatabase db;
  late LibraryRepository repo;
  late Directory tmp;
  final key = GlobalKey();

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadFont('Roboto', ['$fonts/Roboto-Regular.ttf']);
    await loadFont('MaterialIcons', ['$fonts/MaterialIcons-Regular.otf']);
    await loadFont('Satoshi', [
      'assets/fonts/Satoshi-Regular.ttf',
      'assets/fonts/Satoshi-Medium.ttf',
      'assets/fonts/Satoshi-Bold.ttf',
    ]);
    await loadFont('ClashDisplay', [
      'assets/fonts/ClashDisplay-Medium.ttf',
      'assets/fonts/ClashDisplay-Semibold.ttf',
    ]);
    Directory(out).createSync(recursive: true);
  });

  // One directory for the whole run: ArtworkService remembers the first temp
  // path it is given.
  tmp = Directory.systemTemp.createTempSync('shots');
  PathProviderPlatform.instance = FakePaths(tmp.path);

  setUp(() {
    db = LibraryDatabase.forTesting(NativeDatabase.memory());
    repo = LibraryRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  Future<void> shot(WidgetTester t, String name) async {
    await t.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$out/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  Future<void> show(WidgetTester t, Widget page, {double w = 390}) async {
    t.view.physicalSize = Size(w, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppController>.value(
            value: FakeController(),
          ),
          Provider<LibraryRepository>.value(value: repo),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppThemes.darkTheme,
          home: RepaintBoundary(key: key, child: page),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await t.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> finish(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(milliseconds: 50));
  }

  Future<void> seed(WidgetTester t) async {
    final palette = [
      [const Color(0xFFE5484D), const Color(0xFF3B1D5A)],
      [const Color(0xFF30A46C), const Color(0xFF0B3B4A)],
      [const Color(0xFFF5A524), const Color(0xFF7A1F3D)],
      [const Color(0xFF3E63DD), const Color(0xFF111B3D)],
    ];
    await t.runAsync(() async {
      for (var i = 1; i <= 8; i++) {
        await cover(
          '${tmp.path}/cloud_art_$i.png',
          palette[i % 4][0],
          palette[i % 4][1],
        );
      }
      await repo.upsertSongs([
        row(1, 'Midnight Run', track: 1, plays: 14, duration: 231000),
        row(2, 'Neon Rain', track: 2, plays: 31, duration: 198000),
        row(3, 'Afterglow', track: 3, plays: 7, duration: 254000),
        row(4, 'Static Hearts', track: 4, plays: 3, duration: 187000),
        row(5, 'Tail Lights', track: 5, plays: 22, duration: 242000),
        row(6, 'Open Roads', album: 'Daybreak', track: 1, plays: 9),
        row(7, 'First Light', album: 'Daybreak', track: 2, plays: 5),
        row(8, 'Golden Hour', album: 'Daybreak', track: 3, plays: 18),
      ]);
    });
  }

  testWidgets('album', (t) async {
    await seed(t);
    await show(t, const AlbumSongs(albumId: null, album: 'Night Drive', songs: 5));
    await shot(t, 'library_album');
    await finish(t);
  });

  testWidgets('album wide', (t) async {
    await seed(t);
    await show(
      t,
      const AlbumSongs(albumId: null, album: 'Night Drive', songs: 5),
      w: 900,
    );
    await shot(t, 'library_album_wide');
    await finish(t);
  });

  testWidgets('artist', (t) async {
    await seed(t);
    await show(
      t,
      const ArtistSongs(artistId: null, artist: 'Nova Reyes', songs: 8, albums: 2),
    );
    await shot(t, 'library_artist');
    await finish(t);
  });

  testWidgets('playlist', (t) async {
    await seed(t);
    OnAudioQueryPlatform.instance = FakePlatform([
      for (var i = 1; i <= 6; i++)
        model(i, ['Midnight Run', 'Neon Rain', 'Afterglow', 'Open Roads', 'Golden Hour', 'Tail Lights'][i - 1]),
    ]);
    await show(
      t,
      const PlaylistSongs(playlistId: 3, playlist: 'Road trip', songs: 6),
    );
    await shot(t, 'library_playlist');
    await finish(t);
  });

  // The YouTube Music pages need the network, so this is the same page built
  // from the same widgets with a fixture in place of the repository: the
  // Download slot, numbered album rows, YtTrackRow playlist rows.
  testWidgets('youtube album + playlist (fixtures)', (t) async {
    const tracks = [
      YtTrack(videoId: 'a', title: 'Midnight Run', durationSecs: 231),
      YtTrack(videoId: 'b', title: 'Neon Rain', durationSecs: 198),
      YtTrack(videoId: 'c', title: 'Afterglow', artist: 'Kay', durationSecs: 254),
      YtTrack(videoId: 'd', title: 'Static Hearts', durationSecs: 187),
    ];
    for (final album in [true, false]) {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      await t.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppThemes.darkTheme,
          home: RepaintBoundary(
            key: key,
            child: MediaPageScaffold(
              title: 'Night Drive',
              heroHeight: mediaListHeroHeight,
              background: MediaListHero(
                kicker: album ? 'ALBUM' : 'PLAYLIST',
                title: 'Night Drive',
                credits: MediaCredits(
                  children: [
                    MediaCreditChip(
                      name: 'Nova Reyes',
                      portrait: const YtArtwork(
                        url: null,
                        size: 24,
                        circular: true,
                        placeholder: Icons.person_rounded,
                      ),
                      onTap: () {},
                    ),
                  ],
                ),
                facts: '2024 • 4 songs • 14 minutes',
                art: (s) => YtArtwork(url: null, size: s),
                actions: [
                  YtRoundButton(
                    icon: Icons.download_rounded,
                    tooltip: 'Download all',
                    onTap: () {},
                  ),
                  YtRoundButton(
                    icon: Icons.play_arrow_rounded,
                    tooltip: 'Play',
                    size: 64,
                    primary: true,
                    onTap: () {},
                  ),
                  YtRoundButton(
                    icon: Icons.shuffle_rounded,
                    tooltip: 'Shuffle',
                    onTap: () {},
                  ),
                ],
              ),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  sliver: SliverFixedExtentList(
                    itemExtent: 60,
                    delegate: SliverChildBuilderDelegate(
                      childCount: tracks.length,
                      (context, i) => album
                          ? MediaAlbumRow(
                              number: i + 1,
                              title: tracks[i].title,
                              byline: tracks[i].artist,
                              duration: mediaClock(tracks[i].durationSecs),
                              current: i == 1,
                              playing: Stream.value(true),
                              onTap: () {},
                              onMore: () {},
                            )
                          : MediaHighlight(
                              current: i == 1,
                              child: YtTrackRow(
                                track: tracks[i],
                                position: i + 1,
                                onTap: () {},
                                onMore: () {},
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
      await shot(t, album ? 'yt_album_fixture' : 'yt_playlist_fixture');
    }
    addTearDown(t.view.reset);
  });
}
