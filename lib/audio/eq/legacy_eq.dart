import 'eq_layout.dart';

/// One of the earlier 5/10/16/20 slider groupings over the 32-point grid.
/// Kept only so old curves can be migrated from what the user saw.
class LegacyGrouping {
  const LegacyGrouping(this.count, this.frequencies, this.groups);

  final int count;

  /// Display frequency of each slider.
  final List<double> frequencies;

  /// Indices into the 32-point grid that each slider controlled.
  final List<List<int>> groups;
}

const _g5 = LegacyGrouping(
  5,
  [60, 230, 910, 3600, 14000],
  [
    [0, 1, 2, 3, 4, 5],
    [6, 7, 8, 9, 10],
    [11, 12, 13, 14, 15, 16, 17],
    [18, 19, 20, 21, 22, 23, 24],
    [25, 26, 27, 28, 29, 30, 31],
  ],
);

const _g10 = LegacyGrouping(
  10,
  [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000],
  [
    [0, 1],
    [2, 3, 4],
    [5, 6, 7],
    [8, 9, 10],
    [11, 12, 13, 14],
    [15, 16, 17],
    [18, 19, 20],
    [21, 22, 23, 24],
    [25, 26, 27],
    [28, 29, 30, 31],
  ],
);

const _g16 = LegacyGrouping(
  16,
  [
    22.5, 35.75, 56.5, 90, 142.5, 225, 357.5, 565, 715, 1125, 1800, 2825,
    4500, 7150, 11250, 19000,
  ],
  [
    [0, 1], [2, 3], [4, 5], [6, 7], [8, 9], [10, 11], [12, 13], [14, 15],
    [16, 17], [18, 19], [20, 21], [22, 23], [24, 25], [26, 27], [28, 29],
    [30, 31],
  ],
);

LegacyGrouping _build20() {
  final picks = <int>[for (var i = 0; i < 20; i++) (i * 31.0 / 19.0).round()];
  final unique = picks.toSet().toList()..sort();
  while (unique.length < 20) {
    for (var idx = 0; idx < 32 && unique.length < 20; idx++) {
      if (!unique.contains(idx)) {
        unique.add(idx);
        unique.sort();
        break;
      }
    }
  }
  final picked = unique.take(20).toList();
  final groups = List.generate(20, (_) => <int>[]);
  for (var native = 0; native < 32; native++) {
    var bestGroup = 0;
    var bestDist = 999;
    for (var g = 0; g < picked.length; g++) {
      final dist = (native - picked[g]).abs();
      if (dist < bestDist) {
        bestDist = dist;
        bestGroup = g;
      }
    }
    groups[bestGroup].add(native);
  }
  return LegacyGrouping(20, [for (final i in picked) kLegacyIso32[i]], groups);
}

final _g20 = _build20();

/// The legacy groupings, coarsest first.
final List<LegacyGrouping> legacyGroupings = [_g5, _g10, _g16, _g20];
