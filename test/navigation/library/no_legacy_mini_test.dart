import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The shell's own mini player covers every library page, so no page may carry
/// a second one. The widgets are gone from library pages; this keeps them from coming back.
/// Settings sits on the root navigator above the shell, so it keeps its own.
void main() {
  const pages = [
    'lib/pages/folder_songs.dart',
    'lib/pages/genre_songs.dart',
    'lib/pages/cloud/cloud_folder_songs.dart',
    'lib/pages/album_songs.dart',
    'lib/pages/artist_songs.dart',
    'lib/pages/playlist_songs.dart',
    'lib/pages/discover/widgets/local_media.dart',
    'lib/pages/discover/widgets/media_widgets.dart',
  ];

  test('no library page builds a page-level mini player', () {
    for (final path in pages) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('BottomPlayer')), reason: path);
      expect(source, isNot(contains('LocalMiniPlayerBar')), reason: path);
      expect(
        source,
        isNot(contains('bottomNavigationBar: controller')),
        reason: path,
      );
    }
  });

  test('the legacy mini player files are gone', () {
    for (final path in [
      'lib/player/mini_player.dart',
      'lib/pages/Recents.dart',
      'lib/pages/online/playlist.dart',
    ]) {
      expect(File(path).existsSync(), isFalse, reason: path);
    }
  });
}
