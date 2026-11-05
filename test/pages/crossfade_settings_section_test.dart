/// Settings → Crossfade & Gapless: every control is there, the search index
/// points at things the page actually shows, and choices are reported.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/pages/Settings.dart';
import 'package:eq_app/pages/crossfade_settings_section.dart';
import 'package:eq_app/player/fade_settings.dart';

void main() {
  Future<List<FadeSettings>> pump(WidgetTester tester,
      [FadeSettings settings = const FadeSettings()]) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final changes = <FadeSettings>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CrossfadeSettingsSection(
            settings: settings,
            onChanged: changes.add,
          ),
        ),
      ),
    ));
    return changes;
  }

  testWidgets('shows all ten controls', (tester) async {
    await pump(tester);
    for (final label in CrossfadeSettingsSection.labels) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  /// The search index is written by hand, and an entry naming a control the
  /// page does not have lands a search on a page that does not contain what
  /// was asked for.
  test('every search entry for this page names a control on it', () {
    final entries = [
      for (final e in kSettingsIndex)
        if (e.category == SettingsCategory.crossfade) e.label,
    ];
    expect(entries, isNotEmpty);
    for (final label in entries) {
      expect(CrossfadeSettingsSection.labels, contains(label));
    }
    expect(entries.toSet(), CrossfadeSettingsSection.labels.toSet(),
        reason: 'and every control can be searched for');
  });

  testWidgets('choosing a mode reports it', (tester) async {
    final changes = await pump(tester);
    await tester.tap(find.text('Auto-advance fading'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All songs'));
    await tester.pumpAndSettle();
    expect(changes.single.autoAdvance, AutoAdvanceFading.allSongs);
  });

  testWidgets('the current choices are shown', (tester) async {
    await pump(
      tester,
      const FadeSettings(
        autoAdvance: AutoAdvanceFading.shuffledSongs,
        manualChange: ManualChangeFading.none,
        crossfadeMs: 7500,
      ),
    );
    expect(find.text('Shuffled songs'), findsOneWidget);
    expect(find.text('No fading'), findsOneWidget);
    expect(find.text('7.5 s'), findsOneWidget);
  });

  test('lengths read naturally', () {
    expect(formatFadeMs(100), '100 ms');
    expect(formatFadeMs(999), '999 ms');
    expect(formatFadeMs(5000), '5 s');
    expect(formatFadeMs(5100), '5.1 s');
    expect(formatFadeMs(5050), '5.05 s');
    expect(formatFadeMs(15000), '15 s');
  });
}
