import 'dart:developer';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '/Helpers/Channel.dart';
import '/exports/exports.dart';
import 'artwork_service.dart';

/// Scans the app's Documents/Music directory for audio files on iOS.
/// Creates SongModel objects from AVFoundation metadata extraction.
/// This supplements on_audio_query's MPMediaQuery which only sees iTunes library.
class LocalMusicScanner {
  static const _audioExtensions = {
    '.mp3',
    '.m4a',
    '.aac',
    '.flac',
    '.wav',
    '.ogg',
    '.wma',
    '.aiff',
    '.alac',
  };

  /// Get or create the local music directory inside the app's Documents folder.
  static Future<Directory> getMusicDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    final musicDir = Directory('${docs.path}/Music');
    if (!musicDir.existsSync()) {
      musicDir.createSync(recursive: true);
    }
    return musicDir;
  }

  /// Scan the local music directory and return SongModel-compatible objects.
  static Future<List<SongModel>> scanLocalFiles() async {
    if (!Platform.isIOS) return [];

    final musicDir = await getMusicDirectory();
    final files = <File>[];

    // Also scan the root Documents directory
    final docsDir = await getApplicationDocumentsDirectory();

    for (final dir in [musicDir, docsDir]) {
      if (!dir.existsSync()) continue;
      try {
        final entries = dir.listSync(recursive: true);
        for (final entity in entries) {
          if (entity is File) {
            final ext = entity.path.split('.').last.toLowerCase();
            if (_audioExtensions.contains('.$ext')) {
              files.add(entity);
            }
          }
        }
      } catch (e) {
        debugPrint('LocalMusicScanner: Error scanning ${dir.path}: $e');
      }
    }

    // Deduplicate by path
    final seen = <String>{};
    final unique = <File>[];
    for (final f in files) {
      if (seen.add(f.path)) unique.add(f);
    }

    if (unique.isEmpty) return [];
    debugPrint('LocalMusicScanner: Found ${unique.length} audio files');

    final songs = <SongModel>[];
    for (final file in unique) {
      log('LocalMusicScanner: Processing ${file.path}');
      final song = await _fileToSongModel(file);
      if (song != null) songs.add(song);
    }

    debugPrint('LocalMusicScanner: Created ${songs.length} song models');
    return songs;
  }

  /// Convert a local audio file to a SongModel using native metadata extraction.
  static Future<SongModel?> _fileToSongModel(File file) async {
    try {
      final path = file.path;
      final filename = path.split('/').last;
      final nameNoExt = filename.contains('.')
          ? filename.substring(0, filename.lastIndexOf('.'))
          : filename;
      final ext = filename.contains('.')
          ? filename.substring(filename.lastIndexOf('.') + 1)
          : '';
      final stat = file.statSync();
      final id = path.hashCode.abs();

      // Try to extract metadata via native AVFoundation
      String title = nameNoExt;
      String artist = 'Unknown Artist';
      String album = '';
      int durationMs = 0;

      try {
        final artworkDir = await getApplicationSupportDirectory();
        final artPath = savedLocalArtworkPath(artworkDir.path, id);

        final meta = await Channel.extractAudioMetadata(
          url: path,
          artworkPath: artPath,
        );
        if (meta != null) {
          // The native side only writes the file when the track has a cover;
          // one left from an earlier version of the file must not outlive it.
          if (meta['hasArtwork'] != true) {
            try {
              final stale = File(artPath);
              if (stale.existsSync()) stale.deleteSync();
            } catch (_) {}
          }
          if (meta['title'] != null && (meta['title'] as String).isNotEmpty) {
            title = meta['title'] as String;
          }
          if (meta['artist'] != null && (meta['artist'] as String).isNotEmpty) {
            artist = meta['artist'] as String;
          }
          if (meta['album'] != null && (meta['album'] as String).isNotEmpty) {
            album = meta['album'] as String;
          }
          if (meta['durationMs'] != null) {
            durationMs = meta['durationMs'] as int;
          }
        }
      } catch (e) {
        debugPrint(
          'LocalMusicScanner: Metadata extraction failed for $filename: $e',
        );
      }

      // If no metadata title, try to parse "Artist - Title" from filename
      if (title == nameNoExt && nameNoExt.contains(' - ')) {
        final parts = nameNoExt.split(' - ');
        if (parts.length >= 2) {
          artist = parts[0].trim();
          title = parts.sublist(1).join(' - ').trim();
        }
      }

      return SongModel({
        "_id": id,
        "_data": path,
        "_uri": path,
        "_display_name": filename,
        "_display_name_wo_ext": nameNoExt,
        "_size": stat.size,
        "title": title,
        "artist": artist,
        "album": album,
        "album_id": album.hashCode.abs(),
        "artist_id": artist.hashCode.abs(),
        "genre": null,
        "genre_id": null,
        "duration": durationMs,
        "date_added": stat.modified.millisecondsSinceEpoch ~/ 1000,
        "date_modified": stat.modified.millisecondsSinceEpoch ~/ 1000,
        "file_extension": ext,
        "is_music": true,
        "is_alarm": false,
        "is_notification": false,
        "is_ringtone": false,
        "is_podcast": false,
        "bookmark": null,
        "composer": null,
        "track": null,
      });
    } catch (e) {
      debugPrint(
        'LocalMusicScanner: Failed to create SongModel for ${file.path}: $e',
      );
      return null;
    }
  }

  /// Open a document picker to let the user import audio files.
  /// Copies selected files into the app's Documents/Music directory.
  /// Returns the number of files imported.
  static Future<int> importFiles() async {
    try {
      // Use custom extension filter — FileType.audio can fail on some iOS versions
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'mp3',
          'm4a',
          'aac',
          'flac',
          'wav',
          'ogg',
          'wma',
          'aiff',
          'alac',
        ],
        // allowMultiple: true,
      );

      debugPrint('LocalMusicScanner: Picker result: ${result.length}');

      if (result.isEmpty) return 0;

      final musicDir = await getMusicDirectory();
      int imported = 0;

      for (final file in result) {
        debugPrint(
          'LocalMusicScanner: Processing ${file.name}, path=${file.path}',
        );
        if (file.path == null) continue;
        final src = File(file.path!);
        if (!src.existsSync()) {
          debugPrint(
            'LocalMusicScanner: Source file does not exist: ${file.path}',
          );
          continue;
        }

        final destPath = '${musicDir.path}/${file.name}';
        if (!File(destPath).existsSync()) {
          try {
            await src.copy(destPath);
            imported++;
            debugPrint('LocalMusicScanner: Copied ${file.name}');
          } catch (e) {
            debugPrint('LocalMusicScanner: Failed to copy ${file.name}: $e');
          }
        } else {
          imported++; // Already exists
        }
      }

      debugPrint('LocalMusicScanner: Imported $imported files');
      return imported;
    } catch (e) {
      debugPrint('LocalMusicScanner: importFiles error: $e');
      return 0;
    }
  }
}
