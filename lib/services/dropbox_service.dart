import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/cloud_file.dart';
import 'cloud_auth_service.dart';

class DropboxService {
  final CloudAuthService _auth;

  DropboxService(this._auth);

  static const _apiUrl = 'https://api.dropboxapi.com/2';
  static const _contentUrl = 'https://content.dropboxapi.com/2';
  static const _audioExtensions = {
    'mp3',
    'm4a',
    'flac',
    'wav',
    'ogg',
    'aac',
    'wma',
  };

  /// Lists all audio files by recursively listing all folders
  /// and filtering by file extension client-side.
  Future<List<CloudFile>> listAudioFiles() async {
    final headers = await _auth.getDropboxAuthHeaders();
    if (headers.isEmpty) return [];

    final allFiles = <CloudFile>[];
    String? cursor;

    // Initial request — list root recursively
    var response = await http.post(
      Uri.parse('$_apiUrl/files/list_folder'),
      headers: {...headers, 'Content-Type': 'application/json'},
      body: json.encode({
        'path': '',
        'recursive': true,
        'include_media_info': true,
        'include_deleted': false,
        'limit': 2000,
      }),
    );

    if (response.statusCode != 200) {
      return [];
    }

    while (true) {
      final data = json.decode(response.body);
      final entries = data['entries'] as List? ?? [];

      for (final entry in entries) {
        if (entry['.tag'] != 'file') continue;
        final name = entry['name'] as String? ?? '';
        final ext = name.contains('.')
            ? name.split('.').last.toLowerCase()
            : '';
        if (!_audioExtensions.contains(ext)) continue;

        final pathLower = entry['path_lower'] as String? ?? '';
        final size = entry['size'] as int? ?? 0;
        final parentPath = pathLower.substring(0, pathLower.lastIndexOf('/'));

        // Extract media metadata if available
        String? trackTitle;
        String? trackArtist;
        String? albumName;
        int? durationMs;

        final mediaInfo = entry['media_info'];
        if (mediaInfo is Map) {
          final metadata = mediaInfo['metadata'];
          if (metadata is Map) {
            // Dropbox provides metadata for photos/videos; audio fields
            // may appear in some cases depending on the file
            trackTitle = metadata['title'] as String?;
            trackArtist = metadata['artist'] as String?;
            albumName = metadata['album'] as String?;
            final dur = metadata['duration'];
            if (dur is num) durationMs = dur.toInt();
          }
        }

        allFiles.add(
          CloudFile(
            provider: CloudProvider.dropbox,
            fileId: pathLower,
            name: name,
            folderPath: parentPath.isEmpty ? '/' : parentPath,
            size: size,
            mimeType: _mimeFromExtension(name),
            modifiedDate: entry['server_modified'] != null
                ? DateTime.tryParse(entry['server_modified'] as String)
                : null,
            trackTitle: trackTitle,
            trackArtist: trackArtist,
            albumName: albumName,
            durationMs: durationMs,
          ),
        );
      }

      final hasMore = data['has_more'] as bool? ?? false;
      if (!hasMore) break;

      cursor = data['cursor'] as String?;
      if (cursor == null) break;

      // Continue listing
      response = await http.post(
        Uri.parse('$_apiUrl/files/list_folder/continue'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: json.encode({'cursor': cursor}),
      );
      if (response.statusCode != 200) break;
    }

    return allFiles;
  }

  Future<String?> getTemporaryLink(String path) async {
    final headers = await _auth.getDropboxAuthHeaders();
    if (headers.isEmpty) return null;

    final response = await http.post(
      Uri.parse('$_apiUrl/files/get_temporary_link'),
      headers: {...headers, 'Content-Type': 'application/json'},
      body: json.encode({'path': path}),
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return data['link'] as String?;
    }
    return null;
  }

  Future<String?> getThumbnail(String path) async {
    final headers = await _auth.getDropboxAuthHeaders();
    if (headers.isEmpty) return null;

    final response = await http.post(
      Uri.parse('$_contentUrl/files/get_thumbnail_v2'),
      headers: {
        ...headers,
        'Dropbox-API-Arg': json.encode({
          'resource': {'.tag': 'path', 'path': path},
          'format': {'.tag': 'png'},
          'size': {'.tag': 'w256h256'},
        }),
      },
    );

    if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
      final base64Data = base64Encode(response.bodyBytes);
      return 'data:image/png;base64,$base64Data';
    }
    return null;
  }

  String _mimeFromExtension(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    return switch (ext) {
      'mp3' => 'audio/mpeg',
      'm4a' => 'audio/mp4',
      'flac' => 'audio/flac',
      'wav' => 'audio/wav',
      'ogg' => 'audio/ogg',
      'aac' => 'audio/aac',
      'wma' => 'audio/x-ms-wma',
      _ => 'audio/mpeg',
    };
  }
}
