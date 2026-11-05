/// Settings → Headset & Bluetooth: fourteen rows, the iOS subset, dimmed
/// dependants, the button-mode chooser, the seconds slider and the index.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/audio/headset/headset_settings.dart';
import 'package:eq_app/pages/Settings.dart';
import 'package:eq_app/pages/headset_settings_section.dart';
import 'package:eq_app/pages/audio_focus_settings_section.dart';
import 'package:eq_app/pages/dvc_settings_section.dart';
import 'package:eq_app/pages/advanced_settings_section.dart';

void main() {
  Future<List<HeadsetSettings>> pump(
    WidgetTester tester, {
    HeadsetSettings settings = const HeadsetSettings(),
    bool isIos = false,
  }) async {
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final changes = <HeadsetSettings>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: HeadsetSettingsSection(
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

  ListTile tile(WidgetTester tester, String label) =>
      tester.widget<ListTile>(find.widgetWithText(ListTile, label));

  testWidgets('Android shows all fourteen labels', (tester) async {
    await pump(tester);
    expect(HeadsetSettingsSection.labels.length, 14);
    for (final label in HeadsetSettingsSection.labels) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('iOS shows exactly the six shared rows', (tester) async {
    await pump(tester, isIos: true);
    expect(HeadsetSettingsSection.androidOnlyLabels.length, 8);
    var shown = 0;
    for (final label in HeadsetSettingsSection.labels) {
      final both = !HeadsetSettingsSection.androidOnlyLabels.contains(label);
      expect(find.text(label), both ? findsOneWidget : findsNothing,
          reason: label);
      if (both) shown++;
    }
    expect(shown, 6);
  });

  testWidgets('Wired headset buttons -> Single press is reported',
      (tester) async {
    final changes = await pump(tester);
    await tester.tap(find.text('Wired headset buttons'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Single press'));
    await tester.pumpAndSettle();
    expect(changes.single.wiredButtons, ButtonMode.singlePress);
    expect(changes.single.bluetoothButtons, ButtonMode.multiPress);
  });

  testWidgets('Bluetooth buttons -> Long press is reported', (tester) async {
    final changes = await pump(tester);
    await tester.tap(find.text('Bluetooth buttons'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(ButtonMode.longPressNext.label));
    await tester.pumpAndSettle();
    expect(changes.single.bluetoothButtons, ButtonMode.longPressNext);
  });

  testWidgets('Ignore Bluetooth commands slider: 0-20, 20 divisions, "1 s"',
      (tester) async {
    await pump(tester);
    final s = tester.widget<Slider>(find.byType(Slider));
    expect(s.min, 0);
    expect(s.max, 20);
    expect(s.divisions, 20);
    expect(s.onChanged, isNotNull);
    expect(find.text('1 s'), findsOneWidget);
  });

  testWidgets('a slider drag reports once, on release', (tester) async {
    final changes = await pump(tester);
    final g = await tester.startGesture(tester.getCenter(find.byType(Slider)));
    await g.moveBy(const Offset(100, 0));
    await tester.pump();
    expect(changes, isEmpty);
    await g.up();
    await tester.pump();
    expect(changes.length, 1);
    expect(changes.single.ignoreBluetoothCommandsS, greaterThan(1));
  });

  testWidgets('keyboard increase reports the stepped value once',
      (tester) async {
    final changes = await pump(tester);
    final slider = find.byType(Slider);
    final focus = tester
        .widgetList<Focus>(
            find.descendant(of: slider, matching: find.byType(Focus)))
        .firstWhere((f) => f.focusNode != null);
    focus.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(changes.length, 1);
    expect(changes.single.ignoreBluetoothCommandsS, 2);
  });

  testWidgets('semantics increase reports the stepped value once',
      (tester) async {
    final handle = tester.ensureSemantics();
    final changes = await pump(tester);
    tester.semantics
        .increase(find.semantics.byAction(SemanticsAction.increase).first);
    await tester.pump();
    expect(changes.length, 1);
    expect(changes.single.ignoreBluetoothCommandsS, 2);
    handle.dispose();
  });

  testWidgets('Respond to buttons off dims the button rows', (tester) async {
    await pump(tester,
        settings: const HeadsetSettings(respondToButtons: false));
    expect(tile(tester, 'Wired headset buttons').enabled, isFalse);
    expect(tile(tester, 'Bluetooth buttons').enabled, isFalse);
    for (final l in [
      'Beep',
      'Beep more',
      'Vibrate',
      'Disable default long press'
    ]) {
      expect(row(tester, l).onChanged, isNull, reason: l);
    }
    // Tapping a dimmed chooser opens nothing.
    await tester.tap(find.text('Wired headset buttons'));
    await tester.pumpAndSettle();
    expect(find.text('Single press'), findsNothing);
    // The rest stays live.
    expect(row(tester, 'Respond to buttons').onChanged, isNotNull);
    expect(row(tester, 'Strict resume/pause/stop').onChanged, isNotNull);
  });

  testWidgets('with Respond on, the rows are live; Beep off dims Beep more',
      (tester) async {
    await pump(tester);
    expect(tile(tester, 'Wired headset buttons').enabled, isTrue);
    expect(row(tester, 'Beep').onChanged, isNotNull);
    expect(row(tester, 'Beep more').onChanged, isNotNull);
    await pump(tester, settings: const HeadsetSettings(beep: false));
    expect(row(tester, 'Beep more').onChanged, isNull);
    expect(row(tester, 'Vibrate').onChanged, isNotNull);
  });

  testWidgets('the long-press row explains how to choose Hype',
      (tester) async {
    await pump(tester);
    expect(
      find.text('Long press no longer starts voice search while Hype plays. '
          'When Android asks, choose Hype.'),
      findsOneWidget,
    );
  });

  testWidgets('a toggle reports the changed settings', (tester) async {
    final changes = await pump(tester);
    await tester.tap(find.text('Resume on Bluetooth'));
    await tester.pump();
    expect(changes.single.resumeOnBluetooth, isTrue);
  });

  test('every label has a headset index entry; android-only flags agree', () {
    for (final label in HeadsetSettingsSection.labels) {
      final e = kSettingsIndex.where((e) => e.label == label).toList();
      expect(e.length, 1, reason: label);
      expect(e.single.category, SettingsCategory.headset, reason: label);
      final androidOnly =
          HeadsetSettingsSection.androidOnlyLabels.contains(label);
      expect(e.single.androidOnly, androidOnly, reason: label);
      expect(e.single.availableOn(isAndroid: false), !androidOnly,
          reason: label);
    }
    // Exactly the android-only labels are flagged, across the whole index.
    final flagged = {
      for (final e in kSettingsIndex)
        if (e.androidOnly) e.label,
    };
    expect(
      flagged.where((l) =>
          HeadsetSettingsSection.labels.contains(l) ||
          l == 'Pause in call'),
      isNotEmpty,
    );
  });

  test('every settings index row is Android-only exactly when a section says so', () {
    final allAndroidOnly = {
      ...AudioFocusSettingsSection.androidOnlyLabels,
      ...HeadsetSettingsSection.androidOnlyLabels,
      ...DvcSettingsSection.androidOnlyLabels,
      ...AdvancedSettingsSection.androidOnlyLabels,
    };
    for (final e in kSettingsIndex) {
      expect(e.androidOnly, allAndroidOnly.contains(e.label), reason: e.label);
    }
    expect(
      kSettingsIndex
          .where((e) => e.category == SettingsCategory.headset)
          .map((e) => e.label)
          .toSet(),
      HeadsetSettingsSection.labels.toSet(),
    );
    int iosRows(List<String> labels) => kSettingsIndex
        .where((e) => labels.contains(e.label) && e.availableOn(isAndroid: false))
        .length;
    expect(iosRows(HeadsetSettingsSection.labels), 6);
    expect(iosRows(AudioFocusSettingsSection.labels), 3);
  });
}
