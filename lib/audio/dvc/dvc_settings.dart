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
