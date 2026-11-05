import 'package:eq_app/audio/eq/eq_layout.dart';
import 'package:eq_app/audio/eq/equalizer_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('bandCentres', () {
    test('default settings give the ISO 10 centres', () {
      expect(bandCentres(const EqualizerSettings()), kIso10);
    });

    test('31 bands give the 1/3 octave centres', () {
      final c = bandCentres(const EqualizerSettings(bandCount: 31));
      expect(c, kIso31);
      expect(c.length, 31);
      expect(c.first, 20);
      expect(c.last, 20000);
    });

    test('15 bands give the ISO 15 centres', () {
      expect(bandCentres(const EqualizerSettings(bandCount: 15)), kIso15);
    });

    test('logSpacedCentres(5, 20, 16000)', () {
      final c = logSpacedCentres(5, 20, 16000);
      const want = [20, 106.37, 565.69, 3008.47, 16000];
      for (var i = 0; i < 5; i++) {
        // The brief rounds 3008.4825 to 3008.47, so allow 0.02.
        expect(c[i], closeTo(want[i], 0.02));
      }
    });

    test('24 bands run from first to last', () {
      final c = bandCentres(const EqualizerSettings(bandCount: 24));
      expect(c.length, 24);
      expect(c.first, closeTo(20, 1e-9));
      expect(c.last, closeTo(16000, 1e-6));
    });

    test('custom bands use customCount and first/last', () {
      final c = bandCentres(const EqualizerSettings(
          customBands: true, customCount: 7, firstHz: 30, lastHz: 18000));
      expect(c, logSpacedCentres(7, 30, 18000));
    });

    test('platformBandCutoffs', () {
      final c = platformBandCutoffs([1000, 2000, 4000]);
      expect(c[0], closeTo(1414.21, 0.01));
      expect(c[1], closeTo(2828.43, 0.01));
      expect(c[2], 20000);
    });

    test('platformBandCutoffs ends at 20 kHz, strictly increasing', () {
      final c = platformBandCutoffs([12500, 16000, 20000]);
      expect(c[1], closeTo(17888.54, 0.01));
      expect(c.last, 20000);
      for (final hz in [
        [16000.0, 20000.0],
        [18000.0, 20000.0, 22000.0],
        [20000.0, 21000.0, 24000.0],
      ]) {
        final e = platformBandCutoffs(hz);
        expect(e.every((x) => x <= 20000), isTrue, reason: '$hz -> $e');
        for (var i = 1; i < e.length; i++) {
          expect(e[i], greaterThan(e[i - 1]), reason: '$hz -> $e');
        }
      }
    });
  });

  group('interpolation', () {
    test('midpoint in log frequency', () {
      expect(interpolateCurve([100, 1000], [0, 10], [316.228])[0],
          closeTo(5.0, 1e-5));
    });

    test('holds the end values outside the range', () {
      final r = interpolateCurve([100, 1000], [0, 10], [50, 2000]);
      expect(r, [0, 10]);
    });

    test('source frequencies give the source gains exactly', () {
      final hz = [31.0, 63.0, 125.0, 250.0];
      final db = [1.0, 2.5, -3.0, 4.0];
      expect(interpolateCurve(hz, db, hz), db);
    });
  });

  group('counts', () {
    test('nearestStandardBandCount', () {
      expect(nearestStandardBandCount(20), 24);
      expect(nearestStandardBandCount(32), 32);
      expect(nearestStandardBandCount(5), 5);
      expect(nearestStandardBandCount(7), 5);
      expect(nearestStandardBandCount(11), 12);
    });

    test('labels', () {
      expect(bandCountLabel(10), '10 (ISO)');
      expect(bandCountLabel(15), '15 (ISO)');
      expect(bandCountLabel(31), '31 (ISO)');
      expect(bandCountLabel(24), '24');
    });
  });
}
