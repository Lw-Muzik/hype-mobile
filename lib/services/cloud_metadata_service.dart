import 'dart:developer' as dev;
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../Helpers/Channel.dart';
import '../models/cloud_file.dart';
import 'cloud_auth_service.dart';
import 'cloud_cache_service.dart';
import 'dropbox_service.dart';
import 'google_drive_service.dart';

/// Background service that preloads audio metadata (title, artist, album, artwork)
/// for all cloud files. Uses Android's MediaMetadataRetriever via native channel
/// which handles ALL audio formats (MP3, M4A, FLAC, OGG, WAV, WMA, etc.).
class CloudMetadataService {
  final CloudAuthService _auth;
  final CloudCacheService _cache;
  final GoogleDriveService _gdrive;
  final DropboxService _dropbox;

  /// Max concurrent extractions to avoid hammering APIs.
  static const _maxConcurrent = 3;

  /// Track active runs per provider so we can cancel on disconnect.
  int _gdriveRunId = 0;
  int _dropboxRunId = 0;

  CloudMetadataService(this._auth, this._cache, this._gdrive, this._dropbox);

  /// Cancel any running preload for a specific provider (or all).
  void cancel([CloudProvider? provider]) {
    if (provider == null || provider == CloudProvider.googleDrive) {
      _gdriveRunId++;
    }
    if (provider == null || provider == CloudProvider.dropbox) {
      _dropboxRunId++;
    }
  }

  /// Preload metadata for all [files] of a given [provider].
  /// Skips files that already have a `.done` marker (previously extracted).
  /// Processes [_maxConcurrent] files concurrently.
  Future<void> preloadAll(CloudProvider provider, List<CloudFile> files) async {
    // Bump run ID to invalidate any previous run for this provider.
    final runId = provider == CloudProvider.googleDrive
        ? ++_gdriveRunId
        : ++_dropboxRunId;

    final tempDir = await getTemporaryDirectory();

    // Snapshot every existing `.done` marker with ONE async directory scan
    // instead of thousands of synchronous existsSync() calls on the UI isolate
    // (which stalled startup / cloud-view open proportional to library size).
    final Set<String> doneMarkers = {};
    try {
      await for (final entity in tempDir.list(followLinks: false)) {
        final name = entity.path.split('/').last;
        if (name.startsWith('cloud_meta_') && name.endsWith('.done')) {
          doneMarkers.add(name);
        }
      }
    } catch (_) {
      // Temp dir missing/unreadable — treat as no markers.
    }

    String markerName(CloudFile f) =>
        'cloud_meta_${f.fileId.hashCode.abs()}.done';

    // Invalidate stale markers: if a file has a .done marker but still
    // has no metadata, it was marked by the old id3tag extractor which
    // couldn't read M4A/FLAC/OGG. Delete the marker to allow retry.
    for (final file in files) {
      if (file.trackTitle != null) continue; // already has metadata
      final name = markerName(file);
      if (doneMarkers.contains(name)) {
        try {
          await File('${tempDir.path}/$name').delete();
        } catch (_) {}
        doneMarkers.remove(name);
      }
    }

    // Filter to files that haven't been extracted yet (in-memory set lookup).
    final pending = <CloudFile>[];
    for (final file in files) {
      if (!doneMarkers.contains(markerName(file))) {
        pending.add(file);
      }
    }

    if (pending.isEmpty) {
      dev.log(
        'All ${files.length} files already have metadata',
        name: 'CloudMeta',
      );
      return;
    }

    dev.log(
      'Preloading metadata: ${pending.length}/${files.length} '
      '(${provider.name})',
      name: 'CloudMeta',
    );

    // Accumulate extracted metadata and flush in batches: writing per file
    // meant decoding + re-encoding the ENTIRE stored file list once per file
    // (O(N²) churn on the UI isolate for large libraries).
    final pendingUpdates = <CloudFile>[];
    void flushUpdates() {
      if (pendingUpdates.isEmpty) return;
      _cache.updateFilesMetadata(provider, List.of(pendingUpdates));
      pendingUpdates.clear();
    }

    // Process in batches of _maxConcurrent.
    for (int i = 0; i < pending.length; i += _maxConcurrent) {
      // Check if this run was superseded or cancelled — keep what we have.
      if (!_isRunActive(provider, runId)) {
        flushUpdates();
        return;
      }

      final end = (i + _maxConcurrent).clamp(0, pending.length);
      final batch = pending.sublist(i, end);

      final results = await Future.wait(
        batch.map((file) => _extractSingle(file, tempDir, provider, runId)),
      );
      pendingUpdates.addAll(results.whereType<CloudFile>());
      if (pendingUpdates.length >= 30) flushUpdates();
    }
    flushUpdates();

    dev.log('Metadata preload complete (${provider.name})', name: 'CloudMeta');
  }

