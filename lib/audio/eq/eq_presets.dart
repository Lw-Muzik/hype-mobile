import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/eq_models.dart' show ParametricPoint;
import 'eq_layout.dart';
import 'legacy_eq.dart';

/// A gain curve as (frequency, dB) points.
class EqCurve {
  EqCurve(List<double> hz, List<double> db)
    : hz = List.unmodifiable(hz),
      db = List.unmodifiable(db);

  final List<double> hz;
  final List<double> db;

  /// This curve resampled onto [centres].
  EqCurve onto(List<double> centres) =>
      EqCurve(centres, interpolateCurve(hz, db, centres));

  /// True when [o] gives the same gain, within [tol] dB, at this curve's
  /// frequencies.
  bool sameAs(EqCurve o, {double tol = 0.05}) {
    final other = o.onto(hz).db;
    for (var i = 0; i < db.length; i++) {
      if ((db[i] - other[i]).abs() > tol) return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => {'hz': hz, 'db': db};

  /// Reads a stored curve. Points with a non-positive or non-finite
  /// frequency or a non-finite gain are dropped and the rest sorted by
  /// frequency; mismatched lengths or no usable points give a flat curve.
  factory EqCurve.fromJson(Map<String, dynamic> j) {
    final hzRaw = [for (final v in j['hz'] as List) (v as num).toDouble()];
    final dbRaw = [for (final v in j['db'] as List) (v as num).toDouble()];
    if (hzRaw.length != dbRaw.length) {
      final hz = hzRaw.where((f) => f.isFinite && f > 0).toList()..sort();
      return hz.isEmpty
          ? EqCurve(kLegacyIso32, List<double>.filled(32, 0))
          : EqCurve(hz, List<double>.filled(hz.length, 0));
    }
    final pts = <MapEntry<double, double>>[
      for (var i = 0; i < hzRaw.length; i++)
        if (hzRaw[i].isFinite && hzRaw[i] > 0 && dbRaw[i].isFinite)
          MapEntry(hzRaw[i], dbRaw[i]),
    ]..sort((x, y) => x.key.compareTo(y.key));
    if (pts.isEmpty) return EqCurve(kLegacyIso32, List<double>.filled(32, 0));
    return EqCurve(
      [for (final p in pts) p.key],
      [for (final p in pts) p.value],
    );
  }
}

/// The display points of the coarsest legacy grouping (5, 10, 16, 20) in which
/// every group holds one value; otherwise all 32 points on [kLegacyIso32].
///
/// [legacyCount] is the stored legacy `eqBandCount`: its grouping is tried
/// first (what the user actually saw), then the others coarsest first.
EqCurve legacyCurve(List<double> native32, {int? legacyCount}) {
  if (native32.length != 32) {
    return EqCurve(kLegacyIso32, List<double>.filled(32, 0));
  }
  // The stored band count says exactly what the user saw: 32 sliders keep all
  // 32 points, a known grouping is the only one tried (a non-staircase curve
  // under it came from a 32-point preset and keeps its 32 points). Only an
  // unknown count falls back to coarsest-first.
  if (legacyCount == 32) return EqCurve(kLegacyIso32, native32);
  final known = legacyGroupings.where((g) => g.count == legacyCount).toList();
  final order = known.isNotEmpty ? known : legacyGroupings;
  for (final g in order) {
    var constant = true;
    for (final group in g.groups) {
      final first = native32[group.first];
      if (group.any((i) => (native32[i] - first).abs() > 1e-9)) {
        constant = false;
        break;
      }
    }
    if (constant) {
      return EqCurve(g.frequencies, [
        for (final group in g.groups) native32[group.first],
      ]);
    }
  }
  return EqCurve(kLegacyIso32, native32);
}

class EqPreset {
  EqPreset({
    required this.name,
    required this.curve,
    this.preampDb,
    List<ParametricPoint>? parametric,
    this.builtIn = false,
    this.deviceType,
  }) : parametric = parametric == null ? null : List.unmodifiable(parametric);

  final String name;
  final EqCurve curve;

  /// Null means the preset does not set the preamp.
  final double? preampDb;

  /// Null means the preset does not set the parametric EQ (like [preampDb]);
  /// an empty list means it sets it to no points.
  final List<ParametricPoint>? parametric;
  final bool builtIn;
  final String? deviceType;

  EqPreset copyWith({
    String? name,
    EqCurve? curve,
    double? preampDb,
    List<ParametricPoint>? parametric,
  }) => EqPreset(
    name: name ?? this.name,
    curve: curve ?? this.curve,
    preampDb: preampDb ?? this.preampDb,
    parametric: parametric ?? this.parametric,
    builtIn: builtIn,
    deviceType: deviceType,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'curve': curve.toJson(),
    'preampDb': preampDb,
    'parametric': parametric == null
        ? null
        : [for (final p in parametric!) p.toJson()],
    'builtIn': builtIn,
    'deviceType': deviceType,
  };

  factory EqPreset.fromJson(Map<String, dynamic> j) => EqPreset(
    name: j['name'] as String,
    curve: EqCurve.fromJson(j['curve'] as Map<String, dynamic>),
    preampDb: (j['preampDb'] as num?)?.toDouble(),
    // Built-ins never set the parametric EQ: an older v2 save wrote `[]` for
    // every built-in, which must not clear the user's points on apply.
    parametric: (j['parametric'] as List?) == null || j['builtIn'] == true
        ? null
        : [
            for (final p in j['parametric'] as List)
              ParametricPoint.fromJson(p as Map<String, dynamic>),
          ],
    builtIn: j['builtIn'] as bool? ?? false,
    deviceType: j['deviceType'] as String?,
  );
}

/// Factory curves as 32 points on [kLegacyIso32]. Designed for a +-15 dB range.
final Map<String, List<double>> _factoryTable = {
  'Flat': List.filled(32, 0.0),
  'Bass Boost': [
    13.0,
    12.5,
    12.0,
    11.0,
    10.0,
    9.0,
    7.5,
    6.0,
    4.0,
    2.5,
    1.5,
    0.5,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
  ],
  'Bass Boost Heavy': [
    15.0,
    14.5,
    14.0,
    13.0,
    12.0,
    10.0,
    8.0,
    6.0,
    4.0,
    2.0,
    0.5,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    -1.0,
    -1.5,
    -2.0,
  ],
  'Treble Boost': [
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.5,
    1.5,
    3.0,
    4.5,
    6.0,
    7.5,
    9.0,
    10.0,
    11.0,
    12.0,
    12.5,
    13.0,
    13.0,
    12.5,
    12.0,
  ],
  'Treble Boost Heavy': [
    -2.0,
    -1.5,
    -1.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.5,
    1.5,
    3.0,
    5.0,
    7.0,
    9.0,
    10.5,
    12.0,
    13.0,
    14.0,
    14.5,
    15.0,
    15.0,
    14.5,
    14.0,
    13.0,
  ],
  'V-Shape': [
    12.0,
    11.0,
    10.0,
    9.0,
    8.0,
    6.5,
    5.0,
    3.0,
    1.5,
    0.5,
    -1.0,
    -2.0,
    -3.0,
    -3.5,
    -4.0,
    -4.0,
    -4.0,
    -3.5,
    -3.0,
    -2.0,
    -0.5,
    1.5,
    3.5,
    5.5,
    7.5,
    9.0,
    10.5,
    11.5,
    12.0,
    12.0,
    11.5,
    11.0,
  ],
  'Vocal': [
    -4.0,
    -3.5,
    -3.0,
    -2.5,
    -2.0,
    -1.0,
    0.0,
    1.5,
    3.0,
    4.5,
    6.0,
    7.0,
    8.0,
    9.0,
    9.5,
    9.5,
    9.0,
    8.0,
    7.0,
    5.5,
    4.0,
    2.5,
    1.0,
    -0.5,
    -2.0,
    -3.0,
    -3.5,
    -4.0,
    -4.0,
    -3.5,
    -3.0,
    -3.0,
  ],
  'Electronic': [
    10.0,
    9.5,
    9.0,
    8.0,
    7.0,
    5.5,
    3.5,
    1.5,
    -0.5,
    -2.0,
    -3.0,
    -2.5,
    -1.0,
    0.5,
    2.0,
    3.5,
    4.5,
    4.5,
    3.5,
    2.0,
    0.5,
    1.5,
    3.5,
    5.5,
    7.5,
    9.0,
    10.0,
    10.5,
    10.5,
    10.0,
    9.0,
    8.0,
  ],
  'Rock': [
    9.0,
    8.5,
    8.0,
    7.0,
    6.0,
    4.5,
    2.5,
    0.5,
    -1.0,
    -2.5,
    -3.5,
    -3.5,
    -3.0,
    -2.0,
    -0.5,
    1.0,
    2.5,
    4.0,
    5.5,
    7.0,
    8.0,
    9.0,
    9.5,
    10.0,
    10.5,
    10.5,
    10.0,
    9.0,
    8.0,
    7.0,
    6.0,
    5.0,
  ],
  'Jazz': [
    5.0,
    4.5,
    4.0,
    3.0,
    2.0,
    1.0,
    0.0,
    -1.0,
    -2.0,
    -2.5,
    -2.0,
    -1.0,
    0.5,
    2.0,
    3.5,
    5.0,
    6.0,
    7.0,
    7.5,
    8.0,
    7.5,
    6.5,
    5.5,
    4.5,
    3.5,
    2.5,
    1.5,
    0.5,
    -0.5,
    -1.5,
    -2.0,
    -2.0,
  ],
  'Classical': [
    0.0,
    0.0,
    0.5,
    0.5,
    0.0,
    -0.5,
    -1.0,
    -2.0,
    -3.0,
    -3.5,
    -3.5,
    -3.0,
    -2.0,
    -0.5,
    1.0,
    2.5,
    4.0,
    5.5,
    6.5,
    7.5,
    8.0,
    8.0,
    7.5,
    6.5,
    5.5,
    4.0,
    2.5,
    1.0,
    -0.5,
    -1.0,
    -1.0,
    -0.5,
  ],
  'Hip Hop': [
    13.0,
    12.0,
    11.0,
    10.0,
    9.0,
    7.5,
    5.5,
    3.5,
    1.5,
    -0.5,
    -2.0,
    -3.0,
    -2.5,
    -1.5,
    -0.5,
    0.5,
    1.5,
    1.5,
    0.5,
    -0.5,
    -1.5,
    -1.5,
    -0.5,
    0.5,
    2.0,
    3.5,
    5.0,
    6.0,
    6.5,
    6.5,
    5.5,
    4.5,
  ],
  'R&B': [
    10.0,
    9.5,
    9.0,
    8.0,
    7.0,
    5.5,
    4.0,
    2.5,
    1.5,
    0.5,
    0.0,
    0.5,
    1.5,
    3.0,
    4.5,
    5.5,
    6.0,
    5.5,
    4.5,
    3.0,
    1.5,
    0.5,
    -0.5,
    -1.0,
    -0.5,
    0.5,
    1.5,
    2.5,
    3.0,
    3.0,
    2.5,
    2.0,
  ],
  'Pop': [
    -2.0,
    -1.5,
    -1.0,
    0.0,
    1.0,
    2.0,
    3.0,
    4.0,
    5.0,
    5.5,
    5.5,
    5.0,
    4.5,
    4.0,
    3.5,
    3.0,
    3.0,
    3.5,
    4.0,
    4.5,
    5.0,
    5.5,
    6.0,
    6.5,
    7.0,
    7.5,
    7.5,
    7.0,
    6.5,
    6.0,
    5.5,
    5.0,
  ],
  'Metal': [
    11.0,
    10.5,
    10.0,
    9.0,
    8.0,
    6.0,
    3.5,
    1.0,
    -1.5,
    -3.5,
    -5.0,
    -5.5,
    -5.0,
    -4.0,
    -2.5,
    -0.5,
    1.5,
    3.5,
    5.5,
    7.0,
    8.5,
    9.5,
    10.5,
    11.0,
    11.5,
    12.0,
    12.0,
    11.5,
    10.5,
    9.5,
    8.5,
    7.5,
  ],
  'Acoustic': [
    5.5,
    5.0,
    4.5,
    3.5,
    2.5,
    1.5,
    0.5,
    0.0,
    1.0,
    2.5,
    4.0,
    5.5,
    6.5,
    7.5,
    8.0,
    8.0,
    7.5,
    7.0,
    6.0,
    5.0,
    3.5,
    2.0,
    0.5,
    -0.5,
    -1.5,
    -2.5,
    -2.5,
    -2.0,
    -1.0,
    -0.5,
    0.0,
    0.0,
  ],
  'Podcast': [
    -6.0,
    -5.5,
    -5.0,
    -4.5,
    -4.0,
    -3.0,
    -2.0,
    0.0,
    2.5,
    5.0,
    7.0,
    8.5,
    9.5,
    10.0,
    10.0,
    10.0,
    9.5,
    9.0,
    8.0,
    7.0,
    5.5,
    3.5,
    1.5,
    -0.5,
    -2.5,
    -4.0,
    -5.0,
    -5.5,
    -6.0,
    -6.0,
    -5.5,
    -5.0,
  ],
  'Loudness': [
    10.0,
    9.5,
    9.0,
    8.5,
    8.0,
    7.0,
    5.5,
    4.0,
    3.0,
    2.5,
    2.0,
    2.0,
    2.0,
    2.5,
    3.0,
    3.5,
    3.5,
    3.5,
    3.0,
    2.5,
    2.0,
    2.5,
    3.5,
    5.0,
    6.5,
    8.0,
    9.0,
    9.5,
    10.0,
    10.0,
    9.5,
    9.0,
  ],
};

/// The built-in presets, in order.
List<EqPreset> factoryPresets() => [
  for (final e in _factoryTable.entries)
    EqPreset(name: e.key, curve: EqCurve(kLegacyIso32, e.value), builtIn: true),
];

/// [base], or [base] with " (2)", " (3)", ... when [taken] already has it.
String uniqueName(String base, Iterable<String> taken) {
  final set = taken.toSet();
  if (!set.contains(base)) return base;
  var n = 2;
  while (set.contains('$base ($n)')) {
    n++;
  }
  return '$base ($n)';
}

/// The preset list plus the curve that is playing.
///
/// [live] is on the current band centres. [selected] names the active preset
/// ('' when none), and [dirty] says the live curve differs from it.
class EqState {
  EqState({
    required List<EqPreset> presets,
    required this.selected,
    required this.dirty,
    required this.live,
  }) : presets = List.unmodifiable(presets);

  final List<EqPreset> presets;
  final String selected;
  final bool dirty;
  final EqCurve live;

  static const _kPresets = 'eqPresetsV2';
  static const _kSelected = 'activePresetName';
  static const _kDirty = 'eqPresetDirty';
  static const _kCurve = 'eqCurve';

  List<String> get visibleNames => [
    for (final p in presets)
      if (!p.name.startsWith('_device_')) p.name,
  ];

  bool isBuiltIn(String name) => preset(name)?.builtIn ?? false;

  EqPreset? preset(String name) {
    for (final p in presets) {
      if (p.name == name) return p;
    }
    return null;
  }

  EqState _copy({
    List<EqPreset>? presets,
    String? selected,
    bool? dirty,
    EqCurve? live,
  }) => EqState(
    presets: presets ?? this.presets,
    selected: selected ?? this.selected,
    dirty: dirty ?? this.dirty,
    live: live ?? this.live,
  );

  List<EqPreset> _replace(String name, EqPreset Function(EqPreset) f) => [
    for (final p in presets) p.name == name ? f(p) : p,
  ];

  /// Re-interpolates onto new centres: from the selected preset when the
  /// curve is unedited (keeps its resolution), otherwise from [live]. Never
  /// writes a preset.
  EqState withLayout(List<double> centres) {
    final p = preset(selected);
    final source = (!dirty && p != null) ? p.curve : live;
    return _copy(live: source.onto(centres));
  }

  EqState withBandGain(int band, double db, {required bool autoSave}) {
    if (band < 0 || band >= live.db.length) return this;
    final gains = List<double>.of(live.db)..[band] = db;
    final curve = EqCurve(live.hz, gains);
    if (autoSave && preset(selected) != null) {
      return _copy(
        presets: _replace(selected, (p) => p.copyWith(curve: curve)),
        live: curve,
        dirty: false,
      );
    }
    return _copy(live: curve, dirty: true);
  }

  /// Only presets that carry a preamp take it; the others ignore it.
  EqState withPreamp(double db, {required bool autoSave}) {
    final p = preset(selected);
    if (p == null || p.preampDb == null) return this;
    if (autoSave) {
      return _copy(
        presets: _replace(selected, (p) => p.copyWith(preampDb: db)),
      );
    }
    return p.preampDb == db ? this : _copy(dirty: true);
  }

  EqState applyPreset(String name) {
    final p = preset(name);
    if (p == null) return this;
    return _copy(selected: name, dirty: false, live: p.curve.onto(live.hz));
  }

  EqState saveAs(String name, {double? preampDb}) {
    final trimmed = name.trim();
    final unique = uniqueName(
      trimmed.isEmpty ? 'Custom' : trimmed,
      presets.map((p) => p.name),
    );
    return _copy(
      presets: [
        ...presets,
        EqPreset(name: unique, curve: live, preampDb: preampDb),
      ],
      selected: unique,
      dirty: false,
    );
  }

  EqState save({double? preampDb}) {
    if (preset(selected) == null) return this;
    return _copy(
      presets: _replace(
        selected,
        (p) => p.copyWith(curve: live, preampDb: preampDb),
      ),
      dirty: false,
    );
  }

  EqState delete(String name) {
    if (preset(name) == null) return this;
    final left = [
      for (final p in presets)
        if (p.name != name) p,
    ];
    return name == selected
        ? _copy(presets: left, selected: '', dirty: true)
        : _copy(presets: left);
  }

  /// Puts every factory preset back at its factory curve, first and in
  /// factory order. User presets follow untouched (renamed only when their
  /// name now collides).
  EqState restoreFactory() {
    final factory = factoryPresets();
    final taken = <String>{for (final f in factory) f.name};
    var newSelected = selected;
    final users = <EqPreset>[];
    for (final p in presets) {
      if (p.builtIn) continue;
      final name = uniqueName(p.name, taken);
      taken.add(name);
      if (p.name == selected && name != p.name) newSelected = name;
      users.add(
        name == p.name
            ? p
            : EqPreset(
                name: name,
                curve: p.curve,
                preampDb: p.preampDb,
                parametric: p.parametric,
                deviceType: p.deviceType,
              ),
      );
    }
    final restored = _copy(
      presets: [...factory, ...users],
      selected: newSelected,
    );
    final sel = factory.where((f) => f.name == newSelected);
    if (sel.isEmpty) return restored;
    return restored._copy(dirty: false, live: sel.first.curve.onto(live.hz));
  }

  /// Zeroes the curve, selects Flat and stores a flat curve into it.
  EqState flatten() {
    final flat = EqCurve(live.hz, List<double>.filled(live.hz.length, 0));
    final has = preset('Flat') != null;
    final list = has
        ? _replace('Flat', (p) => p.copyWith(curve: flat))
        : [EqPreset(name: 'Flat', curve: flat, builtIn: true), ...presets];
    return _copy(presets: list, selected: 'Flat', dirty: false, live: flat);
  }

  /// A per-device curve applied live; presets stay as they are. The selection
  /// is cleared (no name, unsaved), so Auto save cannot write the device curve
  /// into whichever preset happened to be selected.
  EqState withDeviceCurve(EqCurve c) =>
      _copy(selected: '', live: c.onto(live.hz), dirty: true);

  static EqState load(
    SharedPreferences prefs, {
    required List<double> centres,
  }) {
    final selected = prefs.getString(_kSelected);
    final stored = prefs.getString(_kPresets);
    if (stored != null) {
      try {
        final presets = [
          for (final j in json.decode(stored) as List)
            EqPreset.fromJson(j as Map<String, dynamic>),
        ];
        final sel = selected ?? '';
        final dirty = prefs.getBool(_kDirty) ?? false;
        final liveJson = prefs.getString(_kCurve);
        final p = presets.where((e) => e.name == sel);
        EqCurve live;
        if (!dirty && p.isNotEmpty) {
          live = p.first.curve.onto(centres);
        } else if (liveJson != null) {
          live = EqCurve.fromJson(json.decode(liveJson) as Map<String, dynamic>)
              .onto(centres);
        } else if (p.isNotEmpty) {
          live = p.first.curve.onto(centres);
        } else {
          live = EqCurve(centres, List<double>.filled(centres.length, 0));
        }
        return EqState(
          presets: presets,
          selected: sel,
          dirty: dirty,
          live: live,
        );
      } catch (_) {
        // Unreadable: fall back to migrating from the legacy keys.
      }
    }
    return _migrate(prefs, centres, selected);
  }

  static EqState _migrate(
    SharedPreferences prefs,
    List<double> centres,
    String? active,
  ) {
    final presets = factoryPresets();
    final taken = <String>{for (final p in presets) p.name};
    // The raw 32 values each preset had under the old scheme.
    final raw = <String, List<double>>{
      for (final p in presets) p.name: p.curve.db,
    };
    final legacyCount = prefs.getInt('eqBandCount');

    final legacy = prefs.getString('eqPresets');
    if (legacy != null) {
      Map<String, dynamic>? map;
      try {
        map = json.decode(legacy) as Map<String, dynamic>;
      } catch (e) {
        debugPrint('eqPresets unreadable, skipped: $e');
      }
      for (final e in (map ?? const <String, dynamic>{}).entries) {
        try {
          final j = e.value as Map<String, dynamic>;
          final gains = [
            for (final g in j['graphicGains'] as List) (g as num).toDouble(),
          ];
          if (gains.length != 32) {
            throw FormatException('expected 32 gains, got ${gains.length}');
          }
          final name = uniqueName((j['name'] as String?) ?? e.key, taken);
          final points = [
            for (final p in (j['parametric'] as List? ?? const []))
              ParametricPoint.fromJson(p as Map<String, dynamic>),
          ];
          final migratedParametric = points.isEmpty ? null : points;
          final preset = EqPreset(
            name: name,
            curve: legacyCurve(gains, legacyCount: legacyCount),
            preampDb: (j['preamp'] as num?)?.toDouble() ?? 0.0,
            // An empty list means the old preset had no points; applying it
            // used to wipe the parametric EQ, which the update must not keep.
            parametric: migratedParametric,
            deviceType: j['deviceType'] as String?,
          );
          taken.add(name);
          raw[name] = gains;
          presets.add(preset);
        } catch (err) {
          debugPrint('Skipping legacy preset "${e.key}": $err');
        }
      }
    }

    List<double>? storedRaw;
    final gainsJson = prefs.getString('graphicBandGains');
    if (gainsJson != null) {
      try {
        final g = [
          for (final v in json.decode(gainsJson) as List) (v as num).toDouble(),
        ];
        if (g.length == 32) storedRaw = g;
      } catch (_) {}
    }

    var selected = active != null && taken.contains(active) ? active : 'Flat';
    if (storedRaw != null) {
      final want = raw[selected];
      var same = want != null;
      if (same) {
        for (var i = 0; i < 32; i++) {
          if ((want[i] - storedRaw[i]).abs() > 0.05) {
            same = false;
            break;
          }
        }
      }
      if (!same) {
        selected = uniqueName('Custom', taken);
        presets.add(
          EqPreset(
            name: selected,
            curve: legacyCurve(storedRaw, legacyCount: legacyCount),
          ),
        );
      }
    }
    final sel = presets.firstWhere((p) => p.name == selected);
    return EqState(
      presets: presets,
      selected: selected,
      dirty: false,
      live: sel.curve.onto(centres),
    );
  }

  /// Writes the new keys only; the legacy `graphicBandGains` and `eqPresets`
  /// stay as they were.
  Future<void> saveTo(SharedPreferences prefs) async {
    await Future.wait([
      prefs.setString(
        _kPresets,
        json.encode([for (final p in presets) p.toJson()]),
      ),
      prefs.setString(_kSelected, selected),
      prefs.setBool(_kDirty, dirty),
      prefs.setString(_kCurve, json.encode(live.toJson())),
    ]);
  }
}
