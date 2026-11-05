import 'package:flutter/material.dart';

/// One entry of the visualizer picker (Visual page and Settings chips).
class VisualizerStyle {
  const VisualizerStyle(this.id, this.name, this.description, this.icon);

  final String id;
  final String name;
  final String description;
  final IconData icon;
}

const _kSpectrumIds = {
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
};

const _kStyles = <VisualizerStyle>[
  VisualizerStyle('radial', 'Radial', 'Circular burst', Icons.flare_rounded),
  VisualizerStyle(
    'line',
    'Waveform',
    'Oscilloscope',
    Icons.show_chart_rounded,
  ),
  VisualizerStyle(
    'spectrum_plain',
    'Spectrum Plain',
    'Bars with falling peaks',
    Icons.bar_chart_rounded,
  ),
  VisualizerStyle(
    'spectrum_narrow',
    'Spectrum Narrow',
    'Fine blue bars',
    Icons.bar_chart_rounded,
  ),
  VisualizerStyle(
    'spectrum_wide',
    'Spectrum Wide',
    'Rounded pills',
    Icons.bar_chart_rounded,
  ),
  VisualizerStyle(
    'spectrum_centered',
    'Spectrum Centered',
    'White bars from the middle',
    Icons.align_vertical_center_rounded,
  ),
  VisualizerStyle(
    'spectrum_centered_narrow',
    'Spectrum Centered Narrow',
    'Glowing mirrored bars',
    Icons.align_vertical_center_rounded,
  ),
  VisualizerStyle(
    'spectrum_centered_wide',
    'Spectrum Centered Wide',
    'Wide rounded bars',
    Icons.align_vertical_center_rounded,
  ),
  VisualizerStyle(
    'spectrum_centered_reflected',
    'Spectrum Centered Reflected',
    'Bass in the middle, with trails',
    Icons.align_vertical_center_rounded,
  ),
  VisualizerStyle(
    'spectrum_reflected_wide',
    'Spectrum Reflected Wide',
    'Wide mirrored bars',
    Icons.align_vertical_center_rounded,
  ),
  VisualizerStyle(
    'spectrum_quads_narrow',
    'Spectrum Quads Narrow',
    'LED cells with peaks',
    Icons.grid_on_rounded,
  ),
  VisualizerStyle(
    'spectrum_quads_reflected',
    'Spectrum Quads Reflected',
    'Mirrored LED cells',
    Icons.grid_on_rounded,
  ),
  VisualizerStyle(
    'spectrum_dots',
    'Spectrum Dots',
    'Drifting dot columns',
    Icons.blur_linear_rounded,
  ),
  VisualizerStyle(
    'milkdrop',
    'MilkDrop',
    'MilkDrop presets',
    Icons.blur_on_rounded,
  ),
];

/// The styles the picker offers, in display order. MilkDrop is Android only.
List<VisualizerStyle> visualizerStyles({required bool isIos}) => [
  for (final s in _kStyles)
    if (!(isIos && s.id == 'milkdrop')) s,
];

/// True for the fixed-colour spectrum bar styles.
bool isSpectrumBarsStyle(String id) => _kSpectrumIds.contains(id);

/// Maps a stored style onto one that still exists. Styles from earlier
/// versions (circular, bars, mirror_bars, terrain, dots, silk, ...), unknown
/// values and null become 'radial'; 'milkdrop' does too on iOS.
String migrateVisualizerStyle(String? stored, {required bool isIos}) {
  if (stored == null) return 'radial';
  for (final s in visualizerStyles(isIos: isIos)) {
    if (s.id == stored) return stored;
  }
  return 'radial';
}
