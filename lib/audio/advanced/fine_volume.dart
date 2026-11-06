import 'dart:math' as math;

/// One fine volume step: the new level, the Android music-stream index to set
/// and the engine trim (dB, never above 0) that sits on top of it.
class FineVolumeStep {
  const FineVolumeStep({
    required this.level,
    required this.systemIndex,
    required this.trimDb,
  });

  final int level;
  final int systemIndex;
  final double trimDb;
}

/// Moves [level] (0..[levels]) one step and works out how to reach it.
///
/// Android's index does the coarse part and is rounded up, so the engine only
/// ever has to turn the sound down (a trim <= 0 dB); the system volume is never
/// raised above the level the listener set. Between two system indices the
/// target is interpolated in dB from [dbAt] (the real attenuation of each
/// index, never asked for index 0); below index 1 it falls off like a plain
/// gain.
FineVolumeStep fineVolumeStep({
  required int level,
  required int levels,
  required bool up,
  required int maxIndex,
  required double Function(int index) dbAt,
}) {
  final next = (level + (up ? 1 : -1)).clamp(0, levels);
  if (next == 0) return FineVolumeStep(level: 0, systemIndex: 0, trimDb: 0);
  if (next == levels) {
    return FineVolumeStep(level: next, systemIndex: maxIndex, trimDb: 0);
  }
  // t = next * maxIndex / levels, kept in whole numbers.
  final scaled = next * maxIndex;
  final lo = scaled ~/ levels;
  final remainder = scaled % levels;
  if (remainder == 0) {
    return FineVolumeStep(level: next, systemIndex: lo, trimDb: 0);
  }
  final hi = lo + 1;
  final t = scaled / levels;
  if (lo == 0) {
    // 0 < t < 1: below the first index.
    return FineVolumeStep(
      level: next,
      systemIndex: 1,
      trimDb: 20 * math.log(t) / math.ln10,
    );
  }
  final dbLo = dbAt(lo);
  final dbHi = dbAt(hi);
  final target = dbLo + (t - lo) * (dbHi - dbLo);
  return FineVolumeStep(level: next, systemIndex: hi, trimDb: target - dbHi);
}

/// The fine level (0..[levels]) that a system music [index] stands for.
int fineLevelFromIndex({
  required int index,
  required int maxIndex,
  required int levels,
}) {
  if (maxIndex <= 0) return 0;
  return (index * levels / maxIndex).round().clamp(0, levels);
}
