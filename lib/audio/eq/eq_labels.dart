import 'equalizer_settings.dart';

/// Value text for an EQ band, or null when labels are hidden.
///
/// Shows the value the user set, not the smoothed gain the DSP is chasing.
/// Percent is dB / 15 of the band range.
String? eqValueLabel(double db, EqValueLabels mode) {
  switch (mode) {
    case EqValueLabels.hidden:
      return null;
    case EqValueLabels.db:
      // Rounded before the sign test, so -0.04 reads "0.0", not "-0.0".
      final r = (db * 10).round() / 10;
      return '${r > 0 ? '+' : ''}${(r == 0 ? 0.0 : r).toStringAsFixed(1)}';
    case EqValueLabels.percent:
      final p = (db / 15 * 100).round();
      return '${p > 0 ? '+' : ''}$p%';
  }
}

/// Value text for a Tone knob, or null when labels are hidden.
///
/// The knob's X is bass dB / 22.5 and treble dB / 15; percent is X * 100.
String? toneValueLabel(
  double db, {
  required bool bass,
  required EqValueLabels mode,
}) {
  switch (mode) {
    case EqValueLabels.hidden:
      return null;
    case EqValueLabels.db:
      final r = (db * 10).round() / 10;
      return '${(r == 0 ? 0.0 : r).toStringAsFixed(1)} dB';
    case EqValueLabels.percent:
      return '${(db / (bass ? 22.5 : 15) * 100).round()}%';
  }
}
