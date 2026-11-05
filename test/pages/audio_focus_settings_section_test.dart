/// Settings → Playback → Audio Focus: the eight rows, the iOS subset, the
/// dimmed dependants, and the search index agreeing with the labels.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/audio/focus/audio_focus_settings.dart';
import 'package:eq_app/pages/Settings.dart';
import 'package:eq_app/pages/audio_focus_settings_section.dart';

void main() {
  Future<List<AudioFocusSettings>> pump(
    WidgetTester tester, {
    AudioFocusSettings settings = const AudioFocusSettings(),
    bool isIos = false,
  }) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final changes = <AudioFocusSettings>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AudioFocusSettingsSection(
            settings: settings,
            onChanged: changes.add,
            isIos: isIos,
          ),
        ),
      ),
    ));
    return changes;
  }

  SwitchListTile row(WidgetTester tester, String label) =>
      tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, label));

  testWidgets('Android shows all eight labels', (tester) async {
    await pump(tester);
    expect(AudioFocusSettingsSection.labels.length, 8);
    for (final label in AudioFocusSettingsSection.labels) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('iOS shows only the three shared rows', (tester) async {
    await pump(tester, isIos: true);
    for (final label in AudioFocusSettingsSection.labels) {
      final both = !AudioFocusSettingsSection.androidOnlyLabels.contains(label);
      expect(find.text(label), both ? findsOneWidget : findsNothing,
          reason: label);
    }
    expect(find.text('Resume after call'), findsOneWidget);
    expect(find.text('Resume on start'), findsOneWidget);
    expect(find.text('Resume on reopen'), findsOneWidget);
    expect(AudioFocusSettingsSection.androidOnlyLabels.length, 5);
  });

  testWidgets('Pause in call shows on and disabled while Short is on',
      (tester) async {
    await pump(tester, settings: const AudioFocusSettings(pauseInCall: false));
    final r = row(tester, 'Pause in call');
    expect(r.value, isTrue);
    expect(r.onChanged, isNull);
  });

  testWidgets('Pause in call reports when Short is off', (tester) async {
    final changes = await pump(
      tester,
      settings: const AudioFocusSettings(
          shortFocusChange: false, pauseInCall: false),
    );
    await tester.tap(find.text('Pause in call'));
    await tester.pump();
    expect(changes.single.pauseInCall, isTrue);
  });

  testWidgets('with Short off, focus gain and duck are dimmed',
      (tester) async {
    await pump(tester,
        settings: const AudioFocusSettings(shortFocusChange: false));
    expect(row(tester, 'Resume on focus gain').onChanged, isNull);
    expect(row(tester, 'Duck volume').onChanged, isNull);
    expect(row(tester, 'Pause in call').onChanged, isNotNull);
  });

  testWidgets('with Short on, focus gain and duck are live', (tester) async {
    await pump(tester);
    expect(row(tester, 'Resume on focus gain').onChanged, isNotNull);
    expect(row(tester, 'Duck volume').onChanged, isNotNull);
  });

  testWidgets('Resume on reopen is dimmed while Resume on start is off',
      (tester) async {
    await pump(tester);
    expect(row(tester, 'Resume on reopen').onChanged, isNull);
    await pump(tester,
        settings: const AudioFocusSettings(resumeOnStart: true));
    expect(row(tester, 'Resume on reopen').onChanged, isNotNull);
  });

  testWidgets('a toggle reports the changed settings', (tester) async {
    final changes = await pump(tester);
    await tester.tap(find.text('Resume on start'));
    await tester.pump();
    expect(changes.single.resumeOnStart, isTrue);
    expect(changes.single.resumeAfterCall, isTrue, reason: 'others kept');
  });

  test('every label has a playback index entry; android-only flags agree', () {
    for (final label in AudioFocusSettingsSection.labels) {
      final e = kSettingsIndex.where((e) => e.label == label).toList();
      expect(e.length, 1, reason: label);
      expect(e.single.category, SettingsCategory.playback, reason: label);
      final androidOnly =
          AudioFocusSettingsSection.androidOnlyLabels.contains(label);
      expect(e.single.androidOnly, androidOnly, reason: label);
      expect(e.single.availableOn(isAndroid: false), !androidOnly,
          reason: label);
      expect(e.single.availableOn(isAndroid: true), isTrue, reason: label);
    }
    expect(
      AudioFocusSettingsSection.androidOnlyLabels.toSet().difference(
          AudioFocusSettingsSection.labels.toSet()),
      isEmpty,
    );
  });
}
