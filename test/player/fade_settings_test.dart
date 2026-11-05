/// The fading rules: defaults and ranges, which boundaries
/// crossfade, and when the queue is handed to the player whole.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eq_app/player/fade_settings.dart';

void main() {
  group('defaults', () {
    const d = FadeSettings();

    test('no auto fading, a short crossfade on skips', () {
      expect(d.autoAdvance, AutoAdvanceFading.none);
      expect(d.manualChange, ManualChangeFading.shortCrossfade);
      expect(d.manualChangeMs, 400);
    });

    test('fades on play/pause and seek, at 400 ms and 100 ms', () {
      expect(d.playPauseMs, 400);
      expect(d.seekFadeInMs, 100);
    });

    test('a 5 s crossfade, no preload, no silence', () {
      expect(d.crossfadeMs, 5000);
      expect(d.gaplessPreloadMs, 0);
      expect(d.silenceMs, 0);
    });
  });

  group('lengths', () {
    test('clamped to their ranges', () {
      final s = const FadeSettings().copyWith(
        crossfadeMs: 30000,
        shortCrossfadeMs: 1,
        seekFadeMs: 9999,
        silenceMs: -5,
      );
      expect(s.crossfadeMs, 15000);
      expect(s.shortCrossfadeMs, 10);
      expect(s.seekFadeMs, 500);
      expect(s.silenceMs, 0);
    });

    test('snapped to the slider step', () {
      final s = const FadeSettings().copyWith(crossfadeMs: 5024, silenceMs: 260);
      expect(s.crossfadeMs, 5000);
      expect(s.silenceMs, 300);
    });

    test('switched-off fades are zero long', () {
      final s = const FadeSettings()
          .copyWith(fadePlayPause: false, fadeSeek: false);
      expect(s.playPauseMs, 0);
      expect(s.seekFadeInMs, kDeclickMs);
      expect(s.playPauseFadeMs, 400, reason: 'the length is kept for later');
    });

    test('a manual change uses the length its mode names', () {
      const s = FadeSettings(crossfadeMs: 8000, shortCrossfadeMs: 250);
      expect(s.copyWith(manualChange: ManualChangeFading.none).manualChangeMs, 0);
      expect(
        s.copyWith(manualChange: ManualChangeFading.shortCrossfade)
            .manualChangeMs,
        250,
      );
      expect(
        s.copyWith(manualChange: ManualChangeFading.crossfade).manualChangeMs,
        8000,
      );
    });
  });

  group('saved and restored', () {
    test('round-trips every field', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final s = const FadeSettings().copyWith(
        autoAdvance: AutoAdvanceFading.shuffledSongs,
        manualChange: ManualChangeFading.crossfade,
        fadePlayPause: false,
        fadeSeek: false,
        gaplessPreloadMs: 1200,
        silenceMs: 700,
        crossfadeMs: 9050,
        shortCrossfadeMs: 120,
        playPauseFadeMs: 650,
        seekFadeMs: 40,
      );
      await s.save(prefs);
      expect(FadeSettings.load(prefs), s);
    });

    test('an old crossfade setting carries over, capped at 15 s', () async {
      SharedPreferences.setMockInitialValues({'crossfadeDuration': 20});
      final s = FadeSettings.load(await SharedPreferences.getInstance());
      expect(s.autoAdvance, AutoAdvanceFading.allSongs);
      expect(s.crossfadeMs, 15000);
    });

    test('an old crossfade of 0 means no auto fading', () async {
      SharedPreferences.setMockInitialValues({'crossfadeDuration': 0});
      final s = FadeSettings.load(await SharedPreferences.getInstance());
      expect(s.autoAdvance, AutoAdvanceFading.none);
      expect(s.crossfadeMs, 5000);
    });

    test('the new setting wins over the old one', () async {
      SharedPreferences.setMockInitialValues({
        'crossfadeDuration': 8,
        'crossfadeAutoAdvance': AutoAdvanceFading.none.index,
      });
      final s = FadeSettings.load(await SharedPreferences.getInstance());
      expect(s.autoAdvance, AutoAdvanceFading.none);
    });
  });

  group('gapless pairs', () {
    const t3 = TrackRef(album: 'Abbey Road', albumId: 7, track: 3);
    const t4 = TrackRef(album: 'Abbey Road', albumId: 7, track: 4);

    test('the next track of the same album', () {
      expect(isGaplessPair(t3, t4), isTrue);
    });

    test('not the other way round, nor a skip of one', () {
      expect(isGaplessPair(t4, t3), isFalse);
      expect(
        isGaplessPair(
            t3, const TrackRef(album: 'Abbey Road', albumId: 7, track: 5)),
        isFalse,
      );
    });

    test('not across albums', () {
      expect(
        isGaplessPair(
            t3, const TrackRef(album: 'Let It Be', albumId: 8, track: 4)),
        isFalse,
      );
    });

    test('not across discs (Android folds the disc into the number)', () {
      expect(
        isGaplessPair(
          const TrackRef(album: 'X', albumId: 1, track: 1012),
          const TrackRef(album: 'X', albumId: 1, track: 2001),
        ),
        isFalse,
      );
      expect(
        isGaplessPair(
          const TrackRef(album: 'X', albumId: 1, track: 2001),
          const TrackRef(album: 'X', albumId: 1, track: 2002),
        ),
        isTrue,
      );
    });

    test('matched by name when there are no album ids', () {
      expect(
        isGaplessPair(
          const TrackRef(album: 'Kind of Blue ', track: 1),
          const TrackRef(album: 'kind of blue', track: 2),
        ),
        isTrue,
      );
    });

    test('placeholders and artwork URLs are not album names', () {
      for (final album in ['', '<unknown>', 'https://i.ytimg.com/x.jpg']) {
        expect(
          isGaplessPair(
            TrackRef(album: album, track: 1),
            TrackRef(album: album, track: 2),
          ),
          isFalse,
          reason: album,
        );
      }
    });

    test('no track numbers, no pair', () {
      expect(
        isGaplessPair(
          const TrackRef(album: 'A', albumId: 1),
          const TrackRef(album: 'A', albumId: 1),
        ),
        isFalse,
      );
    });
  });

  group('which boundaries crossfade on their own', () {
    const a1 = TrackRef(album: 'A', albumId: 1, track: 1);
    const a2 = TrackRef(album: 'A', albumId: 1, track: 2);
    const b1 = TrackRef(album: 'B', albumId: 2, track: 1);

    int at(
      AutoAdvanceFading mode, {
      bool shuffled = false,
      bool repeatOne = false,
      TrackRef current = a1,
      TrackRef? next = b1,
    }) =>
        autoCrossfadeMs(
          FadeSettings(autoAdvance: mode, crossfadeMs: 6000),
          shuffled: shuffled,
          repeatOne: repeatOne,
          current: current,
          next: next,
        );

    test('no fading never does', () {
      expect(at(AutoAdvanceFading.none, shuffled: true), 0);
    });

    test('all songs always does, at the crossfade length', () {
      expect(at(AutoAdvanceFading.allSongs), 6000);
      expect(at(AutoAdvanceFading.allSongs, next: a2), 6000);
    });

    test('shuffled songs only while shuffled', () {
      expect(at(AutoAdvanceFading.shuffledSongs), 0);
      expect(at(AutoAdvanceFading.shuffledSongs, shuffled: true), 6000);
    });

    test('non-gapless keeps an album run gapless', () {
      expect(at(AutoAdvanceFading.nonGapless, next: a2), 0);
      expect(at(AutoAdvanceFading.nonGapless, next: b1), 6000);
    });

    test('repeat-one and the end of the queue never do', () {
      expect(at(AutoAdvanceFading.allSongs, repeatOne: true), 0);
      expect(at(AutoAdvanceFading.allSongs, next: null), 0);
    });
  });

  group('the queue is handed over whole when', () {
    bool queue(AutoAdvanceFading mode,
            {bool shuffled = false, int silence = 0}) =>
        usesGaplessQueue(
          FadeSettings(autoAdvance: mode, silenceMs: silence),
          shuffled: shuffled,
        );

    test('no fading, and non-gapless', () {
      expect(queue(AutoAdvanceFading.none), isTrue);
      expect(queue(AutoAdvanceFading.nonGapless), isTrue);
    });

    test('shuffled songs while not shuffled', () {
      expect(queue(AutoAdvanceFading.shuffledSongs), isTrue);
      expect(queue(AutoAdvanceFading.shuffledSongs, shuffled: true), isFalse);
    });

    test('never for all songs, nor with silence between tracks', () {
      expect(queue(AutoAdvanceFading.allSongs), isFalse);
      expect(queue(AutoAdvanceFading.none, silence: 500), isFalse);
    });
  });

  group('a fade switched off still declicks', () {
    const off = FadeSettings(fadePlayPause: false, fadeSeek: false);

    test('a pause is immediate, a resume fades in over 20 ms', () {
      expect(off.playPauseMs, 0);
      expect(off.resumeFadeMs, kDeclickMs);
    });

    test('a seek fades in over 20 ms', () {
      expect(off.seekFadeInMs, kDeclickMs);
    });

    test('switched on, the lengths are the settings', () {
      const on = FadeSettings(playPauseFadeMs: 300, seekFadeMs: 60);
      expect(on.resumeFadeMs, 300);
      expect(on.seekFadeInMs, 60);
    });
  });

  group('a change the listener asked for', () {
    const s = FadeSettings(
      crossfadeMs: 8000,
      shortCrossfadeMs: 250,
      playPauseFadeMs: 450,
    );

    test('no fading is a declicked cut', () {
      final f = s
          .copyWith(manualChange: ManualChangeFading.none)
          .manualChangeFade(incomingDurationMs: 200000);
      expect(f.crossfadeMs, 0);
      expect(f.earlyFadeOutMs, 0);
    });

    /// The old track starts fading the moment the skip is pressed, at the
    /// play/pause fade's rate, while the new one opens.
    test('a short crossfade fades the old track out at once', () {
      final f = s.manualChangeFade(incomingDurationMs: 200000);
      expect(f.crossfadeMs, 250);
      expect(f.earlyFadeOutMs, 450);
    });

    test('a crossfade overlaps for the full length', () {
      final f = s
          .copyWith(manualChange: ManualChangeFading.crossfade)
          .manualChangeFade(incomingDurationMs: 200000);
      expect(f.crossfadeMs, 8000);
      expect(f.earlyFadeOutMs, 8000);
    });

    test('into a track shorter than the crossfade + 1 s, a short one', () {
      final c = s.copyWith(manualChange: ManualChangeFading.crossfade);
      expect(c.manualChangeFade(incomingDurationMs: 8999).crossfadeMs, 250);
      expect(c.manualChangeFade(incomingDurationMs: 9000).crossfadeMs, 8000);
      expect(c.manualChangeFade().crossfadeMs, 8000,
          reason: 'an unknown length is not taken as short');
    });

    test('out of silence, it fades in like a resume', () {
      expect(s.manualChangeFade().fromSilenceMs, 450);
      expect(
        s.copyWith(fadePlayPause: false).manualChangeFade().fromSilenceMs,
        kDeclickMs,
      );
    });
  });
}
