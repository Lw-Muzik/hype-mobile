import 'dart:async';

import 'package:eq_app/audio/headset/output_kind.dart';
import 'package:eq_app/audio/output/output_profiles.dart';
import 'package:eq_app/services/output_profile_service.dart';
import 'package:flutter_test/flutter_test.dart';

ActiveRoute route(AudioOutputKind k, [String? name]) =>
    ActiveRoute(kind: k, deviceName: name);

class Rig {
  Rig({this.profiles = const OutputProfiles(), String? lastRouteKey}) {
    service = OutputProfileService(
      profiles: () => profiles,
      readRoute: () async => current,
      routeEvents: events.stream,
      applyEqPreset: (n) {
        applied.add(n);
        edited = false;
      },
      curveEdited: () => edited,
      applySpeakerProfile: (n) async {
        speaker = n;
        speakerLog.add('apply $n');
      },
      clearSpeakerProfile: () async {
        speaker = null;
        speakerLog.add('clear');
      },
      activeSpeakerProfile: () => speaker,
      onEffective: (p, r) => effective.add(p),
      onRoute: routes.add,
      beforeRouteChange: (prev, next) =>
          leaving.add('${prev?.key}>${next.key}'),
      lastRouteKey: lastRouteKey,
      settle: Duration.zero,
    );
  }

  OutputProfiles profiles;
  ActiveRoute current = route(AudioOutputKind.speaker);
  bool edited = false;
  String? speaker;
  final applied = <String>[];
  final speakerLog = <String>[];
  final effective = <OutputProfile>[];
  final routes = <ActiveRoute>[];
  final leaving = <String>[];
  final events = StreamController<void>.broadcast();
  late final OutputProfileService service;

  Future<void> go(ActiveRoute r) async {
    current = r;
    events.add(null);
    await pump();
  }

  Future<void> pump() => Future<void>.delayed(Duration.zero);
}

