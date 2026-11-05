import 'package:flutter/foundation.dart' show listEquals;

import 'eq_layout.dart';
import 'eq_presets.dart';

enum EqPushKind { layout, allGains, bandGain }

/// One call to the engine. Every list is a fresh plain `List<double>`: the
/// platform channels cast to `List<Double>` / `[Double]` and silently drop
/// anything else (a `Float64List`, say).
///
/// - [EqPushKind.layout]: [values] are the band centres, [cutoffs] the
///   system-wide effect's band edges and [gains] the gain of every band. The
///   layout and its gains go in one call so no block plays old gains at new
///   centres.
/// - [EqPushKind.allGains]: [values] are the gain of every band.
/// - [EqPushKind.bandGain]: [band] and its gain as the one entry of [values].
class EqPush {
  const EqPush._(this.kind, {this.band, this.values, this.cutoffs, this.gains});

  factory EqPush.layout(
    List<double> centres,
    List<double> cutoffs,
    List<double> gains,
  ) => EqPush._(
    EqPushKind.layout,
    values: List<double>.from(centres),
    cutoffs: List<double>.from(cutoffs),
    gains: List<double>.from(gains),
  );

  factory EqPush.allGains(List<double> gains) =>
      EqPush._(EqPushKind.allGains, values: List<double>.from(gains));

  factory EqPush.bandGain(int band, double db) =>
      EqPush._(EqPushKind.bandGain, band: band, values: <double>[db]);

  final EqPushKind kind;
  final int? band;
  final List<double>? values;
  final List<double>? cutoffs;
  final List<double>? gains;

  @override
  String toString() => 'EqPush($kind, band: $band, values: $values)';
}

/// What the engine needs to hear to go from [before] to [after].
///
/// A new layout is one push with the gains in it (the layout always goes
/// first, and alone). On the same layout, one changed band is a single
/// `bandGain`, several are `allGains`, and nothing changed is nothing.
/// Preset names, the unsaved flag and the stored presets never reach the
/// engine.
List<EqPush> eqPushes(EqState before, EqState after) {
  final centres = after.live.hz;
  final gains = after.live.db;
  if (!listEquals(before.live.hz, centres)) {
    return [EqPush.layout(centres, platformBandCutoffs(centres), gains)];
  }
  final old = before.live.db;
  final changed = <int>[
    for (var i = 0; i < gains.length; i++)
      if (gains[i] != old[i]) i,
  ];
  if (changed.isEmpty) return const [];
  if (changed.length == 1) {
    return [EqPush.bandGain(changed.single, gains[changed.single])];
  }
  return [EqPush.allGains(gains)];
}
