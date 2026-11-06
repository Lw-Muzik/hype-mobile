import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/services/artwork_service.dart';
import 'package:eq_app/widgets/artwork_widget.dart';

// 1x1 PNG.
const _png = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0xF8,
  0xCF,
  0xC0,
  0xF0,
  0x1F,
  0x00,
  0x05,
  0x00,
  0x01,
  0xFF,
  0x89,
  0x99,
  0x3D,
  0x1D,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

ImageProvider? _providerOf(WidgetTester t) {
  final box = t.widget<Container>(find.byType(Container).first);
  final deco = box.decoration as BoxDecoration;
  return deco.image!.image;
}

Widget _host(Widget child, {double width = 100}) => MaterialApp(
  home: Center(
    child: SizedBox(width: width, height: width, child: child),
  ),
);

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('art_cache_test');
    File('${dir.path}/cloud_art_7.png').writeAsBytesSync(_png);
    ArtworkService.instance.tempPathForTest = () async => dir.path;
    ArtworkService.instance.clearMemory();
    clearArtworkCacheForTest();
  });

  tearDown(() {
    ArtworkService.instance.tempPathForTest = null;
    dir.deleteSync(recursive: true);
  });

  ArtworkWidget art() => const ArtworkWidget(
    songId: 7,
    path: 'http://x/y',
    width: double.infinity,
    height: double.infinity,
  );

  testWidgets('second widget paints the resolved art on its first frame', (
    t,
  ) async {
    await t.pumpWidget(_host(art()));
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
    await t.pump();
    expect(_providerOf(t), isNot(isA<AssetImage>()));
    final first = _providerOf(t);

    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(_host(art()));
    expect(_providerOf(t), isNot(isA<AssetImage>()));
    expect(_providerOf(t), first);
  });

  testWidgets('small width steps inside a bucket keep the same provider', (
    t,
  ) async {
    await t.pumpWidget(_host(art(), width: 100));
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
    await t.pump();
    final first = _providerOf(t);
    for (final w in [104.0, 108.0, 112.0, 116.0]) {
      await t.pumpWidget(_host(art(), width: w));
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 10)));
      await t.pump();
      expect(_providerOf(t), first, reason: 'width $w');
    }
  });

  testWidgets('a replacement event makes a new widget resolve again', (
    t,
  ) async {
    await t.pumpWidget(_host(art()));
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
    await t.pump();
    await t.pumpWidget(const SizedBox());

    ArtworkService.instance.announceChangeForTest(7);
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 10)));

    await t.pumpWidget(_host(art()));
    expect(_providerOf(t), isA<AssetImage>());
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
    await t.pump();
    expect(_providerOf(t), isNot(isA<AssetImage>()));
  });
}
