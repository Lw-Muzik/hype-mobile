import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/motion/morph.dart';
import 'package:eq_app/navigation/shell/scene_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/shell_harness.dart';

Rect? _flightRect(WidgetTester tester) {
  final found = find.ancestor(
    of: find.byType(FittedBox),
    matching: find.byType(Positioned),
  );
  if (found.evaluate().isEmpty) return null;
  final w = tester.widget<Positioned>(found.first);
  return Rect.fromLTWH(w.left!, w.top!, w.width!, w.height!);
}

Widget _player(BuildContext _) => Stack(
  key: kPlayerKey,
  children: [
    Positioned.fromRect(
      rect: kCoverRect,
      child: MorphTag(
        tag: kNowPlayingArtTag,
        child: const ColoredBox(key: ValueKey('cover'), color: Colors.orange),
      ),
    ),
  ],
);

Future<SceneController> _pump(WidgetTester tester) async {
  final app = FakeApp()..queue = [song(7)];
  await pumpShell(
    tester,
    app: app,
    library: FakeLibrary(),
    host: FakeHost(FakeLibrary(), rowTag: trackTag(7), rowRect: kRowRect),
    playerBuilder: _player,
  );
  return AppNav.host! as SceneController;
}

void main() {
  group('cover to row flight is measured in one transform state', () {
    testWidgets('chevron after a tap into the player flies', (tester) async {
      final scenes = await _pump(tester);
      scenes.toLibrary();
      await advance(tester, 700);
      scenes.toPlayer();
      await advance(tester, 700);
      expect(scenes.scene.value, Scene.player);
      expect(scenes.leaving.value, isFalse);
      scenes.toLibrary();
      var seen = false;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (_flightRect(tester) != null) seen = true;
      }
      expect(seen, isTrue, reason: 'the cover should fly into its row');
    });

    for (final afterTap in [false, true]) {
      testWidgets('a finger drag flies (afterTapToPlayer=$afterTap)', (
        tester,
      ) async {
        final scenes = await _pump(tester);
        if (afterTap) {
          scenes.toLibrary();
          await advance(tester, 700);
          scenes.toPlayer();
          await advance(tester, 700);
        }
        expect(scenes.beginPlayerDrag(), isTrue);
        var seen = false;
        for (var i = 1; i <= 12; i++) {
          scenes.dragPlayer(i * 0.03);
          await tester.pump(const Duration(milliseconds: 16));
          if (_flightRect(tester) != null) seen = true;
        }
        expect(seen, isTrue);
      });
    }
  });
}
