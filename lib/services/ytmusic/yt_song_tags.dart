/// What a downloaded song's file should say about itself, and how it is
/// gathered.
///
/// The way every downloader that tags properly works (yt-dlp, Seal, spotDL):
/// the facts come from the music service itself, not from guessing at the
/// video's title. Here that is YouTube Music's own details for the track —
/// every credited artist, the album, the year — the album's page for its
/// artist and the track's number, the cover at 1200 px, and lyrics: timed
/// from LRCLIB when it has them (they become a `.lrc` beside the song), else
/// YouTube Music's own (Musixmatch / LyricFind), plain.
///
/// Every source is optional. What can't be found is left out; a download is
/// never failed for want of a tag.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/lyrics_model.dart';
import '../lyrics/lrclib_resolver.dart';
import 'parse/yt_json.dart';
import 'parse/yt_track_info.dart';
import 'parse/yt_tracks.dart';
import 'yt_models.dart';
import 'yt_repository.dart';

/// The tags for one song.
@immutable
class YtSongTags {
  final String title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final int? year;
  final int? trackNumber;
  final int? trackTotal;

  /// The cover, a JPEG on disk.
  final String? coverPath;

  /// The cover is a 16:9 video thumbnail: crop it to the middle square.
  final bool cropCover;

  /// Lyrics as plain text, for the file's lyrics tag.
  final String? lyrics;

  /// Timed lyrics (LRC), for the `.lrc` beside the song.
  final String? lrc;

  const YtSongTags({
    required this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.year,
    this.trackNumber,
    this.trackTotal,
    this.coverPath,
    this.cropCover = false,
    this.lyrics,
    this.lrc,
  });

  /// The bare minimum, from what the track row itself said.
  factory YtSongTags.fromTrack(YtTrack track) => YtSongTags(
    title: cleanTitle(track.title, artist: track.artist),
    artist: track.artist,
    album: track.album,
  );

  /// The shape the native tag writers take.
  Map<String, Object?> toChannel() => {
    'title': title,
    'artist': artist,
    'album': album,
    'albumArtist': albumArtist,
    'year': year?.toString(),
    'track': trackNumber?.toString(),
    'trackTotal': trackTotal?.toString(),
    'lyrics': lyrics,
    'coverPath': coverPath,
    'cropCover': cropCover,
  };
}

/// Where [YtSongTagger] gets its facts; each defaults to the real thing and
/// can be swapped in tests.
typedef YtInfoSource = Future<YtTrackInfo?> Function(String videoId);
typedef YtAlbumSource = Future<YtTrackList?> Function(String id, String title);
typedef YtLyricsSource = Future<YtLyrics?> Function(String browseId);
typedef LrcSource =
    Future<String?> Function({
      required String title,
      required String artist,
      int? durationMs,
    });
typedef BytesSource = Future<List<int>?> Function(String url);
typedef SongSearchSource = Future<List<ExploreItem>> Function(String query);

class YtSongTagger {
  YtSongTagger({
    YtInfoSource? trackInfo,
    YtAlbumSource? album,
    YtLyricsSource? ytLyrics,
    LrcSource? lrclib,
    BytesSource? fetch,
    SongSearchSource? songSearch,
    this.lyricsTimeout = defaultLyricsTimeout,
  }) : _trackInfo =
           trackInfo ?? ((id) => YtMusicRepository.instance.trackInfo(id)),
       _album =
           album ??
           ((id, title) => YtMusicRepository.instance.album(id, title: title)),
       _ytLyrics =
           ytLyrics ?? ((id) => YtMusicRepository.instance.lyrics(id)),
       _lrclib = lrclib ?? LrclibResolver().resolve,
       _fetch = fetch ?? _get,
       _songSearch = songSearch ?? _searchSongs;

  /// Lyrics are the slowest, least important part of a download's tags
  /// (LRCLIB allows 15 s a request, with retries). They get their own bound,
  /// so a slow lookup costs the lyrics and never the cover, album, year and
  /// track number already found — which the download's overall bound would
  /// otherwise throw away with them.
  static const defaultLyricsTimeout = Duration(seconds: 8);
  final Duration lyricsTimeout;

  final YtInfoSource _trackInfo;
  final YtAlbumSource _album;
  final YtLyricsSource _ytLyrics;
  final LrcSource _lrclib;
  final BytesSource _fetch;
  final SongSearchSource _songSearch;

  static Future<List<ExploreItem>> _searchSongs(String query) async {
    final shelves = await YtMusicRepository.instance.search(
      query,
      SearchFilter.songs,
    );
    return [
      for (final shelf in shelves)
        for (final item in shelf.items)
          if (item.kind == ExploreKind.song) item,
    ];
  }

