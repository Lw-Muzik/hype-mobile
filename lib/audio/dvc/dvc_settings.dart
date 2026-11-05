import 'package:shared_preferences/shared_preferences.dart';

/// Whether Direct Volume Control may run on the current route.
///
/// DVC holds the system music volume at maximum. On a Bluetooth route with
/// absolute volume, that maximum is sent to the headset as well (and the
/// headset's own volume takes over), so with [noDvcForBtAbsolute] on, DVC only
/// runs on Bluetooth when absolute volume is known to be off
/// ([btAbsoluteVolumeOff] true). Unknown (null) counts as on. The stored
/// setting is never changed by this; it is the route that decides.
bool dvcAllowedOnRoute({
  required bool isAndroid,
  required bool dvcEnabled,
  required bool onBluetooth,
  required bool? btAbsoluteVolumeOff,
  required bool noDvcForBtAbsolute,
  required bool systemWide,
}) {
  if (!isAndroid || !dvcEnabled || systemWide) return false;
  if (onBluetooth && noDvcForBtAbsolute) return btAbsoluteVolumeOff == true;
  return true;
}

/// The Direct Volume Control settings that are new in this section. The
/// enable switch, DVC level and "No DVC – preamp reduction" keep their
/// existing storage.
class DvcSettings {
  const DvcSettings({this.noDvcForBluetoothAbsoluteVolume = true});

  final bool noDvcForBluetoothAbsoluteVolume;

  static const _kNoBtAbsolute = 'dvcNoBtAbsolute';

  DvcSettings copyWith({bool? noDvcForBluetoothAbsoluteVolume}) => DvcSettings(
    noDvcForBluetoothAbsoluteVolume:
        noDvcForBluetoothAbsoluteVolume ?? this.noDvcForBluetoothAbsoluteVolume,
  );

  static DvcSettings load(SharedPreferences prefs) => DvcSettings(
    noDvcForBluetoothAbsoluteVolume: prefs.getBool(_kNoBtAbsolute) ?? true,
  );

  Future<void> save(SharedPreferences prefs) =>
      prefs.setBool(_kNoBtAbsolute, noDvcForBluetoothAbsoluteVolume);

  @override
  bool operator ==(Object other) =>
      other is DvcSettings &&
      other.noDvcForBluetoothAbsoluteVolume == noDvcForBluetoothAbsoluteVolume;

  @override
  int get hashCode => noDvcForBluetoothAbsoluteVolume.hashCode;
}

/// The DVC level (dB, -30..0) matching the system music volume [index] of
/// [max], so a first enable plays at the level the listener already had.
///
/// [streamDb] is the real attenuation Android applies at that step
/// (`AudioManager.getStreamVolumeDb`, API 28+): its curve drops much faster at
/// low steps than a straight line, so it is used when known (clamped to the DVC
/// range; below -30 is -30). Without it (older Android, or unreadable) the
/// linear map stands in.
double dvcGainFromSystemVolume(int index, int max, {double? streamDb}) {
  if (streamDb != null && !streamDb.isNaN) {
    return streamDb.clamp(-30.0, 0.0).toDouble();
  }
  if (max <= 0) return -30.0;
  return (-30.0 + 30.0 * (index / max)).clamp(-30.0, 0.0).toDouble();
}

/// Whether a route read counts as a probe. A failed read (no platform side,
/// as in a headless start) is not "speaker": it leaves DVC off.
bool dvcRouteReadValid(String? outputType) => outputType != null;
