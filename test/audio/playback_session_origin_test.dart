import 'dart:convert';

import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/playback_origin.dart';
import 'package:eq_app/services/playback_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:on_audio_query/on_audio_query.dart';

SongModel song(int id) => SongModel({
  '_id': id,
  '_data': '/music/$id.mp3',
  'title': 'Track $id',
  'artist': 'Artist',
  'album': 'Album',
  'duration': 1000,
  '_display_name': '$id.mp3',
  '_display_name_wo_ext': '$id',
  '_size': 0,
  'file_extension': 'mp3',
  'is_music': true,
});

PlaybackSession? roundTrip(PlaybackSession s) => PlaybackSession.fromJson(
  Map<String, Object?>.from(jsonDecode(jsonEncode(s.toJson())) as Map),
);

void main() {
  final origin = PlaybackOrigin([
    LibraryPageKey.place('albums'),
    const LibraryPageKey('album', {'id': 4}),
  ]);

  test('a session with an origin round-trips', () {
    final restored = roundTrip(
      PlaybackSession(
        songs: [song(1)],
        index: 0,
        position: Duration.zero,
        origin: origin,
      ),
    );
    expect(restored!.origin, origin);
  });

  test('an old save without origin loads with null', () {
    final json = PlaybackSession(
      songs: [song(1)],
      index: 0,
      position: Duration.zero,
    ).toJson();
    expect(json.containsKey('origin'), isFalse);
    expect(PlaybackSession.fromJson(json)!.origin, isNull);
  });

  test('origin survives windowing', () {
    final songs = [for (var i = 0; i < kMaxSessionTracks + 20; i++) song(i)];
    final windowed = PlaybackSession(
      songs: songs,
      index: 5,
      position: Duration.zero,
      origin: origin,
    ).windowed();
    expect(windowed.origin, origin);
  });
}
