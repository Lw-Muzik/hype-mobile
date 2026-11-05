/// Outputs: a row per kind and per known device, the active one marked, each
/// editable.
library;

import 'package:eq_app/audio/headset/output_kind.dart';
import 'package:eq_app/audio/output/output_profiles.dart';
import 'package:eq_app/pages/output_profiles_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<(AudioOutputKind, OutputProfile)> kindChanges;
  late List<(String, AudioOutputKind, OutputProfile?)> deviceChanges;

  Future<void> pump(
    WidgetTester tester, {
    OutputProfiles profiles = const OutputProfiles(),
    ActiveRoute? active,
    bool isAndroid = true,
  }) async {
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    kindChanges = [];
    deviceChanges = [];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OutputProfilesView(
            profiles: profiles,
            active: active,
            presetNames: const ['Flat', 'Bass', 'Rock'],
            isAndroid: isAndroid,
            onKind: (k, p) => kindChanges.add((k, p)),
            onDevice: (n, k, p) => deviceChanges.add((n, k, p)),
            onForget: (_) {},
          ),
        ),
      ),
    );
  }

  testWidgets('lists the five kinds', (tester) async {
    await pump(tester);
    for (final t in [
      'Speaker',
      'Wired headphones',
      'Bluetooth',
      'USB audio',
      'Other',
    ]) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
  });

  testWidgets('marks the active output', (tester) async {
    await pump(
      tester,
      active: const ActiveRoute(kind: AudioOutputKind.bluetooth),
    );
    expect(find.text('Active'), findsOneWidget);
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Active'),
          matching: find.byType(ExpansionTile),
        ),
        matching: find.text('Bluetooth'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a named device lists under Devices and is the active one', (
    tester,
  ) async {
    await pump(
      tester,
      profiles: const OutputProfiles().rememberDevice(
        'WH-1000XM4',
        AudioOutputKind.bluetooth,
      ),
      active: const ActiveRoute(
        kind: AudioOutputKind.bluetooth,
        deviceName: 'WH-1000XM4',
      ),
    );
    expect(find.text('WH-1000XM4'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
  });

  testWidgets('a summary says what a profile does', (tester) async {
    await pump(
      tester,
      profiles: const OutputProfiles().withKind(
        AudioOutputKind.wired,
        const OutputProfile(eqPreset: 'Bass', noDuck: true),
      ),
    );
    expect(find.text('Bass · No Duck'), findsOneWidget);
    expect(find.text('Same as everywhere'), findsNWidgets(4));
  });

  testWidgets('a flag switch edits the kind profile', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Speaker'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, 'No Duck'));
    await tester.pumpAndSettle();
    expect(kindChanges.single.$1, AudioOutputKind.speaker);
    expect(kindChanges.single.$2.noDuck, isTrue);
  });

  testWidgets('No DVC is Android only', (tester) async {
    await pump(tester, isAndroid: false);
    await tester.tap(find.text('Speaker'));
    await tester.pumpAndSettle();
    expect(find.text('No DVC'), findsNothing);
    expect(find.text('No Duck'), findsOneWidget);
  });

  testWidgets('all five flags are offered on Android', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Speaker'));
    await tester.pumpAndSettle();
    for (final t in [
      'No Equ/Tone',
      'No Duck',
      'Ignore audio focus',
      'No DVC',
      'No headroom gain reduction',
    ]) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
  });

  testWidgets('the EQ preset is chosen from a sheet', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Speaker'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('EQ preset'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rock'));
    await tester.pumpAndSettle();
    expect(kindChanges.single.$2.eqPreset, 'Rock');
  });

  testWidgets('a device follows its kind until given a profile of its own', (
    tester,
  ) async {
    await pump(
      tester,
      profiles: const OutputProfiles()
          .withKind(
            AudioOutputKind.bluetooth,
            const OutputProfile(noDuck: true),
          )
          .rememberDevice('Buds', AudioOutputKind.bluetooth),
    );
    expect(find.text('Same as Bluetooth'), findsOneWidget);
    await tester.tap(find.text('Buds'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, 'Own profile'));
    await tester.pumpAndSettle();
    final c = deviceChanges.single;
    expect(c.$1, 'Buds');
    expect(c.$3!.noDuck, isTrue); // starts from the kind's settings
  });

  testWidgets('a legacy saved curve reads as such', (tester) async {
    await pump(
      tester,
      profiles: const OutputProfiles().withKind(
        AudioOutputKind.usb,
        const OutputProfile(eqPreset: '_device_usb_audio'),
      ),
    );
    expect(find.text('Saved curve'), findsOneWidget);
  });
}
