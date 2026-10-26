import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:eq_app/Themes/AppThemes.dart';
import 'package:eq_app/controllers/app_controller.dart';
import 'package:eq_app/data/library_database.dart';
import 'package:eq_app/data/library_repository.dart';
import 'package:eq_app/helpers/audio_handler.dart';
import 'package:eq_app/pages/album_songs.dart';
import 'package:eq_app/pages/artist_songs.dart';
import 'package:eq_app/pages/discover/widgets/media_widgets.dart';
import 'package:eq_app/pages/playlist_songs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';

class _Player implements AudioPlayer {
  @override
  Stream<bool> get playingStream => Stream.value(true);
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Handler implements HypeAudioHandler {
  @override
  final player = _Player();
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

/// Records what the pages ask the player to do.
class FakeController extends ChangeNotifier implements AppController {
  FakeController({this.playing = -1, List<SongModel> queue = const []})
    : songs = queue;

  final calls = <String>[];
  final int playing;

  @override
  List<SongModel> songs;
  @override
  int get songId => playing;
  @override
  bool get hasMiniPlayer => false;
  @override
  bool get hasNowPlaying => playing >= 0;
  @override
  HypeAudioHandler get handler => _Handler();

  List<SongModel> lastList = const [];

  @override
  Future<void> playSongFromList(
    List<SongModel> list,
    int index, {
    Duration? initialPosition,
  }) async {
    lastList = list;
    calls.add('play:$index:${list[index].title}');
  }

  @override
  Future<void> insertNext(List<SongModel> extra) async {
    lastList = extra;
    calls.add('next:${extra.length}');
  }

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class FakePlatform extends OnAudioQueryPlatform {
  FakePlatform(this.songs);
  final List<SongModel> songs;
  @override
  Future<List<SongModel>> queryAudiosFrom(
    AudiosFromType type,
    Object where, {
    SongSortType? sortType,
    OrderType? orderType,
    bool? ignoreCase,
    dynamic args,
  }) async => songs;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class FakePaths extends PathProviderPlatform {
  FakePaths(this.dir);
  final String dir;
  @override
  Future<String?> getTemporaryPath() async => dir;
}

SongsCompanion row(
  int id,
  String title, {
  String artist = 'Nova Reyes',
  String album = 'Night Drive',
  int? track,
  int plays = 0,
  int duration = 215000,
}) => SongsCompanion.insert(
  id: Value(id),
  data: 'http://lib/$id.mp3',
  title: Value(title),
  artist: Value(artist),
  album: Value(album),
  track: Value(track),
  duration: Value(duration),
  playCount: Value(plays),
);

SongModel model(
  int id,
  String title, {
  String artist = 'Nova Reyes',
  String album = 'Night Drive',
}) => SongModel({
  '_id': id,
  '_data': 'http://lib/$id.mp3',
  'title': title,
  'artist': artist,
  'album': album,
  'duration': 215000,
  '_display_name': '$title.mp3',
  '_display_name_wo_ext': title,
  '_size': 0,
  'file_extension': 'mp3',
  'is_music': true,
});

/// A widget test that unmounts the page before it ends: drift schedules a
/// zero-length timer when a stream is cancelled, which has to run inside the
/// test rather than after it.
void pageTest(String name, Future<void> Function(WidgetTester t) body) {
  testWidgets(name, (t) async {
    await body(t);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(milliseconds: 50));
  });
}

void main() {
  late LibraryDatabase db;
  late LibraryRepository repo;
  late FakeController controller;
  late Directory tmp;

  setUp(() {
    db = LibraryDatabase.forTesting(NativeDatabase.memory());
    repo = LibraryRepository(db);
    controller = FakeController();
    tmp = Directory.systemTemp.createTempSync('library_pages');
    PathProviderPlatform.instance = FakePaths(tmp.path);
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Widget host(Widget page) => MultiProvider(
    providers: [
      ChangeNotifierProvider<AppController>.value(value: controller),
      Provider<LibraryRepository>.value(value: repo),
    ],
    child: MaterialApp(theme: AppThemes.darkTheme, home: page),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> tapIcon(WidgetTester tester, String tooltip) async {
    await tester.tap(find.byTooltip(tooltip));
    await tester.pump();
  }

  group('AlbumSongs', () {
    Future<void> open(WidgetTester tester) async {
      await tester.runAsync(
        () => repo.upsertSongs([
          row(1, 'Intro', track: 1),
          row(2, 'Neon', track: 2),
          row(3, 'Outro', track: 3),
        ]),
      );
      await tester.pumpWidget(
        host(const AlbumSongs(albumId: null, album: 'Night Drive', songs: 3)),
      );
      await settle(tester);
    }

    pageTest('shows the album the way the YouTube one reads', (t) async {
      await open(t);
      expect(find.text('ALBUM'), findsOneWidget);
      expect(find.text('Night Drive'), findsWidgets);
      expect(find.text('Nova Reyes'), findsOneWidget); // credit chip
      expect(find.text('3 songs • 11 minutes'), findsWidgets);
      expect(find.text('Neon'), findsOneWidget);
      expect(find.text('2'), findsOneWidget); // numbered like the sleeve
    });

    pageTest('Play, Shuffle, Play next and a row call the controller', (
      t,
    ) async {
      await open(t);
      await tapIcon(t, 'Play');
      expect(controller.calls.last, 'play:0:Intro');
      await tapIcon(t, 'Shuffle');
      expect(controller.calls.last, startsWith('play:0:'));
      expect(controller.lastList, hasLength(3));
      await tapIcon(t, 'Play next');
      // Nothing playing: "next" starts the list instead.
      expect(controller.calls.last, 'play:0:Intro');
      await t.tap(find.text('Outro'));
      expect(controller.calls.last, 'play:2:Outro');
    });

    pageTest('Play next queues the whole list after the playing track', (
      t,
    ) async {
      controller = FakeController(playing: 0, queue: [model(9, 'Else')]);
      await open(t);
      await tapIcon(t, 'Play next');
      expect(controller.calls.last, 'next:3');
    });

    pageTest('an empty album says so', (t) async {
      await t.pumpWidget(
        host(const AlbumSongs(albumId: null, album: 'Nothing', songs: 0)),
      );
      await settle(t);
      expect(find.text('No songs found'), findsOneWidget);
    });
  });

  group('ArtistSongs', () {
    Future<void> open(WidgetTester tester) async {
      // Tall enough that the albums shelf is built.
      tester.view.physicalSize = const Size(390, 1900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(
        () => repo.upsertSongs([
          row(1, 'Quiet', plays: 1),
          row(2, 'Loud', plays: 9),
          row(3, 'Mid', plays: 4, album: 'Second'),
          row(4, 'Four', album: 'Second'),
          row(5, 'Five', album: 'Second'),
          row(6, 'Six', album: 'Second'),
        ]),
      );
      await tester.pumpWidget(
        host(
          const ArtistSongs(
            artistId: null,
            artist: 'Nova Reyes',
            songs: 6,
            albums: 2,
          ),
        ),
      );
      await settle(tester);
    }

    pageTest('top songs by plays, five at a time, and an albums shelf', (
      t,
    ) async {
      await open(t);
      expect(find.text('6 songs • 2 albums'), findsOneWidget);
      expect(find.text('TOP SONGS'), findsOneWidget);
      expect(find.text('Albums'), findsOneWidget);
      // Most played first, and only five of six until asked.
      final loud = t.getTopLeft(find.text('Loud')).dy;
      final mid = t.getTopLeft(find.text('Mid')).dy;
      expect(loud, lessThan(mid));
      expect(find.text('Show all 6'), findsOneWidget);
    });

    pageTest('Play, Shuffle, Play next and a top song', (t) async {
      await open(t);
      await tapIcon(t, 'Play');
      expect(controller.calls.last, startsWith('play:0:'));
      await tapIcon(t, 'Shuffle');
      expect(controller.lastList, hasLength(6));
      await tapIcon(t, 'Play next');
      expect(controller.calls.last, startsWith('play:0:')); // nothing playing
      await t.tap(find.text('Loud'));
      // The queue is the artist's whole list, from the tapped song.
      expect(controller.calls.last, endsWith(':Loud'));
      expect(controller.lastList, hasLength(6));
    });
  });

  group('PlaylistSongs', () {
    pageTest('lists the device playlist with each track', (t) async {
      OnAudioQueryPlatform.instance = FakePlatform([
        model(1, 'One'),
        model(2, 'Two', artist: 'Kay'),
      ]);
      await t.pumpWidget(
        host(
          const PlaylistSongs(playlistId: 7, playlist: 'Road trip', songs: 2),
        ),
      );
      await settle(t);
      expect(find.text('PLAYLIST'), findsOneWidget);
      expect(find.text('Road trip'), findsWidgets);
      expect(find.text('2 songs • 7 minutes'), findsWidgets);
      await tapIcon(t, 'Play');
      expect(controller.calls.last, 'play:0:One');
      await t.tap(find.text('Two'));
      expect(controller.calls.last, 'play:1:Two');
      await tapIcon(t, 'Play next');
      expect(controller.calls.last, 'play:0:One');
    });
  });

  group('shared pieces', () {
    test('clock and total length', () {
      expect(mediaClock(187), '3:07');
      expect(mediaClock(null), isNull);
      expect(mediaTotalLength(60 * 72), '1 hr 12 min');
      expect(mediaTotalLength(60 * 42), '42 minutes');
    });
  });
}

