import 'package:shared_preferences/shared_preferences.dart';

/// How a headset's media button presses are read.
enum ButtonMode {
  singlePress('Single press'),
  multiPress('Double/triple press for next/prev'),
  longPressNext('Long press for next (when playing)');

  const ButtonMode(this.label);
  final String label;
}

/// The longest "ignore Bluetooth commands" window, in seconds.
const kIgnoreBluetoothCommandsMaxS = 20;

int _normaliseSeconds(num s) {
  if (s.isNaN) return 1;
  return s.round().clamp(0, kIgnoreBluetoothCommandsMaxS);
}

T _byName<T extends Enum>(List<T> values, String? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

/// The Headset & Bluetooth settings, saved in the preferences.
class HeadsetSettings {
  const HeadsetSettings({
    this.resumeOnWired = false,
    this.resumeOnBluetooth = false,
    this.pauseOnDisconnect = true,
    this.pauseOnUsbDac = true,
    this.respondToButtons = true,
    this.wiredButtons = ButtonMode.multiPress,
    this.bluetoothButtons = ButtonMode.multiPress,
    this.strictCommands = true,
    int ignoreBluetoothCommandsS = 1,
    this.ignoreRepeatShuffle = false,
    this.beep = true,
    this.beepMore = false,
    this.vibrate = false,
    this.disableDefaultLongPress = false,
  }) : ignoreBluetoothCommandsS = ignoreBluetoothCommandsS < 0
           ? 0
           : ignoreBluetoothCommandsS > kIgnoreBluetoothCommandsMaxS
           ? kIgnoreBluetoothCommandsMaxS
           : ignoreBluetoothCommandsS;

  final bool resumeOnWired;
  final bool resumeOnBluetooth;
  final bool pauseOnDisconnect;
  final bool pauseOnUsbDac;
  final bool respondToButtons;
  final ButtonMode wiredButtons;
  final ButtonMode bluetoothButtons;
  final bool strictCommands;

  /// Seconds after a Bluetooth connect during which commands are ignored
  /// (0…[kIgnoreBluetoothCommandsMaxS]).
  final int ignoreBluetoothCommandsS;
  final bool ignoreRepeatShuffle;
  final bool beep;
  final bool beepMore;
  final bool vibrate;
  final bool disableDefaultLongPress;

  static const _kResumeOnWired = 'hsResumeOnWired';
  static const _kResumeOnBluetooth = 'hsResumeOnBluetooth';
  static const _kPauseOnDisconnect = 'hsPauseOnDisconnect';
  static const _kPauseOnUsbDac = 'hsPauseOnUsbDac';
  static const _kRespondToButtons = 'hsRespondToButtons';
  static const _kWiredButtons = 'hsWiredButtons';
  static const _kBluetoothButtons = 'hsBluetoothButtons';
  static const _kStrictCommands = 'hsStrictCommands';
  static const _kIgnoreBtCommandsS = 'hsIgnoreBtCommandsS';
  static const _kIgnoreRepeatShuffle = 'hsIgnoreRepeatShuffle';
  static const _kBeep = 'hsBeep';
  static const _kBeepMore = 'hsBeepMore';
  static const _kVibrate = 'hsVibrate';
  static const _kDisableLongPress = 'hsDisableLongPress';

  HeadsetSettings copyWith({
    bool? resumeOnWired,
    bool? resumeOnBluetooth,
    bool? pauseOnDisconnect,
    bool? pauseOnUsbDac,
    bool? respondToButtons,
    ButtonMode? wiredButtons,
    ButtonMode? bluetoothButtons,
    bool? strictCommands,
    int? ignoreBluetoothCommandsS,
    bool? ignoreRepeatShuffle,
    bool? beep,
    bool? beepMore,
    bool? vibrate,
    bool? disableDefaultLongPress,
  }) => HeadsetSettings(
    resumeOnWired: resumeOnWired ?? this.resumeOnWired,
    resumeOnBluetooth: resumeOnBluetooth ?? this.resumeOnBluetooth,
    pauseOnDisconnect: pauseOnDisconnect ?? this.pauseOnDisconnect,
    pauseOnUsbDac: pauseOnUsbDac ?? this.pauseOnUsbDac,
    respondToButtons: respondToButtons ?? this.respondToButtons,
    wiredButtons: wiredButtons ?? this.wiredButtons,
    bluetoothButtons: bluetoothButtons ?? this.bluetoothButtons,
    strictCommands: strictCommands ?? this.strictCommands,
    ignoreBluetoothCommandsS: _normaliseSeconds(
      ignoreBluetoothCommandsS ?? this.ignoreBluetoothCommandsS,
    ),
    ignoreRepeatShuffle: ignoreRepeatShuffle ?? this.ignoreRepeatShuffle,
    beep: beep ?? this.beep,
    beepMore: beepMore ?? this.beepMore,
    vibrate: vibrate ?? this.vibrate,
    disableDefaultLongPress:
        disableDefaultLongPress ?? this.disableDefaultLongPress,
  );

  static HeadsetSettings load(SharedPreferences prefs) {
    const d = HeadsetSettings();
    // Read as a num so a stray double in the store is rounded, not dropped.
    final raw = prefs.get(_kIgnoreBtCommandsS);
    return HeadsetSettings(
      resumeOnWired: prefs.getBool(_kResumeOnWired) ?? d.resumeOnWired,
      resumeOnBluetooth:
          prefs.getBool(_kResumeOnBluetooth) ?? d.resumeOnBluetooth,
      pauseOnDisconnect:
          prefs.getBool(_kPauseOnDisconnect) ?? d.pauseOnDisconnect,
      pauseOnUsbDac: prefs.getBool(_kPauseOnUsbDac) ?? d.pauseOnUsbDac,
      respondToButtons:
          prefs.getBool(_kRespondToButtons) ?? d.respondToButtons,
      wiredButtons: _byName(
        ButtonMode.values,
        prefs.getString(_kWiredButtons),
        d.wiredButtons,
      ),
      bluetoothButtons: _byName(
        ButtonMode.values,
        prefs.getString(_kBluetoothButtons),
        d.bluetoothButtons,
      ),
      strictCommands: prefs.getBool(_kStrictCommands) ?? d.strictCommands,
      ignoreBluetoothCommandsS: raw is num
          ? _normaliseSeconds(raw)
          : d.ignoreBluetoothCommandsS,
      ignoreRepeatShuffle:
          prefs.getBool(_kIgnoreRepeatShuffle) ?? d.ignoreRepeatShuffle,
      beep: prefs.getBool(_kBeep) ?? d.beep,
      beepMore: prefs.getBool(_kBeepMore) ?? d.beepMore,
      vibrate: prefs.getBool(_kVibrate) ?? d.vibrate,
      disableDefaultLongPress:
          prefs.getBool(_kDisableLongPress) ?? d.disableDefaultLongPress,
    );
  }

  Future<void> save(SharedPreferences prefs) async {
    await prefs.setBool(_kResumeOnWired, resumeOnWired);
    await prefs.setBool(_kResumeOnBluetooth, resumeOnBluetooth);
    await prefs.setBool(_kPauseOnDisconnect, pauseOnDisconnect);
    await prefs.setBool(_kPauseOnUsbDac, pauseOnUsbDac);
    await prefs.setBool(_kRespondToButtons, respondToButtons);
    await prefs.setString(_kWiredButtons, wiredButtons.name);
    await prefs.setString(_kBluetoothButtons, bluetoothButtons.name);
    await prefs.setBool(_kStrictCommands, strictCommands);
    await prefs.setInt(_kIgnoreBtCommandsS, ignoreBluetoothCommandsS);
    await prefs.setBool(_kIgnoreRepeatShuffle, ignoreRepeatShuffle);
    await prefs.setBool(_kBeep, beep);
    await prefs.setBool(_kBeepMore, beepMore);
    await prefs.setBool(_kVibrate, vibrate);
    await prefs.setBool(_kDisableLongPress, disableDefaultLongPress);
  }

  @override
  bool operator ==(Object other) =>
      other is HeadsetSettings &&
      other.resumeOnWired == resumeOnWired &&
      other.resumeOnBluetooth == resumeOnBluetooth &&
      other.pauseOnDisconnect == pauseOnDisconnect &&
      other.pauseOnUsbDac == pauseOnUsbDac &&
      other.respondToButtons == respondToButtons &&
      other.wiredButtons == wiredButtons &&
      other.bluetoothButtons == bluetoothButtons &&
      other.strictCommands == strictCommands &&
      other.ignoreBluetoothCommandsS == ignoreBluetoothCommandsS &&
      other.ignoreRepeatShuffle == ignoreRepeatShuffle &&
      other.beep == beep &&
      other.beepMore == beepMore &&
      other.vibrate == vibrate &&
      other.disableDefaultLongPress == disableDefaultLongPress;

  @override
  int get hashCode => Object.hash(
    resumeOnWired,
    resumeOnBluetooth,
    pauseOnDisconnect,
    pauseOnUsbDac,
    respondToButtons,
    wiredButtons,
    bluetoothButtons,
    strictCommands,
    ignoreBluetoothCommandsS,
    ignoreRepeatShuffle,
    beep,
    beepMore,
    vibrate,
    disableDefaultLongPress,
  );
}
