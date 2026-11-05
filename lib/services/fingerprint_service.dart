import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '/Helpers/Channel.dart';
import '/config/app_config.dart';
import '/models/recognition_result.dart';

/// Orchestrates audio fingerprinting, AcoustID lookup, and MusicBrainz metadata.
class FingerprintService {
  final SharedPreferences _prefs;
  final Client _client = Client();
  static const Duration _timeout = Duration(seconds: 15);
  static const _userAgent = 'HypeMuzik/1.0';

  // Rate limiting
  DateTime _lastAcoustIdCall = DateTime(2000);
  DateTime _lastMusicBrainzCall = DateTime(2000);

  // In-memory cache keyed by file path. Bounded: after a batchIdentify over a
  // large library this used to grow without limit for the app's lifetime; the
  // persistent prefs cache below still serves evicted entries.
  static const int _ramCacheCap = 100;
  final Map<String, RecognitionResult> _cache = {};

  void _ramCachePut(String path, RecognitionResult result) {
    _cache.remove(path); // refresh position (Dart maps keep insertion order)
    _cache[path] = result;
    while (_cache.length > _ramCacheCap) {
      _cache.remove(_cache.keys.first);
    }
  }

  FingerprintService(this._prefs);

  /// Identifies a song via fingerprinting + AcoustID + MusicBrainz.
  /// Returns null if identification fails or song can't be fingerprinted.
  /// Identifies a song via fingerprinting + AcoustID + MusicBrainz.
  /// For cloud files, pass [fingerprintPath] pointing to the locally cached
  /// audio file since fingerprinting requires a local file path.
  Future<RecognitionResult?> identifySong(
    SongModel song, {
    String? fingerprintPath,
  }) async {
    final path = song.data;

    // Check in-memory cache
    if (_cache.containsKey(path)) return _cache[path];

    // Check persistent cache
    final cached = _loadCachedResult(path);
    if (cached != null) {
      _ramCachePut(path, cached);
      return cached;
    }

    RecognitionResult? result;
    final actualPath = fingerprintPath ?? path;

    // Step 1: Generate Chromaprint fingerprint (not available on iOS)
    final fpData = await Channel.generateFingerprint(actualPath);

    if (fpData != null) {
      final fingerprint = fpData['fingerprint'] as String?;
      final duration = fpData['duration'] as int?;

      if (fingerprint != null && duration != null && duration > 0) {
        // Step 2: AcoustID lookup
        final acoustIdResult = await _lookupAcoustId(fingerprint, duration);
        if (acoustIdResult != null) {
          result = acoustIdResult;
          // Step 3: MusicBrainz enrichment
          if (acoustIdResult.musicBrainzRecordingId != null) {
            final enriched = await _enrichFromMusicBrainz(
              acoustIdResult.musicBrainzRecordingId!,
              acoustIdResult,
            );
            if (enriched != null) result = enriched;
          }
        }
      }
    } else {
      debugPrint(
        'FingerprintService: Chromaprint unavailable, skipping AcoustID',
      );
    }

    // Step 4: ACRCloud fallback (works on all platforms — uses raw audio bytes)
    if (result == null && AppConfig.acrCloudAccessKey.isNotEmpty) {
      debugPrint('FingerprintService: Trying ACRCloud for $actualPath');
      result = await _lookupAcrCloud(actualPath);
    }

    if (result == null) return null;

    // Cache result
    _ramCachePut(path, result);
    _saveCachedResult(path, result);

    return result;
  }

  /// Identifies a song and writes recognized tags + artwork to the file.
  /// Returns true if tags were written successfully.
  Future<bool> identifyAndWriteTags(SongModel song) async {
    final result = await identifySong(song);
    if (result == null || !result.hasUsefulData) return false;

    final tagMap = result.toTagMap();
    if (tagMap.isEmpty) return false;

    // Fetch cover art if we have a release ID
    String? artworkPath;
    if (result.musicBrainzReleaseId != null) {
      artworkPath = await fetchCoverArt(result.musicBrainzReleaseId!);
    }

    final ok = await Channel.writeTags(
      song.data,
      tagMap,
      artworkPath: artworkPath,
    );

    // Clean up temp artwork file
    if (artworkPath != null) {
      try {
        File(artworkPath).deleteSync();
      } catch (_) {}
    }

    // Trigger MediaStore re-scan so UI reflects changes
    if (ok) {
      await Channel.scanMediaFile(song.data);
    }

    return ok;
  }

