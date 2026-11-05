import 'package:eq_app/audio/replay_gain/replay_gain.dart';
import 'package:eq_app/audio/replay_gain/rg_tags.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final settings = ReplayGainSettings(
    mode: ReplayGainMode.apply,
    source: ReplayGainSource.track,
    preampDb: 1,
    untaggedPreampDb: -2,
  );

  test('a local file uses its tags', () async {
    String? asked;
    final db = await trackGainDbFor(
      path: '/music/a.mp3',
      settings: settings,
      read: (p) async {
        asked = p;
        return const ReplayGainTags(trackGainDb: -6);
      },
    );
    expect(asked, '/music/a.mp3');
    expect(db, -5);
  });

  test('http and video ids use the untagged preamp without reading', () async {
    var reads = 0;
    Future<ReplayGainTags> read(String _) async {
      reads++;
      return const ReplayGainTags(trackGainDb: -6);
    }

    for (final path in ['https://x.test/a.mp3', 'http://x/a', 'dQw4w9WgXcQ']) {
      expect(
        await trackGainDbFor(path: path, settings: settings, read: read),
        -2,
      );
    }
    expect(reads, 0);
  });

  test('a read that throws falls back to the untagged preamp', () async {
    final db = await trackGainDbFor(
      path: '/music/a.mp3',
      settings: settings,
      read: (_) async => throw StateError('boom'),
    );
    expect(db, -2);
  });

  test('off is 0 and never reads', () async {
    var reads = 0;
    final db = await trackGainDbFor(
      path: '/music/a.mp3',
      settings: ReplayGainSettings(),
      read: (_) async {
        reads++;
        return ReplayGainTags.empty;
      },
    );
    expect(db, 0);
    expect(reads, 0);
  });

  group('nextGaplessIndex', () {
    test('passes a valid next index through', () {
      expect(nextGaplessIndex(playerNext: 3, length: 5), 3);
      expect(nextGaplessIndex(playerNext: 0, length: 5), 0);
    });
    test('null when there is none or it is out of range', () {
      expect(nextGaplessIndex(playerNext: null, length: 5), isNull);
      expect(nextGaplessIndex(playerNext: 5, length: 5), isNull);
      expect(nextGaplessIndex(playerNext: -1, length: 5), isNull);
      expect(nextGaplessIndex(playerNext: 0, length: 0), isNull);
    });
  });
}
