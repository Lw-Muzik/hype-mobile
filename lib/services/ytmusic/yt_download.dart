/// Saving a YouTube track to the phone's own music library.
///
/// The stream this downloads is the same itag 140 the player streams — an m4a
/// AAC file — so a download is the track, not a transcode of it. It is fetched
/// in ranges ([YtStreamFetch]): one plain GET of it is throttled to about twice
/// its bitrate, a minute and a half a song, where ranges take seconds.
///
/// That stream is a bare streaming (DASH) file with no tags, so it is then
/// repackaged as a plain .m4a and tagged as other downloaders do: title,
/// artists, album, album artist, year, track number, a 1200 px cover and
/// lyrics, from YouTube Music itself ([YtSongTagger], gathered while the audio
/// downloads). Timed lyrics also land beside the song as a `.lrc`. If tagging
/// fails the download is still saved, untagged, as before.
///
/// On Android the file is handed to [NativeMediaStore] rather than written into
/// the shared music tree directly: the app targets SDK 36 and is fully under
/// scoped storage, where inserting a `MediaStore.Audio.Media` row is the only
/// sanctioned way in. That insert doubles as the registration, so a downloaded
/// track appears in the app's own Library with no separate scan.
///
/// On iOS there is no equivalent: `MPMediaLibrary` will not accept an arbitrary
/// file, so the track goes to `Documents/Music/YouTube` — inside the directory
/// [LocalMusicScanner] walks (recursively) and merges into the library, and
/// which `UIFileSharingEnabled` also exposes in Files. Both platforms therefore
/// end with the track in the app's Library; only the mechanism differs.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:path_provider/path_provider.dart';

import '../../Helpers/Channel.dart';
import '../local_music_scanner.dart';
import '../native_media_store.dart';
import 'yt_models.dart';
import 'yt_repository.dart';
import 'yt_song_tags.dart';
import 'yt_stream_fetch.dart';

/// How a download ended.
sealed class YtDownloadResult {
  const YtDownloadResult();
}

class YtDownloadSaved extends YtDownloadResult {
  /// Where the track ended up, as the phone will report it.
  final String path;

  /// Whether it was published to the shared music library, as opposed to
  /// staying inside the app.
  final bool inLibrary;

  const YtDownloadSaved(this.path, {required this.inLibrary});
}

class YtDownloadFailed extends YtDownloadResult {
  final String message;
  const YtDownloadFailed(this.message);
}

class YtDownloader {
  const YtDownloader._();

  /// How tracks are transferred; replaceable in tests.
  @visibleForTesting
  static YtStreamFetch fetcher = const YtStreamFetch();

  /// Where tags come from; replaceable in tests.
  @visibleForTesting
  static YtSongTagger tagger = YtSongTagger();

  /// A transfer that kept failing after its retries: the network, not the URL.
  static const _connectionLost =
      'Download failed. Check your connection and try again.';

  /// Downloads one track.
  ///
  /// [onProgress] is called with a 0–1 fraction where the length is known (the
  /// URL states it; so does the first range), and never called where it isn't
  /// — a fake progress bar is worse than none.
  static Future<YtDownloadResult> download(
    YtTrack track, {
    void Function(double fraction)? onProgress,
  }) async {
    File? raw;
    File? finished;
    try {
      final target = await YtMusicRepository.instance.audioTarget(
        track.videoId,
      );

      // The stream lands in temp first, out of every folder a library scan
      // reads, and only the finished file goes where music lives. `.part`
      // while it transfers, so a failed transfer is never mistaken for audio;
      // `.m4a` once complete, since iOS picks its reader by extension.
      final work = Directory('${(await getTemporaryDirectory()).path}/yt_downloads');
      if (!work.existsSync()) await work.create(recursive: true);
      final partial = File('${work.path}/${track.videoId}.part');
      raw = File('${work.path}/${track.videoId}.m4a');

      // Tags are gathered while the audio downloads; a slow or failed lookup
      // costs the tags, never the download.
      final tagsFuture = tagger
          .gather(track, workDir: work)
          .timeout(const Duration(seconds: 30))
          .catchError((Object _) => YtSongTags.fromTrack(track));

      try {
        await fetcher.toFile(
          Uri.parse(target.url),
          partial,
          headers: target.headers,
          onProgress: onProgress,
        );
      } on YtStreamRefused catch (e) {
        await _deleteQuietly(partial);
        // A dead URL is worth forgetting: the retry should ask YouTube again
        // rather than replay the same expired target.
        YtMusicRepository.instance.forget(track.videoId);
        return YtDownloadFailed(
          'Download failed (${e.statusCode ?? 'refused'}).',
        );
      } catch (_) {
        await _deleteQuietly(partial);
        rethrow;
      }
      await partial.rename(raw.path);
      final tags = await tagsFuture;

      // Android stages in app documents and publishes to MediaStore below.
      // iOS has nowhere to publish to, so it writes straight into the
      // directory the library actually scans — writing to the Documents root
      // instead would leave the track invisible until something else happened
      // to rescan. Its own `YouTube` folder inside it keeps downloads apart
      // from the user's imports.
      final directory = Platform.isIOS
          ? await _iosDownloadDirectory()
          : await getApplicationDocumentsDirectory();
      final name = _fileNameFor(tags.artist, tags.title, track.videoId);
      finished = File('${directory.path}/$name.m4a');
      final tagged = await Channel.finishYtDownload(
        raw.path,
        finished.path,
        tags.toChannel(),
      );
      if (tagged) {
        await _deleteQuietly(raw);
      } else {
        // The raw stream is kept as the song, with no cover or tags. Say why.
        debugPrint(
          'YtDownload: tagging ${track.videoId} failed, keeping the raw '
          'stream: ${Channel.lastFinishError}',
        );
        await _move(raw, finished);
      }
      raw = null;
      await _deleteCover(tags);

      var savedPath = finished.path;
      var inLibrary = false;
      if (NativeMediaStore.supported) {
        final row = await NativeMediaStore.importAudio(
          sourcePath: finished.path,
          displayName: '$name.m4a',
          mimeType: 'audio/mp4',
        );
        if (row != null) {
          // The MediaStore row owns the file now; the app copy is a duplicate.
          await _deleteQuietly(finished);
          savedPath = (row['path'] as String?) ?? finished.path;
          inLibrary = true;
        }
      }
      finished = null;
      final lrc = tags.lrc;
      if (lrc != null) await writeLrcBeside(savedPath, lrc);
      return await _saved(savedPath, inLibrary: inLibrary);
    } on YtException catch (e) {
      return YtDownloadFailed(e.message);
    } on TimeoutException {
      return const YtDownloadFailed(_connectionLost);
    } on SocketException {
      return const YtDownloadFailed(_connectionLost);
    } on HttpException {
      return const YtDownloadFailed(_connectionLost);
    } catch (e) {
      return YtDownloadFailed('Download failed: $e');
    } finally {
      if (raw != null) await _deleteQuietly(raw);
    }
  }

