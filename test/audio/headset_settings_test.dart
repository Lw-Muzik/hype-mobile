import 'package:eq_app/audio/headset/headset_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> prefsWith(Map<String, Object> v) async {
  SharedPreferences.setMockInitialValues(v);
  return SharedPreferences.getInstance();
}

void main() {
  test('empty prefs give every default', () async {
    final s = HeadsetSettings.load(await prefsWith({}));
    expect(s.resumeOnWired, false);
    expect(s.resumeOnBluetooth, false);
    expect(s.pauseOnDisconnect, true);
    expect(s.pauseOnUsbDac, true);
    expect(s.respondToButtons, true);
    expect(s.wiredButtons, ButtonMode.multiPress);
    expect(s.bluetoothButtons, ButtonMode.multiPress);
    expect(s.strictCommands, true);
    expect(s.ignoreBluetoothCommandsS, 1);
    expect(s.ignoreRepeatShuffle, false);
    expect(s.beep, true);
    expect(s.beepMore, false);
    expect(s.vibrate, false);
    expect(s.disableDefaultLongPress, false);
    expect(s, const HeadsetSettings());
  });

  test('save then load round-trips every field flipped', () async {
    final prefs = await prefsWith({});
    const flipped = HeadsetSettings(
      resumeOnWired: true,
      resumeOnBluetooth: true,
      pauseOnDisconnect: false,
      pauseOnUsbDac: false,
      respondToButtons: false,
      wiredButtons: ButtonMode.longPressNext,
      bluetoothButtons: ButtonMode.singlePress,
      strictCommands: false,
      ignoreBluetoothCommandsS: 9,
      ignoreRepeatShuffle: true,
      beep: false,
      beepMore: true,
      vibrate: true,
      disableDefaultLongPress: true,
    );
    await flipped.save(prefs);
    final back = HeadsetSettings.load(prefs);
    expect(back, flipped);
    expect(back.hashCode, flipped.hashCode);
  });

  test('ignoreBluetoothCommandsS is normalised', () async {
    const d = HeadsetSettings();
    expect(d.copyWith(ignoreBluetoothCommandsS: -3).ignoreBluetoothCommandsS, 0);
    expect(d.copyWith(ignoreBluetoothCommandsS: 25).ignoreBluetoothCommandsS, 20);
    expect(d.copyWith(ignoreBluetoothCommandsS: 7).ignoreBluetoothCommandsS, 7);
    expect(
      HeadsetSettings.load(await prefsWith({'hsIgnoreBtCommandsS': -3}))
          .ignoreBluetoothCommandsS,
      0,
    );
    expect(
      HeadsetSettings.load(await prefsWith({'hsIgnoreBtCommandsS': 25}))
          .ignoreBluetoothCommandsS,
      kIgnoreBluetoothCommandsMaxS,
    );
    expect(
      HeadsetSettings.load(await prefsWith({'hsIgnoreBtCommandsS': 7}))
          .ignoreBluetoothCommandsS,
      7,
    );
  });

  test('unknown enum name falls back to the default', () async {
    final s = HeadsetSettings.load(
      await prefsWith({'hsWiredButtons': 'bogus', 'hsBluetoothButtons': 'x'}),
    );
    expect(s.wiredButtons, ButtonMode.multiPress);
    expect(s.bluetoothButtons, ButtonMode.multiPress);
  });

  test('enums are stored by name', () async {
    final prefs = await prefsWith({});
    await const HeadsetSettings(wiredButtons: ButtonMode.longPressNext)
        .save(prefs);
    expect(prefs.getString('hsWiredButtons'), 'longPressNext');
  });

  test('ButtonMode labels', () {
    expect(ButtonMode.singlePress.label, 'Single press');
    expect(ButtonMode.multiPress.label, 'Double/triple press for next/prev');
    expect(ButtonMode.longPressNext.label, 'Long press for next (when playing)');
  });
}
