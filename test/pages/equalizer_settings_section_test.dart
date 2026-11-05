/// Settings → Equalizer: every control is there, choices are reported, rows
/// that do not apply are dimmed (not hidden), Restore asks first, and the
/// search index agrees with the page.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/audio/eq/equalizer_settings.dart';
import 'package:eq_app/pages/Settings.dart';
import 'package:eq_app/pages/audio_sub_page.dart';
import 'package:eq_app/pages/equalizer_settings_section.dart';

class _Calls {
  final changes = <EqualizerSettings>[];
  int resets = 0;
  int restores = 0;
}

void main() {
  Future<_Calls> pump(
    WidgetTester tester, [
    EqualizerSettings settings = const EqualizerSettings(),
  ]) async {
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final calls = _Calls();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: EqualizerSettingsSection(
            settings: settings,
            onChanged: calls.changes.add,
            onResetAutoEqSuggestions: () => calls.resets++,
            onRestorePresets: () => calls.restores++,
          ),
        ),
      ),
    ));
    return calls;
  }

  Finder sliderFinder(String title) => find.descendant(
    of: find.ancestor(of: find.text(title), matching: find.byType(Column))
        .first,
    matching: find.byType(Slider),
  );

  Slider sliderOf(WidgetTester tester, String title) =>
      tester.widget<Slider>(sliderFinder(title));

  testWidgets('shows every label once', (tester) async {
    await pump(tester);
    for (final label in EqualizerSettingsSection.labels) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(EqualizerSettingsSection.labels.length, 16);
  });

  testWidgets('choosing 24 in Number of bands reports bandCount 24',
      (tester) async {
    final calls = await pump(tester);
    await tester.tap(find.text('Number of bands'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('24'));
    await tester.pumpAndSettle();
    expect(calls.changes.single.bandCount, 24);
  });

  testWidgets('the value-label choosers report their choice', (tester) async {
    final calls = await pump(tester);
    await tester.tap(find.text('Equalizer values'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hidden'));
    await tester.pumpAndSettle();
    expect(calls.changes.single.eqValues, EqValueLabels.hidden);
    await tester.tap(find.text('Tone values'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('dB').last);
    await tester.pumpAndSettle();
    expect(calls.changes.last.toneValues, EqValueLabels.db);
  });

  testWidgets('Number of bands is dimmed while custom is on', (tester) async {
    final calls = await pump(
      tester,
      const EqualizerSettings(customBands: true),
    );
    await tester.tap(find.text('Number of bands'));
    await tester.pumpAndSettle();
    expect(find.text('24'), findsNothing, reason: 'no chooser opens');
    expect(calls.changes, isEmpty);
  });

  testWidgets('Custom number is dimmed, and silent, while custom is off',
      (tester) async {
    final calls = await pump(tester);
    final s = sliderOf(tester, 'Custom number of bands');
    expect(s.onChanged, isNull);
    expect(find.text('Custom number of bands'), findsOneWidget);
    expect(calls.changes, isEmpty);
    await tester.pump();
  });

  testWidgets('Custom number is live when custom is on: 5-32, step 1',
      (tester) async {
    await pump(tester, const EqualizerSettings(customBands: true));
    final s = sliderOf(tester, 'Custom number of bands');
    expect(s.onChanged, isNotNull);
    expect(s.min, 5);
    expect(s.max, 32);
    expect(s.divisions, 27);
  });

  testWidgets('First/Last are dimmed on an ISO count, live otherwise',
      (tester) async {
    await pump(tester, const EqualizerSettings(bandCount: 10));
    expect(sliderOf(tester, 'First frequency').onChanged, isNull);
    expect(sliderOf(tester, 'Last frequency').onChanged, isNull);
    expect(find.text('First frequency'), findsOneWidget);

    await pump(tester, const EqualizerSettings(bandCount: 12));
    expect(sliderOf(tester, 'First frequency').onChanged, isNotNull);
    expect(sliderOf(tester, 'Last frequency').onChanged, isNotNull);
  });

  testWidgets('slider ranges, steps and read-outs', (tester) async {
    await pump(tester, const EqualizerSettings(bandCount: 12));
    final first = sliderOf(tester, 'First frequency');
    expect((first.min, first.max, first.divisions), (5, 200, 195));
    final last = sliderOf(tester, 'Last frequency');
    expect((last.min, last.max, last.divisions), (14.0, 20.0, 12));
    final bass = sliderOf(tester, 'Bass frequency');
    expect((bass.min, bass.max, bass.divisions), (20, 250, 23));
    final treble = sliderOf(tester, 'Treble frequency');
    expect((treble.min, treble.max, treble.divisions), (5, 15, 10));
    final q = sliderOf(tester, 'Bass Q');
    expect((q.min, q.max, q.divisions), (0.1, 2.0, 38));
    expect(find.text('20 Hz'), findsOneWidget);
    expect(find.text('16.0 kHz'), findsOneWidget);
    expect(find.text('90 Hz'), findsOneWidget);
    expect(find.text('10 kHz'), findsOneWidget);
    expect(find.text('0.80'), findsOneWidget);
    expect(find.text('0.60'), findsOneWidget);
  });

  testWidgets('a drag reports once, on release', (tester) async {
    final calls = await pump(tester);
    final slider = sliderFinder('Bass frequency');
    final g = await tester.startGesture(tester.getCenter(slider));
    await g.moveBy(const Offset(100, 0));
    await tester.pump();
    expect(calls.changes, isEmpty, reason: 'nothing mid-drag');
    await g.up();
    await tester.pump();
    expect(calls.changes.length, 1);
    expect(calls.changes.single.bassFreq, greaterThan(90));
  });

  testWidgets('a keyboard step commits once', (tester) async {
    final calls = await pump(tester, const EqualizerSettings(bandCount: 12));
    final focus = tester
        .widgetList<Focus>(find.descendant(
          of: sliderFinder('First frequency'),
          matching: find.byType(Focus),
        ))
        .firstWhere((f) => f.focusNode != null);
    focus.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(calls.changes.length, 1);
    expect(calls.changes.single.firstHz, 21);
  });

  testWidgets('a semantics step commits once', (tester) async {
    final handle = tester.ensureSemantics();
    final calls = await pump(tester, const EqualizerSettings(bandCount: 12));
    tester.semantics.increase(
        find.semantics.byAction(SemanticsAction.increase).first);
    await tester.pump();
    expect(calls.changes.length, 1);
    expect(calls.changes.single.firstHz, 21);
    handle.dispose();
  });

  testWidgets('switches report', (tester) async {
    final calls = await pump(tester);
    await tester.tap(find.text('Enable custom bands'));
    await tester.pump();
    expect(calls.changes.last.customBands, isTrue);
    await tester.tap(find.text('Auto save'));
    await tester.pump();
    expect(calls.changes.last.autoSave, isFalse);
    await tester.tap(find.text('Smooth equalizer/tone gains'));
    await tester.pump();
    expect(calls.changes.last.smoothGains, isFalse);
    await tester.tap(find.text('Suggest AutoEq presets'));
    await tester.pump();
    expect(calls.changes.last.suggestAutoEq, isFalse);
  });

  testWidgets('Restore: Cancel never restores, Confirm restores once',
      (tester) async {
    final calls = await pump(tester);
    await tester.tap(find.text('Restore equalizer presets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls.restores, 0);
    await tester.tap(find.text('Restore equalizer presets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(calls.restores, 1);
  });

  testWidgets('Reset disabled AutoEq suggestions calls its callback',
      (tester) async {
    final calls = await pump(tester);
    await tester.tap(find.text('Reset disabled AutoEq suggestions'));
    await tester.pump();
    expect(calls.resets, 1);
  });

  test('every label has a search entry under Audio > Equalizer', () {
    for (final label in EqualizerSettingsSection.labels) {
      expect(
        kSettingsIndex.where(
          (e) =>
              e.label == label &&
              e.category == SettingsCategory.audio &&
              e.subPage == AudioSubPage.equalizer,
        ),
        isNotEmpty,
        reason: label,
      );
    }
  });
}
