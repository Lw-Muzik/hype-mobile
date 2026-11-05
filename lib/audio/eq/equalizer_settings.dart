import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../dsp_core.dart' show isExistingInstall;
import 'eq_layout.dart';

enum EqValueLabels {
  hidden('Hidden'),
  db('dB'),
  percent('%');

  const EqValueLabels(this.label);
  final String label;
}

/// Equalizer screen settings: band layout, tone shelves, labels and Auto save.
@immutable
class EqualizerSettings {
  const EqualizerSettings({
    this.bandCount = 10,
    this.customBands = false,
    this.customCount = 10,
    this.firstHz = 20,
    this.lastHz = 16000,
    this.bassFreq = 90,
    this.bassQ = 0.80,
    this.trebleFreq = 10000,
    this.trebleQ = 0.60,
    this.eqValues = EqValueLabels.db,
    this.toneValues = EqValueLabels.percent,
    this.autoSave = true,
    this.smoothGains = true,
    this.suggestAutoEq = true,
  });

  final int bandCount;
  final bool customBands;
  final int customCount;
  final double firstHz;
  final double lastHz;
  final double bassFreq;
  final double bassQ;
  final double trebleFreq;
  final double trebleQ;
  final EqValueLabels eqValues;
  final EqValueLabels toneValues;
  final bool autoSave;
  final bool smoothGains;
  final bool suggestAutoEq;

  static const _kBandCount = 'eqBandCount';
  static const _kCustomBands = 'eqCustomBands';
  static const _kCustomCount = 'eqCustomCount';
  static const _kFirstHz = 'eqFirstHz';
  static const _kLastHz = 'eqLastHz';
  static const _kBassFreq = 'bassFreq';
  static const _kBassQ = 'bassQ';
  static const _kTrebleFreq = 'trebleFreq';
  static const _kTrebleQ = 'trebleQ';
  static const _kEqValues = 'eqValueLabels';
  static const _kToneValues = 'toneValueLabels';
  static const _kAutoSave = 'eqAutoSave';
  static const _kSmoothGains = 'eqSmoothGains';
  static const _kSuggestAutoEq = 'eqSuggestAutoEq';

  /// First/Last frequency apply to every layout that is not an ISO one.
  bool get usesFirstLast => customBands || !kIsoBandCounts.contains(bandCount);

  static int normBandCount(num v) => nearestStandardBandCount(v.round());
  static int normCustomCount(num v) => v.round().clamp(5, 32);
  static double normFirstHz(double v) => v.clamp(5.0, 200.0).roundToDouble();
  static double normLastHz(double v) =>
      ((v.clamp(14000.0, 20000.0)) / 500).round() * 500.0;
  static double normBassFreq(double v) => v.clamp(20.0, 250.0).toDouble();
  static double normTrebleFreq(double v) => v.clamp(5000.0, 15000.0).toDouble();
  static double normQ(double v) => v.clamp(0.1, 2.0).toDouble();

  /// Bass shelf gain in dB (tone X 0..1 maps to 0..22.5 dB).
  static double normBassGainDb(double v) => v.clamp(0.0, 22.5).toDouble();
  static double normTrebleGainDb(double v) => v.clamp(0.0, 15.0).toDouble();

  static EqValueLabels _label(String? name, EqValueLabels fallback) {
    for (final l in EqValueLabels.values) {
      if (l.name == name) return l;
    }
    return fallback;
  }

  static double? _num(SharedPreferences p, String key) {
    final v = p.get(key);
    return v is num ? v.toDouble() : null;
  }

  static bool? _bool(SharedPreferences p, String key) {
    final v = p.get(key);
    return v is bool ? v : null;
  }

  static String? _string(SharedPreferences p, String key) {
    final v = p.get(key);
    return v is String ? v : null;
  }

