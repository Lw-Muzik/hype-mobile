import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/playback_origin.dart';
import 'package:eq_app/navigation/yt_page_keys.dart';
import 'package:eq_app/services/ytmusic/yt_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every kind survives a JSON round trip', () {
    for (final kind in LibraryPageKey.kinds) {
      final key = LibraryPageKey(kind, {'id': 7, 'name': 'x', 'n': null});
      expect(LibraryPageKey.fromJson(key.toJson()), key, reason: kind);
    }
  });

  test('place factory carries the place id', () {
    final key = LibraryPageKey.place('albums');
    expect(key.kind, 'place');
    expect(LibraryPageKey.fromJson(key.toJson()), key);
  });

  test('equality and hash ignore map order', () {
    const a = LibraryPageKey('album', {'id': 1, 'n': 'a'});
    const b = LibraryPageKey('album', {'n': 'a', 'id': 1});
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(const LibraryPageKey('album', {'id': 2, 'n': 'a'})));
    expect(a, isNot(const LibraryPageKey('artist', {'id': 1, 'n': 'a'})));
  });

  test('garbage and unknown kinds are rejected', () {
    expect(LibraryPageKey.fromJson(null), isNull);
    expect(LibraryPageKey.fromJson('x'), isNull);
    expect(LibraryPageKey.fromJson({'kind': 'nope'}), isNull);
    expect(LibraryPageKey.fromJson({'args': {}}), isNull);
  });

  test('origin round trips and tolerates bad entries', () {
    final origin = PlaybackOrigin([
      LibraryPageKey.place('albums'),
      const LibraryPageKey('album', {'id': 3}),
    ]);
    expect(PlaybackOrigin.fromJson(origin.toJson()), origin);
    expect(
      PlaybackOrigin.fromJson({
        'path': [
          {'kind': 'bogus'},
          LibraryPageKey.place('x').toJson(),
        ],
      })!.path,
      [LibraryPageKey.place('x')],
    );
    expect(PlaybackOrigin.fromJson({'path': []}), isNull);
    expect(PlaybackOrigin.fromJson(null), isNull);
  });

  test('yt keys keep every item field and rebuild the item', () {
    const item = ExploreItem(
      id: 'MPREb1',
      kind: ExploreKind.album,
      title: 'Album',
      subtitle: 'Album - A',
      thumbnail: 'https://t/x.jpg',
      artist: 'A',
      album: 'Album',
      durationSecs: 12.5,
      hasVideo: true,
    );
    for (final key in [
      ytListKey(item, highlightVideoId: 'v'),
      ytArtistKey(item),
    ]) {
      final back = LibraryPageKey.fromJson(key.toJson())!;
      final rebuilt = exploreItemFromArgs(back.args)!;
      expect(rebuilt.id, item.id);
      expect(rebuilt.kind, item.kind);
      expect(rebuilt.subtitle, item.subtitle);
      expect(rebuilt.thumbnail, item.thumbnail);
      expect(rebuilt.artist, item.artist);
      expect(rebuilt.album, item.album);
      expect(rebuilt.durationSecs, item.durationSecs);
      expect(rebuilt.hasVideo, isTrue);
    }
    expect(
      ytListKey(item, highlightVideoId: 'v').args['highlightVideoId'],
      'v',
    );
    expect(ytCategoryKey(const ExploreCategory(title: 'T', params: 'p')).args, {
      'title': 'T',
      'params': 'p',
    });
    expect(exploreItemFromArgs({'id': 1}), isNull);
  });
}
