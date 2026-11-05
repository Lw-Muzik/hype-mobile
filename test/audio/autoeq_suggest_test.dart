import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eq_app/audio/eq/autoeq_suggest.dart';
import 'package:eq_app/models/speaker_profile.dart';
import 'package:eq_app/services/autoeq_suggestions.dart';

SpeakerProfile _p(String name) => SpeakerProfile(
  name: name,
  source: '',
  category: 'headphone',
  preamp: 0,
  filters: const [],
);

void main() {
  autoEqLaunchTests();
  final profiles = [
    _p('Sony WH-1000XM4'),
    _p('Sony WH-1000XM4 (ANC Off)'),
    _p('Apple AirPods'),
    _p('Apple AirPods Pro'),
    _p('Apple Airpods Pro 2'),
    _p('Samsung Galaxy Buds Pro'),
    _p('FlipEars Aegis'),
    _p('Cardas A8'),
  ];

  group('matchAutoEqProfile', () {
    test('model-only name matches full profile', () {
      expect(
        matchAutoEqProfile('WH-1000XM4', profiles)?.name,
        'Sony WH-1000XM4',
      );
    });
    test('possessive device name picks longest contained model', () {
      expect(
        matchAutoEqProfile("Bruno's AirPods Pro", profiles)?.name,
        'Apple AirPods Pro',
      );
    });
    test('parenthesised suffix is ignored', () {
      expect(
        matchAutoEqProfile('Galaxy Buds Pro (A1B2)', profiles)?.name,
        'Samsung Galaxy Buds Pro',
      );
    });
    test('unknown and too-short names give null', () {
      expect(matchAutoEqProfile('JBL Flip 5', profiles), isNull);
      expect(matchAutoEqProfile('Pro', profiles), isNull);
    });
    test('generic names never match', () {
      final more = [
        ...profiles,
        _p('OnePlus Buds'),
        _p('AKG N60 NC Wireless'),
        _p('Xbox Stereo Headset'),
        _p('KZ Z10 Pro 2'),
      ];
      for (final n in [
        'Buds',
        'Headset',
        'Wireless',
        'Pro 2',
        'Bluetooth Audio',
      ]) {
        expect(matchAutoEqProfile(n, more), isNull, reason: n);
      }
    });
    test('normaliseDeviceName', () {
      expect(normaliseDeviceName('Galaxy Buds Pro (A1B2)'), 'galaxybudspro');
      expect(normaliseDeviceName('WH-1000XM4'), 'wh1000xm4');
    });
  });

  group('autoEqSuggestion gating', () {
    OutputDeviceEvent bt([String n = 'WH-1000XM4']) =>
        OutputDeviceEvent(name: n, kind: OutputKind.bluetooth);
    SpeakerProfile? run({
      OutputDeviceEvent? device,
      bool enabled = true,
      bool systemWide = false,
      Set<String> dismissed = const {},
      Set<String> asked = const {},
      String? active,
    }) => autoEqSuggestion(
      device: device ?? bt(),
      enabled: enabled,
      systemWide: systemWide,
      dismissed: dismissed,
      askedThisSession: asked,
      activeProfile: active,
      profiles: profiles,
    );

    test('happy path', () => expect(run()?.name, 'Sony WH-1000XM4'));
    test('disabled', () => expect(run(enabled: false), isNull));
    test('system-wide', () => expect(run(systemWide: true), isNull));
    test('dismissed', () => expect(run(dismissed: {'wh1000xm4'}), isNull));
    test('asked this session', () => expect(run(asked: {'wh1000xm4'}), isNull));
    test(
      'already active',
      () => expect(run(active: 'Sony WH-1000XM4'), isNull),
    );
    test(
      'kind other',
      () => expect(
        run(
          device: const OutputDeviceEvent(
            name: 'WH-1000XM4',
            kind: OutputKind.other,
          ),
        ),
        isNull,
      ),
    );
  });

  group('AutoEqDismissals', () {
    test('add then reset', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await AutoEqDismissals.add(prefs, 'WH-1000XM4');
      expect(AutoEqDismissals.load(prefs), contains('wh1000xm4'));
      await AutoEqDismissals.reset(prefs);
      expect(AutoEqDismissals.load(prefs), isEmpty);
    });
  });
}

void autoEqLaunchTests() {
  group('AutoEqSuggestions at launch', () {
    testWidgets('waits for the navigator, then asks once', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = (await tester.runAsync(SharedPreferences.getInstance))!;
      final key = GlobalKey<NavigatorState>();
      final applied = <String>[];
      final frames = <Completer<void>>[];
      final service = AutoEqSuggestions(
        enabled: () => true,
        systemWide: () => false,
        activeProfile: () => null,
        apply: (n) async => applied.add(n),
        profiles: () async => [_p('Sony WH-1000XM4')],
        prefs: prefs,
        navigatorKey: key,
        devices: const Stream.empty(),
        initialDevices: () async => const [
          OutputDeviceEvent(name: 'WH-1000XM4', kind: OutputKind.bluetooth),
        ],
        nextFrame: () {
          final c = Completer<void>();
          frames.add(c);
          return c.future;
        },
      );
      final started = service.start();
      for (var i = 0; i < 3; i++) {
        await tester.pump();
        expect(frames.length, i + 1, reason: 'one wait per frame');
        if (i == 2) {
          await tester.pumpWidget(
            MaterialApp(navigatorKey: key, home: const Scaffold()),
          );
        }
        frames.last.complete();
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Tune for these headphones?'), findsOneWidget);
      await tester.tap(find.text('Apply'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await started;
      expect(applied, ['Sony WH-1000XM4']);
      expect(frames.length, 3);
      await tester.runAsync(service.dispose);
    });

    testWidgets('gives up silently when no navigator ever appears',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = (await tester.runAsync(SharedPreferences.getInstance))!;
      var waits = 0;
      final service = AutoEqSuggestions(
        enabled: () => true,
        systemWide: () => false,
        activeProfile: () => null,
        apply: (n) async {},
        profiles: () async => [_p('Sony WH-1000XM4')],
        prefs: prefs,
        navigatorKey: GlobalKey<NavigatorState>(),
        devices: const Stream.empty(),
        initialDevices: () async => const [
          OutputDeviceEvent(name: 'WH-1000XM4', kind: OutputKind.bluetooth),
        ],
        nextFrame: () async => waits++,
      );
      await service.start();
      expect(waits, 10);
      await tester.runAsync(service.dispose);
    });
  });
}