void main() {
  const bass = OutputProfile(eqPreset: 'Bass');

  OutputProfiles bt() => const OutputProfiles()
      .withKind(AudioOutputKind.bluetooth, bass)
      .withKind(
        AudioOutputKind.wired,
        const OutputProfile(eqPreset: 'Flat', noDuck: true),
      );

  test('applies the preset once when the route becomes active', () async {
    final r = Rig(profiles: bt());
    await r.service.start();
    expect(r.applied, isEmpty); // speaker has none
    await r.go(route(AudioOutputKind.bluetooth, 'Buds'));
    expect(r.applied, ['Bass']);
    // The same route reported again does nothing.
    await r.go(route(AudioOutputKind.bluetooth, 'Buds'));
    expect(r.applied, ['Bass']);
  });

  test('a named device uses its own profile, not the kind one', () async {
    final r = Rig(
      profiles: bt().withDevice(
        'Buds',
        AudioOutputKind.bluetooth,
        const OutputProfile(eqPreset: 'Vocal'),
      ),
    );
    await r.service.start();
    await r.go(route(AudioOutputKind.bluetooth, 'Buds'));
    expect(r.applied, ['Vocal']);
    await r.go(route(AudioOutputKind.bluetooth, 'Car'));
    expect(r.applied, ['Vocal', 'Bass']);
  });

  test('route back applies again and the flags revert', () async {
    final r = Rig(profiles: bt());
    await r.service.start();
    await r.go(route(AudioOutputKind.wired));
    expect(r.service.effective.noDuck, isTrue);
    await r.go(route(AudioOutputKind.speaker));
    expect(r.service.effective.noDuck, isFalse);
    await r.go(route(AudioOutputKind.wired));
    expect(r.applied, ['Flat', 'Flat']);
    expect(r.service.effective.noDuck, isTrue);
    expect(r.effective.last.noDuck, isTrue);
  });

  test(
    'the listener editing the curve on a route stops a re-apply there',
    () async {
      final r = Rig(profiles: bt());
      await r.service.start();
      await r.go(route(AudioOutputKind.bluetooth, 'Buds'));
      r.edited = true; // the listener moved a band
      // The assignment changes in the Outputs page while still on this route.
      r.profiles = r.profiles.withKind(
        AudioOutputKind.bluetooth,
        const OutputProfile(eqPreset: 'Rock'),
      );
      await r.service.refresh();
      expect(r.applied, ['Bass']); // not fought
      // Unedited: the new assignment is applied straight away.
      r.edited = false;
      await r.service.refresh();
      expect(r.applied, ['Bass', 'Rock']);
      await r.service.refresh();
      expect(r.applied, ['Bass', 'Rock']);
    },
  );

  test('a new route applies even if the old one was edited', () async {
    final r = Rig(profiles: bt());
    await r.service.start();
    await r.go(route(AudioOutputKind.bluetooth, 'Buds'));
    r.edited = true;
    await r.go(route(AudioOutputKind.wired));
    expect(r.applied, ['Bass', 'Flat']);
    expect(r.leaving.last, 'bluetooth:buds>wired');
  });

  test('a route with no preset leaves the curve alone', () async {
    final r = Rig(profiles: bt());
    await r.service.start();
    await r.go(route(AudioOutputKind.bluetooth, 'Buds'));
    await r.go(route(AudioOutputKind.usb));
    expect(r.applied, ['Bass']);
  });

  test(
    'at launch the preset is not re-applied on the route last seen',
    () async {
      final r = Rig(profiles: bt(), lastRouteKey: 'bluetooth:buds');
      r.current = route(AudioOutputKind.bluetooth, 'Buds');
      await r.service.start();
      expect(r.applied, isEmpty); // the listener's last curve stays
      expect(r.service.effective.eqPreset, 'Bass');
      expect(r.routes.single.key, 'bluetooth:buds');
    },
  );

  test('at launch on a different route the preset applies', () async {
    final r = Rig(profiles: bt(), lastRouteKey: 'speaker');
    r.current = route(AudioOutputKind.bluetooth, 'Buds');
    await r.service.start();
    expect(r.applied, ['Bass']);
  });

  test(
    'a device bound to an AutoEq profile applies it and clears it after',
    () async {
      final r = Rig(
        profiles: const OutputProfiles().withDevice(
          'Buds',
          AudioOutputKind.bluetooth,
          const OutputProfile(autoEq: 'Sony WH-1000XM4'),
        ),
      );
      await r.service.start();
      await r.go(route(AudioOutputKind.bluetooth, 'Buds'));
      expect(r.speakerLog, ['apply Sony WH-1000XM4']);
      await r.go(route(AudioOutputKind.speaker));
      expect(r.speakerLog.last, 'clear');
      // A profile the listener chose by hand elsewhere is not cleared.
      r.speaker = 'Manual';
      await r.go(route(AudioOutputKind.bluetooth, 'Buds'));
      expect(r.speakerLog.last, 'apply Sony WH-1000XM4');
      r.speaker = 'Manual';
      await r.go(route(AudioOutputKind.speaker));
      expect(r.speakerLog.last, 'apply Sony WH-1000XM4'); // unchanged
    },
  );

  test('a failing read leaves the state as it was', () async {
    final r = Rig(profiles: bt());
    await r.service.start();
    await r.go(route(AudioOutputKind.wired));
    final svc = OutputProfileService(
      profiles: () => r.profiles,
      readRoute: () async => throw StateError('no session'),
      routeEvents: const Stream.empty(),
      applyEqPreset: (_) {},
      curveEdited: () => false,
      applySpeakerProfile: (_) async {},
      clearSpeakerProfile: () async {},
      activeSpeakerProfile: () => null,
      onEffective: (_, _) {},
      onRoute: (_) {},
      settle: Duration.zero,
    );
    await svc.start();
    expect(svc.route, isNull);
    expect(svc.effective.isDefault, isTrue);
  });

  test('dispose stops listening', () async {
    final r = Rig(profiles: bt());
    await r.service.start();
    r.service.dispose();
    await r.go(route(AudioOutputKind.wired));
    expect(r.applied, isEmpty);
  });
}
