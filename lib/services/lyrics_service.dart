import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:id3tag/id3tag.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../Helpers/Channel.dart';
import '../apis/index.dart';
import '../models/lyrics_model.dart';
import '../models/recognition_result.dart';
import 'lyrics/lrclib_resolver.dart';

/// Identifies a track by audio fingerprint (see `FingerprintService`).
typedef LyricsIdentifier = Future<RecognitionResult?> Function(SongModel song);

class LyricsService {
  /// In-memory cache keyed by song ID. LRU-bounded: lyrics auto-load on every
  /// track change, so an unbounded map used to accumulate an entry per unique
  /// track played (several MB over a long shuffle session). Evicted entries
  /// reload cheaply from .lrc/ID3/API.
  static const int _cacheCap = 50;
  final Map<int, LyricsData> _cache = {};

  void _cachePut(int id, LyricsData data) {
    _cache.remove(id); // refresh position (Dart maps keep insertion order)
    _cache[id] = data;
    while (_cache.length > _cacheCap) {
      _cache.remove(_cache.keys.first);
    }
  }

  LyricsService({
    LrclibResolver? lrclib,
    LyricsIdentifier? identify,
    Future<String?> Function(String title, String artist)? backend,
  }) : _lrclib = lrclib ?? LrclibResolver(),
       _identify = identify, // ignore: prefer_initializing_formals
       _backend = backend ?? Apis.fetchLyricsData;

  final LrclibResolver _lrclib;

  /// The HypeMuzik backend lookup, tried after LRCLIB.
  final Future<String?> Function(String title, String artist) _backend;

  /// Corrects a local track's title/artist by audio fingerprint (AcoustID →
  /// MusicBrainz). Optional: without it, weak tags are searched as-is.
  final LyricsIdentifier? _identify;

  /// Resolves lyrics using the same chain as the desktop app:
  /// 1. .lrc sidecar file
  /// 2. ID3 USLT tag (Dart id3tag package)
  /// 3. Embedded lyrics (native JAudioTagger/mp3agic)
  /// 4. Weak local tags (no artist, filename-as-title) → fingerprint first
  /// 5. LRCLIB "try-hard" resolver, then the HypeMuzik backend
  /// 6. Tags looked fine but still missed → fingerprint once and retry
  ///
  /// [isCancelled] stops the online chain early once the user has moved on.
  ///
  /// Concurrent calls for the same song share one lookup: the player screen and
  /// a Hype Connect controller both ask for the playing track's lyrics, and a
  /// second fingerprint-and-search for the same words is pure waste. The lookup
  /// belongs to whoever asked first, so [isCancelled] is that caller's.
  Future<LyricsData?> loadLyrics(
    SongModel song, {
    bool Function()? isCancelled,
  }) {
    // Check cache first (refresh LRU position on hit)
    final hit = _cache.remove(song.id);
    if (hit != null) {
      _cache[song.id] = hit;
      return Future.value(hit);
    }
    final running = _inflight[song.id];
    if (running != null) return running;
    final lookup = _lookup(song, isCancelled);
    _inflight[song.id] = lookup;
    return lookup.whenComplete(() => _inflight.remove(song.id));
  }

  final Map<int, Future<LyricsData?>> _inflight = {};

  Future<LyricsData?> _lookup(
    SongModel song,
    bool Function()? isCancelled,
  ) async {
    LyricsData? result;

    final filePath = song.data;
    final isLocalFile = !filePath.startsWith('http');

    if (isLocalFile) {
      // 1. Try .lrc sidecar file
      result = (await _loadFromLrcFile(filePath))?.withSource('file');

      // 2. Try ID3 USLT via Dart id3tag package
      result ??= (await _loadFromId3Tag(filePath))?.withSource('embedded');

      // 3. Try native fallback
      result ??= (await _loadFromNative(filePath))?.withSource('embedded');
    }

    // 4–6. Online sources.
    result ??= await _loadOnline(song, isLocalFile, isCancelled);

    if (result != null) {
      _cachePut(song.id, result);
    }
    return result;
  }

  Future<LyricsData?> _loadOnline(
    SongModel song,
    bool isLocalFile,
    bool Function()? isCancelled,
  ) async {
    bool cancelled() => isCancelled?.call() ?? false;

    var title = song.title;
    var artist = song.artist ?? '';
    var identified = false;

    // 4. Weak local tags can't match online lyrics — identify the track first
    //    so we search with real metadata.
    if (isLocalFile && isMetadataWeak(song)) {
      final r = await _tryIdentify(song);
      if (cancelled()) return null;
      if (r != null) {
        title = (r.title?.isNotEmpty ?? false) ? r.title! : title;
        artist = (r.artist?.isNotEmpty ?? false) ? r.artist! : artist;
        identified = true;
      }
    }

    // 5. LRCLIB (best source of synced lyrics), then the backend.
    var data = await _fetchByName(
      song,
      title,
      artist,
      isLocalFile,
      isCancelled,
    );
    if (data != null || cancelled()) return data;

    // 6. Seemingly-fine tags that still missed may be mistagged — identify
    //    (if we haven't yet) and retry once with the result.
    if (!identified && isLocalFile) {
      final r = await _tryIdentify(song);
      if (cancelled() || r == null) return null;
      final t = (r.title?.isNotEmpty ?? false) ? r.title! : title;
      final a = (r.artist?.isNotEmpty ?? false) ? r.artist! : artist;
      if (t == title && a == artist) return null;
      data = await _fetchByName(song, t, a, isLocalFile, isCancelled);
    }
    if (data == null) {
      debugPrint('LyricsService: none found for "$title" / "$artist"');
    }
    return data;
  }

