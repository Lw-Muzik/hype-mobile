/// Volume controls: balance, mono, tempo and a confirmed reset.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/audio/dsp_core.dart';
import 'package:eq_app/pages/volume_controls.dart';

void main() {
  const base = DspCoreSettings(
    headroomDb: 0,
    balance: 0,
    mono: false,
    limiter: true,
    preampDb: 0,
    tempoOn: true,
    tempo: 1.0,
  );

  Future<({List<DspCoreSettings> changes, List<double> expands})> pump(
    WidgetTester tester,
    DspCoreSettings settings, {
    double stereoExpand = 0.0,
    String? disabledReason,
  }) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final changes = <DspCoreSettings>[];
    final expands = <double>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: VolumeControls(
            settings: settings,
            onChanged: changes.add,
            stereoExpand: stereoExpand,
            onStereoExpand: expands.add,
            disabledReason: disabledReason,
          ),
        ),
      ),
    ));
    return (changes: changes, expands: expands);
  }

  testWidgets('shows Balance, Mono, Tempo and Reset', (tester) async {
    await pump(tester, base);
    for (final label in ['Balance', 'Mono', 'Tempo', 'Reset']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('0.00'), findsOneWidget);
    expect(find.text('1.00x'), findsOneWidget);
  });

  testWidgets('plus at 1.00x reports 1.05', (tester) async {
    final r = await pump(tester, base);
    await tester.tap(find.byIcon(Icons.add));
    expect(r.changes.single.tempo, closeTo(1.05, 1e-9));
  });

  testWidgets('plus is disabled at 3.00x, minus at 0.50x', (tester) async {
    final r = await pump(tester, base.copyWith(tempo: 3.0));
    await tester.tap(find.byIcon(Icons.add));
    expect(r.changes, isEmpty);
    final plus = tester.widget<IconButton>(
      find.ancestor(of: find.byIcon(Icons.add), matching: find.byType(IconButton)),
    );
    expect(plus.onPressed, isNull);

    final low = await pump(tester, base.copyWith(tempo: 0.5));
    await tester.tap(find.byIcon(Icons.remove));
    expect(low.changes, isEmpty);
  });

  testWidgets('mono switch reports mono on', (tester) async {
    final r = await pump(tester, base);
    await tester.tap(find.byType(Switch).first);
    expect(r.changes.single.mono, isTrue);
  });

  testWidgets('reset needs confirmation, then clears everything',
      (tester) async {
    final r = await pump(
      tester,
      base.copyWith(balance: 0.5, mono: true, tempo: 1.5),
      stereoExpand: 0.6,
    );
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(r.changes, isEmpty, reason: 'nothing changes before confirming');

    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('Reset'),
    ));
    await tester.pumpAndSettle();

    final out = r.changes.single;
    expect(out.balance, 0);
    expect(out.mono, isFalse);
    expect(out.tempoOn, isFalse);
    expect(out.tempo, 1.0);
    expect(r.expands, [0.0]);
  });

  testWidgets('cancelling the reset changes nothing', (tester) async {
    final r = await pump(tester, base.copyWith(balance: 0.5));
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(r.changes, isEmpty);
    expect(r.expands, isEmpty);
  });

  group('with a disabled reason (system-wide equalizer)', () {
    testWidgets('shows the reason; Balance and Mono report nothing',
        (tester) async {
      final r = await pump(tester, base, disabledReason: 'X');
      expect(find.text('X'), findsOneWidget);
      await tester.drag(find.byType(Slider).first, const Offset(200, 0));
      await tester.pump();
      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      expect(r.changes, isEmpty);
      final balance = tester.widget<Slider>(find.byType(Slider).first);
      expect(balance.onChanged, isNull);
      final mono = tester.widget<Switch>(find.byType(Switch).first);
      expect(mono.onChanged, isNull);
    });

    testWidgets('Tempo plus still reports 1.05', (tester) async {
      final r = await pump(tester, base, disabledReason: 'X');
      await tester.tap(find.byIcon(Icons.add));
      expect(r.changes.single.tempo, closeTo(1.05, 1e-9));
    });

    testWidgets('Reset stays usable', (tester) async {
      final r = await pump(tester, base.copyWith(tempo: 1.5),
          disabledReason: 'X');
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Reset'),
      ));
      await tester.pumpAndSettle();
      expect(r.changes.single.tempo, 1.0);
    });

    testWidgets('without a reason nothing is disabled or shown', (tester) async {
      final r = await pump(tester, base);
      expect(find.text('X'), findsNothing);
      await tester.tap(find.byType(Switch).first);
      expect(r.changes.single.mono, isTrue);
      final balance = tester.widget<Slider>(find.byType(Slider).first);
      expect(balance.onChanged, isNotNull);
    });
  });
}
