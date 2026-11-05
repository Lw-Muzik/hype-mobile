import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../eq/autoeq_suggest.dart' show normaliseDeviceName;
import '../headset/output_kind.dart';

/// What Hype does while one output is active. Every field defaults to "leave
/// things as they are".
class OutputProfile {
  const OutputProfile({
    this.eqPreset,
    this.noEqTone = false,
    this.noDuck = false,
    this.ignoreFocus = false,
    this.noDvc = false,
    this.noHeadroomReduction = false,
    this.autoEq,
  });

  /// The EQ preset applied when this output becomes active; null leaves the
  /// curve alone. A name starting `_device_` is a curve kept by the old "link
  /// all devices" switch.
  final String? eqPreset;

  /// EQ and tone are bypassed on this output.
  final bool noEqTone;

  /// Audio focus pauses instead of ducking.
  final bool noDuck;

  /// Audio focus losses and gains are ignored.
  final bool ignoreFocus;

  /// Direct Volume Control stays off on this output (Android).
  final bool noDvc;

  /// The headroom gain reduction is skipped on this output.
  final bool noHeadroomReduction;

  /// The AutoEq headphone profile bound to a named device.
  final String? autoEq;

  bool get isDefault => this == const OutputProfile();

  OutputProfile copyWith({
    Object? eqPreset = _keep,
    bool? noEqTone,
    bool? noDuck,
    bool? ignoreFocus,
    bool? noDvc,
    bool? noHeadroomReduction,
    Object? autoEq = _keep,
  }) => OutputProfile(
    eqPreset: identical(eqPreset, _keep) ? this.eqPreset : eqPreset as String?,
    noEqTone: noEqTone ?? this.noEqTone,
    noDuck: noDuck ?? this.noDuck,
    ignoreFocus: ignoreFocus ?? this.ignoreFocus,
    noDvc: noDvc ?? this.noDvc,
    noHeadroomReduction: noHeadroomReduction ?? this.noHeadroomReduction,
    autoEq: identical(autoEq, _keep) ? this.autoEq : autoEq as String?,
  );

  static const _keep = Object();

  Map<String, dynamic> toJson() => {
    'eqPreset': eqPreset,
    'noEqTone': noEqTone,
    'noDuck': noDuck,
    'ignoreFocus': ignoreFocus,
    'noDvc': noDvc,
    'noHeadroomReduction': noHeadroomReduction,
    'autoEq': autoEq,
  };

  factory OutputProfile.fromJson(Map<String, dynamic> j) => OutputProfile(
    eqPreset: j['eqPreset'] as String?,
    noEqTone: j['noEqTone'] == true,
    noDuck: j['noDuck'] == true,
    ignoreFocus: j['ignoreFocus'] == true,
    noDvc: j['noDvc'] == true,
    noHeadroomReduction: j['noHeadroomReduction'] == true,
    autoEq: j['autoEq'] as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is OutputProfile &&
      other.eqPreset == eqPreset &&
      other.noEqTone == noEqTone &&
      other.noDuck == noDuck &&
      other.ignoreFocus == ignoreFocus &&
      other.noDvc == noDvc &&
      other.noHeadroomReduction == noHeadroomReduction &&
      other.autoEq == autoEq;

  @override
  int get hashCode => Object.hash(
    eqPreset,
    noEqTone,
    noDuck,
    ignoreFocus,
    noDvc,
    noHeadroomReduction,
    autoEq,
  );
}

/// A Bluetooth or USB device Hype has seen, and the profile of its own if it
/// has one (null: it follows its kind).
class DeviceProfile {
  const DeviceProfile({required this.name, required this.kind, this.profile});

  final String name;
  final AudioOutputKind kind;
  final OutputProfile? profile;
}

/// The profile of each output kind and of each named device, saved as JSON.
class OutputProfiles {
  const OutputProfiles({this.kinds = const {}, this.devices = const {}});

  static const prefKey = 'outputProfilesV1';

  final Map<AudioOutputKind, OutputProfile> kinds;

  /// By [normaliseDeviceName].
  final Map<String, DeviceProfile> devices;

  OutputProfiles withKind(AudioOutputKind kind, OutputProfile p) =>
      OutputProfiles(kinds: {...kinds, kind: p}, devices: devices);

  /// Gives [name] a profile of its own.
  OutputProfiles withDevice(
    String name,
    AudioOutputKind kind,
    OutputProfile? p,
  ) {
    final key = normaliseDeviceName(name);
    if (key.isEmpty) return this;
    return OutputProfiles(
      kinds: kinds,
      devices: {
        ...devices,
        key: DeviceProfile(name: name, kind: kind, profile: p),
      },
    );
  }

  /// Lists [name] without changing its profile.
  OutputProfiles rememberDevice(String name, AudioOutputKind kind) {
    final key = normaliseDeviceName(name);
    if (key.isEmpty) return this;
    final old = devices[key];
    if (old != null) return this;
    return withDevice(name, kind, null);
  }

  OutputProfiles forgetDevice(String name) {
    final key = normaliseDeviceName(name);
    if (!devices.containsKey(key)) return this;
    return OutputProfiles(kinds: kinds, devices: {...devices}..remove(key));
  }

