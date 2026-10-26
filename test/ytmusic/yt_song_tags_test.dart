/// Tags for a downloaded song: what YouTube Music says about it, the album's
/// page, a 1200 px cover, and lyrics — gathered from fakes here — plus the
/// title clean-up that real video titles from the test tablet's library need.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/services/ytmusic/parse/yt_track_info.dart';
import 'package:eq_app/services/ytmusic/parse/yt_tracks.dart';
import 'package:eq_app/services/ytmusic/yt_models.dart';
import 'package:eq_app/services/ytmusic/yt_song_tags.dart';

void main() {
  group('cleanTitle', () {
    const cases = {
      'just like me (Official Audio)': 'just like me',
      'Sungba (Remix) (Official Video) (feat. Burna Boy)':
          'Sungba (Remix) (feat. Burna Boy)',
      'Play Play (Official Lyric Video) (feat. Burna Boy)':
          'Play Play (feat. Burna Boy)',
      'Loved By You (Visualizer) (feat. Burna Boy)':
          'Loved By You (feat. Burna Boy)',
      'My Oasis (Lyric Video)': 'My Oasis',
      'Ginger [Official Music Video]': 'Ginger',
      'Last Last | Official Video': 'Last Last',
      'Temper (Remix) ft Burna Boy (Live)': 'Temper (Remix) ft Burna Boy (Live)',
      'Collateral Damage Live Session Vevo Ctrl':
          'Collateral Damage Live Session Vevo Ctrl',
    };
    cases.forEach((raw, clean) {
      test(raw, () => expect(cleanTitle(raw), clean));
    });

    test('drops a leading "Artist - " the artist already says', () {
      expect(
        cleanTitle('Black Sherif - Second Sermon (Remix) (Official Video)',
            artist: 'Black Sherif'),
        'Second Sermon (Remix)',
      );
    });

    test('never empties a title', () {
      expect(cleanTitle('(Official Video)'), '(Official Video)');
    });
  });

  group('videoCredits', () {
    test('credits naming the channel become the artist', () {
      expect(
        videoCredits(
          '21 Savage, Metro Boomin & Burna Boy - just like me (Official Audio)',
          'Burna Boy',
        ),
        ('just like me', '21 Savage, Metro Boomin & Burna Boy'),
      );
    });

    test('a dash that is not a credit stays in the title', () {
      expect(
        videoCredits('Part 1 - The Beginning', 'Some Channel'),
        ('Part 1 - The Beginning', 'Some Channel'),
      );
    });
  });

  test('bareTitle drops credits, keeps what names the song', () {
    expect(bareTitle('Mood (feat. BNXN)'), 'Mood');
    expect(bareTitle('Mood (feat. Buju)'), 'Mood');
    expect(bareTitle('Temper (Remix) ft Burna Boy'), 'Temper (Remix)');
    expect(bareTitle('Sungba (Remix) (with Burna Boy)'), 'Sungba (Remix)');
    expect(bareTitle('GWAGWALADA'), 'GWAGWALADA');
  });

  test('primaryArtist takes the first credit', () {
    expect(primaryArtist('Burna Boy & Ed Sheeran'), 'Burna Boy');
    expect(primaryArtist('Wizkid, Tems'), 'Wizkid');
    expect(primaryArtist('Asake feat. Burna Boy'), 'Asake');
    expect(primaryArtist('Shubh'), 'Shubh');
    expect(primaryArtist(null), isNull);
  });

  group('albumTrackNumber', () {
    const album = YtTrackList(
      title: 'Love, Damini',
      tracks: [
        YtTrack(videoId: 'a', title: 'Glory'),
        YtTrack(videoId: 'b', title: 'Science'),
        YtTrack(videoId: 'c', title: 'Last, Last'),
      ],
    );
    test('by id', () {
      expect(albumTrackNumber(album, videoId: 'b', title: 'x'), 2);
    });
    test('by title when the album lists another upload', () {
      expect(albumTrackNumber(album, videoId: 'zz', title: 'Last Last'), 3);
    });
    test('null when it is not there', () {
      expect(albumTrackNumber(album, videoId: 'zz', title: 'Nope'), isNull);
    });
  });

  group('gather', () {
    late Directory work;
    final fetched = <String>[];
    setUp(() async {
      fetched.clear();
      work = await Directory.systemTemp.createTemp('yt_tags_test');
    });
    tearDown(() => work.delete(recursive: true));

    Future<List<int>?> fetch(String url) async {
      fetched.add(url);
      return List<int>.filled(4096, 7);
    }

    test('a song: album page, track number, 1200 px cover, timed lyrics',
        () async {
      final tagger = YtSongTagger(
        trackInfo: (id) async => const YtTrackInfo(
          videoId: 'v1',
          title: 'Last Last',
          artist: 'Burna Boy',
          album: 'Love, Damini',
          albumId: 'MPREb_x',
          year: 2022,
          thumbnail: 'https://yt3.googleusercontent.com/abc=w544-h544-l90-rj',
          durationSecs: 172,
          lyricsId: 'MPLYt_x',
          isSong: true,
        ),
        album: (id, title) async => const YtTrackList(
          title: 'Love, Damini',
          artist: 'Burna Boy',
          tracks: [
            YtTrack(videoId: 'a', title: 'Glory'),
            YtTrack(videoId: 'b', title: 'Last Last'),
          ],
        ),
        lrclib: ({required title, required artist, durationMs}) async =>
            '[00:01.00](E don cast)\n[00:02.50](Last, last)',
        ytLyrics: (id) async => fail('LRCLIB had them'),
        fetch: fetch,
      );
      final tags = await tagger.gather(
        const YtTrack(videoId: 'v1', title: 'Last Last'),
        workDir: work,
      );
      expect(tags.title, 'Last Last');
      expect(tags.artist, 'Burna Boy');
      expect(tags.album, 'Love, Damini');
      expect(tags.albumArtist, 'Burna Boy');
      expect(tags.year, 2022);
      expect(tags.trackNumber, 2);
      expect(tags.trackTotal, 2);
      expect(fetched.first, 'https://yt3.googleusercontent.com/abc=w1200-h1200-l90-rj');
      expect(tags.cropCover, isFalse);
      expect(File(tags.coverPath!).lengthSync(), 4096);
      expect(tags.lyrics, '(E don cast)\n(Last, last)');
      expect(tags.lrc, contains('[ti:Last Last]'));
      expect(tags.lrc, contains('[ar:Burna Boy]'));
      expect(tags.lrc, contains('[al:Love, Damini]'));
      expect(tags.lrc, contains('[00:02.50](Last, last)'));
      expect(tags.toChannel(), containsPair('track', '2'));
      expect(tags.toChannel(), containsPair('year', '2022'));
    });

    test('a video: credits from its title, a cropped thumbnail, YouTube lyrics',
        () async {
      final tagger = YtSongTagger(
        trackInfo: (id) async => const YtTrackInfo(
          videoId: 'v2',
          title:
              '21 Savage, Metro Boomin & Burna Boy - just like me (Official Audio)',
          artist: 'Burna Boy',
          thumbnail: 'https://i.ytimg.com/vi/v2/hqdefault.jpg?sqp=x',
          lyricsId: 'MPLYt_y',
        ),
        album: (id, title) async => fail('no album'),
        lrclib: ({required title, required artist, durationMs}) async => null,
        ytLyrics: (id) async => const YtLyrics('line one\nline two'),
        fetch: fetch,
        songSearch: (q) async => [],
      );
      final tags = await tagger.gather(
        const YtTrack(videoId: 'v2', title: 'x', hasVideo: true),
        workDir: work,
      );
      expect(tags.title, 'just like me');
      expect(tags.artist, '21 Savage, Metro Boomin & Burna Boy');
      expect(tags.album, isNull);
      expect(tags.albumArtist, isNull);
      expect(fetched.first, 'https://i.ytimg.com/vi/v2/maxresdefault.jpg');
      expect(tags.cropCover, isTrue);
      expect(tags.lyrics, 'line one\nline two');
      expect(tags.lrc, isNull, reason: 'untimed lyrics make no .lrc');
    });

    test('a video finds its song: album, year and the square cover', () async {
      final queries = <String>[];
      final tagger = YtSongTagger(
        trackInfo: (id) async => id == 'video'
            ? const YtTrackInfo(
                videoId: 'video',
                title: 'CHANEL (Official Music Video)',
                artist: 'Tyla',
                thumbnail: 'https://i.ytimg.com/vi/video/hqdefault.jpg',
                durationSecs: 190,
              )
            : const YtTrackInfo(
                videoId: 'song',
                title: 'CHANEL',
                artist: 'Tyla',
                album: 'A*POP',
                albumId: 'MPREb_apop',
                year: 2025,
                thumbnail: 'https://lh3.googleusercontent.com/c=w544-h544-l90-rj',
                durationSecs: 189,
                isSong: true,
              ),
        album: (id, title) async => const YtTrackList(
          title: 'A*POP',
          artist: 'Tyla',
          tracks: [
            YtTrack(videoId: 'x', title: 'RIGHT NOW'),
            YtTrack(videoId: 'song', title: 'CHANEL'),
          ],
        ),
        lrclib: ({required title, required artist, durationMs}) async => null,
        ytLyrics: (id) async => null,
        fetch: fetch,
        songSearch: (q) async {
          queries.add(q);
          return [
            const ExploreItem(
              id: 'other',
              kind: ExploreKind.song,
              title: 'CHANEL (Remix)',
              artist: 'Somebody',
              durationSecs: 240,
            ),
            const ExploreItem(
              id: 'song',
              kind: ExploreKind.song,
              title: 'CHANEL',
              artist: 'Tyla',
              durationSecs: 189,
            ),
          ];
        },
      );
      final tags = await tagger.gather(
        const YtTrack(videoId: 'video', title: 'x', hasVideo: true),
        workDir: work,
      );
      expect(queries, ['Tyla CHANEL']);
      expect(tags.title, 'CHANEL');
      expect(tags.album, 'A*POP');
      expect(tags.year, 2025);
      expect(tags.trackNumber, 2);
      expect(fetched.first, 'https://lh3.googleusercontent.com/c=w1200-h1200-l90-rj');
      expect(tags.cropCover, isFalse);
    });

    test('a video with an intro still finds its song when the title is exact',
        () async {
      final tagger = YtSongTagger(
        trackInfo: (id) async => id == 'video'
            ? const YtTrackInfo(
                videoId: 'video',
                title: 'Mood (Official Video) (feat. BNXN)',
                artist: 'Wizkid',
                durationSecs: 238, // the video: 28 s of intro
              )
            : const YtTrackInfo(
                videoId: 'song',
                title: 'Mood (feat. BNXN)',
                artist: 'Wizkid',
                album: 'Made In Lagos: Deluxe Edition',
                isSong: true,
              ),
        album: (id, title) async => null,
        lrclib: ({required title, required artist, durationMs}) async => null,
        ytLyrics: (id) async => null,
        fetch: fetch,
        songSearch: (q) async => [
          const ExploreItem(
            id: 'song',
            kind: ExploreKind.song,
            title: 'Mood (feat. Buju)',
            artist: 'Wizkid',
            durationSecs: 210,
          ),
        ],
      );
      final tags = await tagger.gather(
        const YtTrack(videoId: 'video', title: 'x', hasVideo: true),
        workDir: work,
      );
      expect(tags.album, 'Made In Lagos: Deluxe Edition');
    });

    test('an exact title is found however long the video runs, and '
        'apostrophes don\'t split words', () async {
      final tagger = YtSongTagger(
        trackInfo: (id) async => id == 'video'
            ? const YtTrackInfo(
                videoId: 'video',
                title: 'Heaven’s Gate (feat. Lily Allen)',
                artist: 'Burna Boy',
                durationSecs: 257,
              )
            : const YtTrackInfo(
                videoId: 'song',
                title: 'Heavens Gate',
                artist: 'Burna Boy',
                album: 'Outside',
                isSong: true,
              ),
        album: (id, title) async => null,
        lrclib: ({required title, required artist, durationMs}) async => null,
        ytLyrics: (id) async => null,
        fetch: fetch,
        songSearch: (q) async => [
          const ExploreItem(
            id: 'song',
            kind: ExploreKind.song,
            title: 'Heavens Gate',
            artist: 'Burna Boy',
            durationSecs: 203,
          ),
        ],
      );
      final tags = await tagger.gather(
        const YtTrack(videoId: 'video', title: 'x', hasVideo: true),
        workDir: work,
      );
      expect(tags.album, 'Outside');
    });

    test('a video whose song isn\'t found keeps the video\'s facts', () async {
      final tagger = YtSongTagger(
        trackInfo: (id) async => const YtTrackInfo(
          videoId: 'video',
          title: 'Live at the Hall (Official Video)',
          artist: 'Band',
          durationSecs: 600,
        ),
        album: (id, title) async => fail('no album'),
        lrclib: ({required title, required artist, durationMs}) async => null,
        ytLyrics: (id) async => null,
        fetch: fetch,
        songSearch: (q) async => [
          const ExploreItem(
            id: 'song',
            kind: ExploreKind.song,
            title: 'Live at the Hall (Studio Mix)',
            artist: 'Band',
            durationSecs: 240, // only partly the title, and far off: not it
          ),
        ],
      );
      final tags = await tagger.gather(
        const YtTrack(videoId: 'video', title: 'x', hasVideo: true),
        workDir: work,
      );
      expect(tags.title, 'Live at the Hall');
      expect(tags.album, isNull);
      expect(tags.cropCover, isTrue);
    });

    test('a lyrics lookup that never answers costs only the lyrics', () async {
      final tagger = YtSongTagger(
        lyricsTimeout: const Duration(milliseconds: 50),
        trackInfo: (id) async => const YtTrackInfo(
          videoId: 'v1',
          title: 'Last Last',
          artist: 'Burna Boy',
          album: 'Love, Damini',
          albumId: 'MPREb_x',
          year: 2022,
          thumbnail: 'https://yt3.googleusercontent.com/abc=w544-h544-l90-rj',
          durationSecs: 172,
          lyricsId: 'MPLYt_x',
          isSong: true,
        ),
        album: (id, title) async => const YtTrackList(
          title: 'Love, Damini',
          artist: 'Burna Boy',
          tracks: [
            YtTrack(videoId: 'a', title: 'Glory'),
            YtTrack(videoId: 'v1', title: 'Last Last'),
          ],
        ),
        lrclib: ({required title, required artist, durationMs}) =>
            Completer<String?>().future,
        ytLyrics: (id) async => null,
        fetch: fetch,
      );
      final tags = await tagger
          .gather(
            const YtTrack(videoId: 'v1', title: 'Last Last'),
            workDir: work,
          )
          .timeout(const Duration(seconds: 5));
      expect(tags.album, 'Love, Damini');
      expect(tags.year, 2022);
      expect(tags.trackNumber, 2);
      expect(tags.coverPath, isNotNull);
      expect(File(tags.coverPath!).lengthSync(), 4096);
      expect(tags.lyrics, isNull);
      expect(tags.lrc, isNull);
    });

    test('nothing answering still tags from the track row', () async {
      final tagger = YtSongTagger(
        trackInfo: (id) async => throw const SocketException('offline'),
        album: (id, title) async => null,
        lrclib: ({required title, required artist, durationMs}) async =>
            throw const SocketException('offline'),
        ytLyrics: (id) async => null,
        fetch: (url) async => null,
        songSearch: (q) async => throw const SocketException('offline'),
      );
      final tags = await tagger.gather(
        const YtTrack(
          videoId: 'v3',
          title: 'Ye',
          artist: 'Burna Boy',
          album: 'Outside',
        ),
        workDir: work,
      );
      expect(tags.title, 'Ye');
      expect(tags.artist, 'Burna Boy');
      expect(tags.album, 'Outside');
      expect(tags.coverPath, isNull);
      expect(tags.lyrics, isNull);
    });
  });
}
