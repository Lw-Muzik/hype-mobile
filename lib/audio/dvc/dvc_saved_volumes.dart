import 'dart:convert';

/// The listener's own system music volume, saved per output while Direct
/// Volume Control holds the system volume at maximum.
///
/// Each output (device key: type plus a stable id when known) has its own saved
/// original index. The rules, mirrored by the native `DvcController` (which
/// persists the same JSON in its own preferences):
///
/// * enabling on output D saves D's current index if D has none yet, and only
///   then may D be raised ([enable], [canRaise]); a device found at maximum is
///   never saved as maximum (see [dvcSafeOriginal]); an existing entry is
///   refreshed when D is not at maximum (the listener changed it);
/// * a release is only for an output change and writes nothing ([release]);
///   see [dvcOutputChanged];
/// * a real disable restores every output that has a saved original: the active
///   one now, the others the moment each becomes active again ([realDisable],
///   [deviceActive]). An entry is written back only if that output is still at
///   maximum (our own raise); if the listener moved it, the entry is dropped.
///
/// A restore applies the value saved when DVC was enabled, even if the listener
/// changed that output's volume while it was away and it is back at maximum.
class DvcSavedVolumes {
  const DvcSavedVolumes({this.saved = const {}, this.disabling = false});

  /// Device key -> saved original index.
  final Map<String, int> saved;

  /// A real disable has happened and entries are being handed back.
  final bool disabling;

  /// The state after enabling on [device] at volume [index] of [max]. An
  /// unknown (empty) key saves nothing, so it can never be raised.
  DvcSavedVolumes enable(String device, int index, int max) {
    if (device.isEmpty) return DvcSavedVolumes(saved: saved);
    final existing = saved[device];
    final int value;
    if (existing == null) {
      value = dvcSafeOriginal(index, max);
    } else if (index != max) {
      value = index; // the listener changed it while away: refresh
    } else {
      value = existing; // still at our raise: keep the original
    }
    return DvcSavedVolumes(saved: {...saved, device: value});
  }

  /// Whether [device] may be raised: only with an original already saved.
  bool canRaise(String device) => device.isNotEmpty && saved.containsKey(device);

  /// A release (an output change): nothing is written, nothing is forgotten.
  DvcSavedVolumes release() => this;

  /// A real disable while on [device] at [index] of [max].
  DvcRestoreResult realDisable(String device, int index, int max) =>
      DvcSavedVolumes(saved: saved, disabling: true)
          .deviceActive(device, index, max);

  /// [device] became the active output at [index] of [max].
  DvcRestoreResult deviceActive(String device, int index, int max) {
    final idx = saved[device];
    if (!disabling || idx == null) return DvcRestoreResult(this, null);
    final rest = {...saved}..remove(device);
    return DvcRestoreResult(
      DvcSavedVolumes(saved: rest, disabling: rest.isNotEmpty),
      index == max ? idx : null, // moved by the listener: drop, do not write
    );
  }

  String toJson() => jsonEncode({'saved': saved, 'disabling': disabling});

  static DvcSavedVolumes fromJson(String? text) {
    if (text == null) return const DvcSavedVolumes();
    try {
      final m = jsonDecode(text) as Map<String, dynamic>;
      return DvcSavedVolumes(
        saved: {
          for (final e in (m['saved'] as Map<String, dynamic>).entries)
            e.key: (e.value as num).toInt(),
        },
        disabling: m['disabling'] as bool? ?? false,
      );
    } catch (_) {
      return const DvcSavedVolumes();
    }
  }
}

/// The new state and the index to write to the active output (null: none).
class DvcRestoreResult {
  const DvcRestoreResult(this.state, this.restoreIndex);
  final DvcSavedVolumes state;
  final int? restoreIndex;
}

/// A volume to save as an original: the current index, but never the maximum
/// (an output found at maximum was most likely raised already; half is a safe
/// stand-in rather than blasting it on restore).
int dvcSafeOriginal(int index, int max) =>
    index >= max ? (max * 0.5).round() : index;

/// Whether a device key identifies one output: the built-in speaker, or a type
/// with a stable id ("bluetooth:AA:BB..."). A bare type ("bluetooth") could be
/// any of several devices.
bool dvcKeyIsStable(String key) => key == 'speaker' || key.contains(':');

/// Whether the route gate turning DVC off is an OUTPUT change (release: write
/// nothing, the old output keeps its original) or the same output (a real
/// disable: restore its original, then master to the DVC-off value). Only a
/// route event can change the output; a settings-driven re-evaluation never
/// does. Any doubt (a key without a stable id) counts as changed.
bool dvcOutputChanged({
  required String? previous,
  required String next,
  required bool routeEvent,
}) {
  if (!routeEvent) return false;
  return previous != next || !dvcKeyIsStable(next);
}
