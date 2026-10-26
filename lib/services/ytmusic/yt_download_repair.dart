/// Repairing YouTube downloads made before downloads were tagged.
///
/// Those are YouTube's bare streaming files: no title, artist, album, cover or
/// lyrics, so the Library shows their file name and an unknown artist. They
/// are found by their container — an MP4 whose `ftyp` brand is `dash`, which
/// only YouTube's streams carry here (a finished download is a plain `M4A`) —
/// identified on YouTube Music from their "Artist - Title" file name and
/// length, repackaged and tagged exactly as a new download is, and written
/// back over themselves. Overwriting in place keeps each song's id in the
/// media library, so play counts, favourites and playlists stay attached.
///
/// A file that can't be identified still gets a title and artist from its
/// name (and lyrics, if LRCLIB knows the song).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../Helpers/Channel.dart';
import 'yt_downloads.dart';
import 'yt_models.dart';
import 'yt_repository.dart';
import 'yt_song_tags.dart';

/// A file to repair.
@immutable
class YtRepairCandidate {
  final String path;

  /// The file name without its extension ("Burna Boy - Last Last").
  final String name;
  final int? durationMs;

  const YtRepairCandidate({
    required this.path,
    required this.name,
    this.durationMs,
  });
}

/// How a repair went.
@immutable
class YtRepairReport {
  /// Written back, tagged.
  final int fixed;

  /// Of those, the ones named from their file name only (not found on
  /// YouTube Music).
  final int fromFileName;

  /// Couldn't be repackaged or written back (or permission was refused).
  final int failed;

  /// Left alone because they were playing.
  final int skipped;

  const YtRepairReport({
    this.fixed = 0,
    this.fromFileName = 0,
    this.failed = 0,
    this.skipped = 0,
  });
}

typedef YtSearchSource =
    Future<List<ExploreItem>> Function(String query, SearchFilter filter);
typedef YtFinish =
    Future<bool> Function(String src, String dst, Map<String, Object?> tags);
typedef YtReplace =
    Future<Map<String, bool>> Function(
      List<({String path, String replacement})> files,
    );

class YtDownloadRepair {
  YtDownloadRepair({
    YtSongTagger? tagger,
    YtSearchSource? search,
    YtFinish? finish,
    YtReplace? replace,
    Future<Directory> Function()? workDir,
    Future<void> Function(String videoId, String path)? remember,
    this.batchSize = 25,
  }) : _tagger = tagger ?? YtSongTagger(),
       _search = search ?? _searchYouTubeMusic,
       _finish = finish ?? Channel.finishYtDownload,
       _replace = replace ?? Channel.replaceAudioFiles,
       _workDir = workDir ?? _defaultWorkDir,
       _remember = remember ?? YtDownloads.instance.remember;

  final YtSongTagger _tagger;
  final YtSearchSource _search;
  final YtFinish _finish;
  final YtReplace _replace;
  final Future<Directory> Function() _workDir;

  /// Notes which track a repaired file turned out to be, so the player knows
  /// it is already downloaded.
  final Future<void> Function(String videoId, String path) _remember;

  /// Files written back per batch — one permission dialog each for files
  /// another app owns, and the temp space a batch takes (~4 MB a song).
  final int batchSize;

  static Future<Directory> _defaultWorkDir() async =>
      Directory('${(await getTemporaryDirectory()).path}/yt_repair');

  static Future<List<ExploreItem>> _searchYouTubeMusic(
    String query,
    SearchFilter filter,
  ) async {
    final shelves = await YtMusicRepository.instance.search(query, filter);
    return [
      for (final shelf in shelves)
        for (final item in shelf.items)
          if (item.isPlayable) item,
    ];
  }

  /// The untagged YouTube downloads among [songs] (path and length).
  static Future<List<YtRepairCandidate>> findCandidates(
    Iterable<({String path, int? durationMs})> songs,
  ) async {
    final out = <YtRepairCandidate>[];
    for (final song in songs) {
      final lower = song.path.toLowerCase();
      if (!lower.endsWith('.m4a') && !lower.endsWith('.mp4')) continue;
      if (!await isYouTubeStreamFile(song.path)) continue;
      final file = song.path.split('/').last;
      final dot = file.lastIndexOf('.');
      out.add(
        YtRepairCandidate(
          path: song.path,
          name: dot > 0 ? file.substring(0, dot) : file,
          durationMs: song.durationMs,
        ),
      );
    }
    return out;
  }

  /// Whether [path] is YouTube's streaming MP4 (`ftyp` brand `dash`).
  static Future<bool> isYouTubeStreamFile(String path) async {
    RandomAccessFile? raf;
    try {
      raf = await File(path).open();
      final head = await raf.read(12);
      return head.length == 12 &&
          String.fromCharCodes(head.sublist(4, 12)) == 'ftypdash';
    } catch (_) {
      return false;
    } finally {
      await raf?.close();
    }
  }

