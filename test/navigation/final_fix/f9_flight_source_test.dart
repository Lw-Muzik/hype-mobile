import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/motion/morph.dart';
import 'package:eq_app/navigation/shell/scene_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/shell_harness.dart';

// Found on a tablet: tapping a song flew the FIRST row's art into the player.
// Installing a queue briefly reported its first track as playing, and the
// shell read "the playing row" only after waiting a frame to mount the player.
// The row the move flies from is the one playing when the move was asked for.

bool _flying(WidgetTester tester) => find
    .ancestor(of: find.byType(FittedBox), matching: find.byType(Positioned))
    .evaluate()
    .isNotEmpty;

Widget _player(BuildContext _) => Stack(
  key: kPlayerKey,
  children: [
    Positioned.fromRect(
      rect: kCoverRect,
      child: MorphTag(
        tag: kNowPlayingArtTag,
        child: const ColoredBox(color: Colors.orange),
      ),
    ),
  ],
);

void main() {
  testWidgets('the flight source is read when the move is asked for', (
    tester,
  ) async {
    final app = FakeApp()..queue = [song(7)];
    await pumpShell(
      tester,
      app: app,
      library: FakeLibrary(),
      host: FakeHost(FakeLibrary(), rowTag: trackTag(7), rowRect: kRowRect),
      playerBuilder: _player,
    );
    final scenes = AppNav.host! as SceneController;
    scenes.toLibrary();
    await advance(tester, 900);
    expect(scenes.scene.value, Scene.library);
    expect(scenes.playerMounted.value, isFalse);

    scenes.toPlayer();
    // The queue's index wobbles before the player has mounted.
    app.queue = [song(8)];
    var seen = false;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (_flying(tester)) seen = true;
    }
    expect(seen, isTrue, reason: 'track 7 was playing when the move began');
  });
}
