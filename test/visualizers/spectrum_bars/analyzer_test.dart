import 'dart:math' as math;
import 'dart:typed_data';

import 'package:eq_app/visualizers/spectrum_bars/analyzer.dart';
import 'package:eq_app/visualizers/spectrum_bars/presets.dart';
import 'package:flutter_test/flutter_test.dart';

Float32List _flat(double p) => Float32List(256)..fillRange(0, 256, p);

void main() {
  test('bands for 32', () {
    final b = SpectrumBarsAnalyzer.bandsFor(32);
    expect(b.length, 32);
    for (var i = 0; i <= 16; i++) {
      expect(b[i].start, i);
      expect(b[i].count, 1);
    }
    for (var i = 17; i < 32; i++) {
      expect(b[i].start, greaterThanOrEqualTo(b[i - 1].start));
      expect(b[i].start + b[i].count, lessThanOrEqualTo(214));
    }
  });

  test('bands for 16', () {
    final b = SpectrumBarsAnalyzer.bandsFor(16);
    expect([for (var i = 0; i < 8; i++) b[i].start], [0, 1, 2, 4, 5, 6, 8, 9]);
  });

  test('level maps window ends', () {
    final p = spectrumBarsPresetById('spectrum_plain')!;
    for (final bass in [false, true]) {
      final w = SpectrumBarsAnalyzer.window(p.sens, p.bassSens, bass: bass);
      final bar = bass ? 0 : 5;
      final a = SpectrumBarsAnalyzer(p);
      a.update(_flat(math.pow(10, w.hi / 10).toDouble()), fps: 60, time: 0);
      // smooth 0.75 from 0: fully-lit target is 1, so bar = 1 - s.
      final s = math.pow(p.smooth, 1.0);
      expect(a.bars[bar], closeTo(1 - s, 1e-6));
      final lo = SpectrumBarsAnalyzer(p);
      lo.update(_flat(math.pow(10, w.lo / 10).toDouble()), fps: 60, time: 0);
      expect(lo.bars[bar], closeTo(0, 1e-6));
      final below = SpectrumBarsAnalyzer(p);
      below.update(
        _flat(math.pow(10, (w.lo - 20) / 10).toDouble()),
        fps: 60,
        time: 0,
      );
      expect(below.bars[bar], 0);
    }
  });

  test('smoothing is frame-rate compensated', () {
    final p = spectrumBarsPresetById('spectrum_narrow')!;
    final power = _flat(1e4);
    final a = SpectrumBarsAnalyzer(p);
    for (var i = 0; i < 2; i++) {
      a.update(power, fps: 30, time: i / 30);
    }
    final b = SpectrumBarsAnalyzer(p);
    for (var i = 0; i < 4; i++) {
      b.update(power, fps: 60, time: i / 60);
    }
    for (var i = 0; i < p.barCount; i++) {
      expect(a.bars[i], closeTo(b.bars[i], 1e-9));
    }
    expect(a.bars[10], greaterThan(0));
  });

  test('peaks hold then fall', () {
    final peaks = BarPeaks(height: .012, spacing: .002, delay: 1.5, accel: .25);
    final bars = Float64List(128);
    expect(peaks.reserve, closeTo(.014, 1e-12));
    bars[0] = .5;
    peaks.update(bars, 1, 0, 1 / 60);
    expect(peaks.pos[0], closeTo(.5 * (1 - .014) + .002, 1e-12));
    bars[0] = 0;
    peaks.update(bars, 1, .1, 1 / 60);
    final held = peaks.pos[0];
    peaks.update(bars, 1, 1.5, 1 / 60);
    expect(peaks.pos[0], held);
    peaks.update(bars, 1, 1.7, 1 / 60); // hold elapsed, switches to falling
    peaks.update(bars, 1, 1.8, 1 / 60);
    expect(peaks.pos[0], lessThan(held));
    var t = 1.8;
    for (var i = 0; i < 2000; i++) {
      t += 1 / 60;
      peaks.update(bars, 1, t, 1 / 60);
    }
    expect(peaks.pos[0], closeTo(.002, 1e-12));
  });

  test('setPreset keeps bars and resets peaks', () {
    final a = SpectrumBarsAnalyzer(spectrumBarsPresetById('spectrum_plain')!);
    a.update(_flat(1e5), fps: 60, time: 0);
    final before = a.bars[3];
    expect(before, greaterThan(0));
    expect(a.peaks.pos[3], greaterThan(0));
    a.setPreset(spectrumBarsPresetById('spectrum_quads_narrow')!);
    expect(a.bars[3], before);
    expect(a.peaks.pos[3], 0);
    expect(a.preset.id, 'spectrum_quads_narrow');
    a.setPreset(spectrumBarsPresetById('spectrum_narrow')!);
    expect(a.peaks.reserve, 0);
  });
}
