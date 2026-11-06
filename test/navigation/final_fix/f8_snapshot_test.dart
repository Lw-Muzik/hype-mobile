import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/motion/layer_snapshot.dart';
import 'package:eq_app/navigation/motion/morph.dart';
import 'package:eq_app/navigation/motion/page_layer.dart';
import 'package:eq_app/navigation/shell/scene_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/shell_harness.dart';

SnapshotController _controllerOf(WidgetTester tester) => tester
    .widget<SnapshotWidget>(
      find.descendant(
        of: find.byType(PageLayer),
        matching: find.byType(SnapshotWidget),
      ),
    )
    .controller;

void main() {
  testWidgets(
    'a page layer snapshots exactly while strictly between its ends',
    (tester) async {
      final p = ValueNotifier<double>(0);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: PageLayer(
            progress: p,
            scaleAt0: 1,
            scaleAt1: 1.25,
            opacityAt0: 0,
            opacityAt1: 1,
            pivot: Offset.zero,
            child: const SizedBox(width: 50, height: 50),
          ),
        ),
      );
      expect(
        _controllerOf(tester).allowSnapshotting,
        isFalse,
        reason: 'rest 0',
      );
      for (final v in [0.001, 0.5, 0.999]) {
        p.value = v;
        await tester.pump();
        expect(_controllerOf(tester).allowSnapshotting, isTrue, reason: '$v');
      }
      p.value = 1;
      await tester.pump();
      expect(
        _controllerOf(tester).allowSnapshotting,
        isFalse,
        reason: 'rest 1',
      );
    },
  );

  testWidgets(
    'a tag changing hidden state makes the enclosing snapshot retake',
    (tester) async {
      final p = ValueNotifier<double>(0);
      var retakes = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MorphScope(
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  width: 100,
                  height: 100,
                  child: LayerSnapshotScope(
                    invalidate: () => retakes++,
                    child: const MorphTag(
                      tag: 'a',
                      child: ColoredBox(color: Colors.red),
                    ),
                  ),
                ),
                Positioned(
                  left: 200,
                  top: 100,
                  width: 50,
                  height: 50,
                  child: LayerSnapshotScope(
                    invalidate: () {},
                    child: const MorphTag(
                      tag: 'b',
                      child: ColoredBox(color: Colors.blue),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final scope = MorphScope.of(tester.element(find.byType(MorphTag).first));
      scope.fly(from: 'a', to: 'b', progress: p);
      p.value = 0.5;
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(retakes, greaterThanOrEqualTo(1), reason: 'hidden');
      final hidden = retakes;
      p.value = 1;
      await tester.pump();
      await tester.pump();
      expect(retakes, greaterThan(hidden), reason: 'shown again');
    },
  );

  testWidgets('a nested snapshot passes a retake request outward', (
    tester,
  ) async {
    var outer = 0;
    late BuildContext inner;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: LayerSnapshotScope(
          invalidate: () => outer++,
          child: LayerSnapshot(
            snapshotting: true,
            child: Builder(
              builder: (c) {
                inner = c;
                return const SizedBox(width: 10, height: 10);
              },
            ),
          ),
        ),
      ),
    );
    LayerSnapshotScope.maybeOf(inner)!.invalidate();
    expect(outer, 1);
  });

  testWidgets('the player layer stops ticking when hidden, resumes on a move', (
    tester,
  ) async {
    late BuildContext probe;
    await pumpShell(
      tester,
      app: FakeApp(),
      library: FakeLibrary(),
      playerBuilder: (_) => Builder(
        builder: (c) {
          probe = c;
          return const ColoredBox(key: kPlayerKey, color: Colors.black);
        },
      ),
    );
    final scenes = AppNav.host! as SceneController;
    expect(TickerMode.valuesOf(probe).enabled, isTrue, reason: 'player scene');
    scenes.toLibrary();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await advance(tester, 100);
    expect(TickerMode.valuesOf(probe).enabled, isTrue, reason: 'mid move');
    // The library has fully covered a still-mounted player.
    scenes.list.jumpTo(1);
    await tester.pump();
    expect(find.byKey(kPlayerKey), findsOneWidget);
    {
      expect(TickerMode.valuesOf(probe).enabled, isFalse, reason: 'hidden');
      scenes.toPlayer();
      await tester.pump();
      await tester.pump();
      expect(
        TickerMode.valuesOf(probe).enabled,
        isTrue,
        reason: 'move toward the player',
      );
    }
  });
}
