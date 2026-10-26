/// iOS local files (Documents/Music) have ids that are `path.hashCode`, which
/// the media library can't resolve; their cover is the file the scanner saved.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:on_audio_query/on_audio_query.dart';

import 'package:eq_app/services/artwork_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  final service = ArtworkService.instance;

  setUpAll(() {
    // ArtworkService caches the temp folder once; it is empty on purpose.
    final temp = Directory.systemTemp.createTempSync('art_ios_temp').path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => temp,
    );
  });

  setUp(() async {
    support = await Directory.systemTemp.createTemp('art_ios_test');
    service.clearMemory();
    service.supportPathForTest = () async => support.path;
  });

  tearDown(() async {
    service.isIosForTest = () => Platform.isIOS;
    await support.delete(recursive: true);
  });

  test('the scanner and the service agree on the file name', () {
    expect(savedLocalArtworkPath('/s', 42), '/s/artwork_42.jpg');
  });

  test('iOS: serves the cover the scanner saved for that id', () async {
    service.isIosForTest = () => true;
    final art = File(savedLocalArtworkPath(support.path, 7))
      ..writeAsBytesSync([1, 2, 3]);
    final path = await service.pathFor(
      id: 7,
      data: '/Documents/Music/a.m4a',
      type: ArtworkType.AUDIO,
    );
    expect(path, art.path);
    expect(service.memoryPathForTest('a:7'), art.path);
  });

  test('iOS: an empty saved file is not a cover', () async {
    service.isIosForTest = () => true;
    File(savedLocalArtworkPath(support.path, 8)).writeAsBytesSync([]);
    final path = await service.pathFor(
      id: 8,
      data: '/Documents/Music/b.m4a',
      type: ArtworkType.AUDIO,
    );
    // Falls through to the media-library query, which has no plugin here.
    expect(path, isNull);
  });

  test('not iOS: the saved file is ignored', () async {
    service.isIosForTest = () => false;
    File(savedLocalArtworkPath(support.path, 9)).writeAsBytesSync([1]);
    final path = await service.pathFor(
      id: 9,
      data: '/Documents/Music/c.m4a',
      type: ArtworkType.AUDIO,
    );
    expect(path, isNull);
  });
}
