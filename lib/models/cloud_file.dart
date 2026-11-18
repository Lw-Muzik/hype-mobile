import '/exports/exports.dart';
import 'track_extras.dart';

enum CloudProvider { googleDrive, dropbox }

/// How long a Dropbox temporary link is trusted.
///
/// Dropbox says four hours; three leaves room for a queue that was built a
/// little before it was played. Past this a queue entry is renewed before it is
/// opened, like a YouTube one, instead of being handed to the player to fail.
const dropboxLinkLifetime = Duration(hours: 3);

class CloudFile {
  final CloudProvider provider;
  final String fileId;
  final String name;
  final String folderPath;
  final int size;
  final String mimeType;
  final String? thumbnailUrl;
  final DateTime? modifiedDate;

  /// Metadata extracted from cloud API (Dropbox media_info, etc.)
  final String? trackTitle;
  final String? trackArtist;
  final String? albumName;
  final int? durationMs;

  CloudFile({
    required this.provider,
    required this.fileId,
    required this.name,
    required this.folderPath,
    required this.size,
    required this.mimeType,
    this.thumbnailUrl,
    this.modifiedDate,
    this.trackTitle,
    this.trackArtist,
    this.albumName,
    this.durationMs,
  });

  String get folderName =>
      folderPath.split('/').where((s) => s.isNotEmpty).lastOrNull ?? 'Root';

  /// Parse "Artist - Title" from filename, stripping track numbers and extension.
  static ({String title, String artist}) _parseFilename(String filename) {
    // Strip extension
    var base = filename.replaceAll(
        RegExp(r'\.(mp3|m4a|flac|wav|ogg|aac|wma)$', caseSensitive: false), '');

    // Strip leading track numbers: "01 ", "01. ", "01 - ", "1. "
    base = base.replaceFirst(RegExp(r'^\d{1,3}[\.\-\s]+\s*'), '');

    // Try "Artist - Title" pattern (with various dash types)
    final dashMatch = RegExp(r'^(.+?)\s*[-–—]\s*(.+)$').firstMatch(base);
    if (dashMatch != null) {
      return (
        title: dashMatch.group(2)!.trim(),
        artist: dashMatch.group(1)!.trim(),
      );
    }

    // No dash pattern — use whole string as title
    return (title: base.trim(), artist: '');
  }

  /// Convert to SongModel for the existing player pipeline.
  /// [streamUrl] is the direct HTTP URL for audio streaming.
  SongModel toSongModel(String streamUrl) {
    final parsed = _parseFilename(name);

    // Use metadata fields if available, fall back to filename parsing
    final title = trackTitle ?? parsed.title;
    final artist = trackArtist ?? (parsed.artist.isNotEmpty ? parsed.artist : 'Unknown Artist');
    final album = albumName ?? '';
    final duration = durationMs ?? 0;

    return SongModel({
      "_id": fileId.hashCode.abs(),
      "_data": streamUrl,
      "title": title,
      "artist": artist,
      "album": thumbnailUrl ?? album,
      "duration": duration,
      "_display_name": name,
      "_display_name_wo_ext": name.split('.').first,
      "_size": size,
      "file_extension": name.split('.').last,
      // Where the track came from, so a dead link — or a stale sign-in token —
      // can be made good again from the queue entry alone. A Google Drive link
      // never expires, so it records no deadline; a Dropbox one lasts hours.
      TrackKeys.cloudProvider: provider.index,
      TrackKeys.cloudFileId: fileId,
      if (provider == CloudProvider.dropbox)
        TrackKeys.expiresAt:
            DateTime.now().add(dropboxLinkLifetime).millisecondsSinceEpoch ~/
            1000,
    });
  }

  Map<String, dynamic> toJson() => {
        'provider': provider.index,
        'fileId': fileId,
        'name': name,
        'folderPath': folderPath,
        'size': size,
        'mimeType': mimeType,
        'thumbnailUrl': thumbnailUrl,
        'modifiedDate': modifiedDate?.toIso8601String(),
        'trackTitle': trackTitle,
        'trackArtist': trackArtist,
        'albumName': albumName,
        'durationMs': durationMs,
      };

  factory CloudFile.fromJson(Map<String, dynamic> json) => CloudFile(
        provider: CloudProvider.values[json['provider'] as int],
        fileId: json['fileId'] as String,
        name: json['name'] as String,
        folderPath: json['folderPath'] as String,
        size: json['size'] as int,
        mimeType: json['mimeType'] as String,
        thumbnailUrl: json['thumbnailUrl'] as String?,
        modifiedDate: json['modifiedDate'] != null
            ? DateTime.parse(json['modifiedDate'] as String)
            : null,
        trackTitle: json['trackTitle'] as String?,
        trackArtist: json['trackArtist'] as String?,
        albumName: json['albumName'] as String?,
        durationMs: json['durationMs'] as int?,
      );
}
