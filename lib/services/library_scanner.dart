import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '/data/library_database.dart';
import '/data/library_repository.dart';
import 'local_music_scanner.dart';

enum ScanPhase { idle, scanning, done, error }

/// Progress emitted by [LibraryScanner.status] so the UI can show a scanning
/// chip / skeletons on first run and disappear when the library is settled.
class ScanStatus {
  const ScanStatus(this.phase, {this.found = 0, this.total = 0, this.error});

  final ScanPhase phase;
  final int found;
  final int total;
  final Object? error;

  bool get isScanning => phase == ScanPhase.scanning;
}

/// Keeps the library database in sync with MediaStore by diffing, not
/// re-importing. The loader renders from the DB immediately and then calls
/// [scan] after the first frame, so scanning never blocks launch. Only changed
/// rows are written, and each batch is committed so drift's watched queries
/// emit — that is what makes songs stream in progressively on a cold first run.
class LibraryScanner {
  LibraryScanner(this._repo, {Future<List<SongModel>> Function()? querySongs})
    : _queryOverride = querySongs;

  final LibraryRepository _repo;
  final OnAudioQuery _audioQuery = OnAudioQuery();
  final Future<List<SongModel>> Function()? _queryOverride;
  final StreamController<ScanStatus> _status =
      StreamController<ScanStatus>.broadcast();

  bool _running = false;

  Stream<ScanStatus> get status => _status.stream;

  static const int _batchSize = 200;
  static const String _sigKey = 'scan_signature';
  static const String _lastScanKey = 'last_scan_sec';

  Future<void> dispose() => _status.close();

  void _emit(ScanStatus s) {
    if (!_status.isClosed) _status.add(s);
  }

  /// Diff MediaStore against the DB. [force] re-diffs even when the cheap
  /// signature is unchanged (used by the manual "Rescan library" action).
  Future<void> scan({bool force = false}) async {
    if (_running) return;
    _running = true;
    try {
      _emit(const ScanStatus(ScanPhase.scanning));

      final songs = await _querySongs();

      // Cheap signature (count + newest mtime) lets an unchanged library skip
      // the diff/write pass entirely.
      var maxMod = 0;
      for (final s in songs) {
        final m = s.dateModified ?? 0;
        if (m > maxMod) maxMod = m;
      }
      final signature = '${songs.length}:$maxMod';
      final storedCount = await _repo.songCount();
      if (!force &&
          storedCount > 0 &&
          signature == await _repo.metaGet(_sigKey)) {
        _emit(ScanStatus(ScanPhase.done, total: storedCount));
        return;
      }

      final existing = await _repo.existingModifiedById();
      final seen = <int>{};
      final batch = <SongsCompanion>[];
      var processed = 0;

      for (final song in songs) {
        seen.add(song.id);
        final isNew = !existing.containsKey(song.id);
        final changed = isNew || existing[song.id] != song.dateModified;
        if (changed) {
          final companion = _companion(song);
          if (companion != null) batch.add(companion);
        }
        processed++;

        if (batch.length >= _batchSize) {
          await _repo.upsertSongs(List.of(batch));
          batch.clear();
          _emit(
            ScanStatus(
              ScanPhase.scanning,
              found: processed,
              total: songs.length,
            ),
          );
          // Yield so a huge first-run import can't monopolise a frame.
          await Future<void>.delayed(Duration.zero);
        }
      }
      if (batch.isNotEmpty) await _repo.upsertSongs(batch);

      // Delete rows for files MediaStore no longer reports.
      final removed = existing.keys.where((id) => !seen.contains(id)).toList();
      await _repo.deleteSongs(removed);

      await _repo.metaSet(_sigKey, signature);
      await _repo.metaSet(
        _lastScanKey,
        '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      );

      _emit(ScanStatus(ScanPhase.done, total: songs.length));
    } catch (e, st) {
      debugPrint('LibraryScanner error: $e\n$st');
      _emit(ScanStatus(ScanPhase.error, error: e));
    } finally {
      _running = false;
    }
  }

  Future<List<SongModel>> _querySongs() async {
    // A query that fails is not an empty library. Letting the error through
    // makes [scan] stop before the diff; treating it as "no songs" would delete
    // every row, and with them the play counts and last-played times. It
    // fails whenever the app runs with no screen: on_audio_query needs an
    // Activity, and Hype Connect's background service starts the app without
    // one after a reboot or an update.
    var songs = await (_queryOverride ?? _audioQuery.querySongs)();

    // iOS: MPMediaQuery misses files imported into Documents/Music.
    if (Platform.isIOS) {
      try {
        final local = await LocalMusicScanner.scanLocalFiles();
        if (local.isNotEmpty) {
          final have = songs.map((s) => s.data).toSet();
          songs = [...songs, ...local.where((s) => !have.contains(s.data))];
        }
      } catch (e) {
        debugPrint('LocalMusicScanner error during scan: $e');
      }
    }
    return songs;
  }

  static String _folderOf(String path) {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '' : path.substring(0, i);
  }

  /// Builds a row companion, tolerating an occasional malformed MediaStore
  /// entry (a bad row is skipped, never fatal to the whole scan).
  SongsCompanion? _companion(SongModel s) {
    try {
      return SongsCompanion.insert(
        id: Value(s.id),
        data: s.data,
        uri: Value(s.uri),
        displayName: Value(_safe(() => s.displayName)),
        displayNameWOExt: Value(_safe(() => s.displayNameWOExt)),
        size: Value(_safeInt(() => s.size)),
        album: Value(s.album),
        albumId: Value(s.albumId),
        artist: Value(s.artist),
        artistId: Value(s.artistId),
        genre: Value(s.genre),
        genreId: Value(s.genreId),
        composer: Value(s.composer),
        dateAdded: Value(s.dateAdded),
        dateModified: Value(s.dateModified),
        duration: Value(s.duration),
        title: Value(_safe(() => s.title)),
        track: Value(s.track),
        fileExtension: Value(_safe(() => s.fileExtension)),
        folderPath: Value(_folderOf(s.data)),
      );
    } catch (e) {
      debugPrint('Skipping unparseable song row: $e');
      return null;
    }
  }

  static String _safe(String Function() get) {
    try {
      return get();
    } catch (_) {
      return '';
    }
  }

  static int _safeInt(int Function() get) {
    try {
      return get();
    } catch (_) {
      return 0;
    }
  }
}
