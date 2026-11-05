import 'package:eq_app/audio/dvc/dvc_settings.dart';
import 'package:eq_app/pages/dvc_settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final settingsLog = <DvcSettings>[];
  final enabledLog = <bool>[];
  final gainLog = <double>[];
  final headroomLog = <double>[];

  Future<void> pump(
    WidgetTester tester, {
    bool isIos = false,
    bool dvcEnabled = true,
    double headroom = -6.0,
    double gain = -15.0,
  }) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    settingsLog.clear();
    enabledLog.clear();
    gainLog.clear();
    headroomLog.clear();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: DvcSettingsSection(
            settings: const DvcSettings(),
            onChanged: settingsLog.add,
            dvcEnabled: dvcEnabled,
            onDvcEnabled: enabledLog.add,
            dvcGainDb: gain,
            onDvcGainDb: gainLog.add,
            headroomDb: headroom,
            onHeadroomDb: headroomLog.add,
            isIos: isIos,
          ),
        ),
      ),
    ));
  }

  testWidgets('Android shows the four rows', (tester) async {
    await pump(tester);
    expect(DvcSettingsSection.labels.length, 4);
    for (final l in DvcSettingsSection.labels) {
      expect(find.text(l), findsOneWidget, reason: l);
    }
  });

  testWidgets('iOS shows only the preamp reduction', (tester) async {
    await pump(tester, isIos: true);
    for (final l in DvcSettingsSection.labels) {
      expect(
        find.text(l),
        DvcSettingsSection.androidOnlyLabels.contains(l)
            ? findsNothing
            : findsOneWidget,
        reason: l,
      );
    }
    expect(find.text('-6.0 dB'), findsOneWidget);
  });

  testWidgets('toggles report', (tester) async {
    await pump(tester);
    await tester.tap(find.text('No DVC for Bluetooth absolute volume'));
    await tester.pump();
    expect(settingsLog.single.noDvcForBluetoothAbsoluteVolume, isFalse);
    await tester.tap(find.text('Enable direct volume control'));
    await tester.pump();
    expect(enabledLog.single, isFalse);
  });

  testWidgets('headroom slider commits on release only', (tester) async {
    await pump(tester, dvcEnabled: false);
    final slider = find.byType(Slider).first;
    final g = await tester.startGesture(tester.getCenter(slider));
    await g.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(headroomLog, isEmpty);
    await g.up();
    await tester.pump();
    expect(headroomLog.length, 1);
    expect(headroomLog.single % 0.5, 0);
  });

  testWidgets('headroom slider commits on semantics steps', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, dvcEnabled: false);
    tester.semantics
        .increase(find.semantics.byAction(SemanticsAction.increase).first);
    await tester.pump();
    expect(headroomLog.single, -5.5);
    handle.dispose();
  });
}