  /// Gathers the tags for [track], writing its cover into [workDir].
  Future<YtSongTags> gather(YtTrack track, {required Directory workDir}) async {
    var info = await _quietly(() => _trackInfo(track.videoId));
    final isSong = info?.isSong ?? !track.hasVideo;
    final rawTitle = info?.title ?? track.title;
    var (title, artist) = isSong
        ? (rawTitle, info?.artist ?? track.artist)
        : videoCredits(rawTitle, info?.artist ?? track.artist);
    final durationSecs = info?.durationSecs ?? track.durationSecs;

    // A music video knows no album. Its song usually exists on YouTube Music
    // as a track of one, with the album, year and square cover: find it by
    // title and artist (and roughly the length — a video often runs longer).
    if (info?.album == null && track.album == null) {
      final song = await _quietly(
        () => _findSong(title, artist, durationSecs),
      );
      final songInfo = song == null
          ? null
          : await _quietly(() => _trackInfo(song.id));
      if (songInfo != null && songInfo.album != null) {
        info = songInfo;
        title = songInfo.title;
        artist = songInfo.artist ?? artist;
      }
    }
    final album = info?.album ?? track.album;

    final albumId = info?.albumId;
    final albumPage = albumId == null
        ? Future<YtTrackList?>.value()
        : _quietly(() => _album(albumId, album ?? ''));
    final art = info?.thumbnail ?? track.thumbnail;
    final cover = _quietly(
      () => _fetchCover(
        art,
        track.videoId,
        workDir,
        isSong: isSong || (info?.isSong ?? false),
      ),
    );
    final lyrics = _lyrics(
      title: title,
      artist: artist,
      album: album,
      durationSecs: durationSecs,
      lyricsId: info?.lyricsId,
    ).timeout(lyricsTimeout, onTimeout: () => (null, null));

    final page = await albumPage;
    final coverFile = await cover;
    final words = await lyrics;
    final number = page == null
        ? null
        : albumTrackNumber(page, videoId: track.videoId, title: title);
    return YtSongTags(
      title: title,
      artist: artist,
      album: album,
      albumArtist: page?.artist ?? (album != null ? primaryArtist(artist) : null),
      year: info?.year,
      trackNumber: number,
      trackTotal: number == null ? null : page!.tracks.length,
      coverPath: coverFile?.$1,
      cropCover: coverFile?.$2 ?? false,
      lyrics: words.$1,
      lrc: words.$2,
    );
  }

  /// The song version of a video. Its title (credits aside) and artist must
  /// agree. The length is only a hint — a video can run minutes longer
  /// ("Higher": 4:25 against the song's 2:18) — so it is ignored when the
  /// title is word for word the same, and must be within 10 s when it only
  /// mostly is.
  Future<ExploreItem?> _findSong(
    String title,
    String? artist,
    double? durationSecs,
  ) async {
    final query = [?artist, title].join(' ');
    final items = await _songSearch(query);
    final want = bareTitle(title);
    ExploreItem? best;
    var bestScore = 0.0;
    for (final item in items.take(5)) {
      final have = bareTitle(item.title);
      final exact = _overlap(want, have) >= 0.999 && _overlap(have, want) >= 0.999;
      if (!exact && _overlap(want, have) < 0.8) continue;
      final artistOk = artist == null ||
          item.artist == null ||
          _overlap(primaryArtist(artist) ?? artist, item.artist!) >= 0.5;
      if (!artistOk) continue;
      final score = matchScore(
        wantTitle: want,
        wantArtist: artist,
        wantMs: durationSecs == null ? null : (durationSecs * 1000).round(),
        item: ExploreItem(
          id: item.id,
          kind: item.kind,
          title: have,
          artist: item.artist,
          durationSecs: item.durationSecs,
        ),
        toleranceMs: exact ? 3600000 : 10000,
      );
      if (score > bestScore) {
        bestScore = score;
        best = item;
      }
    }
    return bestScore >= 1.0 ? best : null;
  }

  /// Tags from a file's "Artist - Title" name alone — a download YouTube
  /// Music couldn't place — with lyrics if LRCLIB knows the song.
  Future<YtSongTags> fromFileName(String name, {double? durationSecs}) async {
    final (artist, rawTitle) = splitFileName(name);
    final title = cleanTitle(rawTitle, artist: artist);
    final words = await _lyrics(
      title: title,
      artist: artist,
      album: null,
      durationSecs: durationSecs,
      lyricsId: null,
    );
    return YtSongTags(
      title: title,
      artist: artist,
      lyrics: words.$1,
      lrc: words.$2,
    );
  }

