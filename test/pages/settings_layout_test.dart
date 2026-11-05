// Settings > Audio folds the former Equalizer, Tone & Effects, Crossfade and
// the audio half of Playback into one category. These tests pin that nothing a
// user could reach before is lost: every pre-move label is still in the search
// index, under Audio, pointing at the sub-page that holds it.
import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/pages/Settings.dart';
import 'package:eq_app/pages/advanced_settings_section.dart';
import 'package:eq_app/pages/audio_focus_settings_section.dart';
import 'package:eq_app/pages/audio_settings_page.dart';
import 'package:eq_app/pages/audio_sub_page.dart';
import 'package:eq_app/pages/crossfade_settings_section.dart';
import 'package:eq_app/pages/dvc_settings_section.dart';
import 'package:eq_app/pages/equalizer_settings_section.dart';
import 'package:eq_app/pages/replay_gain_settings_section.dart';

/// Every label that lived in the Equalizer, Tone & Effects or Crossfade
/// categories, or in Playback apart from Autoplay, before the Audio category
/// (read from the index at that point), and the sub-page that holds it now.
const _preMove = <String, AudioSubPage>{
  // Crossfade & Gapless
  'Auto-advance fading': AudioSubPage.crossfade,
  'Manual track change fading': AudioSubPage.crossfade,
  'Crossfade length': AudioSubPage.crossfade,
  'Short crossfade length': AudioSubPage.crossfade,
  'Fade play/pause/stop': AudioSubPage.crossfade,
  'Play/pause/stop fade length': AudioSubPage.crossfade,
  'Fade on seek': AudioSubPage.crossfade,
  'Seek fade length': AudioSubPage.crossfade,
  'Preload gapless tracks': AudioSubPage.crossfade,
  'Silence between tracks': AudioSubPage.crossfade,
  // Equalizer
  'Equalizer': AudioSubPage.equalizer,
  'Global equalizer': AudioSubPage.equalizer,
  'Number of bands': AudioSubPage.equalizer,
  'Enable custom bands': AudioSubPage.equalizer,
  'Custom number of bands': AudioSubPage.equalizer,
  'First frequency': AudioSubPage.equalizer,
  'Last frequency': AudioSubPage.equalizer,
  'Bass frequency': AudioSubPage.equalizer,
  'Bass Q': AudioSubPage.equalizer,
  'Treble frequency': AudioSubPage.equalizer,
  'Treble Q': AudioSubPage.equalizer,
  'Equalizer values': AudioSubPage.equalizer,
  'Tone values': AudioSubPage.equalizer,
  'Auto save': AudioSubPage.equalizer,
  'Smooth equalizer/tone gains': AudioSubPage.equalizer,
  'Suggest AutoEq presets': AudioSubPage.equalizer,
  'Reset disabled AutoEq suggestions': AudioSubPage.equalizer,
  'Restore equalizer presets': AudioSubPage.equalizer,
  // Replay Gain (was Playback)
  'Replay Gain': AudioSubPage.replayGain,
  'Source': AudioSubPage.replayGain,
  'RG preamp': AudioSubPage.replayGain,
  'Preamp for songs without RG info': AudioSubPage.replayGain,
  // Audio Focus (was Playback)
  'Resume after call': AudioSubPage.audioFocus,
  'Resume on start': AudioSubPage.audioFocus,
  'Resume on reopen': AudioSubPage.audioFocus,
  'Short audio focus change / calls': AudioSubPage.audioFocus,
  'Pause in call': AudioSubPage.audioFocus,
  'Resume on focus gain': AudioSubPage.audioFocus,
  'Duck volume': AudioSubPage.audioFocus,
  'Permanent audio focus change': AudioSubPage.audioFocus,
  // Tone & Effects: tone, limiter, balance, mono, tempo
  'Bass': AudioSubPage.effects,
  'Treble': AudioSubPage.effects,
  'Audio enhancement': AudioSubPage.effects,
  'Balance': AudioSubPage.effects,
  'Mono': AudioSubPage.effects,
  'Tempo': AudioSubPage.effects,
  'Limiter': AudioSubPage.effects,
  // Tone & Effects: direct volume control
  'Enable direct volume control': AudioSubPage.dvc,
  'No DVC for Bluetooth absolute volume': AudioSubPage.dvc,
  'No DVC – preamp reduction': AudioSubPage.dvc,
  'Volume': AudioSubPage.dvc,
  // Tone & Effects: advanced tweaks
  'Volume levels': AudioSubPage.advanced,
  'Volume panel': AudioSubPage.advanced,
  'Pause/resume on volume': AudioSubPage.advanced,
  'MusicFX': AudioSubPage.advanced,
  'Force audio on audio focus change': AudioSubPage.advanced,
  'Restore reverb presets': AudioSubPage.advanced,
  // Tone & Effects: outputs
  'Outputs': AudioSubPage.outputs,
};