  Future<RecognitionResult?> _tryIdentify(SongModel song) async {
    final identify = _identify;
    if (identify == null) return null;
    try {
      final r = await identify(song);
      return (r != null && r.hasUsefulData) ? r : null;
    } catch (e) {
      debugPrint('LyricsService: identify failed: $e');
      return null;
    }
  }

  /// A local track's tags are too weak to search online lyrics when it has no
  /// real artist or its title is just the file name.
  static bool isMetadataWeak(SongModel song) {
    final artist = (song.artist ?? '').trim().toLowerCase();
    if (artist.isEmpty ||
        artist == '<unknown>' ||
        artist == 'unknown' ||
        artist == 'unknown artist') {
      return true;
    }
    final title = song.title.trim();
    if (title.isEmpty) return true;
    final stem = song.displayNameWOExt.trim();
    return stem.isNotEmpty && title == stem;
  }

  /// LRCLIB first (best synced source), then the HypeMuzik backend.
  /// Auto-saves to a .lrc sidecar when found online for offline persistence.
  Future<LyricsData?> _fetchByName(
    SongModel song,
    String title,
    String artist,
    bool isLocalFile,
    bool Function()? isCancelled,
  ) async {
    LyricsData? found;

    try {
      final text = await _lrclib.resolve(
        title: title,
        artist: artist,
        durationMs: song.duration,
        isCancelled: isCancelled,
      );
      found = _parse(text)?.withSource('lrclib');
    } catch (e) {
      debugPrint('LyricsService: error fetching lyrics from LRCLIB: $e');
    }

    if (found == null && !(isCancelled?.call() ?? false)) {
      try {
        found = _parse(await _backend(title, artist))?.withSource('hypemuzik');
      } catch (e) {
        debugPrint('LyricsService: error fetching lyrics from backend: $e');
      }
    }

    if (found != null && isLocalFile) _autoSaveToLrc(song.data, found);
    return found;
  }

  /// Parses raw lyrics, treating blank/unparseable text as a miss.
  LyricsData? _parse(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    final data = parseLrc(text);
    return data.lines.any((l) => l.text.trim().isNotEmpty) ? data : null;
  }

  /// Loads and parses a .lrc sidecar file next to the audio file.
  Future<LyricsData?> _loadFromLrcFile(String audioPath) async {
    try {
      final lrcPath = _lrcPathFor(audioPath);
      final file = File(lrcPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          return parseLrc(content);
        }
      }
    } catch (e) {
      debugPrint('LyricsService: error reading .lrc file: $e');
    }
    return null;
  }

  /// Reads USLT frame from ID3 tag using the Dart id3tag package.
  Future<LyricsData?> _loadFromId3Tag(String filePath) async {
    try {
      final parser = ID3TagReader.path(filePath);
      final tag = await parser.readTag();
      final lyricsList = tag.lyrics;
      if (lyricsList.isNotEmpty) {
        final text = lyricsList.first.lyrics;
        if (text.isNotEmpty) {
          return parseLrc(text);
        }
      }
    } catch (e) {
      debugPrint('LyricsService: error reading ID3 lyrics: $e');
    }
    return null;
  }

  /// Native JAudioTagger/mp3agic fallback for reading embedded lyrics.
  Future<LyricsData?> _loadFromNative(String filePath) async {
    try {
      final text = await Channel.readLyrics(filePath);
      if (text != null && text.isNotEmpty) {
        return parseLrc(text);
      }
    } catch (e) {
      debugPrint('LyricsService: error reading native lyrics: $e');
    }
    return null;
  }

  /// Fire-and-forget save to .lrc sidecar for fetched lyrics.
  /// Silently fails for non-writable paths (e.g. scoped storage on Android 11+).
  Future<void> _autoSaveToLrc(String audioPath, LyricsData data) async {
    try {
      final lrcPath = _lrcPathFor(audioPath);
      await File(lrcPath).writeAsString(encodeLrc(data));
    } catch (_) {
      // Non-writable path (scoped storage restriction) — lyrics still
      // display fine, they just won't persist as a sidecar file.
    }
  }

  /// Saves lyrics to a .lrc sidecar file next to the audio file.
  Future<bool> saveLyricsToLrc(SongModel song, LyricsData lyrics) async {
    try {
      final lrcPath = _lrcPathFor(song.data);
      final file = File(lrcPath);
      await file.writeAsString(encodeLrc(lyrics));
      _cachePut(song.id, lyrics);
      return true;
    } catch (e) {
      debugPrint('LyricsService: error saving .lrc file: $e');
      return false;
    }
  }

  /// Embeds lyrics text into the MP3 file's ID3 USLT tag via native channel.
  Future<bool> saveLyricsToId3(SongModel song, String lyricsText) async {
    try {
      return await Channel.writeLyrics(song.data, lyricsText);
    } catch (e) {
      debugPrint('LyricsService: error writing ID3 lyrics: $e');
      return false;
    }
  }

  /// Clears the cache entry for a specific song (e.g. after editing lyrics).
  void invalidateCache(int songId) {
    _cache.remove(songId);
  }

  /// Clears the entire lyrics cache.
  void clearCache() {
    _cache.clear();
  }

  /// Computes the .lrc file path for an audio file.
  String _lrcPathFor(String audioPath) {
    final lastDot = audioPath.lastIndexOf('.');
    final basePath = lastDot > 0 ? audioPath.substring(0, lastDot) : audioPath;
    return '$basePath.lrc';
  }
}
