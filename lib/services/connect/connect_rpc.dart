/// Answering a controller's questions: searching YouTube Music and reading this
/// phone's library on its behalf.
///
/// The browser never talks to YouTube (contract §0): it asks the player, and the
/// player answers with its own session — on this phone, the same InnerTube
/// client Discover uses. So a search from the web returns exactly what this
/// phone's Discover would show for the same words.
library;

import 'package:flutter/foundation.dart';

import '../ytmusic/yt_models.dart';
import 'package:on_audio_query/on_audio_query.dart';

import 'connect_executor.dart';
import 'connect_lyrics.dart';
import 'connect_protocol.dart';
import 'connect_tracks.dart';
import 'connect_video.dart';

/// YouTube Music, as the rpc handler reads it.
abstract interface class ConnectCatalog {
  /// Whether YouTube Music can be used on this phone right now.
  bool get available;

  Future<List<ExploreShelf>> search(String query, SearchFilter filter);
  Future<List<String>> suggest(String query);

  /// An album's or playlist's title and tracks.
  Future<({String title, List<YtTrack> tracks})> open(ExploreItem item);

  Future<List<ExploreShelf>> artist(String browseId);
}

/// The contract's filter names, as the app's search filters.
SearchFilter searchFilterOf(ConnectSearchFilter filter) => switch (filter) {
      ConnectSearchFilter.all => SearchFilter.top,
      ConnectSearchFilter.songs => SearchFilter.songs,
      ConnectSearchFilter.videos => SearchFilter.videos,
      ConnectSearchFilter.albums => SearchFilter.albums,
      ConnectSearchFilter.artists => SearchFilter.artists,
      ConnectSearchFilter.playlists => SearchFilter.playlists,
    };

class ConnectRpcHandler {
  ConnectRpcHandler({
    required this._catalog,
    required this._library,
    required this._deviceId,
    this._lyrics,
    this._video,
    this._currentSong,
    this.lyricsWindow = lyricsAnswerWindow,
    this.videoWindow = videoAnswerWindow,
  });

  final ConnectLyricsSource? _lyrics;
  final ConnectVideoSource? _video;

  /// The track playing now, or null.
  final SongModel? Function()? _currentSong;

  /// How long the `lyrics` rpc waits for a lookup.
  final Duration lyricsWindow;

  /// How long the `video` rpc waits for a rendition.
  final Duration videoWindow;

  final ConnectCatalog _catalog;
  final ConnectLibrary _library;
  final String _deviceId;

  Future<RpcResultFrame> handle(RpcFrame frame) async {
    final method = frame.knownMethod;
    if (method == null) {
      return RpcResultFrame.error(id: frame.id, error: RpcError.unsupported);
    }
    try {
      final result = await _run(method, frame.params);
      return RpcResultFrame.ok(id: frame.id, result: result);
    } on _Unsupported {
      return RpcResultFrame.error(id: frame.id, error: RpcError.unsupported);
    } on _NotSignedIn {
      return RpcResultFrame.error(id: frame.id, error: RpcError.notSignedIn);
    } on FormatException catch (e) {
      debugPrint('Hype Connect: bad ${frame.method} params: ${e.message}');
      return RpcResultFrame.error(id: frame.id, error: RpcError.failed);
    } catch (e) {
      debugPrint('Hype Connect: ${frame.method} failed: $e');
      return RpcResultFrame.error(id: frame.id, error: RpcError.failed);
    }
  }

  Future<JsonMap> _run(RpcMethod method, JsonMap params) async {
    switch (method) {
      case RpcMethod.search:
        final p = SearchParams.fromJson(params);
        _requireYt();
        final shelves = await _catalog.search(p.query, searchFilterOf(p.filter));
        return ShelvesResult([for (final s in shelves) shelfOf(s)]).toJson();

      case RpcMethod.suggest:
        final p = SuggestParams.fromJson(params);
        _requireYt();
        return SuggestResult(await _catalog.suggest(p.query)).toJson();

      case RpcMethod.open:
        final p = OpenParams.fromJson(params);
        _requireYt();
        final opened = await _catalog.open(exploreItemOf(p.item));
        return OpenResult(
          title: opened.title,
          tracks: [
            // A track YouTube lists but will not serve cannot be played by
            // any player, so it is not offered to one.
            for (final track in opened.tracks)
              if (track.isAvailable) ytRefOf(track),
          ],
        ).toJson();

      case RpcMethod.artist:
        final p = ArtistParams.fromJson(params);
        _requireYt();
        final shelves = await _catalog.artist(p.id);
        return ShelvesResult([for (final s in shelves) shelfOf(s)]).toJson();

      case RpcMethod.lyrics:
        final source = _lyrics;
        final current = _currentSong;
        if (source == null || current == null) throw const _Unsupported();
        final song = current();
        return (await answerLyrics(
          track: song == null ? null : trackRefOf(song, deviceId: _deviceId),
          song: song,
          source: source,
          window: lyricsWindow,
        ))
            .toJson();

      case RpcMethod.video:
        final source = _video;
        final current = _currentSong;
        if (source == null || current == null) throw const _Unsupported();
        final song = current();
        return (await answerVideo(
          track: song == null ? null : trackRefOf(song, deviceId: _deviceId),
          song: song,
          source: source,
          window: videoWindow,
        ))
            .toJson();

      case RpcMethod.library:
        final p = LibraryParams.fromJson(params);
        // A page larger than the contract allows is served at the largest
        // allowed size rather than refused: the caller pages by `total` anyway.
        final limit = p.limit.clamp(0, LibraryParams.maxLimit);
        final offset = p.offset < 0 ? 0 : p.offset;
        final query = p.query?.trim();
        final page = await _library.page(
          offset: offset,
          limit: limit,
          query: query == null || query.isEmpty ? null : query,
        );
        return LibraryResult(
          total: page.total,
          tracks: [
            for (final song in page.songs)
              LocalTrackRef(
                deviceId: _deviceId,
                id: song.id.toString(),
                title: song.title,
                artist: _orNull(song.artist),
                album: _orNull(song.album),
                durationMs: (song.duration ?? 0) > 0 ? song.duration : null,
              ),
          ],
        ).toJson();
    }
  }

  void _requireYt() {
    if (!_catalog.available) throw const _NotSignedIn();
  }

  static String? _orNull(String? value) =>
      value == null || value.isEmpty || value == '<unknown>' ? null : value;
}

class _Unsupported implements Exception {
  const _Unsupported();
}

class _NotSignedIn implements Exception {
  const _NotSignedIn();
}