  /// Batch-identifies songs with missing metadata.
  /// Calls [onProgress] with (current index, total count, current song title).
  /// Returns the number of successfully identified songs.
  Future<int> batchIdentify(
    List<SongModel> songs, {
    void Function(int current, int total, String songName)? onProgress,
  }) async {
    // Filter songs needing identification
    final needsId = songs.where((s) {
      final title = s.title.toLowerCase();
      final artist = (s.artist ?? '').toLowerCase();
      return title.startsWith('track') ||
          title.contains('unknown') ||
          artist.isEmpty ||
          artist == '<unknown>' ||
          artist == 'unknown' ||
          artist == 'unknown artist';
    }).toList();

    if (needsId.isEmpty) return 0;

    int identified = 0;
    for (int i = 0; i < needsId.length; i++) {
      final song = needsId[i];
      onProgress?.call(i + 1, needsId.length, song.title);

      final success = await identifyAndWriteTags(song);
      if (success) identified++;

      // Rate limiting: 350ms between songs
      await Future.delayed(const Duration(milliseconds: 350));
    }

    return identified;
  }

  void invalidateCache(String filePath) {
    _cache.remove(filePath);
    _prefs.remove(_cacheKey(filePath));
  }

  void clearCache() {
    _cache.clear();
    // Clear all fingerprint cache keys
    final keys = _prefs.getKeys().where((k) => k.startsWith('fp_cache_'));
    for (final key in keys) {
      _prefs.remove(key);
    }
  }

  // ---------------------------------------------------------------------------
  // Cover Art Archive
  // ---------------------------------------------------------------------------