/// Rows added with the Audio category itself.
const _added = <String, AudioSubPage>{
  'Audio Info': AudioSubPage.info,
  'Effects': AudioSubPage.effects,
};

SettingsEntry _only(String label) {
  final rows = kSettingsIndex.where((e) => e.label == label).toList();
  expect(rows.length, 1, reason: '$label appears exactly once in the index');
  return rows.single;
}

void main() {
  test('every pre-move label is still searchable, under Audio, on its sub-page',
      () {
    expect(_preMove.length, 58);
    _preMove.forEach((label, page) {
      final e = _only(label);
      expect(e.category, SettingsCategory.audio, reason: label);
      expect(e.subPage, page, reason: label);
    });
  });

  test('Audio rows are exactly the moved ones plus the new ones', () {
    final audioLabels = {
      for (final e in kSettingsIndex)
        if (e.category == SettingsCategory.audio) e.label,
    };
    expect(audioLabels, {..._preMove.keys, ..._added.keys});
    for (final e in kSettingsIndex) {
      // A sub-page key only makes sense on an Audio row, and vice versa.
      expect(e.subPage != null, e.category == SettingsCategory.audio,
          reason: e.label);
    }
    _added.forEach((label, page) => expect(_only(label).subPage, page));
  });

  test('every sub-page can be reached from search', () {
    for (final page in AudioSubPage.values) {
      expect(
        kSettingsIndex.where((e) => e.subPage == page),
        isNotEmpty,
        reason: page.title,
      );
    }
  });

  test('each section widget\'s own labels point at its sub-page', () {
    void check(Iterable<String> labels, AudioSubPage page,
        {Set<String> except = const {}}) {
      for (final label in labels) {
        if (except.contains(label)) continue;
        expect(_only(label).subPage, page, reason: label);
      }
    }

    check(CrossfadeSettingsSection.labels, AudioSubPage.crossfade);
    check(ReplayGainSettingsSection.labels, AudioSubPage.replayGain);
    check(AudioFocusSettingsSection.labels, AudioSubPage.audioFocus);
    check(EqualizerSettingsSection.labels, AudioSubPage.equalizer);
    check(DvcSettingsSection.labels, AudioSubPage.dvc);
    // Advanced also offers a second copy of the equalizer-preset restore.
    check(AdvancedSettingsSection.labels, AudioSubPage.advanced,
        except: {...EqualizerSettingsSection.labels});
  });

  test('Playback keeps Autoplay; the audio rows left it', () {
    expect(
      kSettingsIndex
          .where((e) => e.category == SettingsCategory.playback)
          .map((e) => e.label),
      ['Autoplay'],
    );
  });

  group('categories', () {
    test('Audio sits under SOUND and is the only Sound category', () {
      expect(SettingsCategory.audio.title, 'Audio');
      expect(
        SettingsCategory.values
            .where((c) => c.group.label == 'SOUND')
            .toList(),
        [SettingsCategory.audio],
      );
    });

    test('the folded categories are gone, headset stays', () {
      final names = SettingsCategory.values.map((c) => c.name).toSet();
      expect(names, isNot(contains('equalizer')));
      expect(names, isNot(contains('tone')));
      expect(names, isNot(contains('crossfade')));
      expect(names, contains('headset'));
    });

    test('the full list shows Audio, Headset and Playback', () {
      final shown = visibleSettingsCategories(isEqMode: false, isAndroid: true);
      expect(shown, containsAll([
        SettingsCategory.audio,
        SettingsCategory.headset,
        SettingsCategory.playback,
      ]));
      expect(shown, contains(SettingsCategory.appMode));
    });

    test('App Mode stays Android-only outside Equalizer-only mode', () {
      expect(
        visibleSettingsCategories(isEqMode: false, isAndroid: false),
        isNot(contains(SettingsCategory.appMode)),
      );
    });

    test('Equalizer-only mode shows App Mode, Audio and About', () {
      for (final android in [true, false]) {
        expect(
          visibleSettingsCategories(isEqMode: true, isAndroid: android),
          [
            SettingsCategory.appMode,
            SettingsCategory.audio,
            SettingsCategory.about,
          ],
        );
      }
    });

    test('Equalizer-only Audio list: Info, Equalizer, DVC, Advanced, Effects',
        () {
      expect(
        AudioSubPage.values.where((p) => p.inEqualizerOnlyMode),
        [
          AudioSubPage.info,
          AudioSubPage.equalizer,
          AudioSubPage.dvc,
          AudioSubPage.advanced,
          AudioSubPage.effects,
        ],
      );
    });

    test('no category is empty, on either platform or mode', () {
      for (final eq in [false, true]) {
        for (final android in [true, false]) {
          final reachable = {
            for (final e in kSettingsIndex)
              if (e.availableOn(isAndroid: android) &&
                  (!eq || (e.subPage?.inEqualizerOnlyMode ?? true)))
                e.category,
          };
          for (final c
              in visibleSettingsCategories(isEqMode: eq, isAndroid: android)) {
            // App Mode and its page are not searchable rows on iOS.
            if (c == SettingsCategory.appMode && !android) continue;
            expect(reachable, contains(c),
                reason: '${c.title} (eq=$eq, android=$android)');
          }
        }
      }
    });
  });

  group('search', () {
    test('a Replay Gain hit carries the Replay Gain sub-page', () {
      final hits = searchSettingsIndex('replay gain',
          isEqMode: false, isAndroid: true);
      expect(hits, isNotEmpty);
      expect(hits.map((e) => e.label), contains('RG preamp'));
      expect(hits.firstWhere((e) => e.label == 'Replay Gain').subPage,
          AudioSubPage.replayGain);
    });

    test('a sub-page title finds its rows', () {
      final hits = searchSettingsIndex('audio focus',
          isEqMode: false, isAndroid: true);
      expect(hits.map((e) => e.label), contains('Resume after call'));
    });

    test('a hit opens AudioSettingsPage on the sub-page', () {
      for (final e in kSettingsIndex.where((e) => e.subPage != null)) {
        final page = settingsDestination(e.category, e.subPage);
        expect(page, isA<AudioSettingsPage>(), reason: e.label);
        expect((page as AudioSettingsPage).open, e.subPage, reason: e.label);
      }
      final other = settingsDestination(SettingsCategory.playback);
      expect(other, isA<Settings>());
      expect((other as Settings).category, SettingsCategory.playback);
    });

    test('Equalizer-only mode hides player sub-pages from search', () {
      List<String> labels(String q) =>
          searchSettingsIndex(q, isEqMode: true, isAndroid: true)
              .map((e) => e.label)
              .toList();
      expect(labels('crossfade'), isEmpty);
      expect(labels('replay gain'), isEmpty);
      expect(labels('duck'), isEmpty);
      expect(labels('outputs'), isEmpty);
      expect(labels('limiter'), contains('Limiter'));
      expect(labels('preamp'), contains('No DVC – preamp reduction'));
      expect(labels('bands'), contains('Number of bands'));
      expect(labels('audio info'), contains('Audio Info'));
    });

    test('Android-only rows are left out of iOS search', () {
      for (final q in ['dvc', 'volume', 'musicfx', 'focus', 'audio']) {
        final hits = searchSettingsIndex(q, isEqMode: false, isAndroid: false);
        expect(hits.where((e) => e.androidOnly), isEmpty, reason: q);
      }
      final android =
          searchSettingsIndex('dvc', isEqMode: false, isAndroid: true);
      expect(android.map((e) => e.label),
          contains('Enable direct volume control'));
      final ios =
          searchSettingsIndex('dvc', isEqMode: false, isAndroid: false);
      expect(ios.map((e) => e.label),
          isNot(contains('Enable direct volume control')));
      expect(ios.map((e) => e.label), contains('No DVC – preamp reduction'));
    });
  });
}
