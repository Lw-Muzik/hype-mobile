/// Translating between this app's tracks and Hype Connect's.
///
/// Pure functions over plain values, shared by the side that reports the queue
/// (the state publisher) and the side that acts on it (the executor's `jump`),
/// which must agree on every uid or a jump lands on the wrong song.
library;

import 'package:on_audio_query/on_audio_query.dart';

import '../../models/track_extras.dart';
import '../ytmusic/yt_models.dart';
import 'connect_protocol.dart';

/// The artist this app writes for a YouTube track YouTube credited to nobody.
///
/// A placeholder, not a name: reporting it would show a browser "YouTube Music"
/// as the artist of every uncredited track.
const _placeholderArtist = 'YouTube Music';

/// How this phone describes [song] to a controller.
///
/// * A YouTube stream or video is `yt`, so any player with YouTube can take it
///   over.
/// * A file on this phone is `local`, owned by [deviceId], named by its
///   media-store id.
/// * Everything else — a drive file, a radio stream, a track streamed from a
///   paired desktop — is `other`: shown, never commanded.
TrackRef trackRefOf(SongModel song, {required String deviceId}) {
  final durationMs = (song.duration ?? 0) > 0 ? song.duration : null;
  final videoId = song.ytVideoId;
  if (videoId != null && videoId.isNotEmpty) {
    // Streamed tracks carry their artwork URL in `album` — see
    // `YtPlayback.songModelOf` — so `album` is never an album name here.
    final art = song.album;
    return YtTrackRef(
      videoId: videoId,
      title: song.title,
      artist: _realArtist(song.artist),
      album: null,
      durationMs: durationMs,
      artUrl: art != null && art.startsWith('https://') ? art : null,
    );
  }
  final data = song.data;
  // The app's own test for "on this device" (the player, the lyrics editor and
  // the song sheet all use it): anything not fetched over http. It covers
  // Android paths and iOS media-library URLs alike.
  if (data.isNotEmpty && !data.startsWith('http')) {
    return LocalTrackRef(
      deviceId: deviceId,
      id: song.id.toString(),
      title: song.title,
      artist: _realArtist(song.artist),
      album: _realAlbum(song.album),
      durationMs: durationMs,
    );
  }
  return OtherTrackRef(
    title: song.title,
    artist: _realArtist(song.artist),
    album: _realAlbum(song.album),
    durationMs: durationMs,
    artUrl: null,
  );
}

String? _realArtist(String? artist) {
  if (artist == null || artist.isEmpty) return null;
  if (artist == _placeholderArtist || artist == '<unknown>') return null;
  return artist;
}

String? _realAlbum(String? album) {
  if (album == null || album.isEmpty) return null;
  // Streamed tracks of every kind ride their artwork URL in this field.
  if (album.startsWith('http')) return null;
  return album;
}

/// The uid of every entry in [queue], position for position.
///
/// A uid has to survive the queue changing around it: a controller reads one
/// from a state frame and sends it back in a `jump` some seconds later, by
/// which time the queue may have advanced, grown or been shuffled. So it is
/// built from the song itself rather than from its position — `q-<id>` — and
/// a song queued more than once is told apart by which occurrence it is,
/// counted from the start of the queue: `q-<id>`, `q-<id>-2`, `q-<id>-3`.
/// Counting from the start rather than from the playing track is what keeps a
/// repeat's uid stable as playback moves past the first copy.
List<String> queueUids(List<SongModel> queue) {
  final seen = <int, int>{};
  return [
    for (final song in queue)
      () {
        final n = seen.update(song.id, (count) => count + 1, ifAbsent: () => 1);
        return n == 1 ? 'q-${song.id}' : 'q-${song.id}-$n';
      }(),
  ];
}

/// The track a `yt` ref names, as the app's YouTube layer wants it.
YtTrack ytTrackOf(YtTrackRef ref) => YtTrack(
  videoId: ref.videoId,
  title: ref.title,
  artist: ref.artist,
  album: ref.album,
  durationSecs: ref.durationMs == null ? null : ref.durationMs! / 1000,
  thumbnail: ref.artUrl,
);

/// [track] as a `yt` track ref — the shape `open` returns its tracks in.
YtTrackRef ytRefOf(YtTrack track) => YtTrackRef(
  videoId: track.videoId,
  title: track.title,
  artist: track.artist,
  album: track.album,
  durationMs: _ms(track.durationSecs),
  artUrl: track.thumbnail,
);

int? _ms(double? secs) => secs == null ? null : (secs * 1000).round();

/// An `ExploreItem` on the wire.
Item itemOf(ExploreItem item) => Item(
  kind: switch (item.kind) {
    ExploreKind.song => ItemKind.song,
    ExploreKind.video => ItemKind.video,
    ExploreKind.album => ItemKind.album,
    ExploreKind.playlist => ItemKind.playlist,
    ExploreKind.artist => ItemKind.artist,
  },
  id: item.id,
  title: item.title,
  subtitle: item.subtitle,
  thumbnail: item.thumbnail,
  artist: item.artist,
  album: item.album,
  durationMs: _ms(item.durationSecs),
  hasVideo: item.hasVideo,
);

/// An item off the wire, as the app's YouTube layer opens it.
ExploreItem exploreItemOf(Item item) => ExploreItem(
  id: item.id,
  kind: switch (item.kind) {
    ItemKind.song => ExploreKind.song,
    ItemKind.video => ExploreKind.video,
    ItemKind.album => ExploreKind.album,
    ItemKind.playlist => ExploreKind.playlist,
    ItemKind.artist => ExploreKind.artist,
  },
  title: item.title,
  subtitle: item.subtitle,
  thumbnail: item.thumbnail,
  artist: item.artist,
  album: item.album,
  durationSecs: item.durationMs == null ? null : item.durationMs! / 1000,
  hasVideo: item.hasVideo,
);

Shelf shelfOf(ExploreShelf shelf) => Shelf(
  title: shelf.title,
  items: [for (final item in shelf.items) itemOf(item)],
);
