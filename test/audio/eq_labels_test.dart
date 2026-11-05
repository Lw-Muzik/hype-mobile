import 'package:flutter_test/flutter_test.dart';
import 'package:eq_app/audio/eq/eq_labels.dart';
import 'package:eq_app/audio/eq/equalizer_settings.dart';

void main() {
  group('eqValueLabel', () {
    test('db', () {
      expect(eqValueLabel(6, EqValueLabels.db), '+6.0');
      expect(eqValueLabel(-4.5, EqValueLabels.db), '-4.5');
      expect(eqValueLabel(0, EqValueLabels.db), '0.0');
      expect(eqValueLabel(-0.04, EqValueLabels.db), '0.0');
      expect(toneValueLabel(-0.04, bass: true, mode: EqValueLabels.db),
          '0.0 dB');
    });
    test('percent', () {
      expect(eqValueLabel(6, EqValueLabels.percent), '+40%');
      expect(eqValueLabel(-15, EqValueLabels.percent), '-100%');
      expect(eqValueLabel(0, EqValueLabels.percent), '0%');
    });
    test('hidden', () => expect(eqValueLabel(6, EqValueLabels.hidden), isNull));
  });

  group('toneValueLabel', () {
    test('percent', () {
      expect(toneValueLabel(9, bass: true, mode: EqValueLabels.percent), '40%');
      expect(
          toneValueLabel(9, bass: false, mode: EqValueLabels.percent), '60%');
    });
    test('db', () {
      expect(toneValueLabel(9, bass: true, mode: EqValueLabels.db), '9.0 dB');
      expect(toneValueLabel(0, bass: true, mode: EqValueLabels.db), '0.0 dB');
    });
    test('hidden', () {
      expect(toneValueLabel(9, bass: true, mode: EqValueLabels.hidden), isNull);
    });
  });
}
