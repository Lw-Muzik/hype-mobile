import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:path_provider/path_provider.dart';

import '/data/library_repository.dart';

/// Where [LocalMusicScanner] saves the cover it reads out of a local file
/// (iOS, `Documents/Music`) — one fixed name per song id, so the scanner and
/// [ArtworkService] agree without a lookup.
String savedLocalArtworkPath(String supportDir, int id) =>
    '$supportDir/artwork_$id.jpg';

/// Resolves cover-art file paths on demand instead of extracting the whole
/// library at launch. A path is served from (in order) an in-memory LRU, the
/// song's `artworkPath` column, an existing temp PNG, or a fresh extraction
/// that is capped at [_maxConcurrent] so a fast fling can't spawn hundreds of
/// simultaneous decodes. The temp-file naming matches the app's historical
/// scheme, so art extracted by older builds is reused rather than redone.
class ArtworkService {
  ArtworkService._();

  static final ArtworkService instance = ArtworkService._();

  LibraryRepository? _repo;
  String? _tempPath;

  final Map<String, String> _mem = HashMap<String, String>();
  final ListQueue<String> _lruOrder = ListQueue<String>();
  final Map<String, Future<String?>> _inFlight = {};
  final _Semaphore _sem = _Semaphore(_maxConcurrent);

  static const int _maxConcurrent = 4;
  static const int _maxMem = 600;

  /// Resolution of the ONE cached source image per song. Extraction is always
  /// done at this size and full quality, regardless of the requesting view, so
  /// the full-screen player is never stuck with a thumbnail-sized source. Each
  /// tile then decodes this down to its own display size via ArtworkWidget's
  /// ResizeImage, so a big source costs nothing extra for small tiles. Matches
  /// ArtworkWidget's 1600px decode ceiling so large views never upscale.
  static const int _sourceArtSize = 1600;

  /// Test seams: the platform check and the app-support folder.
  @visibleForTesting
  bool Function() isIosForTest = () => Platform.isIOS;
  @visibleForTesting
  Future<String> Function() supportPathForTest = () async =>
      (await getApplicationSupportDirectory()).path;

  /// The cover [LocalMusicScanner] saved for a local file (iOS only).
  ///
  /// Files in `Documents/Music` are not in the Music library, and their ids
  /// are `path.hashCode`, so `OnAudioQuery.queryArtwork` (which looks the id
  /// up as a media-library persistent id) can never find them. The scanner
  /// reads the embedded picture out of the file on every scan, to
  /// `artwork_<id>.jpg`; this serves that file, and records it in the
  /// `songs` row like any other extracted art.
  Future<String?> _savedLocalArtwork(int id) async {
    if (!isIosForTest()) return null;
    final path = savedLocalArtworkPath(await supportPathForTest(), id);
    final file = File(path);
    if (!await file.exists() || await file.length() == 0) return null;
    await _repo?.setArtworkPath(id, path);
    return path;
  }

  /// Wire the repository so AUDIO art paths persist in the `songs` table
  /// (survives restarts without re-extraction).
  void attachRepository(LibraryRepository repo) => _repo = repo;

  // ---------------------------------------------------------------------------
  // Artwork the user chose
  // ---------------------------------------------------------------------------

  /// Song id → the artwork the user picked for it ("Find artwork").
  ///
  /// Kept apart from the extracted art and checked before it: art is recorded
  /// in the `songs` row again whenever it is re-read (iOS re-reads a local
  /// file's cover on every scan), and a choice the user made must not be
  /// undone by the app rereading the file. Recorded in
  /// `library_meta` as `art:<id>`; loaded once.
  Map<int, String>? _chosen;
  static const _chosenKey = 'art:';

  final _changes = StreamController<int>.broadcast();

  /// The id of each song whose artwork was just replaced, so every view of it
  /// can let go of the old picture.
  Stream<int> get changes => _changes.stream;

  Future<Map<int, String>> _chosenArt() async {
    final loaded = _chosen;
    if (loaded != null) return loaded;
    final out = <int, String>{};
    final rows = await _repo?.metaWithPrefix(_chosenKey) ?? const {};
    for (final entry in rows.entries) {
      final id = int.tryParse(entry.key.substring(_chosenKey.length));
      if (id != null && await File(entry.value).exists()) out[id] = entry.value;
    }
    return _chosen = out;
  }

