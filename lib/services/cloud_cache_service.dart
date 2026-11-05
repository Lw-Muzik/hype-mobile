import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/cloud_file.dart';
import 'streaming_data_guard.dart';

class CloudCacheService {
  final SharedPreferences _prefs;
  late Directory _cacheDir;
  Map<String, _CacheEntry> _metadata = {};

  static const _metadataKey = 'cloud_cache_metadata';
  static const _gdriveListKey = 'cloud_file_list_gdrive';
  static const _dropboxListKey = 'cloud_file_list_dropbox';
  static const _gdriveListTsKey = 'cloud_file_list_gdrive_ts';
  static const _dropboxListTsKey = 'cloud_file_list_dropbox_ts';
  static const int defaultMaxCacheBytes = 500 * 1024 * 1024; // 500 MB

  // Track active downloads for cancellation and dedup
  String? _prefetchingFileId;
  http.Client? _activeClient;
  bool _downloadCancelled = false;

  int get maxCacheBytes =>
      _prefs.getInt('cloudCacheMaxBytes') ?? defaultMaxCacheBytes;

  set maxCacheBytes(int value) {
    _prefs.setInt('cloudCacheMaxBytes', value);
  }

  CloudCacheService(this._prefs);

  Future<void> init() async {
    final appDir = await getApplicationSupportDirectory();
    _cacheDir = Directory('${appDir.path}/cloud_audio_cache');
    if (!_cacheDir.existsSync()) {
      _cacheDir.createSync(recursive: true);
    }
    _loadMetadata();
    // Clean up orphaned partial files that have no metadata
    _cleanupOrphans();
  }

  File cacheFile(String fileId) {
    final hash = fileId.hashCode.toRadixString(16);
    return File('${_cacheDir.path}/$hash.audio');
  }

  File _partialFile(String fileId) {
    final hash = fileId.hashCode.toRadixString(16);
    return File('${_cacheDir.path}/$hash.part');
  }

  bool isCached(String fileId) {
    final entry = _metadata[fileId];
    if (entry == null || !entry.complete) return false;
    return cacheFile(fileId).existsSync();
  }

  /// Check if a partial download exists (for resume).
  int partialSize(String fileId) {
    final partial = _partialFile(fileId);
    if (partial.existsSync()) return partial.lengthSync();
    return 0;
  }

  /// Check if a download is already in progress.
  bool isDownloading(String fileId) {
    if (_prefetchingFileId == fileId) return true;
    return _partialFile(fileId).existsSync();
  }

  /// Cancel any active background download.
  /// Called when the user skips a track to stop wasting data.
  void cancelActiveDownload() {
    if (_activeClient != null) {
      _downloadCancelled = true;
      _activeClient!.close();
      _activeClient = null;
      debugPrint('CloudCache: Cancelled active download');
    }
  }