  static EqualizerSettings load(SharedPreferences prefs) {
    final existing = isExistingInstall(prefs);
    return EqualizerSettings(
      bandCount: normBandCount(_num(prefs, _kBandCount) ?? (existing ? 32 : 10)),
      customBands: _bool(prefs, _kCustomBands) ?? false,
      customCount: normCustomCount(_num(prefs, _kCustomCount) ?? 10),
      firstHz: normFirstHz(_num(prefs, _kFirstHz) ?? 20),
      lastHz: normLastHz(_num(prefs, _kLastHz) ?? (existing ? 20000 : 16000)),
      bassFreq: normBassFreq(_num(prefs, _kBassFreq) ?? (existing ? 80 : 90)),
      bassQ: normQ(_num(prefs, _kBassQ) ?? (existing ? 0.707 : 0.80)),
      trebleFreq: normTrebleFreq(_num(prefs, _kTrebleFreq) ?? 10000),
      trebleQ: normQ(_num(prefs, _kTrebleQ) ?? (existing ? 0.707 : 0.60)),
      eqValues: _label(_string(prefs, _kEqValues), EqValueLabels.db),
      toneValues: _label(_string(prefs, _kToneValues), EqValueLabels.percent),
      autoSave: _bool(prefs, _kAutoSave) ?? true,
      smoothGains: _bool(prefs, _kSmoothGains) ?? true,
      suggestAutoEq: _bool(prefs, _kSuggestAutoEq) ?? true,
    );
  }

  Future<void> save(SharedPreferences prefs) async {
    await Future.wait([
      prefs.setInt(_kBandCount, bandCount),
      prefs.setBool(_kCustomBands, customBands),
      prefs.setInt(_kCustomCount, customCount),
      prefs.setDouble(_kFirstHz, firstHz),
      prefs.setDouble(_kLastHz, lastHz),
      prefs.setDouble(_kBassFreq, bassFreq),
      prefs.setDouble(_kBassQ, bassQ),
      prefs.setDouble(_kTrebleFreq, trebleFreq),
      prefs.setDouble(_kTrebleQ, trebleQ),
      prefs.setString(_kEqValues, eqValues.name),
      prefs.setString(_kToneValues, toneValues.name),
      prefs.setBool(_kAutoSave, autoSave),
      prefs.setBool(_kSmoothGains, smoothGains),
      prefs.setBool(_kSuggestAutoEq, suggestAutoEq),
    ]);
  }

  EqualizerSettings copyWith({
    int? bandCount,
    bool? customBands,
    int? customCount,
    double? firstHz,
    double? lastHz,
    double? bassFreq,
    double? bassQ,
    double? trebleFreq,
    double? trebleQ,
    EqValueLabels? eqValues,
    EqValueLabels? toneValues,
    bool? autoSave,
    bool? smoothGains,
    bool? suggestAutoEq,
  }) => EqualizerSettings(
    bandCount: normBandCount(bandCount ?? this.bandCount),
    customBands: customBands ?? this.customBands,
    customCount: normCustomCount(customCount ?? this.customCount),
    firstHz: normFirstHz(firstHz ?? this.firstHz),
    lastHz: normLastHz(lastHz ?? this.lastHz),
    bassFreq: normBassFreq(bassFreq ?? this.bassFreq),
    bassQ: normQ(bassQ ?? this.bassQ),
    trebleFreq: normTrebleFreq(trebleFreq ?? this.trebleFreq),
    trebleQ: normQ(trebleQ ?? this.trebleQ),
    eqValues: eqValues ?? this.eqValues,
    toneValues: toneValues ?? this.toneValues,
    autoSave: autoSave ?? this.autoSave,
    smoothGains: smoothGains ?? this.smoothGains,
    suggestAutoEq: suggestAutoEq ?? this.suggestAutoEq,
  );

  @override
  bool operator ==(Object other) =>
      other is EqualizerSettings &&
      other.bandCount == bandCount &&
      other.customBands == customBands &&
      other.customCount == customCount &&
      other.firstHz == firstHz &&
      other.lastHz == lastHz &&
      other.bassFreq == bassFreq &&
      other.bassQ == bassQ &&
      other.trebleFreq == trebleFreq &&
      other.trebleQ == trebleQ &&
      other.eqValues == eqValues &&
      other.toneValues == toneValues &&
      other.autoSave == autoSave &&
      other.smoothGains == smoothGains &&
      other.suggestAutoEq == suggestAutoEq;

  @override
  int get hashCode => Object.hash(
    bandCount, customBands, customCount, firstHz, lastHz, bassFreq, bassQ,
    trebleFreq, trebleQ, eqValues, toneValues, autoSave, smoothGains,
    suggestAutoEq,
  );
}
