/// Settings → Playback → Replay Gain: the four controls are there, dimmed
/// (not hidden) while off, choices are reported, and the search index agrees.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/audio/replay_gain/replay_gain.dart';
import 'package:eq_app/pages/Settings.dart';
import 'package:eq_app/pages/audio_sub_page.dart';
import 'package:eq_app/pages/replay_gain_settings_section.dart';

void main() {
  Future<List<ReplayGainSettings>> pump(
    WidgetTester tester, [
    ReplayGainSettings? settings,
    String? disabledReason,
  ]) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final changes = <ReplayGainSettings>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ReplayGainSettingsSection(
            settings: settings ?? ReplayGainSettings(),
            onChanged: changes.add,
            disabledReason: disabledReason,
          ),
        ),
      ),
    ));
    return changes;
  }

  testWidgets('shows the four labels', (tester) async {
    await pump(tester);
    for (final label in ReplayGainSettingsSection.labels) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(ReplayGainSettingsSection.labels.length, 4);
  });

  testWidgets('a disabled reason shows and every control stops reporting',
      (tester) async {
    final changes = await pump(
      tester,
      ReplayGainSettings(mode: ReplayGainMode.apply),
      'Not here',
    );
    expect(find.text('Not here'), findsOneWidget);
    await tester.tap(find.text('Replay Gain'));
    await tester.pumpAndSettle();
    expect(find.text('Songs play at their own volume'), findsNothing,
        reason: 'no list opens');
    await tester.tap(find.text('Source'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Slider).first, const Offset(100, 0));
    await tester.pump();
    expect(changes, isEmpty);
    final slider = tester.widget<Slider>(find.byType(Slider).first);
    expect(slider.onChanged, isNull);
  });

  testWidgets('choosing "Apply gain" reports apply', (tester) async {
    final changes = await pump(tester);
    await tester.tap(find.text('Replay Gain'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply gain'));
    await tester.pumpAndSettle();
    expect(changes.single.mode, ReplayGainMode.apply);
  });

  testWidgets('choosing a source reports it', (tester) async {
    final changes = await pump(
      tester,
      ReplayGainSettings(mode: ReplayGainMode.apply),
    );
    await tester.tap(find.text('Source'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Track'));
    await tester.pumpAndSettle();
    expect(changes.single.source, ReplayGainSource.track);
  });

  testWidgets('Source and preamps are dimmed, not hidden, while off',
      (tester) async {
    await pump(tester);
    expect(find.byType(Slider), findsNWidgets(2));
    for (final s in tester.widgetList<Slider>(find.byType(Slider))) {
      expect(s.onChanged, isNull);
    }
    expect(find.text('Source'), findsOneWidget);
    // Tapping the dimmed Source tile opens nothing.
    await tester.tap(find.text('Source'));
    await tester.pumpAndSettle();
    expect(find.text('Album'), findsOneWidget); // only the tile's own subtitle
  });

  testWidgets('sliders are live when applying, and show %.1f dB',
      (tester) async {
    await pump(
      tester,
      ReplayGainSettings(mode: ReplayGainMode.apply, preampDb: 3.5),
    );
    for (final s in tester.widgetList<Slider>(find.byType(Slider))) {
      expect(s.onChanged, isNotNull);
      expect(s.min, -16.0);
      expect(s.max, 16.0);
      expect(s.divisions, 320);
    }
    expect(find.text('3.5 dB'), findsOneWidget);
    expect(find.text('0.0 dB'), findsOneWidget);
  });

  test('every search entry for this section names a label on it', () {
    final entries = [
      for (final e in kSettingsIndex)
        if (ReplayGainSettingsSection.labels.contains(e.label)) e.label,
    ];
    expect(entries.toSet(), ReplayGainSettingsSection.labels.toSet());
    for (final e in kSettingsIndex) {
      if (ReplayGainSettingsSection.labels.contains(e.label)) {
        expect(e.category, SettingsCategory.audio, reason: e.label);
        expect(e.subPage, AudioSubPage.replayGain, reason: e.label);
      }
    }
    expect(
      kSettingsIndex.where((e) => e.label == 'Replay gain'),
      isEmpty,
      reason: 'the old single row is replaced',
    );
  });

  final active = ReplayGainSettings(mode: ReplayGainMode.apply);

  testWidgets('a drag reports once, on release, with the snapped value',
      (tester) async {
    final changes = await pump(tester, active);
    final slider = find.byType(Slider).first;
    final g = await tester.startGesture(tester.getCenter(slider));
    await g.moveBy(const Offset(100, 0));
    await tester.pump();
    expect(changes, isEmpty, reason: 'nothing mid-drag');
    await g.up();
    await tester.pump();
    expect(changes.length, 1);
    final v = changes.single.preampDb;
    expect(v, greaterThan(0));
    expect((v * 10).roundToDouble(), closeTo(v * 10, 1e-9));
  });

  testWidgets('a drag ending near the centre reports exactly 0.0',
      (tester) async {
    final changes = await pump(
      tester,
      ReplayGainSettings(mode: ReplayGainMode.apply, preampDb: 5.0),
    );
    final slider = find.byType(Slider).first;
    final box = tester.getRect(slider);
    final g = await tester.startGesture(
        Offset(box.left + box.width * 0.8, box.center.dy));
    await g.moveTo(Offset(box.center.dx + 1, box.center.dy));
    await g.up();
    await tester.pump();
    expect(changes.length, 1);
    expect(changes.single.preampDb, 0.0);
  });

  testWidgets('keyboard increase reports the stepped value once',
      (tester) async {
    final changes = await pump(tester, active);
    final slider = find.byType(Slider).first;
    final focus = tester
        .widgetList<Focus>(
            find.descendant(of: slider, matching: find.byType(Focus)))
        .firstWhere((f) => f.focusNode != null);
    focus.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(changes.length, 1);
    expect(changes.single.preampDb, closeTo(0.1, 1e-9));
  });

  testWidgets('semantics increase reports the stepped value once',
      (tester) async {
    final handle = tester.ensureSemantics();
    final changes = await pump(tester, active);
    tester.semantics.increase(
        find.semantics.byAction(SemanticsAction.increase).first);
    await tester.pump();
    expect(changes.length, 1);
    expect(changes.single.preampDb, closeTo(0.1, 1e-9));
    handle.dispose();
  });
}
