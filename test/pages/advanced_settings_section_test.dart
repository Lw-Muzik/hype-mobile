import 'package:eq_app/audio/advanced/advanced_settings.dart';
import 'package:eq_app/pages/advanced_settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<AdvancedSettings>> pump(
    WidgetTester tester, {
    AdvancedSettings settings = const AdvancedSettings(),
    bool isIos = false,
    bool musicFxAvailable = true,
    VoidCallback? onEq,
    VoidCallback? onReverb,
    VoidCallback? onMusicFx,
  }) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final changes = <AdvancedSettings>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AdvancedSettingsSection(
              settings: settings,
              onChanged: changes.add,
              isIos: isIos,
              musicFxAvailable: musicFxAvailable,
              onOpenMusicFx: onMusicFx ?? () {},
              onRestoreEqPresets: onEq ?? () {},
              onRestoreReverbPresets: onReverb ?? () {},
            ),
          ),
        ),
      ),
    );
    return changes;
  }

  testWidgets('Android shows all seven rows', (tester) async {
    await pump(tester);
    expect(AdvancedSettingsSection.labels.length, 7);
    for (final l in AdvancedSettingsSection.labels) {
      expect(find.text(l), findsOneWidget, reason: l);
    }
  });

  testWidgets('iOS hides the Android-only rows', (tester) async {
    await pump(tester, isIos: true);
    for (final l in AdvancedSettingsSection.androidOnlyLabels) {
      expect(find.text(l), findsNothing, reason: l);
    }
    expect(find.text('Pause/resume on volume'), findsOneWidget);
    expect(find.text('Restore equalizer presets'), findsOneWidget);
    expect(find.text('Restore reverb presets'), findsOneWidget);
    expect(AdvancedSettingsSection.androidOnlyLabels, [
      'Volume levels',
      'Volume panel',
      'MusicFX',
      'Force audio on audio focus change',
    ]);
  });

  testWidgets('switches write through copyWith', (tester) async {
    final changes = await pump(tester);
    await tester.tap(find.text('Volume panel'));
    await tester.tap(find.text('Pause/resume on volume'));
    await tester.tap(find.text('Force audio on audio focus change'));
    expect(changes[0].volumePanel, isTrue);
    expect(changes[1].pauseResumeOnVolume, isTrue);
    expect(changes[2].forceAudioOnFocusChange, isTrue);
  });

  testWidgets('volume levels chooser lists the five options', (tester) async {
    final changes = await pump(tester);
    expect(find.text('System default'), findsOneWidget);
    await tester.tap(find.text('Volume levels'));
    await tester.pumpAndSettle();
    for (final o in ['30 steps', '50 steps', '75 steps', '100 steps']) {
      expect(find.text(o), findsOneWidget, reason: o);
    }
    await tester.tap(find.text('100 steps'));
    await tester.pumpAndSettle();
    expect(changes.single.volumeLevels, VolumeLevels.l100);
  });

  testWidgets('MusicFX: switch, and the open button only when on', (
    tester,
  ) async {
    var opened = 0;
    final changes = await pump(tester, onMusicFx: () => opened++);
    expect(find.text('Open MusicFX'), findsNothing);
    await tester.tap(find.text('MusicFX'));
    expect(changes.single.musicFx, isTrue);
    await pump(
      tester,
      settings: const AdvancedSettings(musicFx: true),
      onMusicFx: () => opened++,
    );
    await tester.tap(find.text('Open MusicFX'));
    expect(opened, 1);
  });

  testWidgets('MusicFX row is disabled when no handler resolves', (
    tester,
  ) async {
    await pump(
      tester,
      settings: const AdvancedSettings(musicFx: true),
      musicFxAvailable: false,
    );
    expect(find.text('Open MusicFX'), findsNothing);
    final sw = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'MusicFX'),
    );
    expect(sw.onChanged, isNull);
  });

  testWidgets('restore actions ask first and run only on confirm', (
    tester,
  ) async {
    var eq = 0, rev = 0;
    await pump(tester, onEq: () => eq++, onReverb: () => rev++);
    await tester.tap(find.text('Restore equalizer presets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(eq, 0);
    await tester.tap(find.text('Restore equalizer presets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(eq, 1);
    await tester.tap(find.text('Restore reverb presets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(rev, 1);
  });
}