  /// Plain lyrics for the tag, and LRC when they are timed.
  Future<(String?, String?)> _lyrics({
    required String title,
    required String? artist,
    required String? album,
    required double? durationSecs,
    required String? lyricsId,
  }) async {
    final raw = await _quietly(
      () => _lrclib(
        title: title,
        artist: artist ?? '',
        durationMs: durationSecs == null ? null : (durationSecs * 1000).round(),
      ),
    );
    if (raw != null && raw.trim().isNotEmpty) {
      final data = parseLrc(raw);
      if (data.isSynced && data.lines.isNotEmpty) {
        final lrc = encodeLrc(
          LyricsData(
            lines: data.lines,
            isSynced: true,
            raw: raw,
            title: title,
            artist: artist,
            album: album,
            offsetMs: data.offsetMs,
          ),
        );
        return (_plain(data), lrc);
      }
      return (raw.trim(), null);
    }
    if (lyricsId != null) {
      final yt = await _quietly(() => _ytLyrics(lyricsId));
      if (yt != null) return (yt.text, null);
    }
    return (null, null);
  }

  static String _plain(LyricsData data) =>
      data.lines.map((l) => l.text).join('\n').trim();

  /// The cover at 1200 px: album art scales on its CDN; a video's thumbnail
  /// is a fixed 16:9 file, cropped square later. Returns (path, crop).
  Future<(String, bool)?> _fetchCover(
    String? url,
    String videoId,
    Directory workDir, {
    required bool isSong,
  }) async {
    final candidates = <String>[
      if (url != null && !url.contains('i.ytimg.com')) thumbnailAt(url, 1200),
      if (url == null || url.contains('i.ytimg.com') || !isSong) ...[
        'https://i.ytimg.com/vi/$videoId/maxresdefault.jpg',
        'https://i.ytimg.com/vi/$videoId/sddefault.jpg',
        'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
      ],
    ];
    if (!workDir.existsSync()) await workDir.create(recursive: true);
    for (final candidate in candidates) {
      final bytes = await _fetch(candidate);
      if (bytes == null || bytes.length < 2048) continue; // a placeholder
      final file = File('${workDir.path}/cover_$videoId.jpg');
      await file.writeAsBytes(bytes, flush: true);
      return (file.path, candidate.contains('i.ytimg.com'));
    }
    return null;
  }

  static Future<List<int>?> _get(String url) async {
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().catchError((_) {});
        return null;
      }
      final bytes = <int>[];
      await response
          .forEach(bytes.addAll)
          .timeout(const Duration(seconds: 20));
      return bytes;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<T?> _quietly<T>(Future<T?> Function() call) async {
    try {
      return await call();
    } catch (e) {
      debugPrint('YtSongTagger: $e');
      return null;
    }
  }
}

/// Writes [lrc] beside [audioPath] (same name, `.lrc`), where music players
/// and this app's own lyrics look first. False when it couldn't.
Future<bool> writeLrcBeside(String audioPath, String lrc) async {
  final dot = audioPath.lastIndexOf('.');
  final slash = audioPath.lastIndexOf('/');
  final base = dot > slash ? audioPath.substring(0, dot) : audioPath;
  try {
    await File('$base.lrc').writeAsString(lrc, flush: true);
    return true;
  } catch (e) {
    debugPrint('YtSongTagger: could not write $base.lrc: $e');
    return false;
  }
}

/// A video's title without what only describes the video — "(Official
/// Video)", "[Lyric Video]", "| Visualizer" — nor a leading "Artist - "
/// when [artist] already says it. What describes the song stays: "(Remix)",
/// "(feat. …)", "(Live)", "(Acoustic)".
String cleanTitle(String title, {String? artist}) {
  var t = title;
  const noise =
      r'(official\s+)?(music\s+|lyrics?\s+|hd\s+|4k\s+|audio\s+|video\s+)*'
      r'(video|audio|lyrics?|visuali[sz]er|mv|hd|4k)';
  t = t.replaceAll(
    RegExp(r'\s*[\(\[]\s*' + noise + r'\s*[\)\]]', caseSensitive: false),
    '',
  );
  t = t.replaceAll(RegExp(r'\s*\|\s*' + noise + r'.*$', caseSensitive: false), '');
  if (artist != null && artist.isNotEmpty) {
    final lead = RegExp(
      '^${RegExp.escape(artist)}\\s*[-–—]\\s*',
      caseSensitive: false,
    );
    t = t.replaceFirst(lead, '');
  }
  t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  return t.isEmpty ? title.trim() : t;
}

