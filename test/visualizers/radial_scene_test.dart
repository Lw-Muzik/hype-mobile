/// The radial scene puts each bass hit on screen when it is heard: a hit the
/// native side reports ahead of time waits, the frame that will be visible
/// then shows it, and how long frames take to become visible is learned from
/// the app's own frame timings.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show FrameTiming;

import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/visualizers/beat_frame.dart';
import 'package:eq_app/visualizers/radial_scene.dart';

const double hop = 256 / 44100;
const int hopUs = 5805;

double ms(double db) => math.pow(10, db / 10).toDouble();

BeatFrame frame(List<double> hops, {int? heardAtUs, bool synced = true}) =>
    BeatFrame(
      sampleRate: 44100,
      hopSeconds: hop,
      synced: synced,
      hops: Float32List.fromList(hops),
      bandsDb: Float32List.fromList(List.filled(64, -40)),
      heardAtUs: heardAtUs,
    );

/// 60 hops of a quiet bassline, so the detector has warmed up.
List<double> quiet() => List.filled(60, ms(-24));

/// A kick in the last of 6 hops.
List<double> kick() => [...List.filled(5, ms(-24)), ms(-4)];

FrameTiming timing(int spanUs) => FrameTiming(
  vsyncStart: 0,
  buildStart: 1000,
  buildFinish: 5000,
  rasterStart: 6000,
  rasterFinish: spanUs,
  rasterFinishWallTime: spanUs,
);

void main() {
  test('a hit reported ahead of time waits for the frame that shows it', () {
    final scene = RadialScene(defaultDisplayLatencyUs: 60000);
    const now = 10000000;
    scene.addFrame(frame(quiet(), heardAtUs: now - 1000), now);
    // The kick will be heard 200 ms from now.
    scene.addFrame(frame(kick(), heardAtUs: now + 200000), now);

    // Frames built until 60 ms before the kick is heard do not show it (the
    // core only breathes with the bassline)...
    var before = 0.0;
    for (var t = now; t < now + 140000 - 16667; t += 16667) {
      scene.tick(t);
      expect(scene.flare, lessThan(0.01), reason: 'built at ${t - now} µs');
      before = scene.swell;
    }
    // ...the one on screen when it is heard does, at the start of the swell,
    // and ~40 ms on it is near the top.
    scene.tick(now + 140000);
    expect(scene.flare, greaterThan(0.9));
    expect(scene.swell - before, lessThan(0.03));
    scene.tick(now + 180000);
    expect(scene.swell - before, greaterThan(0.12));
    expect(scene.rings, hasLength(1));
  });

  test('without a heard time a hit shows on the next frame', () {
    final scene = RadialScene();
    const now = 5000000;
    scene.addFrame(frame(quiet(), synced: false), now);
    scene.addFrame(frame(kick(), synced: false), now);
    scene.tick(now);
    expect(scene.flare, greaterThan(0.9));
    expect(scene.rings, hasLength(1));
  });

  test('how long frames take to be seen is learned from frame timings', () {
    final scene = RadialScene(defaultDisplayLatencyUs: 60000);
    expect(scene.displayLatencyUs, 60000);
    scene.refreshPeriodUs = 16667;
    scene.observeFrameTimings([for (var i = 0; i < 200; i++) timing(45000)]);
    // The build-to-raster span, then ~3.5 refreshes for the display path.
    expect(scene.displayLatencyUs, closeTo(45000 + 3.5 * 16667, 500));
    // One very slow frame barely moves it.
    scene.observeFrameTimings([timing(400000)]);
    expect(scene.displayLatencyUs, lessThan(130000));
  });

  test('a hit that would land more than half a second late is dropped', () {
    final scene = RadialScene(defaultDisplayLatencyUs: 60000);
    const now = 20000000;
    scene.addFrame(frame(quiet(), heardAtUs: now - 1000), now);
    scene.addFrame(frame(kick(), heardAtUs: now - 800000), now);
    scene.tick(now);
    expect(scene.flare, lessThan(0.01));
    expect(scene.rings, isEmpty);
  });

  test('switching between timed and untimed reports starts over', () {
    final scene = RadialScene(defaultDisplayLatencyUs: 60000);
    const now = 30000000;
    scene.addFrame(frame(quiet(), heardAtUs: now), now);
    // A kick queued for later, then the clock is lost before it is due.
    scene.addFrame(frame(kick(), heardAtUs: now + 200000), now);
    scene.addFrame(frame(quiet(), synced: false), now + 10000);
    scene.tick(now + 300000);
    expect(scene.rings, isEmpty);
  });

  test('the bars follow the band levels of the audio on screen', () {
    final scene = RadialScene(defaultDisplayLatencyUs: 0);
    const now = 40000000;
    final loud = Float32List.fromList([
      -60,
      for (var b = 1; b < 64; b++) b < 8 ? -6 : -60,
    ]);
    scene.addFrame(
      BeatFrame(
        sampleRate: 44100,
        hopSeconds: hop,
        synced: true,
        hops: Float32List.fromList(quiet()),
        bandsDb: loud,
        heardAtUs: now + 100000,
      ),
      now,
    );
    scene.tick(now);
    expect(scene.crown.first, lessThan(0.01));
    for (var t = now + 100000; t <= now + 300000; t += 16667) {
      scene.tick(t);
    }
    // The lowest band is tilted down against the low-mids (-3 dB/octave
    // below 1 kHz), so it sits high but not at the top.
    expect(scene.crown.first, greaterThan(0.6));
    expect(scene.crown[5], greaterThan(0.9));
    expect(scene.crown.last, lessThan(0.1));
  });

  test('the bars follow an iOS frame, which has bands but no heard time', () {
    // Laid out as HypeAudioTap's takeBeatFrame writes it: a bare float list,
    // unsynced, the hops then 64 band levels.
    final hops = quiet();
    final raw = Float32List.fromList([
      1,
      48000,
      256 / 48000,
      0,
      hops.length.toDouble(),
      ...hops,
      64,
      -60,
      for (var b = 1; b < 64; b++) b < 8 ? -6 : -60,
    ]);
    final parsed = BeatFrame.parse(raw)!;
    expect(parsed.synced, isFalse);
    expect(parsed.heardAtUs, isNull);
    expect(parsed.bandsDb, hasLength(64));

    final scene = RadialScene();
    const now = 40000000;
    scene.addFrame(parsed, now);
    for (var t = now; t <= now + 200000; t += 16667) {
      scene.tick(t);
    }
    expect(scene.crown[5], greaterThan(0.9));
    expect(scene.crown.last, lessThan(0.1));
  });
}
