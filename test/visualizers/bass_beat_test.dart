/// The radial visualizer's bass hits: one per kick, none for what only looks
/// like one in the low end, and on a real song exactly where the prototype the
/// numbers were tuned with put them.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/visualizers/bass_beat.dart';
import 'package:eq_app/visualizers/beat_frame.dart';

const double hop = 256 / 44100;

/// A bass level of [db] dBFS as one hop's mean square.
double ms(double db) => math.pow(10, db / 10).toDouble();

/// Feeds [hops] in visualizer-tick-sized batches; returns each report with
/// the absolute hop index it happened at.
List<(int, BassHit)> run(BassBeat beat, List<double> hops, {int batch = 6}) {
  final out = <(int, BassHit)>[];
  for (var start = 0; start < hops.length; start += batch) {
    final end = math.min(hops.length, start + batch);
    for (final hit in beat.add(hops.sublist(start, end), hop)) {
      out.add((end - 1 - (hit.age / hop).round(), hit));
    }
  }
  return out;
}

/// A held bassline at -20 dB and [count] kicks [every] seconds apart, the
/// first at [every]: each rises to [kickDb] within one hop and falls back
/// with a 50 ms time constant, like a kick's low end.
List<double> kicks(int count, double every, {double kickDb = -4}) {
  final perKick = (every / hop).round();
  return [
    for (var i = 0; i < (count + 1) * perKick + perKick ~/ 2; i++)
      ms(-20) +
          (i >= perKick && i < (count + 1) * perKick
              ? ms(kickDb) * math.exp(-(i % perKick) * hop / 0.05)
              : 0),
  ];
}

/// The strongest report of the hit that starts at [onset].
double strengthOf(List<(int, BassHit)> reports, int onset) => reports
    .where((r) => r.$1 >= onset && r.$1 < onset + 8)
    .map((r) => r.$2.strength)
    .reduce(math.max);

