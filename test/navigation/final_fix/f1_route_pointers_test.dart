import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/motion/morph.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../library/library_harness.dart';

void main() {
  testWidgets('taps are ignored while a page opens, and work afterwards', (
    tester,
  ) async {
    var bodyTaps = 0;
    var rowTaps = 0;
    final root = Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.only(top: 100),
          child: SizedBox(
            width: 300,
            height: 72,
            child: GestureDetector(
              onTap: () => rowTaps++,
              child: MorphTag(
                tag: itemTag(albumKey),
                child: Container(color: Colors.red, child: const Text('row')),
              ),
            ),
          ),
        ),
      ),
    );
    final page = Scaffold(
      body: Column(
        children: [
          MorphTag(
            tag: headerTag(albumKey),
            child: Container(
              width: double.infinity,
              height: 240,
              color: Colors.blue,
              child: const Text('header'),
            ),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => bodyTaps++,
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
    final nav = await pumpNavigator(tester, root: root);
    nav.currentState!.openPage(
      page,
      key: albumKey,
      morphFrom: itemTag(albumKey),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // Over the incoming page's body, and over the old row.
    await tester.tapAt(const Offset(150, 136));
    await tester.tapAt(const Offset(150, 500));
    await tester.pump(const Duration(milliseconds: 20));
    expect(bodyTaps, 0);
    expect(rowTaps, 0);
    expect(nav.currentState!.path.length, 1);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(150, 500));
    expect(bodyTaps, 1);
  });
}