  /// Pre-cache a track with resume support.
  /// Downloads the file, resuming from partial if available.
  /// [maxBytes] limits how much to download (0 = unlimited).
  /// Use maxBytes on cellular to only cache enough for ~30s of playback.
  Future<bool> preCacheTrack(
    String url,
    String fileId,
    Map<String, String> headers, {
    int maxBytes = 0,
  }) async {
    if (isCached(fileId)) return true;
    if (_prefetchingFileId == fileId) return false; // already in progress

    _prefetchingFileId = fileId;
    _downloadCancelled = false;
    final file = cacheFile(fileId);
    final partial = _partialFile(fileId);

    try {
      final client = http.Client();
      _activeClient = client;

      // Check for existing partial download
      int existingBytes = 0;
      IOSink sink;
      if (partial.existsSync()) {
        existingBytes = partial.lengthSync();
        // If we already have enough for a partial prefetch, skip
        if (maxBytes > 0 && existingBytes >= maxBytes) {
          _activeClient = null;
          _prefetchingFileId = null;
          return true;
        }
        sink = partial.openWrite(mode: FileMode.append);
      } else {
        sink = partial.openWrite();
      }

      // Build request with Range header for resume
      final request = http.Request('GET', Uri.parse(url));
      request.headers.addAll(headers);
      if (existingBytes > 0) {
        request.headers['Range'] = 'bytes=$existingBytes-';
      }

      final response = await client.send(request);

      // If server doesn't support range and we had partial, start over
      if (existingBytes > 0 && response.statusCode == 200) {
        await sink.close();
        sink = partial.openWrite(); // overwrite
        existingBytes = 0;
      }

      if (response.statusCode != 200 && response.statusCode != 206) {
        await sink.close();
        client.close();
        _activeClient = null;
        _prefetchingFileId = null;
        return false;
      }

      // Stream to file, tracking data usage
      int totalDownloaded = existingBytes;
      await for (final chunk in response.stream) {
        if (_downloadCancelled) {
          debugPrint(
            'CloudCache: Download cancelled for $fileId at ${_formatBytes(totalDownloaded)}',
          );
          break;
        }

        sink.add(chunk);
        totalDownloaded += chunk.length;

        // Track cellular data usage
        try {
          StreamingDataGuard.instance.recordCellularUsage(chunk.length);
        } catch (_) {}

        // Stop if we've reached the byte limit (partial prefetch on cellular)
        if (maxBytes > 0 && totalDownloaded >= maxBytes) {
          debugPrint(
            'CloudCache: Partial prefetch limit reached for $fileId (${_formatBytes(totalDownloaded)})',
          );
          break;
        }
      }

      await sink.flush();
      await sink.close();
      client.close();
      _activeClient = null;

      // Only mark complete if we downloaded the entire file (not partial/cancelled)
      final isComplete = !_downloadCancelled && maxBytes == 0;

      if (isComplete && partial.existsSync()) {
        // Move partial → complete
        final dest = file.path;
        if (file.existsSync()) file.deleteSync();
        partial.renameSync(dest);

        final stat = file.statSync();
        _metadata[fileId] = _CacheEntry(
          size: stat.size,
          lastAccess: DateTime.now(),
          complete: true,
        );
        _saveMetadata();
        await _evictIfNeeded();

        debugPrint('CloudCache: Cached $fileId (${_formatBytes(stat.size)})');
      }

      _prefetchingFileId = null;
      return isComplete;
    } catch (e) {
      if (!_downloadCancelled) {
        debugPrint('CloudCache: Download failed for $fileId: $e');
      }
      // DON'T delete partial file — keep it for resume on retry
      _activeClient = null;
      _prefetchingFileId = null;
      return false;
    }
  }

  /// Mark a download as complete in metadata.
  void markComplete(String fileId) {
    final file = cacheFile(fileId);
    if (!file.existsSync()) return;
    final stat = file.statSync();
    _metadata[fileId] = _CacheEntry(
      size: stat.size,
      lastAccess: DateTime.now(),
      complete: true,
    );
    _saveMetadata();
    debugPrint(
      'CloudCache: Marked complete $fileId (${_formatBytes(stat.size)})',
    );
  }

  void markAccessed(String fileId) {
    final entry = _metadata[fileId];
    if (entry != null) {
      _metadata[fileId] = _CacheEntry(
        size: entry.size,
        lastAccess: DateTime.now(),
        complete: entry.complete,
      );
      _saveMetadata();
    }
  }

  int get currentSize {
    int total = 0;
    for (final entry in _metadata.values) {
      if (entry.complete) total += entry.size;
    }
    return total;
  }

  String get currentSizeFormatted => _formatBytes(currentSize);

  // --- Cloud file list caching ---

  String _listKey(CloudProvider provider) =>
      provider == CloudProvider.googleDrive ? _gdriveListKey : _dropboxListKey;

  String _tsKey(CloudProvider provider) => provider == CloudProvider.googleDrive
      ? _gdriveListTsKey
      : _dropboxListTsKey;