  Map<String, dynamic> toJson() => {
    'v': 1,
    'kinds': {for (final e in kinds.entries) e.key.name: e.value.toJson()},
    'devices': {
      for (final e in devices.entries)
        e.key: {
          'name': e.value.name,
          'kind': e.value.kind.name,
          'profile': e.value.profile?.toJson(),
        },
    },
  };

  factory OutputProfiles.fromJson(Map<String, dynamic> j) {
    AudioOutputKind? kindOf(Object? n) {
      for (final k in AudioOutputKind.values) {
        if (k.name == n) return k;
      }
      return null;
    }

    final kinds = <AudioOutputKind, OutputProfile>{};
    final rawKinds = j['kinds'];
    if (rawKinds is Map) {
      for (final e in rawKinds.entries) {
        final k = kindOf(e.key);
        if (k != null && e.value is Map) {
          kinds[k] = OutputProfile.fromJson(
            Map<String, dynamic>.from(e.value as Map),
          );
        }
      }
    }
    final devices = <String, DeviceProfile>{};
    final rawDevices = j['devices'];
    if (rawDevices is Map) {
      for (final e in rawDevices.entries) {
        final v = e.value;
        if (v is! Map) continue;
        final k = kindOf(v['kind']);
        final name = v['name'];
        if (k == null || name is! String) continue;
        final p = v['profile'];
        devices[e.key as String] = DeviceProfile(
          name: name,
          kind: k,
          profile: p is Map
              ? OutputProfile.fromJson(Map<String, dynamic>.from(p))
              : null,
        );
      }
    }
    return OutputProfiles(kinds: kinds, devices: devices);
  }

  /// Empty when nothing is saved or the data is unreadable.
  static OutputProfiles load(SharedPreferences prefs) {
    final s = prefs.getString(prefKey);
    if (s == null) return const OutputProfiles();
    try {
      return OutputProfiles.fromJson(
        Map<String, dynamic>.from(json.decode(s) as Map),
      );
    } catch (_) {
      return const OutputProfiles();
    }
  }

  Future<void> save(SharedPreferences prefs) =>
      prefs.setString(prefKey, json.encode(toJson()));
}

/// The profile for the output now active: a named device's own, else its
/// kind's, else the default.
OutputProfile resolveProfile(
  OutputProfiles p, {
  required AudioOutputKind kind,
  String? deviceName,
}) {
  if (deviceName != null) {
    final own = p.devices[normaliseDeviceName(deviceName)]?.profile;
    if (own != null) return own;
  }
  return p.kinds[kind] ?? const OutputProfile();
}

/// The kind behind `Channel.getAudioOutputType`'s strings (Android:
/// bluetooth, wired_headphone, usb_audio, speaker; iOS: headset, bluetooth,
/// speaker, airplay and others).
AudioOutputKind kindOfLegacyOutput(String s) => switch (s) {
  'bluetooth' => AudioOutputKind.bluetooth,
  'wired_headphone' || 'headset' => AudioOutputKind.wired,
  'usb_audio' => AudioOutputKind.usb,
  'speaker' => AudioOutputKind.speaker,
  _ => AudioOutputKind.other,
};

/// The hidden `_device_<type>` EQ presets the old "link all devices" switch
/// kept become the matching kind's EQ preset. An existing assignment stays,
/// and of two aliases of one kind the first wins.
OutputProfiles migrateLegacyDevicePresets(
  OutputProfiles p,
  Iterable<String> presetNames,
) {
  var out = p;
  for (final n in presetNames) {
    if (!n.startsWith('_device_')) continue;
    final kind = kindOfLegacyOutput(n.substring('_device_'.length));
    final cur = out.kinds[kind] ?? const OutputProfile();
    if (cur.eqPreset != null) continue;
    out = out.withKind(kind, cur.copyWith(eqPreset: n));
  }
  return out;
}

/// The output audio is going to: its kind and, for Bluetooth and USB, its
/// name when known.
class ActiveRoute {
  const ActiveRoute({
    required this.kind,
    this.deviceName,
    this.legacyType = 'speaker',
  });

  final AudioOutputKind kind;
  final String? deviceName;

  /// The string `Channel.getAudioOutputType` gave (names the old per-device
  /// presets).
  final String legacyType;

  /// Same for equal routes.
  String get key => deviceName == null
      ? kind.name
      : '${kind.name}:${normaliseDeviceName(deviceName!)}';
}

/// The route from the platform's output string and the outputs present.
ActiveRoute activeRouteOf(
  String legacyType,
  Iterable<({String name, AudioOutputKind kind})> outputs,
) {
  final kind = kindOfLegacyOutput(legacyType);
  String? name;
  if (kind == AudioOutputKind.bluetooth || kind == AudioOutputKind.usb) {
    for (final o in outputs) {
      if (o.kind == kind && normaliseDeviceName(o.name).isNotEmpty) {
        name = o.name;
        break;
      }
    }
  }
  return ActiveRoute(kind: kind, deviceName: name, legacyType: legacyType);
}