  /// Makes [bytes] the artwork of song [id] from now on, wherever it shows.
  ///
  /// Stored in app support — temp is the OS's to clear — under a name that is
  /// new every time, so no image cache can hand back the old picture.
  Future<String> setChosenArtwork(int id, List<int> bytes) async {
    final chosen = await _chosenArt();
    final dir = Directory(
      '${(await getApplicationSupportDirectory()).path}/chosen_artwork',
    );
    if (!dir.existsSync()) await dir.create(recursive: true);
    final file = File(
      '${dir.path}/${id}_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    await file.writeAsBytes(bytes, flush: true);
    final previous = chosen[id];
    chosen[id] = file.path;
    await _repo?.metaSet('$_chosenKey$id', file.path);
    _mem.remove('a:$id');
    _lruOrder.remove('a:$id');
    if (previous != null) {
      try {
        await File(previous).delete();
      } catch (_) {}
    }
    _changes.add(id);
    return file.path;
  }

  Future<String> get _temp async =>
      _tempPath ??= (await getTemporaryDirectory()).path;

  /// Returns an on-disk PNG path for the requested art, extracting if needed.
  /// Null means no art is available (caller shows the placeholder).
  Future<String?> pathFor({
    required int id,
    String data = '',
    ArtworkType type = ArtworkType.AUDIO,
    String other = '',
  }) async {
    final temp = await _temp;

    if (type == ArtworkType.AUDIO) {
      final chosen = (await _chosenArt())[id];
      if (chosen != null) return chosen;
    }

    // Cloud files keep their existing stable naming; extraction for those
    // happens on the cloud path, so here we only read.
    if (data.startsWith('http')) {
      final p = '$temp/cloud_art_$id.png';
      return await File(p).exists() ? p : null;
    }

    final key = _key(id, type, other, data);

    final memHit = _mem[key];
    if (memHit != null) {
      _touch(key);
      return memHit;
    }

    // iOS local files: the cover the scanner saved. Before the DB column so a
    // stale or missing column never hides it.
    if (type == ArtworkType.AUDIO) {
      final saved = await _savedLocalArtwork(id);
      if (saved != null) {
        _remember(key, saved);
        return saved;
      }
    }

    // Persisted path for AUDIO tracks.
    if (type == ArtworkType.AUDIO && _repo != null) {
      final dbPath = await _repo!.artworkPathFor(id);
      if (dbPath != null && await File(dbPath).exists()) {
        _remember(key, dbPath);
        return dbPath;
      }
    }

    final target = _targetPath(temp, type, other, data);

    if (await File(target).exists()) {
      _remember(key, target);
      if (type == ArtworkType.AUDIO) await _repo?.setArtworkPath(id, target);
      return target;
    }

    // Dedupe concurrent requests for the same art.
    return _inFlight.putIfAbsent(
      key,
      () => _extract(id: id, type: type, target: target, key: key),
      // A BLOCK body, deliberately. `whenComplete(() => _inFlight.remove(key))`
      // reads as identical but deadlocks: `Map.remove` returns the value it
      // removed — this very future — and `whenComplete` waits on any Future its
      // callback returns, so the future ends up awaiting itself and never
      // completes. The symptom is artwork that never appears for any track
      // whose art has to be extracted rather than read from disk.
    ).whenComplete(() {
      _inFlight.remove(key);
    });
  }

  Future<String?> _extract({
    required int id,
    required ArtworkType type,
    required String target,
    required String key,
  }) async {
    await _sem.acquire();
    try {
      final bytes = await OnAudioQuery().queryArtwork(
        id,
        type,
        quality: 100,
        size: _sourceArtSize,
      );
      if (bytes == null || bytes.isEmpty) return null;
      final file = File(target);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: false);
      _remember(key, target);
      if (type == ArtworkType.AUDIO) await _repo?.setArtworkPath(id, target);
      return target;
    } catch (e) {
      debugPrint('ArtworkService extract failed for $id: $e');
      return null;
    } finally {
      _sem.release();
    }
  }

  String _key(int id, ArtworkType type, String other, String data) {
    if (data.isNotEmpty && type == ArtworkType.AUDIO) return 'a:$id';
    return '${type.index}:${other.isNotEmpty ? other : data}';
  }

  String _targetPath(String temp, ArtworkType type, String other, String data) {
    String legacy(String s) =>
        s.replaceFirst(' ', '_').replaceFirst('/', '_');
    String sanitize(String s) => s.replaceAll(RegExp(r'[ /|:]'), '_');

    if (data.isEmpty && other.isNotEmpty && other != 'Unknown') {
      switch (type) {
        case ArtworkType.ALBUM:
          return '$temp/Albums/${legacy(other)}.png';
        case ArtworkType.ARTIST:
          return '$temp/Artists/${legacy(other)}.png';
        case ArtworkType.GENRE:
          return '$temp/Genres/${legacy(other)}.png';
        default:
          break;
      }
    }
    if (data.isEmpty && other.isNotEmpty) {
      return '$temp/${sanitize(other)}.png';
    }
    final base = data.split('/').last.split('.').first;
    return '$temp/${sanitize(base)}.png';
  }

  void _remember(String key, String path) {
    if (_mem.containsKey(key)) {
      _touch(key);
      return;
    }
    _mem[key] = path;
    _lruOrder.addLast(key);
    while (_lruOrder.length > _maxMem) {
      _mem.remove(_lruOrder.removeFirst());
    }
  }

  void _touch(String key) {
    _lruOrder.remove(key);
    _lruOrder.addLast(key);
  }

  @visibleForTesting
  int get memoryEntries => _mem.length;

  @visibleForTesting
  void clearMemory() {
    _mem.clear();
    _lruOrder.clear();
  }

  @visibleForTesting
  void rememberForTest(String key, String path) => _remember(key, path);

  @visibleForTesting
  String? memoryPathForTest(String key) => _mem[key];
}

/// Minimal fair FIFO semaphore used to cap concurrent art extractions.
class _Semaphore {
  _Semaphore(this.max);

  final int max;
  int _current = 0;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_current < max) {
      _current++;
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else if (_current > 0) {
      _current--;
    }
  }
}
