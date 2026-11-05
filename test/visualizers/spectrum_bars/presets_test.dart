import 'dart:ui';

import 'package:eq_app/visualizers/spectrum_bars/analyzer.dart';
import 'package:eq_app/visualizers/spectrum_bars/presets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const ids = [
    'plain',
    'narrow',
    'wide',
    'centered',
    'centered_narrow',
    'centered_wide',
    'centered_reflected',
    'reflected_wide',
    'quads_narrow',
    'quads_reflected',
    'dots',
  ];
  const names = [
    'Spectrum Plain',
    'Spectrum Narrow',
    'Spectrum Wide',
    'Spectrum Centered',
    'Spectrum Centered Narrow',
    'Spectrum Centered Wide',
    'Spectrum Centered Reflected',
    'Spectrum Reflected Wide',
    'Spectrum Quads Narrow',
    'Spectrum Quads Reflected',
    'Spectrum Dots',
  ];

  test('eleven presets in order with ids and names', () {
    expect(kSpectrumBarsPresets.length, 11);
    expect(kSpectrumBarsPresets.map((p) => p.id).toList(), [
      for (final i in ids) 'spectrum_$i',
    ]);
    expect(kSpectrumBarsPresets.map((p) => p.name).toList(), names);
  });

  test('bar counts and decay multipliers', () {
    expect(kSpectrumBarsPresets.map((p) => p.barCount).toList(), [
      32,
      128,
      16,
      128,
      64,
      16,
      32,
      16,
      32,
      24,
      64,
    ]);
    expect(
      kSpectrumBarsPresets
          .map((p) => (p.decayMultiplier * 255).round())
          .toList(),
      [239, 0, 0, 0, 0, 0, 242, 242, 229, 0, 245],
    );
    expect(kSpectrumBarsPresets.first.hasPeaks, isTrue);
    expect(kSpectrumBarsPresets[1].hasPeaks, isFalse);
    expect(kSpectrumBarsPresets.first.hasTrail, isTrue);
    expect(kSpectrumBarsPresets[1].hasTrail, isFalse);
  });

  test('lookup by id', () {
    expect(spectrumBarsPresetById('nope'), isNull);
    expect(spectrumBarsPresetById('spectrum_dots')!.name, 'Spectrum Dots');
  });

  test('colours spot-check', () {
    final plain = spectrumBarsPresetById('spectrum_plain')!;
    expect(plain.colorT, const Color(0xFF768BBF));
    expect(plain.colorB, const Color(0xFF94A2C3));
    expect(plain.colorR, const Color(0x00000000));
    expect(plain.peakB, const Color(0xFF94A2C3));
    final cn = spectrumBarsPresetById('spectrum_centered_narrow')!;
    expect(cn.colorB, const Color(0xFF050709));
    expect(cn.thrR, const Color(0xFF050709));
    expect(cn.thrT, const Color(0xFF98C8FF));
    final dots = spectrumBarsPresetById('spectrum_dots')!;
    expect(dots.colorR, const Color(0xFF94A2C3));
    expect(dots.thrT, const Color(0xFFCAC3FF));
    expect(dots.thrB, const Color(0xFF7A87FF));
    expect(dots.zoom, .999);
    expect(dots.zoomExp, 1.05);
    expect(dots.sy, .75);
  });

  test('windows match the record', () {
    const exp = {
      'plain': [-5.00, 37.50, 5.75, 42.75],
      'narrow': [-4.00, 36.75, 10.30, 45.00],
      'wide': [0.50, 33.38, 16.15, 40.50],
      'centered': [-5.00, 37.50, 8.00, 45.00],
      'centered_narrow': [-5.00, 37.50, 8.00, 45.00],
      'centered_wide': [-5.00, 37.50, 8.00, 45.00],
      'centered_reflected': [3.00, 31.50, 22.35, 40.95],
      'reflected_wide': [3.00, 31.50, 22.35, 40.95],
      'quads_narrow': [1.00, 33.00, 19.55, 42.75],
      'quads_reflected': [0.00, 33.75, 15.00, 40.50],
      'dots': [4.00, 30.75, 24.20, 40.50],
    };
    exp.forEach((suffix, v) {
      final p = spectrumBarsPresetById('spectrum_$suffix')!;
      final n = SpectrumBarsAnalyzer.window(p.sens, p.bassSens, bass: false);
      final b = SpectrumBarsAnalyzer.window(p.sens, p.bassSens, bass: true);
      expect(n.lo, closeTo(v[0], .01), reason: '$suffix lo');
      expect(n.hi, closeTo(v[1], .01), reason: '$suffix hi');
      expect(b.lo, closeTo(v[2], .01), reason: '$suffix bass lo');
      expect(b.hi, closeTo(v[3], .01), reason: '$suffix bass hi');
    });
  });
}