void main() {
  test('one hit per kick, at the kick, at full strength', () {
    final reports = run(BassBeat(), kicks(11, 0.5));
    final onsets = [
      for (final r in reports)
        if (r.$2.onset) r.$1,
    ];
    expect(onsets, hasLength(11));
    final perKick = (0.5 / hop).round();
    for (var k = 0; k < 11; k++) {
      // Answered within two hops (~12 ms) of the kick's first hop.
      expect(onsets[k] - (k + 1) * perKick, inInclusiveRange(0, 2));
      expect(strengthOf(reports, onsets[k]), greaterThan(0.9));
    }
  });

  test('a softer kick is a softer hit, and the reports top up', () {
    final hops = [
      ...List.filled(200, ms(-24)),
      for (var i = 0; i < 40; i++) ms(-24) + ms(-6) * math.exp(-i * hop / 0.05),
      ...List.filled(120, ms(-24)),
      for (var i = 0; i < 40; i++)
        ms(-24) + ms(-18) * math.exp(-i * hop / 0.05),
      ...List.filled(120, ms(-24)),
    ];
    final reports = run(BassBeat(), hops);
    final onsets = reports.where((r) => r.$2.onset).toList();
    expect(onsets, hasLength(2));
    final loud = strengthOf(reports, onsets[0].$1);
    final soft = strengthOf(reports, onsets[1].$1);
    expect(loud, greaterThan(0.9));
    expect(soft, inInclusiveRange(0.3, loud - 0.3));
    // What the reports add up to is the hit's final strength.
    final gains = reports
        .where((r) => r.$1 >= onsets[0].$1 && r.$1 < onsets[1].$1)
        .fold<double>(0, (sum, r) => sum + r.$2.gain);
    expect(gains, closeTo(loud, 1e-9));
  });

  test('a notch and its recovery, a slow swell and silence are not hits', () {
    final hops = [
      ...List.filled(200, ms(-12)),
      // The bass cancels for ~12 ms — a kick's tail against the bassline, or
      // sidechain ducking — then comes straight back.
      ...List.filled(2, ms(-40)),
      ...List.filled(200, ms(-12)),
      // Swells 12 dB over half a second.
      for (var i = 0; i < 86; i++) ms(-12 + 12 * i / 86),
      ...List.filled(200, ms(0)),
      ...List.filled(300, 0.0),
    ];
    final beat = BassBeat();
    expect(run(beat, hops).where((r) => r.$2.onset), isEmpty);
    expect(beat.level, 0);
  });

  test('a note after a gap is a hit: log drums, staccato bass', () {
    final hops = [
      ...List.filled(200, ms(-10)),
      ...List.filled(10, ms(-34)), // ~60 ms between notes
      ...List.filled(60, ms(-10)),
    ];
    expect(run(BassBeat(), hops).where((r) => r.$2.onset), hasLength(1));
  });

  test('two hits closer than ~110 ms are one', () {
    final hops = [
      ...List.filled(200, ms(-24)),
      ...List.filled(8, ms(-4)),
      ...List.filled(4, ms(-24)),
      ...List.filled(8, ms(-4)),
      ...List.filled(200, ms(-24)),
    ];
    expect(run(BassBeat(), hops).where((r) => r.$2.onset), hasLength(1));
  });

  test('reset forgets the song', () {
    final beat = BassBeat();
    run(beat, kicks(3, 0.5));
    beat.reset();
    expect(beat.level, 0);
    // A fresh start fires on the first kick again, not on its own warm-up.
    final hits = run(beat, kicks(2, 0.5)).where((r) => r.$2.onset).toList();
    expect(hits.first.$1 - (0.5 / hop).round(), inInclusiveRange(0, 2));
  });

  test('a real song: the kicks and bass notes the prototype found', () {
    // 9.5 s of "Last Last" (59.0-68.5 s) as the native tap measures it: the
    // bass hops FFTVisualizer::computeBeat produced on the Mac, which match the
    // Python prototype's to 1e-7 dB.
    final bytes = File('test/fixtures/visualizer/last_last_bass_hops.f32')
        .readAsBytesSync();
    final hops = Float32List.view(bytes.buffer)
        .map((v) => v.toDouble())
        .toList();
    final reports = run(BassBeat(), hops);
    final onsets = [
      for (final r in reports)
        if (r.$2.onset) r.$1,
    ];
    // Six kicks (61.5 62.5 64.2 65.2 66.9 67.9 s), two bassline notes (63.0,
    // 63.5 s) and two kicks before the stretch plotted in the tuning notes.
    expect(onsets, [45, 132, 426, 600, 690, 779, 895, 1072, 1365, 1540]);
    for (final kick in [426, 600, 895, 1072, 1365, 1540]) {
      expect(strengthOf(reports, kick), closeTo(1.0, 1e-3), reason: '$kick');
    }
    expect(strengthOf(reports, 690), closeTo(0.648, 2e-3));
    expect(strengthOf(reports, 779), closeTo(0.702, 2e-3));
  });

  group('beat frames', () {
    test('read the native layout', () {
      final f = BeatFrame.parse(
        Float32List.fromList([
          1,
          44100,
          0.0058,
          1,
          2,
          0.5,
          0.25,
          3,
          -10,
          -20,
          -30,
        ]),
      )!;
      expect(f.sampleRate, 44100);
      expect(f.hopSeconds, closeTo(0.0058, 1e-6));
      expect(f.synced, isTrue);
      expect(f.hops, [0.5, 0.25]);
      expect(f.bandsDb, [-10, -20, -30]);
    });

    test('iOS frames are not synced, and have no bands until a window is heard', () {
      final f = BeatFrame.parse([1, 48000, 0.0058, 0, 1, 0.5, 0])!;
      expect(f.synced, isFalse);
      expect(f.hops, [0.5]);
      expect(f.bandsDb, isEmpty);
    });

    test('anything else is refused', () {
      expect(BeatFrame.parse(null), isNull);
      expect(
        BeatFrame.parse(Float32List.fromList([2, 44100, 0.0058, 1, 0, 0])),
        isNull,
      );
      // Says it holds five hops, holds one.
      expect(
        BeatFrame.parse(Float32List.fromList([1, 44100, 0.0058, 1, 5, 0.5])),
        isNull,
      );
      expect(
        BeatFrame.parse(Float32List.fromList([1, 44100, 0, 1, 0, 0])),
        isNull,
      );
    });
  });
}
