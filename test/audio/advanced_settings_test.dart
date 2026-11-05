import 'package:eq_app/audio/advanced/advanced_settings.dart';
import 'package:eq_app/models/room_preset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<SharedPreferences> prefs([Map<String, Object> v = const {}]) async {
    SharedPreferences.setMockInitialValues(v);
    return SharedPreferences.getInstance();
  }

  group('defaults and round trip', () {
    test('spec defaults', () async {
      final s = AdvancedSettings.load(await prefs());
      expect(s.volumeLevels, VolumeLevels.systemDefault);
      expect(s.volumePanel, isFalse);
      expect(s.pauseResumeOnVolume, isFalse);
      expect(s.musicFx, isFalse);
      expect(s.forceAudioOnFocusChange, isFalse);
    });

    test('save then load gives the same settings', () async {
      final p = await prefs();
      const s = AdvancedSettings(
        volumeLevels: VolumeLevels.l75,
        volumePanel: true,
        pauseResumeOnVolume: true,
        musicFx: true,
        forceAudioOnFocusChange: true,
      );
      await s.save(p);
      expect(AdvancedSettings.load(p), s);
    });

    test('an unknown stored level falls back to the default', () async {
      final p = await prefs({'advVolumeLevels': 'l9000'});
      expect(AdvancedSettings.load(p).volumeLevels, VolumeLevels.systemDefault);
    });
  });

  group('migration from "Fine volume steps"', () {
    test('fine (1 %) becomes 100 levels', () async {
      final p = await prefs({'dvcFineSteps': true});
      expect(AdvancedSettings.load(p).volumeLevels, VolumeLevels.l100);
    });

    test('coarse (5 %) becomes 30 levels', () async {
      final p = await prefs({'dvcFineSteps': false});
      expect(AdvancedSettings.load(p).volumeLevels, VolumeLevels.l30);
    });

    test('never set stays System default', () async {
      final p = await prefs();
      expect(AdvancedSettings.load(p).volumeLevels, VolumeLevels.systemDefault);
    });

    test('the new setting wins over the legacy one', () async {
      final p = await prefs({'dvcFineSteps': true, 'advVolumeLevels': 'l50'});
      expect(AdvancedSettings.load(p).volumeLevels, VolumeLevels.l50);
    });
  });

  group('volume levels', () {
    test('dvc step is the 30 dB range split into the levels', () {
      expect(VolumeLevels.systemDefault.dvcStepDb, 1.5);
      expect(VolumeLevels.l30.dvcStepDb, closeTo(1.0, 1e-9));
      expect(VolumeLevels.l50.dvcStepDb, closeTo(0.6, 1e-9));
      expect(VolumeLevels.l75.dvcStepDb, closeTo(0.4, 1e-9));
      expect(VolumeLevels.l100.dvcStepDb, closeTo(0.3, 1e-9));
    });
  });

  group('volumeAction', () {
    VolumeAction? act(
      double previous,
      double now, {
      bool playing = false,
      bool pausedByVolume = false,
      bool visible = true,
    }) => volumeAction(
      previous: previous,
      now: now,
      playing: playing,
      pausedByVolume: pausedByVolume,
      uiOrNotificationVisible: visible,
    );

    test('playing and volume reaches 0 pauses', () {
      expect(act(0.2, 0, playing: true), VolumeAction.pause);
    });
    test('pauses even when nothing is visible', () {
      expect(act(0.2, 0, playing: true, visible: false), VolumeAction.pause);
    });
    test('already silent when music starts: no pause', () {
      expect(act(0, 0, playing: true), isNull);
    });
    test('not playing and volume reaches 0: nothing', () {
      expect(act(0.2, 0), isNull);
    });
    test('paused by volume, raised from 0, visible: resume', () {
      expect(act(0, 0.1, pausedByVolume: true), VolumeAction.resume);
    });
    test('paused by volume, raised, hidden: nothing', () {
      expect(act(0, 0.1, pausedByVolume: true, visible: false), isNull);
    });
    test('never resumes what the volume did not pause', () {
      expect(act(0, 0.1), isNull);
    });
    test('does not resume while still at 0', () {
      expect(act(0, 0, pausedByVolume: true), isNull);
    });
    test('does not resume when already playing', () {
      expect(act(0, 0.1, playing: true, pausedByVolume: true), isNull);
    });
    test('a plain change of level does nothing', () {
      expect(act(0.4, 0.5, playing: true), isNull);
    });
  });

  group('forceAudioDecision', () {
    ForceAudioStep d({
      bool enabled = true,
      bool meantToPlay = true,
      Duration before = const Duration(seconds: 5),
      Duration after = const Duration(seconds: 5),
      int attempts = 0,
    }) => forceAudioDecision(
      enabled: enabled,
      meantToPlay: meantToPlay,
      positionAtGain: before,
      positionNow: after,
      attempts: attempts,
    );

    test('stalled position while meant to play: restart', () {
      expect(d(), ForceAudioStep.restart);
    });
    test('position advanced: nothing', () {
      expect(
        d(after: const Duration(seconds: 6, milliseconds: 400)),
        ForceAudioStep.none,
      );
    });
    test('tiny drift still counts as stalled', () {
      expect(
        d(after: const Duration(seconds: 5, milliseconds: 40)),
        ForceAudioStep.restart,
      );
    });
    test('off: nothing', () => expect(d(enabled: false), ForceAudioStep.none));
    test(
      'not meant to play: nothing',
      () => expect(d(meantToPlay: false), ForceAudioStep.none),
    );
    test('one retry only', () => expect(d(attempts: 1), ForceAudioStep.none));
  });

  group('restore reverb presets', () {
    test('restores the factory default built-in preset', () {
      final p = factoryRoomPreset();
      expect(p.name, 'Off');
      expect(p.wetDry, 0.0);
      expect(identical(p, RoomPreset.builtIn.first), isTrue);
    });
  });
}
