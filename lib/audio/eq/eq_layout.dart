import 'dart:math' as math;

import 'equalizer_settings.dart';

/// Band counts the equalizer offers.
const kStandardBandCounts = [5, 10, 12, 15, 16, 24, 31, 32];

/// Counts laid out on ISO centre frequencies (first/last do not apply).
const kIsoBandCounts = {10, 15, 31};

const kIso10 = <double>[
  31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
];

const kIso15 = <double>[
  25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000,
  16000,
];

/// The 31 1/3-octave centres, 20 Hz to 20 kHz.
const kIso31 = <double>[
  20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630,
  800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000,
  12500, 16000, 20000,
];

/// The 32-point grid earlier versions stored curves on (includes 18 kHz).
const kLegacyIso32 = <double>[
  20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630,
  800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000,
  12500, 16000, 18000, 20000,
];

/// [count] centres spaced evenly in log frequency from [firstHz] to [lastHz].
List<double> logSpacedCentres(int count, double firstHz, double lastHz) {
  if (count <= 1) return [firstHz];
  final ratio = lastHz / firstHz;
  return List<double>.generate(count, (i) {
    if (i == count - 1) return lastHz;
    return firstHz * math.pow(ratio, i / (count - 1));
  });
}

/// The centre frequencies the settings describe.
List<double> bandCentres(EqualizerSettings s) {
  if (!s.usesFirstLast) {
    switch (s.bandCount) {
      case 10:
        return kIso10;
      case 15:
        return kIso15;
      case 31:
        return kIso31;
    }
  }
  final count = s.customBands ? s.customCount : s.bandCount;
  return logSpacedCentres(count, s.firstHz, s.lastHz);
}

/// Upper band edges for a crossover-style engine: geometric midpoints between
/// centres, the last one at 20 kHz (the legacy known-good maximum; a device
/// that range-checks edges would throw on more). Every edge is at most
/// 20 kHz and the edges are strictly increasing.
List<double> platformBandCutoffs(List<double> centres) {
  const maxHz = 20000.0;
  final out = List<double>.generate(centres.length, (i) {
    if (i == centres.length - 1) return maxHz;
    return math.min(math.sqrt(centres[i] * centres[i + 1]), maxHz);
  });
  // Centres at or above the limit can make edges collide: pull earlier edges
  // down just enough to keep them strictly increasing.
  for (var i = out.length - 2; i >= 0; i--) {
    if (out[i] >= out[i + 1]) out[i] = out[i + 1] * 0.9999;
  }
  return out;
}

/// Gain at [f]: linear in log2 frequency between points, holding the end
/// values outside the range.
double curveGainAt(List<double> hz, List<double> db, double f) {
  if (hz.isEmpty) return 0.0;
  if (f <= hz.first) return db.first;
  if (f >= hz.last) return db.last;
  var i = 0;
  while (i < hz.length - 2 && f >= hz[i + 1]) {
    i++;
  }
  final span = math.log(hz[i + 1] / hz[i]);
  if (span <= 0) return db[i];
  final t = math.log(f / hz[i]) / span;
  return db[i] + (db[i + 1] - db[i]) * t;
}

/// Resamples a curve onto new frequencies.
List<double> interpolateCurve(
  List<double> fromHz,
  List<double> fromDb,
  List<double> toHz,
) => [for (final f in toHz) curveGainAt(fromHz, fromDb, f)];

/// Maps any stored count to a listed one. 20 becomes 24; other unlisted counts
/// go to the nearest listed one, ties to the larger.
int nearestStandardBandCount(int count) {
  if (kStandardBandCounts.contains(count)) return count;
  if (count == 20) return 24;
  var best = kStandardBandCounts.first;
  var bestDist = (count - best).abs();
  for (final c in kStandardBandCounts) {
    final d = (count - c).abs();
    if (d < bestDist || (d == bestDist && c > best)) {
      best = c;
      bestDist = d;
    }
  }
  return best;
}

String bandCountLabel(int count) =>
    kIsoBandCounts.contains(count) ? '$count (ISO)' : '$count';
