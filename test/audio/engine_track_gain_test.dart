import 'dart:async';

import 'package:eq_app/audio/replay_gain/replay_gain.dart';
import 'package:eq_app/player/engine_track_gain.dart';
import 'package:flutter_test/flutter_test.dart';

class _P {
  _P(this.id);
  String id;
  final ids = StreamController<String?>.broadcast(sync: true);
}

void main() {
  late List<(String, double)> sent;
  late EngineTrackGain<_P> gain;
  setUp(() {
    sent = [];
    gain = EngineTrackGain<_P>(
      idOf: (p) => p.id,
      idStream: (p) => p.ids.stream,
      send: (id, db) async => sent.add((id, db)),
    );
  });

  test('sends now', () {
    gain.set(_P('a'), -3);
    expect(sent, [('a', -3.0)]);
  });

  test('does not send before the player has an id', () {
    final p = _P('');
    gain.set(p, -3);
    expect(sent, isEmpty);
    p.id = 'x';
    p.ids.add('x');
    expect(sent, [('x', -3.0)]);
  });

  test('re-sends on each new id, skipping empty and null', () {
    final p = _P('a');
    gain.set(p, -2);
    sent.clear();
    p.id = 'b';
    p.ids.add('b');
    p.ids.add(null);
    p.ids.add('');
    p.id = 'c';
    p.ids.add('c');
    expect(sent, [('b', -2.0), ('c', -2.0)]);
  });

  test('one subscription per player across repeated calls', () {
    final p = _P('a');
    gain.set(p, 1);
    gain.set(p, 2);
    gain.set(p, 3);
    sent.clear();
    p.ids.add('a');
    expect(sent.length, 1);
  });

  test('the latest value wins on re-send', () {
    final p = _P('a');
    gain.set(p, 1);
    gain.set(p, -4);
    sent.clear();
    p.id = 'b';
    p.ids.add('b');
    expect(sent, [('b', -4.0)]);
    expect(gain.dbOf(p), -4);
  });

  test('keeps the subject and counts sets', () {
    final p = _P('a');
    expect(gain.seqOf(p), 0);
    gain.set(p, 1, subject: 'song');
    expect(gain.subjectOf(p), 'song');
    expect(gain.seqOf(p), 1);
  });

  group('shouldApplyGain', () {
    bool ok({
      int rs = 1,
      int rn = 1,
      int gs = 5,
      int gn = 5,
      int i = 2,
      int? pi = 2,
      bool m = true,
    }) => shouldApplyGain(
      requestAtStart: rs,
      requestNow: rn,
      gainSeqAtStart: gs,
      gainSeqNow: gn,
      index: i,
      playerIndexNow: pi,
      songStillMatches: m,
    );
    test('applies when nothing moved', () => expect(ok(), isTrue));
    test('not after a newer request', () => expect(ok(rn: 2), isFalse));
    test('not after a load set a gain', () => expect(ok(gn: 6), isFalse));
    test('not after the queue moved on', () => expect(ok(pi: 3), isFalse));
    test('a single-source player has no index', () {
      expect(ok(pi: null), isTrue);
    });
    test('not when the song changed', () => expect(ok(m: false), isFalse));
  });
}
