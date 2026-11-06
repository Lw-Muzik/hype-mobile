import 'package:eq_app/Themes/AppThemes.dart';
import 'package:eq_app/controllers/app_controller.dart';
import 'package:eq_app/pages/discover/widgets/yt_widgets.dart';
import 'package:eq_app/pages/playlist_songs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:provider/provider.dart';

class _Controller extends ChangeNotifier implements AppController {
  @override
  List<SongModel> songs = const [];
  @override
  int get songId => -1;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

void main() {
  testWidgets('a playlist whose query fails shows the empty state', (t) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    // The media query fails, as it does when the playlist is gone.
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.lucasjosino.on_audio_query'),
      (call) async => throw PlatformException(code: 'gone'),
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.lucasjosino.on_audio_query'),
        null,
      ),
    );
    await t.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: _Controller(),
        child: MaterialApp(
          theme: AppThemes.darkTheme,
          home: const PlaylistSongs(playlistId: 3, playlist: 'Gone', songs: 0),
        ),
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byType(YtTrackSkeleton), findsNothing);
    expect(find.text('No songs found'), findsOneWidget);
  });
}