  void saveFileList(CloudProvider provider, List<CloudFile> files) {
    final jsonList = files.map((f) => f.toJson()).toList();
    _prefs.setString(_listKey(provider), json.encode(jsonList));
    _prefs.setInt(_tsKey(provider), DateTime.now().millisecondsSinceEpoch);
  }

  List<CloudFile>? loadFileList(CloudProvider provider) {
    final raw = _prefs.getString(_listKey(provider));
    if (raw == null) return null;
    try {
      final list = json.decode(raw) as List;
      return list
          .map((e) => CloudFile.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }

  Duration? getFileListAge(CloudProvider provider) {
    final ts = _prefs.getInt(_tsKey(provider));
    if (ts == null) return null;
    return DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ts));
  }

  void updateFileMetadata(CloudProvider provider, CloudFile updated) {
    updateFilesMetadata(provider, [updated]);
  }

  /// Batch metadata update: ONE decode + ONE encode of the whole stored list
  /// for any number of updated files. The per-file variant made the metadata
  /// preloader O(N²) — it re-decoded and re-wrote the entire library JSON for
  /// every single extracted file.
  void updateFilesMetadata(CloudProvider provider, List<CloudFile> updates) {
    if (updates.isEmpty) return;
    final files = loadFileList(provider);
    if (files == null) return;
    final byId = {for (final u in updates) u.fileId: u};
    var changed = false;
    for (var i = 0; i < files.length; i++) {
      final u = byId[files[i].fileId];
      if (u != null) {
        files[i] = u;
        changed = true;
      }
    }
    if (!changed) return;
    final jsonList = files.map((f) => f.toJson()).toList();
    _prefs.setString(_listKey(provider), json.encode(jsonList));
  }

  void clearFileList(CloudProvider provider) {
    _prefs.remove(_listKey(provider));
    _prefs.remove(_tsKey(provider));
  }

  Future<void> clearCache() async {
    if (_cacheDir.existsSync()) {
      await _cacheDir.delete(recursive: true);
      await _cacheDir.create(recursive: true);
    }
    _metadata.clear();
    _saveMetadata();
  }

  Future<void> _evictIfNeeded() async {
    while (currentSize > maxCacheBytes && _metadata.isNotEmpty) {
      String? lruId;
      DateTime? oldest;
      for (final entry in _metadata.entries) {
        if (oldest == null || entry.value.lastAccess.isBefore(oldest)) {
          oldest = entry.value.lastAccess;
          lruId = entry.key;
        }
      }
      if (lruId == null) break;

      final file = cacheFile(lruId);
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
      _metadata.remove(lruId);
    }
    _saveMetadata();
  }

  void _cleanupOrphans() {
    // Remove .part files older than 7 days with no progress
    try {
      for (final entity in _cacheDir.listSync()) {
        if (entity is File && entity.path.endsWith('.part')) {
          final stat = entity.statSync();
          if (DateTime.now().difference(stat.modified).inDays > 7) {
            entity.deleteSync();
          }
        }
      }
    } catch (_) {}
  }

  void _loadMetadata() {
    final raw = _prefs.getString(_metadataKey);
    if (raw != null) {
      try {
        final map = json.decode(raw) as Map<String, dynamic>;
        _metadata = map.map((k, v) => MapEntry(k, _CacheEntry.fromJson(v)));
      } catch (_) {
        _metadata = {};
      }
    }
  }

  void _saveMetadata() {
    _prefs.setString(
      _metadataKey,
      json.encode(_metadata.map((k, v) => MapEntry(k, v.toJson()))),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class _CacheEntry {
  final int size;
  final DateTime lastAccess;
  final bool complete;

  _CacheEntry({
    required this.size,
    required this.lastAccess,
    required this.complete,
  });

  Map<String, dynamic> toJson() => {
    'size': size,
    'lastAccess': lastAccess.toIso8601String(),
    'complete': complete,
  };

  factory _CacheEntry.fromJson(Map<String, dynamic> json) => _CacheEntry(
    size: json['size'] as int,
    lastAccess: DateTime.parse(json['lastAccess'] as String),
    complete: json['complete'] as bool,
  );
}
