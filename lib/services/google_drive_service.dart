import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/cloud_file.dart';
import 'cloud_auth_service.dart';

class GoogleDriveService {
  final CloudAuthService _auth;

  GoogleDriveService(this._auth);

  static const _baseUrl = 'https://www.googleapis.com/drive/v3';
  static const _audioMimeTypes = [
    'audio/mpeg',
    'audio/mp4',
    'audio/x-m4a',
    'audio/flac',
    'audio/wav',
    'audio/ogg',
    'audio/aac',
    'audio/x-ms-wma',
  ];

  Future<List<CloudFile>> listAudioFiles() async {
    final headers = await _auth.getGoogleAuthHeaders();
    if (headers.isEmpty) return [];

    final mimeQuery = _audioMimeTypes.map((m) => "mimeType='$m'").join(' or ');
    final query = '($mimeQuery) and trashed=false';
    final fields =
        'nextPageToken,files(id,name,mimeType,size,parents,thumbnailLink,modifiedTime)';

    final allFiles = <_RawFile>[];
    String? pageToken;

    do {
      final uri = Uri.parse('$_baseUrl/files').replace(
        queryParameters: {
          'q': query,
          'fields': fields,
          'pageSize': '100',
          if (pageToken case final pt?) 'pageToken': pt,
        },
      );

      final response = await http.get(uri, headers: headers);
      if (response.statusCode != 200) break;

      final data = json.decode(response.body);
      final files = data['files'] as List? ?? [];
      for (final f in files) {
        allFiles.add(
          _RawFile(
            id: f['id'] as String,
            name: f['name'] as String,
            mimeType: f['mimeType'] as String,
            size: int.tryParse('${f['size'] ?? 0}') ?? 0,
            parentId: (f['parents'] as List?)?.firstOrNull as String?,
            thumbnailLink: f['thumbnailLink'] as String?,
            modifiedTime: f['modifiedTime'] != null
                ? DateTime.tryParse(f['modifiedTime'] as String)
                : null,
          ),
        );
      }
      pageToken = data['nextPageToken'] as String?;
    } while (pageToken != null);

    // Resolve parent folder names
    final parentIds = allFiles
        .where((f) => f.parentId != null)
        .map((f) => f.parentId!)
        .toSet();
    final folderNames = await _resolveFolderNames(parentIds, headers);

    return allFiles.map((f) {
      final folderName = f.parentId != null
          ? (folderNames[f.parentId!] ?? 'My Drive')
          : 'My Drive';
      return CloudFile(
        provider: CloudProvider.googleDrive,
        fileId: f.id,
        name: f.name,
        folderPath: '/$folderName',
        size: f.size,
        mimeType: f.mimeType,
        thumbnailUrl: f.thumbnailLink,
        modifiedDate: f.modifiedTime,
      );
    }).toList();
  }

  Future<Map<String, String>> _resolveFolderNames(
    Set<String> parentIds,
    Map<String, String> headers,
  ) async {
    final names = <String, String>{};
    for (final id in parentIds) {
      try {
        final uri = Uri.parse('$_baseUrl/files/$id')
            .replace(queryParameters: {'fields': 'name'});
        final response = await http.get(uri, headers: headers);
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          names[id] = data['name'] as String;
        }
      } catch (_) {}
    }
    return names;
  }

  String getStreamUrl(String fileId) {
    return '$_baseUrl/files/$fileId?alt=media';
  }
}

class _RawFile {
  final String id;
  final String name;
  final String mimeType;
  final int size;
  final String? parentId;
  final String? thumbnailLink;
  final DateTime? modifiedTime;

  _RawFile({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.size,
    this.parentId,
    this.thumbnailLink,
    this.modifiedTime,
  });
}
