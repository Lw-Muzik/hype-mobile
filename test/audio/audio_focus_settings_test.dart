import 'package:eq_app/audio/focus/audio_focus_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> prefsWith(Map<String, Object> v) async {
  SharedPreferences.setMockInitialValues(v);
  return SharedPreferences.getInstance();
}

void main() {
  test('empty prefs give every default', () async {
    final s = AudioFocusSettings.load(await prefsWith({}));
    expect(s.resumeAfterCall, true);
    expect(s.resumeOnStart, false);
    expect(s.resumeOnReopen, false);
    expect(s.shortFocusChange, true);
    expect(s.pauseInCall, true);
    expect(s.resumeOnFocusGain, true);
    expect(s.duckVolume, true);
    expect(s.permanentFocusChange, true);
    expect(s, const AudioFocusSettings());
  });

  test('save then load round-trips every field flipped', () async {
    final prefs = await prefsWith({});
    const flipped = AudioFocusSettings(
      resumeAfterCall: false,
      resumeOnStart: true,
      resumeOnReopen: true,
      shortFocusChange: false,
      pauseInCall: false,
      resumeOnFocusGain: false,
      duckVolume: false,
      permanentFocusChange: false,
    );
    await flipped.save(prefs);
    final back = AudioFocusSettings.load(prefs);
    expect(back, flipped);
    expect(back.hashCode, flipped.hashCode);
  });

  test('copyWith changes only the named field', () {
    const d = AudioFocusSettings();
    final c = d.copyWith(duckVolume: false);
    expect(c.duckVolume, false);
    expect(c.copyWith(duckVolume: true), d);
  });

  test('effectivePauseInCall', () {
    expect(
      const AudioFocusSettings(
        shortFocusChange: true,
        pauseInCall: false,
      ).effectivePauseInCall,
      true,
    );
    expect(
      const AudioFocusSettings(
        shortFocusChange: false,
        pauseInCall: false,
      ).effectivePauseInCall,
      false,
    );
    expect(
      const AudioFocusSettings(
        shortFocusChange: false,
        pauseInCall: true,
      ).effectivePauseInCall,
      true,
    );
  });

  test('pauseInCall false survives save/load while short is on', () async {
    final prefs = await prefsWith({});
    await const AudioFocusSettings(
      shortFocusChange: true,
      pauseInCall: false,
    ).save(prefs);
    final back = AudioFocusSettings.load(prefs);
    expect(back.pauseInCall, false);
    expect(back.effectivePauseInCall, true);
  });
}
