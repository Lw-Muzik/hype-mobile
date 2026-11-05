import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/visualizers/visualizer_styles.dart';

const _ids = [
  'radial',
  'line',
  'spectrum_plain',
  'spectrum_narrow',
  'spectrum_wide',
  'spectrum_centered',
  'spectrum_centered_narrow',
  'spectrum_centered_wide',
  'spectrum_centered_reflected',
  'spectrum_reflected_wide',
  'spectrum_quads_narrow',
  'spectrum_quads_reflected',
  'spectrum_dots',
  'milkdrop',
];

const _names = [
  'Radial',
  'Waveform',
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
  'MilkDrop',
];

void main() {
  test('android list is the 14 styles in order', () {
    final l = visualizerStyles(isIos: false);
    expect(l.map((s) => s.id), _ids);
    expect(l.map((s) => s.name), _names);
    expect(l.every((s) => s.description.isNotEmpty), isTrue);
  });

  test('ios list drops milkdrop only', () {
    final l = visualizerStyles(isIos: true);
    expect(l.map((s) => s.id), _ids.where((i) => i != 'milkdrop'));
  });

  test('isSpectrumBarsStyle covers the 11 spectrum ids only', () {
    expect(_ids.where(isSpectrumBarsStyle).length, 11);
    expect(isSpectrumBarsStyle('radial'), isFalse);
    expect(isSpectrumBarsStyle('line'), isFalse);
    expect(isSpectrumBarsStyle('milkdrop'), isFalse);
  });

  group('migrateVisualizerStyle', () {
    test('retired and unknown ids become radial', () {
      for (final old in [
        null,
        'circular',
        'bars',
        'mirror_bars',
        'terrain',
        'dots',
        'silk',
        'neon_grid',
        'fractal_flame',
        'nonsense',
      ]) {
        expect(migrateVisualizerStyle(old, isIos: false), 'radial', reason: '$old');
        expect(migrateVisualizerStyle(old, isIos: true), 'radial', reason: '$old');
      }
    });

    test('listed ids are kept', () {
      for (final id in _ids) {
        expect(migrateVisualizerStyle(id, isIos: false), id);
        if (id != 'milkdrop') expect(migrateVisualizerStyle(id, isIos: true), id);
      }
    });

    test('milkdrop becomes radial on ios only', () {
      expect(migrateVisualizerStyle('milkdrop', isIos: true), 'radial');
      expect(migrateVisualizerStyle('milkdrop', isIos: false), 'milkdrop');
    });
  });
}
