import 'package:eq_app/navigation/library/library_navigator.dart';
import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/motion/morph.dart';
import 'package:eq_app/navigation/motion/page_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const albumKey = LibraryPageKey('album', {'albumId': 5, 'album': 'Five'});

/// A full-width row (single column) or half-width tile that opens [albumKey].
Widget rootList({bool grid = false}) => Scaffold(
  body: Align(
    alignment: Alignment.topLeft,
    child: Padding(
      padding: const EdgeInsets.only(top: 100),
      child: SizedBox(
        width: grid ? 300 : 800,
        height: 72,
        child: MorphTag(
          tag: itemTag(albumKey),
          child: Container(
            key: const ValueKey('row-src'),
            color: Colors.red,
            child: const Text('row'),
          ),
        ),
      ),
    ),
  ),
);

Widget albumPage() => Scaffold(
  body: Column(
    children: [
      MorphTag(
        tag: headerTag(albumKey),
        child: Container(
          key: const ValueKey('header-dst'),
          width: double.infinity,
          height: 240,
          color: Colors.blue,
          child: const Text('header'),
        ),
      ),
      const Expanded(child: SizedBox.expand(key: ValueKey('album-body'))),
    ],
  ),
);

Future<GlobalKey<LibraryNavigatorState>> pumpNavigator(
  WidgetTester tester, {
  Widget? root,
}) async {
  final key = GlobalKey<LibraryNavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      home: MorphScope(
        child: LibraryNavigator(key: key, root: root ?? rootList()),
      ),
    ),
  );
  return key;
}

/// Current scale of the page layer that wraps [content] with the given end
/// scale (distinguishes the old-layer and new-layer wrappers).
double layerScale(WidgetTester tester, Finder content, {required double end}) {
  final layers = find
      .ancestor(of: content, matching: find.byType(PageLayer))
      .evaluate()
      .map((e) => e.widget as PageLayer);
  final layer = layers.firstWhere((l) => l.scaleAt1 == end);
  return layer.scaleAt0 +
      (layer.scaleAt1 - layer.scaleAt0) * layer.progress.value;
}