  /// Downloads a whole list, one track at a time.
  ///
  /// # Why sequential
  ///
  /// Each track needs its own resolved stream URL, and resolving is the part
  /// YouTube rate-limits. Downloading four at once turns one slow playlist into
  /// four failed ones, and each track already arrives over several connections
  /// of its own ([YtStreamFetch]). [onTrack] reports `(index, total, title)` as
  /// each begins so the caller can say which one, and [onProgress] is that
  /// track's own fraction.
  ///
  /// A failure does not stop the run: one dead video should not cost the other
  /// forty-nine. The returned list is per-track and in order, so the caller can
  /// say exactly how many landed.
  static Future<List<YtDownloadResult>> downloadAll(
    List<YtTrack> tracks, {
    void Function(int index, int total, String title)? onTrack,
    void Function(double fraction)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final results = <YtDownloadResult>[];
    for (var i = 0; i < tracks.length; i++) {
      if (isCancelled?.call() ?? false) break;
      final track = tracks[i];
      onTrack?.call(i, tracks.length, track.title);
      results.add(await download(track, onProgress: onProgress));
    }
    return results;
  }

  /// A file name that survives every filesystem this app runs on.
  ///
  /// Keeps the track identifiable while dropping anything a path separator or a
  /// Windows-hostile character could turn into a different file than intended.
  static String _fileNameFor(String? artist, String title, String videoId) {
    final raw = artist == null || artist.isEmpty ? title : '$artist - $title';
    final cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return videoId;
    // Long names are rejected outright by some filesystems, so cap well short
    // of any real limit and keep the id as the tiebreaker.
    return cleaned.length <= 80 ? cleaned : cleaned.substring(0, 80).trim();
  }

  /// Where iOS keeps YouTube downloads: `Documents/Music/YouTube`.
  ///
  /// Only the path — nothing is created, so asking leaves no empty folder in
  /// Files for people who never download anything.
  static Future<String> iosDownloadDirectoryPath() async {
    final docs = await getApplicationDocumentsDirectory();
    return '${docs.path}/Music/$_iosFolder';
  }

  static const _iosFolder = 'YouTube';

  static Future<Directory> _iosDownloadDirectory() async {
    final directory = Directory(await iosDownloadDirectoryPath());
    if (!directory.existsSync()) await directory.create(recursive: true);
    return directory;
  }

  static Future<YtDownloadSaved> _saved(
    String path, {
    required bool inLibrary,
  }) async => YtDownloadSaved(path, inLibrary: inLibrary);

  /// Moves [from] to [to], copying when a rename can't (another volume).
  static Future<void> _move(File from, File to) async {
    try {
      await from.rename(to.path);
    } on FileSystemException {
      await from.copy(to.path);
      await _deleteQuietly(from);
    }
  }

  static Future<void> _deleteCover(YtSongTags tags) async {
    final cover = tags.coverPath;
    if (cover != null) await _deleteQuietly(File(cover));
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } catch (_) {
      // A leftover temp file is not worth failing a finished download over.
    }
  }
}