  bool _isRunActive(CloudProvider provider, int runId) {
    return provider == CloudProvider.googleDrive
        ? runId == _gdriveRunId
        : runId == _dropboxRunId;
  }

  /// Extracts metadata for one file. Returns the updated [CloudFile] when new
  /// tags were found (the caller batches these into a single cache write), or
  /// null when nothing needs persisting.
  Future<CloudFile?> _extractSingle(
    CloudFile file,
    Directory tempDir,
    CloudProvider provider,
    int runId,
  ) async {
    final songId = file.fileId.hashCode.abs();
    final artPath = '${tempDir.path}/cloud_art_$songId.png';
    final metaCachePath = '${tempDir.path}/cloud_meta_$songId.done';

    // Double-check marker (could have been created by concurrent run).
    if (await File(metaCachePath).exists()) return null;

    try {
      // Resolve stream URL.
      String? streamUrl;
      if (provider == CloudProvider.googleDrive) {
        streamUrl = _gdrive.getStreamUrl(file.fileId);
      } else {
        streamUrl = await _dropbox.getTemporaryLink(file.fileId);
      }
      if (streamUrl == null) return null;

      // Check cancellation before network call.
      if (!_isRunActive(provider, runId)) return null;

      // Build headers (Google Drive needs auth; Dropbox temp links don't).
      final headers = <String, String>{};
      if (provider == CloudProvider.googleDrive) {
        headers.addAll(await _auth.getGoogleAuthHeaders());
      }

      // Use native MediaMetadataRetriever — handles ALL audio formats.
      // Returns null on failure (timeout, network error) — don't mark as done
      // so it gets retried. Returns empty Map if file has no tags — mark done.
      final metadata = await Channel.extractAudioMetadata(
        url: streamUrl,
        headers: headers,
        artworkPath: artPath,
      );

      if (!_isRunActive(provider, runId)) return null;

      // null = extraction failed (timeout/error) — skip marker, retry later.
      if (metadata == null) {
        dev.log(
          'Metadata extraction failed for ${file.name} — will retry',
          name: 'CloudMeta',
        );
        return null;
      }

      // Write completion marker (extraction succeeded, even if no tags found).
      await File(metaCachePath).writeAsString('done');

      // Return extracted metadata for batched persistence by the caller.
      if (metadata['title'] != null ||
          metadata['artist'] != null ||
          metadata['album'] != null) {
        return CloudFile(
          provider: file.provider,
          fileId: file.fileId,
          name: file.name,
          folderPath: file.folderPath,
          size: file.size,
          mimeType: file.mimeType,
          thumbnailUrl: file.thumbnailUrl,
          modifiedDate: file.modifiedDate,
          trackTitle: metadata['title'] as String? ?? file.trackTitle,
          trackArtist: metadata['artist'] as String? ?? file.trackArtist,
          albumName: metadata['album'] as String? ?? file.albumName,
          durationMs: metadata['durationMs'] as int? ?? file.durationMs,
        );
      }
      return null;
    } catch (e) {
      dev.log(
        'Metadata extract failed for ${file.name}: $e',
        name: 'CloudMeta',
      );
      return null;
    }
  }
}
