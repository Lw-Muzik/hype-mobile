import 'package:eq_app/widgets/volume_panel_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the level and hides after 1.5 s', (tester) async {
    final c = VolumePanelController();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(children: [VolumePanelOverlay(controller: c)]),
        ),
      ),
    );
    expect(find.byKey(VolumePanelOverlay.panelKey), findsNothing);
    c.show(0.4);
    await tester.pump();
    expect(find.byKey(VolumePanelOverlay.panelKey), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1400));
    expect(find.byKey(VolumePanelOverlay.panelKey), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.byKey(VolumePanelOverlay.panelKey), findsNothing);
  });

  testWidgets('a new change restarts the 1.5 s timer', (tester) async {
    final c = VolumePanelController();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(children: [VolumePanelOverlay(controller: c)]),
        ),
      ),
    );
    c.show(0.4);
    await tester.pump(const Duration(milliseconds: 1000));
    c.show(0.5);
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.byKey(VolumePanelOverlay.panelKey), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.byKey(VolumePanelOverlay.panelKey), findsNothing);
  });
}