/// A video's title and artist: the title without its video noise, and when
/// it reads "Credits - Song" with credits naming [artist] (the channel), the
/// credits become the artist — "21 Savage, Metro Boomin & Burna Boy - just
/// like me (Official Audio)" on Burna Boy's channel is "just like me" by all
/// three.
(String, String?) videoCredits(String title, String? artist) {
  final clean = cleanTitle(title);
  if (artist != null && artist.isNotEmpty) {
    final dash = RegExp(r'\s[-–—]\s').firstMatch(clean);
    if (dash != null) {
      final credits = clean.substring(0, dash.start).trim();
      final song = clean.substring(dash.end).trim();
      if (song.isNotEmpty &&
          credits.toLowerCase().contains(artist.toLowerCase())) {
        return (song, credits);
      }
    }
  }
  return (clean, artist);
}

/// A title without its credits: "Mood (feat. BNXN)" and "Mood (feat. Buju)"
/// are the same song under an artist's two names.
String bareTitle(String title) {
  var t = cleanTitle(title);
  t = t.replaceAll(
    RegExp(r'\s*[\(\[]\s*(feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]',
        caseSensitive: false),
    '',
  );
  t = t.replaceAll(
    RegExp(r'\s+(feat\.?|ft\.?|featuring)\s.*$', caseSensitive: false),
    '',
  );
  t = t.trim();
  return t.isEmpty ? title.trim() : t;
}

/// "Artist - Title" → (artist, title); a name without " - " is all title.
(String?, String) splitFileName(String name) {
  final dash = RegExp(r'\s[-–—]\s').firstMatch(name);
  if (dash == null) return (null, name.trim());
  final artist = name.substring(0, dash.start).trim();
  final title = name.substring(dash.end).trim();
  if (artist.isEmpty || title.isEmpty) return (null, name.trim());
  return (artist, title);
}

/// The first of several credited artists ("Burna Boy & Ed Sheeran" → "Burna
/// Boy"): the album artist when the album page doesn't name one.
String? primaryArtist(String? artist) {
  if (artist == null) return null;
  final first = artist.split(RegExp(r'\s*(,|&| x | feat\.? | ft\.? )\s*')).first;
  return first.trim().isEmpty ? artist : first.trim();
}

/// The track's number on its album page: by id, else by title (an album
/// lists its own upload of a song, often under another video id).
int? albumTrackNumber(
  YtTrackList album, {
  required String videoId,
  required String title,
}) {
  final byId = album.tracks.indexWhere((t) => t.videoId == videoId);
  if (byId >= 0) return byId + 1;
  final want = _normalise(title);
  if (want.isEmpty) return null;
  final byTitle = album.tracks.indexWhere((t) => _normalise(t.title) == want);
  return byTitle >= 0 ? byTitle + 1 : null;
}

String _normalise(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

/// How well a search result fits a file: 1.0 or more is a match.
///
/// Length within [toleranceMs] (3 s for a file) is the strong signal (a different song almost never
/// lasts the same to the second as well as sharing words); the title's words
/// must mostly be there; the artist helps when the length is unknown.
double matchScore({
  required String wantTitle,
  required String? wantArtist,
  required int? wantMs,
  required ExploreItem item,
  int toleranceMs = 3000,
}) => _matchScore(wantTitle, wantArtist, wantMs, item, toleranceMs);

double _matchScore(
  String title,
  String? artist,
  int? wantMs,
  ExploreItem item,
  int toleranceMs,
) {
  final titleOverlap = _overlap(cleanTitle(title), cleanTitle(item.title));
  if (titleOverlap < 0.5) return 0;
  final artistOverlap = artist == null || item.artist == null
      ? 0.0
      : _overlap(artist, item.artist!);
  final seconds = item.durationSecs;
  if (wantMs != null && seconds != null) {
    final off = (seconds * 1000 - wantMs).abs();
    if (off > toleranceMs) return 0;
    return 1.0 + titleOverlap + artistOverlap * 0.5 - off / (2 * toleranceMs);
  }
  // No length to check: title and artist must both agree.
  return titleOverlap >= 0.8 && artistOverlap >= 0.5
      ? 0.5 + titleOverlap + artistOverlap * 0.5
      : 0;
}

/// Whether [credits] (a result's artists) include [artist]'s first name —
/// not just a title that mentions them, as a stranger's re-upload does.
bool creditsInclude(String? credits, String artist) =>
    credits != null && _overlap(primaryArtist(artist) ?? artist, credits) >= 0.5;

/// The share of [a]'s words found in [b] (case and punctuation ignored).
double _overlap(String a, String b) {
  final wa = _words(a);
  if (wa.isEmpty) return 0;
  final wb = _words(b).toSet();
  return wa.where(wb.contains).length / wa.length;
}

List<String> _words(String s) => s
    .toLowerCase()
    // "Heaven’s Gate" and "Heavens Gate" are one title: apostrophes go
    // before splitting, so they don't break a word in two.
    .replaceAll(RegExp("['’`´]"), '')
    .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
    .where((w) => w.isNotEmpty && w != 'feat' && w != 'ft')
    .toList();