  /// Repairs [candidates] one by one, [onProgress] saying which. A
  /// [playingPath] is skipped: rewriting a file under the player cuts it off.
  Future<YtRepairReport> run(
    List<YtRepairCandidate> candidates, {
    void Function(int done, int total, String name)? onProgress,
    bool Function()? isCancelled,
    String? playingPath,
  }) async {
    final work = await _workDir();
    if (!work.existsSync()) await work.create(recursive: true);
    var fixed = 0, fromFileName = 0, failed = 0, skipped = 0;
    final batch = <_Prepared>[];

    Future<void> flush() async {
      if (batch.isEmpty) return;
      final written = await _replace([
        for (final p in batch) (path: p.path, replacement: p.finished),
      ]);
      for (final p in batch) {
        if (written[p.path] == true) {
          fixed++;
          if (p.fromFileName) fromFileName++;
          if (p.lrc != null) await writeLrcBeside(p.path, p.lrc!);
          if (p.videoId != null) await _remember(p.videoId!, p.path);
        } else {
          failed++;
        }
        await _deleteQuietly(p.finished);
        if (p.cover != null) await _deleteQuietly(p.cover!);
      }
      batch.clear();
    }

    for (var i = 0; i < candidates.length; i++) {
      if (isCancelled?.call() ?? false) break;
      final c = candidates[i];
      onProgress?.call(i, candidates.length, c.name);
      if (c.path == playingPath) {
        skipped++;
        continue;
      }
      try {
        final track = await identify(c);
        final tags = track != null
            ? await _tagger.gather(track, workDir: work)
            : await _tagger.fromFileName(
                c.name,
                durationSecs: c.durationMs == null
                    ? null
                    : c.durationMs! / 1000,
              );
        final finished = '${work.path}/repair_$i.m4a';
        if (await _finish(c.path, finished, tags.toChannel())) {
          batch.add(
            _Prepared(
              path: c.path,
              finished: finished,
              lrc: tags.lrc,
              cover: tags.coverPath,
              fromFileName: track == null,
              videoId: track?.videoId,
            ),
          );
        } else {
          debugPrint(
            'YtDownloadRepair: ${c.name}: finisher failed: '
            '${Channel.lastFinishError}',
          );
          failed++;
          if (tags.coverPath != null) await _deleteQuietly(tags.coverPath!);
        }
      } catch (e) {
        debugPrint('YtDownloadRepair: ${c.name}: $e');
        failed++;
      }
      if (batch.length >= batchSize) await flush();
    }
    await flush();
    onProgress?.call(candidates.length, candidates.length, '');
    return YtRepairReport(
      fixed: fixed,
      fromFileName: fromFileName,
      failed: failed,
      skipped: skipped,
    );
  }

  /// The YouTube Music track a file is, from its name and length, or null.
  ///
  /// Songs first, then videos (the download may have been a music video). A
  /// match must agree on length within 3 s and share most of the title's
  /// words; with no length known it must match title and artist closely.
  /// When the name says who sings, the match must credit them: a song of the
  /// same name and length by someone else, or a stranger's re-upload whose
  /// title merely mentions them, is not this file.
  Future<YtTrack?> identify(YtRepairCandidate c) async {
    final (artist, title) = splitFileName(c.name);
    for (final filter in const [SearchFilter.songs, SearchFilter.videos]) {
      List<ExploreItem> items;
      try {
        items = await _search(c.name, filter);
      } catch (e) {
        debugPrint('YtDownloadRepair: search "${c.name}": $e');
        continue;
      }
      ExploreItem? best;
      var bestScore = 0.0;
      for (final item in items.take(8)) {
        if (artist != null && !creditsInclude(item.artist, artist)) continue;
        final score = matchScore(
          wantTitle: title,
          wantArtist: artist,
          wantMs: c.durationMs,
          item: item,
        );
        if (score > bestScore) {
          bestScore = score;
          best = item;
        }
      }
      if (best != null && bestScore >= 1.0) return best.asTrack();
    }
    return null;
  }
}

class _Prepared {
  final String path;
  final String finished;
  final String? lrc;
  final String? cover;
  final bool fromFileName;
  final String? videoId;

  const _Prepared({
    required this.path,
    required this.finished,
    required this.lrc,
    required this.cover,
    required this.fromFileName,
    this.videoId,
  });
}

Future<void> _deleteQuietly(String path) async {
  try {
    final f = File(path);
    if (f.existsSync()) await f.delete();
  } catch (_) {}
}