  /// Downloads cover art for a MusicBrainz release to a temp file.
  /// Returns the temp file path, or null if not available.
  Future<String?> fetchCoverArt(String releaseId) async {
    try {
      // Cover Art Archive: front cover, 500px for good quality
      final uri = Uri.parse(
        'https://coverartarchive.org/release/$releaseId/front-500',
      );
      final res = await _client
          .get(uri, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 10));

      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;

      final tempDir = await getTemporaryDirectory();
      final artFile = File('${tempDir.path}/fp_cover_$releaseId.jpg');
      await artFile.writeAsBytes(res.bodyBytes);
      return artFile.path;
    } catch (e) {
      debugPrint('Cover art fetch error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // AcoustID API
  // ---------------------------------------------------------------------------

  Future<RecognitionResult?> _lookupAcoustId(
    String fingerprint,
    int duration,
  ) async {
    // Rate limit: max 3 req/sec
    final elapsed = DateTime.now().difference(_lastAcoustIdCall);
    if (elapsed.inMilliseconds < 334) {
      await Future.delayed(
        Duration(milliseconds: 334 - elapsed.inMilliseconds),
      );
    }
    _lastAcoustIdCall = DateTime.now();

    try {
      final uri = Uri.https('api.acoustid.org', '/v2/lookup', {
        'client': AppConfig.acoustIdApiKey,
        'fingerprint': fingerprint,
        'duration': duration.toString(),
        'meta': 'recordings releases releasegroups tracks sources',
      });

      final res = await _client
          .get(uri, headers: {'User-Agent': _userAgent})
          .timeout(_timeout);

      if (res.statusCode != 200) {
        debugPrint('AcoustID: HTTP ${res.statusCode}');
        return null;
      }

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      if (json['status'] != 'ok') return null;

      final results = json['results'] as List? ?? [];
      if (results.isEmpty) return null;

      // Find best result with recordings
      Map<String, dynamic>? bestResult;
      double bestScore = 0;
      for (final r in results) {
        final score = (r['score'] as num?)?.toDouble() ?? 0;
        final recordings = r['recordings'] as List?;
        if (recordings != null && recordings.isNotEmpty && score > bestScore) {
          bestScore = score;
          bestResult = r as Map<String, dynamic>;
        }
      }

      if (bestResult == null) return null;

      final recordings = bestResult['recordings'] as List;
      final recording = recordings.first as Map<String, dynamic>;

      // Extract title and artists
      final title = recording['title'] as String?;
      String? artist;
      final artists = recording['artists'] as List?;
      if (artists != null && artists.isNotEmpty) {
        artist = artists.map((a) => a['name'] as String).join(', ');
      }

      // Extract album info from releases
      String? album;
      String? year;
      String? mbReleaseId;
      final releaseGroups = recording['releasegroups'] as List?;
      if (releaseGroups != null && releaseGroups.isNotEmpty) {
        final rg = releaseGroups.first as Map<String, dynamic>;
        album = rg['title'] as String?;

        final releases = rg['releases'] as List?;
        if (releases != null && releases.isNotEmpty) {
          final release = releases.first as Map<String, dynamic>;
          mbReleaseId = release['id'] as String?;
          final date = release['date'] as Map<String, dynamic>?;
          if (date != null) {
            year = date['year']?.toString();
          }
        }
      }

      return RecognitionResult(
        title: title,
        artist: artist,
        album: album,
        year: year,
        musicBrainzRecordingId: recording['id'] as String?,
        musicBrainzReleaseId: mbReleaseId,
        score: bestScore,
      );
    } catch (e) {
      debugPrint('AcoustID lookup error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // MusicBrainz API
  // ---------------------------------------------------------------------------

  Future<RecognitionResult?> _enrichFromMusicBrainz(
    String recordingId,
    RecognitionResult base,
  ) async {
    // Rate limit: max 1 req/sec
    final elapsed = DateTime.now().difference(_lastMusicBrainzCall);
    if (elapsed.inSeconds < 1) {
      await Future.delayed(
        Duration(milliseconds: 1000 - elapsed.inMilliseconds),
      );
    }
    _lastMusicBrainzCall = DateTime.now();

    try {
      final uri = Uri.https('musicbrainz.org', '/ws/2/recording/$recordingId', {
        'inc': 'isrcs releases artist-credits',
        'fmt': 'json',
      });

      final res = await _client
          .get(
            uri,
            headers: {'User-Agent': '$_userAgent ( contact@hypemuzik.app )'},
          )
          .timeout(_timeout);

      if (res.statusCode != 200) return null;

      final json = jsonDecode(res.body) as Map<String, dynamic>;

      // ISRC
      String? isrc;
      final isrcs = json['isrcs'] as List?;
      if (isrcs != null && isrcs.isNotEmpty) {
        isrc = isrcs.first as String;
      }

      // Artist credits (more detailed than AcoustID)
      String? artist;
      String? albumArtist;
      final credits = json['artist-credit'] as List?;
      if (credits != null && credits.isNotEmpty) {
        final parts = <String>[];
        for (final c in credits) {
          final name = c['name'] as String? ?? '';
          final joinPhrase = c['joinphrase'] as String? ?? '';
          parts.add('$name$joinPhrase');
        }
        artist = parts.join();
      }

      // Get album + year from releases if not already set
      String? album = base.album;
      String? year = base.year;
      String? mbReleaseId = base.musicBrainzReleaseId;
      final releases = json['releases'] as List?;
      if (releases != null && releases.isNotEmpty) {
        final release = releases.first as Map<String, dynamic>;
        album ??= release['title'] as String?;
        mbReleaseId ??= release['id'] as String?;
        final date = release['date'] as String?;
        if (date != null && year == null) {
          year = date.length >= 4 ? date.substring(0, 4) : date;
        }
        // Album artist from release artist-credit
        final relCredits = release['artist-credit'] as List?;
        if (relCredits != null && relCredits.isNotEmpty) {
          final parts = <String>[];
          for (final c in relCredits) {
            parts.add('${c['name'] ?? ''}${c['joinphrase'] ?? ''}');
          }
          albumArtist = parts.join();
        }
      }

      return RecognitionResult(
        title: json['title'] as String? ?? base.title,
        artist: artist ?? base.artist,
        album: album,
        albumArtist: albumArtist,
        year: year,
        isrc: isrc,
        musicBrainzRecordingId: recordingId,
        musicBrainzReleaseId: mbReleaseId,
        score: base.score,
      );
    } catch (e) {
      debugPrint('MusicBrainz lookup error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // ACRCloud API (fallback)
  // ---------------------------------------------------------------------------

  /// Reads up to [maxBytes] from the start of a file for ACRCloud identification.
  static const int _acrSampleMaxBytes = 1024 * 1024; // 1 MB

  Future<RecognitionResult?> _lookupAcrCloud(String filePath) async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;

      // Read first ~1 MB of the audio file as sample
      final raf = file.openSync();
      final fileLen = raf.lengthSync();
      final readLen = min(fileLen, _acrSampleMaxBytes);
      final sampleBytes = Uint8List(readLen);
      raf.readIntoSync(sampleBytes);
      raf.closeSync();

      // Build HMAC-SHA1 signature
      final timestamp = (DateTime.now().millisecondsSinceEpoch ~/ 1000)
          .toString();
      const dataType = 'audio';
      const signatureVersion = '1';
      final stringToSign =
          'POST\n/v1/identify\n${AppConfig.acrCloudAccessKey}\n$dataType\n$signatureVersion\n$timestamp';
      final hmac = Hmac(sha1, utf8.encode(AppConfig.acrCloudAccessSecret));
      final signature = base64Encode(
        hmac.convert(utf8.encode(stringToSign)).bytes,
      );

      // Multipart POST
      final uri = Uri.https(AppConfig.acrCloudHost, '/v1/identify');
      final request = MultipartRequest('POST', uri)
        ..fields['access_key'] = AppConfig.acrCloudAccessKey
        ..fields['data_type'] = dataType
        ..fields['signature_version'] = signatureVersion
        ..fields['signature'] = signature
        ..fields['timestamp'] = timestamp
        ..fields['sample_bytes'] = readLen.toString()
        ..files.add(
          MultipartFile.fromBytes(
            'sample',
            sampleBytes,
            filename: 'sample.mp3',
          ),
        );

      final streamedRes = await request.send().timeout(
        const Duration(seconds: 20),
      );
      final resBody = await streamedRes.stream.bytesToString();

      if (streamedRes.statusCode != 200) {
        debugPrint('ACRCloud: HTTP ${streamedRes.statusCode}');
        return null;
      }

      final json = jsonDecode(resBody) as Map<String, dynamic>;
      final status = json['status'] as Map<String, dynamic>?;
      if (status == null || status['code'] != 0) {
        debugPrint('ACRCloud: status ${status?['code']} - ${status?['msg']}');
        return null;
      }

      final metadata = json['metadata'] as Map<String, dynamic>?;
      final musicList = metadata?['music'] as List?;
      if (musicList == null || musicList.isEmpty) return null;

      final music = musicList.first as Map<String, dynamic>;
      return _parseAcrCloudResult(music);
    } catch (e) {
      debugPrint('ACRCloud lookup error: $e');
      return null;
    }
  }

  RecognitionResult _parseAcrCloudResult(Map<String, dynamic> music) {
    final title = music['title'] as String?;

    // Artists
    String? artist;
    final artists = music['artists'] as List?;
    if (artists != null && artists.isNotEmpty) {
      artist = artists.map((a) => a['name'] as String? ?? '').join(', ');
    }

    // Album
    String? album;
    final albumObj = music['album'] as Map<String, dynamic>?;
    if (albumObj != null) {
      album = albumObj['name'] as String?;
    }

    // Release date → year
    String? year;
    final releaseDate = music['release_date'] as String?;
    if (releaseDate != null && releaseDate.length >= 4) {
      year = releaseDate.substring(0, 4);
    }

    // ISRC from external_ids
    String? isrc;
    final externalIds = music['external_ids'] as Map<String, dynamic>?;
    if (externalIds != null) {
      final isrcVal = externalIds['isrc'] as String?;
      if (isrcVal != null && isrcVal.isNotEmpty) isrc = isrcVal;
    }

    // MusicBrainz IDs from external_metadata
    String? mbRecordingId;
    String? mbReleaseId;
    final externalMeta = music['external_metadata'] as Map<String, dynamic>?;
    if (externalMeta != null) {
      final mbData = externalMeta['musicbrainz'] as List?;
      if (mbData != null && mbData.isNotEmpty) {
        final mb = mbData.first as Map<String, dynamic>;
        mbRecordingId = mb['track']?['id'] as String?;
        mbReleaseId = mb['release']?['id'] as String?;
      }
    }

    // Score (ACRCloud uses 0-100, normalize to 0.0-1.0)
    final score = ((music['score'] as num?)?.toDouble() ?? 0) / 100.0;

    return RecognitionResult(
      title: title,
      artist: artist,
      album: album,
      year: year,
      isrc: isrc,
      musicBrainzRecordingId: mbRecordingId,
      musicBrainzReleaseId: mbReleaseId,
      score: score,
    );
  }

  // ---------------------------------------------------------------------------
  // Persistent cache
  // ---------------------------------------------------------------------------

  String _cacheKey(String filePath) => 'fp_cache_${filePath.hashCode}';

  void _saveCachedResult(String filePath, RecognitionResult result) {
    final json = jsonEncode({
      'title': result.title,
      'artist': result.artist,
      'album': result.album,
      'albumArtist': result.albumArtist,
      'year': result.year,
      'isrc': result.isrc,
      'mbRecId': result.musicBrainzRecordingId,
      'mbRelId': result.musicBrainzReleaseId,
      'score': result.score,
    });
    _prefs.setString(_cacheKey(filePath), json);
  }

  RecognitionResult? _loadCachedResult(String filePath) {
    final raw = _prefs.getString(_cacheKey(filePath));
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return RecognitionResult(
        title: json['title'] as String?,
        artist: json['artist'] as String?,
        album: json['album'] as String?,
        albumArtist: json['albumArtist'] as String?,
        year: json['year'] as String?,
        isrc: json['isrc'] as String?,
        musicBrainzRecordingId: json['mbRecId'] as String?,
        musicBrainzReleaseId: json['mbRelId'] as String?,
        score: (json['score'] as num?)?.toDouble() ?? 0,
      );
    } catch (e) {
      return null;
    }
  }
}
