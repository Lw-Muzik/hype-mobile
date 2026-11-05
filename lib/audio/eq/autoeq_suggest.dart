import 'package:shared_preferences/shared_preferences.dart';

import '../../models/speaker_profile.dart';
import '../headset/output_kind.dart';

class OutputDeviceEvent {
  const OutputDeviceEvent({required this.name, required this.kind});
  final String name;
  final AudioOutputKind kind;
}

/// Lower case, parenthesised text removed, only `[a-z0-9]` kept.
String normaliseDeviceName(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'\([^)]*\)'), '')
    .replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Profile name without its brand (first word), normalised.
String _model(String profileName) {
  final t = profileName.trim();
  final i = t.indexOf(' ');
  return normaliseDeviceName(i < 0 ? t : t.substring(i + 1));
}

/// Names made only of generic words and digits ("Bluetooth Audio", "Pro 2").
final RegExp _genericOnly = RegExp(
  r'^(?:headphones|headphone|headset|earphones|earbuds|bluetooth|wireless|'
  r'speaker|stereo|audio|buds|plus|mini|lite|true|tws|max|pro|anc|hd|nc|bt|le|'
  r'\d)+$',
);

/// Decision 13: exact name or model first; else the shortest profile name
/// containing the device name; else the longest model (>= 5 chars) contained
/// in the device name. Names under 4 characters never match.
SpeakerProfile? matchAutoEqProfile(
  String deviceName,
  List<SpeakerProfile> profiles,
) {
  final dev = normaliseDeviceName(deviceName);
  if (dev.length < 4 || _genericOnly.hasMatch(dev)) return null;

  for (final p in profiles) {
    if (normaliseDeviceName(p.name) == dev || _model(p.name) == dev) return p;
  }

  if (dev.length >= 6) {
    SpeakerProfile? shortest;
    var shortestLen = 1 << 30;
    for (final p in profiles) {
      final n = normaliseDeviceName(p.name);
      if (n.contains(dev) && n.length < shortestLen) {
        shortest = p;
        shortestLen = n.length;
      }
    }
    if (shortest != null) return shortest;
  }

  SpeakerProfile? best;
  var bestLen = 0;
  for (final p in profiles) {
    final m = _model(p.name);
    if (m.length >= 5 && m.length > bestLen && dev.contains(m)) {
      best = p;
      bestLen = m.length;
    }
  }
  return best;
}

SpeakerProfile? autoEqSuggestion({
  required OutputDeviceEvent device,
  required bool enabled,
  required bool systemWide,
  required Set<String> dismissed,
  required Set<String> askedThisSession,
  required String? activeProfile,
  required List<SpeakerProfile> profiles,
}) {
  // Only headphones that name themselves: Bluetooth and USB.
  if (!enabled ||
      systemWide ||
      (device.kind != AudioOutputKind.bluetooth &&
          device.kind != AudioOutputKind.usb)) {
    return null;
  }
  final key = normaliseDeviceName(device.name);
  if (dismissed.contains(key) || askedThisSession.contains(key)) return null;
  final match = matchAutoEqProfile(device.name, profiles);
  if (match == null || match.name == activeProfile) return null;
  return match;
}

class AutoEqDismissals {
  static const prefKey = 'eqAutoEqDismissed';

  static Set<String> load(SharedPreferences p) =>
      (p.getStringList(prefKey) ?? const <String>[]).toSet();

  static Future<void> add(SharedPreferences p, String deviceName) async {
    final s = load(p)..add(normaliseDeviceName(deviceName));
    await p.setStringList(prefKey, s.toList());
  }

  static Future<void> reset(SharedPreferences p) async {
    await p.remove(prefKey);
  }
}
