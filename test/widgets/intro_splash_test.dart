import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eq_app/widgets/intro_splash.dart';

Future<void> _font(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    l.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
  }
  await l.load();
}

void main() {
  testWidgets('plays the timeline, renders frames, hands over', (t) async {
    await _font('ClashDisplay', [
      'assets/fonts/ClashDisplay-Medium.ttf',
      'assets/fonts/ClashDisplay-Semibold.ttf',
    ]);
    final ready = ValueNotifier(true);
    var done = false;
    final key = GlobalKey();
    t.view.physicalSize = const Size(540, 1080);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.runAsync(() async {
      // preload mark image
      final img = AssetImage('assets/mark.png');
      await t.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: key,
            child: IntroSplash(ready: ready, onDone: () => done = true),
          ),
        ),
      );
      final ctx = t.element(find.byType(IntroSplash));
      await precacheImage(img, ctx);
    });
    var elapsed = 0;
    for (final ms in [600, 1400, 1900, 2300, 2500, 2900, 3500]) {
      await t.pump(Duration(milliseconds: ms - elapsed));
      elapsed = ms;
      await t.runAsync(() async {
        final b =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final im = await b.toImage();
        final bd = await im.toByteData(format: ui.ImageByteFormat.png);
        File('${Platform.environment['SHOTS']}/mobile_$ms.png')
            .writeAsBytesSync(bd!.buffer.asUint8List());
      });
    }
    expect(done, false);
    await t.pump(const Duration(milliseconds: 200));
    await t.pump(const Duration(milliseconds: 300));
    expect(done, true);
  });

  testWidgets('waits for ready, then leaves', (t) async {
    final ready = ValueNotifier(false);
    var done = false;
    await t.pumpWidget(
      MaterialApp(
        home: IntroSplash(ready: ready, onDone: () => done = true),
      ),
    );
    await t.pump(const Duration(seconds: 5));
    expect(done, false);
    ready.value = true;
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(done, true);
  });

  testWidgets('tap skips', (t) async {
    var done = false;
    await t.pumpWidget(
      MaterialApp(
        home: IntroSplash(
          ready: ValueNotifier(false),
          onDone: () => done = true,
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 500));
    await t.tap(find.byType(IntroSplash));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(done, true);
  });
}
