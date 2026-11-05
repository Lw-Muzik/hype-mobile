import 'package:eq_app/audio/replay_gain/replay_gain.dart';
import 'package:eq_app/audio/replay_gain/rg_native_tags.dart';
import 'package:eq_app/audio/replay_gain/rg_tags.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('replayGainTagsFromStrings', () {
    test('parses gains and peaks like a file tag', () {
      final t = replayGainTagsFromStrings({
        'trackGain': '-6.50 dB',
        'trackPeak': '0.987654',
        'albumGain': '+3.2 dB',
        'albumPeak': '1.0',
      });
      expect(t.trackGainDb, -6.5);
      expect(t.trackPeak, 0.987654);
      expect(t.albumGainDb, 3.2);
      expect(t.albumPeak, 1.0);
    });

    test('missing and blank values stay null', () {
      final t = replayGainTagsFromStrings({
        'trackGain': ' -2 dB ',
        'albumGain': '   ',
        'albumPeak': null,
      });
      expect(t.trackGainDb, -2.0);
      expect(t.albumGainDb, isNull);
      expect(t.albumPeak, isNull);
      expect(t.trackPeak, isNull);
    });

    test('nothing usable is empty', () {
      expect(replayGainTagsFromStrings({}).isEmpty, isTrue);
      expect(
        replayGainTagsFromStrings({'trackGain': 'loud'}).isEmpty,
        isTrue,
      );
    });

    test('non-ASCII text does not throw', () {
      expect(
        replayGainTagsFromStrings({'trackGain': '-4,5 dB — ünïcode'}).trackGainDb,
        -4.0,
      );
    });
  });

  group('readNativeReplayGainTags', () {
    test('passes the uri to the platform and parses its strings', () async {
      String? asked;
      final t = await readNativeReplayGainTags(
        'ipod-library://item/item.mp3?id=1',
        fetch: (u) async {
          asked = u;
          return {'trackGain': '-7.1 dB'};
        },
      );
      expect(asked, 'ipod-library://item/item.mp3?id=1');
      expect(t.trackGainDb, -7.1);
    });

    test('null (no tags / protected / unsupported) is empty', () async {
      final t = await readNativeReplayGainTags(
        'ipod-library://item/item.m4a?id=2',
        fetch: (_) async => null,
      );
      expect(t.isEmpty, isTrue);
    });

    test('a failing platform call is empty, not an error', () async {
      final t = await readNativeReplayGainTags(
        'ipod-library://item/item.m4a?id=3',
        fetch: (_) async => throw StateError('boom'),
      );
      expect(t.isEmpty, isTrue);
    });
  });

  group('trackGainDbFor routing', () {
    final settings = ReplayGainSettings(
      mode: ReplayGainMode.apply,
      source: ReplayGainSource.track,
      untaggedPreampDb: -3.0,
    );

    Future<double> run(String path, List<String> log) => trackGainDbFor(
      path: path,
      settings: settings,
      read: (p) async {
        log.add('file:$p');
        return const ReplayGainTags(trackGainDb: -5.0);
      },
      readNative: (p) async {
        log.add('native:$p');
        return const ReplayGainTags(trackGainDb: -8.0);
      },
    );

    test('a file path uses the file reader', () async {
      final log = <String>[];
      expect(await run('/music/a.mp3', log), -5.0);
      expect(log, ['file:/music/a.mp3']);
    });

    test('an ipod-library uri uses the native reader', () async {
      final log = <String>[];
      expect(await run('ipod-library://item/item.mp3?id=9', log), -8.0);
      expect(log, ['native:ipod-library://item/item.mp3?id=9']);
    });

    test('a stream is untagged and reads nothing', () async {
      final log = <String>[];
      expect(await run('https://example.com/a.mp3', log), -3.0);
      expect(await run('', log), -3.0);
      expect(log, isEmpty);
    });

    test('a native item with no tags gets the untagged preamp', () async {
      final db = await trackGainDbFor(
        path: 'ipod-library://item/item.mp3?id=9',
        settings: settings,
        readNative: (_) async => ReplayGainTags.empty,
      );
      expect(db, -3.0);
    });

    test('a throwing native reader gets the untagged preamp', () async {
      final db = await trackGainDbFor(
        path: 'ipod-library://item/item.mp3?id=9',
        settings: settings,
        readNative: (_) async => throw StateError('x'),
      );
      expect(db, -3.0);
    });

    test('off reads nothing', () async {
      final log = <String>[];
      final db = await trackGainDbFor(
        path: 'ipod-library://item/item.mp3?id=9',
        settings: ReplayGainSettings(),
        readNative: (p) async {
          log.add(p);
          return ReplayGainTags.empty;
        },
      );
      expect(db, 0.0);
      expect(log, isEmpty);
    });
  });
}
