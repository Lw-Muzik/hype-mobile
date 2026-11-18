/// A cloud track that can be made good again.
///
/// A queue holds the link each cloud track had when the folder was opened. A
/// Dropbox link lasts a few hours and a Google Drive sign-in token about one,
/// so a queue that outlives either holds entries that fail when reached — and a
/// failed cloud track used to be skipped, onto the next entry with the same
/// dead token, until the queue ran out. These tests pin what an entry now
/// remembers and when it counts as stale; the YouTube and local-file rules must
/// come through untouched.
library;

import 'dart:convert';

import 'package:eq_app/models/cloud_file.dart';
import 'package:eq_app/models/track_extras.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:on_audio_query/on_audio_query.dart';

CloudFile _file(CloudProvider provider) => CloudFile(
  provider: provider,
  fileId: provider == CloudProvider.dropbox ? '/music/a.mp3' : 'drive-file-id',
  name: 'Artist - Title.mp3',
  folderPath: '/Music',
  size: 4000000,
  mimeType: 'audio/mpeg',
);

int get _nowSeconds => DateTime.now().millisecondsSinceEpoch ~/ 1000;

SongModel _youtube({int? expiresAt}) => SongModel({
  '_id': 7,
  '_data': 'https://rr1---sn-abc.googlevideo.com/videoplayback?itag=140',
  TrackKeys.videoId: 'dQw4w9WgXcQ',
  TrackKeys.expiresAt: ?expiresAt,
});

void main() {
  group('a cloud track remembers where it came from', () {
    test('its provider and file id ride in the entry', () {
      final dropbox = _file(CloudProvider.dropbox).toSongModel('https://x/y');
      expect(dropbox.cloudFileId, '/music/a.mp3');
      expect(dropbox.cloudProviderIndex, CloudProvider.dropbox.index);

      final drive = _file(CloudProvider.googleDrive).toSongModel('https://x/y');
      expect(drive.cloudFileId, 'drive-file-id');
      expect(drive.cloudProviderIndex, CloudProvider.googleDrive.index);
    });

    test('a Dropbox link records a deadline about three hours out', () {
      final song = _file(CloudProvider.dropbox).toSongModel('https://x/y');
      final deadline = (song.getMap[TrackKeys.expiresAt] as num).toInt();
      final expected = _nowSeconds + dropboxLinkLifetime.inSeconds;
      expect((deadline - expected).abs(), lessThan(5));
    });

    test('a Google Drive link records none — it never expires', () {
      final song = _file(CloudProvider.googleDrive).toSongModel('https://x/y');
      expect(song.getMap.containsKey(TrackKeys.expiresAt), isFalse);
    });

    test('it survives a save and restore of the queue', () {
      final song = _file(CloudProvider.dropbox).toSongModel('https://x/y');
      final restored = SongModel(
        Map<dynamic, dynamic>.from(jsonDecode(jsonEncode(song.getMap)) as Map),
      );
      expect(restored.cloudFileId, song.cloudFileId);
      expect(restored.cloudProviderIndex, song.cloudProviderIndex);
      expect(restored.hasFreshTarget, isTrue);
    });
  });

  group('when a cloud track is stale', () {
    test('a fresh Dropbox entry needs no renewal', () {
      final song = _file(CloudProvider.dropbox).toSongModel('https://x/y');
      expect(song.hasFreshTarget, isTrue);
      expect(song.needsRefresh(staged: false), isFalse);
    });

    test('a Dropbox entry past its deadline is renewed before it is opened', () {
      final song = _file(CloudProvider.dropbox)
          .toSongModel('https://x/y')
          .withTarget('https://x/y', _nowSeconds - 10);
      expect(song.hasFreshTarget, isFalse);
      expect(song.needsRefresh(staged: false), isTrue);
    });

    test('a minute of headroom: one about to expire counts as expired', () {
      final song = _file(CloudProvider.dropbox)
          .toSongModel('https://x/y')
          .withTarget('https://x/y', _nowSeconds + 30);
      expect(song.hasFreshTarget, isFalse);
    });

    test('a Google Drive entry is never stale on its own', () {
      final song = _file(CloudProvider.googleDrive).toSongModel('https://x/y');
      expect(song.needsRefresh(staged: false), isFalse);
    });

    test('a failure marks any cloud entry stale, and renewing clears it', () {
      for (final provider in CloudProvider.values) {
        final song = _file(provider).toSongModel('https://x/y');
        final failed = song.markStale();
        expect(failed.needsRefresh(staged: false), isTrue, reason: '$provider');
        // The link is untouched; only the deadline says "renew me".
        expect(failed.getMap['_data'], 'https://x/y');
        // Renewed: no deadline for Drive, a new one for Dropbox.
        final renewed = failed.withTarget('https://x/y', null);
        expect(renewed.needsRefresh(staged: false), isFalse, reason: '$provider');
      }
    });
  });

  group('everything else keeps its own rules', () {
    test('a YouTube entry with no deadline is still stale', () {
      expect(_youtube().hasFreshTarget, isFalse);
      expect(_youtube().needsRefresh(staged: false), isTrue);
    });

    test('a YouTube entry inside its deadline is still fresh', () {
      final song = _youtube(expiresAt: _nowSeconds + 3600);
      expect(song.hasFreshTarget, isTrue);
      expect(song.needsRefresh(staged: false), isFalse);
    });

    test('a local file is always fresh and never renewed', () {
      final local = SongModel({'_id': 1, '_data': '/storage/emulated/0/a.mp3'});
      expect(local.hasFreshTarget, isTrue);
      expect(local.needsRefresh(staged: false), isFalse);
      expect(local.cloudFileId, isNull);
    });

    test('a saved queue from before this change loads as fresh', () {
      // A cloud entry with no cloud keys: exactly what an old session holds.
      final old = SongModel({'_id': 9, '_data': 'https://x/y'});
      expect(old.hasFreshTarget, isTrue);
      expect(old.needsRefresh(staged: false), isFalse);
    });
  });
}
