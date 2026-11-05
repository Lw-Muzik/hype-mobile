import 'dart:math' as math;

import 'package:eq_app/audio/replay_gain/replay_gain.dart';
import 'package:eq_app/audio/replay_gain/rg_tags.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const album = ReplayGainTags(
    trackGainDb: -2,
    trackPeak: 0.9,
    albumGainDb: -4,
    albumPeak: 0.8,
  );

  test('off is always 0', () {
    expect(replayGainDb(ReplayGainSettings(), album), 0);
    expect(replayGainDb(ReplayGainSettings(), null), 0);
  });

  test('apply + album: album gain plus preamp', () {
    final s = ReplayGainSettings(
      mode: ReplayGainMode.apply,
      source: ReplayGainSource.album,
      preampDb: 1,
    );
    expect(replayGainDb(s, album), closeTo(-3, 1e-9));
  });

  test('track source uses the track gain', () {
    final s = ReplayGainSettings(
      mode: ReplayGainMode.apply,
      source: ReplayGainSource.track,
    );
    expect(replayGainDb(s, album), -2);
  });

  test('album chosen, only a track tag: falls back to track', () {
    final s = ReplayGainSettings(mode: ReplayGainMode.apply);
    expect(replayGainDb(s, const ReplayGainTags(trackGainDb: -5)), -5);
  });

  test('null or empty tags use the untagged preamp', () {
    final s = ReplayGainSettings(
      mode: ReplayGainMode.apply,
      untaggedPreampDb: -3.5,
    );
    expect(replayGainDb(s, null), -3.5);
    expect(replayGainDb(s, ReplayGainTags.empty), -3.5);
    // A peak with no gain is not a gain.
    expect(replayGainDb(s, const ReplayGainTags(trackPeak: 0.5)), -3.5);
  });

  test('prevent clipping caps the boost by the peak', () {
    final s = ReplayGainSettings(
      mode: ReplayGainMode.applyPreventClipping,
      source: ReplayGainSource.track,
      preampDb: 2,
    );
    final db = replayGainDb(
      s,
      const ReplayGainTags(trackGainDb: 6, trackPeak: 0.794),
    );
    expect(db, closeTo(-20 * (math.log(0.794) / math.ln10), 1e-9));
    expect(db, lessThan(8));
  });

  test('prevent clipping leaves cuts and peak-less tracks alone', () {
    final s = ReplayGainSettings(
      mode: ReplayGainMode.applyPreventClipping,
      source: ReplayGainSource.track,
    );
    expect(
      replayGainDb(s, const ReplayGainTags(trackGainDb: -6, trackPeak: 0.9)),
      -6,
    );
    expect(replayGainDb(s, const ReplayGainTags(trackGainDb: 6)), 6);
  });

  test('peak comes from the same source as the gain used', () {
    final s = ReplayGainSettings(
      mode: ReplayGainMode.applyPreventClipping,
      source: ReplayGainSource.album,
    );
    // Album gain +6 with album peak 0.5 (cap ~6.02); track peak 0.1 must not
    // be used.
    final db = replayGainDb(
      s,
      const ReplayGainTags(
        albumGainDb: 6,
        albumPeak: 0.5,
        trackGainDb: 1,
        trackPeak: 0.1,
      ),
    );
    expect(db, closeTo(6, 1e-9));
    // Album gain missing: track gain and track peak are used together.
    final t = replayGainDb(
      s,
      const ReplayGainTags(trackGainDb: 6, trackPeak: 0.5, albumPeak: 0.1),
    );
    expect(t, closeTo(6, 1e-9));
  });

  test('defaults and legacy migration', () async {
    SharedPreferences.setMockInitialValues({});
    var s = ReplayGainSettings.load(await SharedPreferences.getInstance());
    expect(s.mode, ReplayGainMode.off);
    expect(s.source, ReplayGainSource.album);
    expect(s.preampDb, 0);
    expect(s.untaggedPreampDb, 0);

    SharedPreferences.setMockInitialValues({'replayGain': true});
    s = ReplayGainSettings.load(await SharedPreferences.getInstance());
    expect(s.mode, ReplayGainMode.applyPreventClipping);
    expect(s.source, ReplayGainSource.track);

    SharedPreferences.setMockInitialValues({'replayGain': false});
    s = ReplayGainSettings.load(await SharedPreferences.getInstance());
    expect(s.mode, ReplayGainMode.off);

    // The legacy flag is ignored once rgMode exists.
    SharedPreferences.setMockInitialValues({
      'replayGain': true,
      'rgMode': 'off',
    });
    s = ReplayGainSettings.load(await SharedPreferences.getInstance());
    expect(s.mode, ReplayGainMode.off);
  });

  test('preamps clamp to -16..16 and snap to 0.1', () {
    expect(ReplayGainSettings(preampDb: 40).preampDb, 16);
    expect(ReplayGainSettings(preampDb: -40).preampDb, -16);
    expect(ReplayGainSettings(preampDb: 1.234).preampDb, 1.2);
    expect(ReplayGainSettings(untaggedPreampDb: -2.76).untaggedPreampDb, -2.8);
    expect(ReplayGainSettings().copyWith(preampDb: 99).preampDb, 16);
  });

  test('save then load round-trips', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final s = ReplayGainSettings(
      mode: ReplayGainMode.applyPreventClipping,
      source: ReplayGainSource.track,
      preampDb: 3.3,
      untaggedPreampDb: -4.1,
    );
    await s.save(prefs);
    expect(ReplayGainSettings.load(prefs), s);
  });

  group('limiter off', () {
    ReplayGainSettings apply({bool limiterOn = false, double preamp = 0}) =>
        ReplayGainSettings(
          mode: ReplayGainMode.apply,
          source: ReplayGainSource.track,
          preampDb: preamp,
          limiterOn: limiterOn,
        );

    test('positive gain is peak-capped even in Apply gain', () {
      final db = replayGainDb(
        apply(),
        const ReplayGainTags(trackGainDb: 6, trackPeak: 0.794),
      );
      expect(db, closeTo(-20 * (math.log(0.794) / math.ln10), 1e-9));
    });

    test('positive gain with no peak is capped at 0 dB', () {
      expect(replayGainDb(apply(), const ReplayGainTags(trackGainDb: 6)), 0);
    });

    test('cuts and an on limiter are untouched', () {
      expect(
        replayGainDb(apply(), const ReplayGainTags(trackGainDb: -6)),
        -6,
      );
      expect(
        replayGainDb(
          apply(limiterOn: true),
          const ReplayGainTags(trackGainDb: 6),
        ),
        6,
      );
    });

    test('the preamp counts toward the cap', () {
      expect(
        replayGainDb(
          apply(preamp: 3),
          const ReplayGainTags(trackGainDb: -1, trackPeak: 0.5),
        ),
        closeTo(2, 1e-9),
      ); // cap is 6.02, gain+preamp 2
      expect(
        replayGainDb(
          apply(preamp: 3),
          const ReplayGainTags(trackGainDb: 4, trackPeak: 0.5),
        ),
        closeTo(6.0206, 1e-3),
      );
    });

    test('untagged preamp: boost capped at 0 dB only with the limiter off', () {
      ReplayGainSettings u({required bool on, required double db}) =>
          ReplayGainSettings(
            mode: ReplayGainMode.apply,
            untaggedPreampDb: db,
            limiterOn: on,
          );
      expect(replayGainDb(u(on: false, db: 6), null), 0);
      expect(replayGainDb(u(on: false, db: 6), ReplayGainTags.empty), 0);
      expect(replayGainDb(u(on: true, db: 6), null), 6);
      expect(replayGainDb(u(on: false, db: -3), null), -3);
    });

    test('limiterOn is not persisted and takes part in equality', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await apply().save(prefs);
      expect(ReplayGainSettings.load(prefs).limiterOn, isTrue);
      expect(apply() == apply(limiterOn: true), isFalse);
    });
  });
}
