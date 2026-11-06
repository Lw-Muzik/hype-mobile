import 'package:eq_app/controllers/app_controller.dart';
import 'package:eq_app/pages/discover/yt_open.dart';
import 'package:eq_app/services/ytmusic/yt_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// Owner request: a song found by searching (Discover or global) offers
// "Play next" on a long press — it goes right after the song playing now.

class _App extends ChangeNotifier implements AppController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('the YouTube track sheet offers Play next first', (t) async {
    await t.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: _App(),
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showTrackActions(
                context,
                YtTrack(videoId: 'v1', title: 'Last Last'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('Play next'), findsOneWidget);
    expect(find.text('Start radio'), findsOneWidget);
    final playNextY = t.getTopLeft(find.text('Play next')).dy;
    final radioY = t.getTopLeft(find.text('Start radio')).dy;
    expect(playNextY, lessThan(radioY), reason: 'Play next comes first');
  });
}
