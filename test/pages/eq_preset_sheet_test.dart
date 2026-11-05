import 'package:eq_app/pages/eq_preset_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const names = ['Flat', 'Rock', 'Jazz', 'My Mix'];
  const builtIns = {'Flat', 'Rock', 'Jazz'};

  Future<void> pump(
    WidgetTester tester, {
    String selected = 'Rock',
    bool dirty = false,
    bool autoSave = true,
    ValueChanged<String>? onApply,
    ValueChanged<String>? onDelete,
    ValueChanged<bool>? onAutoSave,
    VoidCallback? onSave,
    VoidCallback? onSaveAs,
  }) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EqPresetSheet(
            names: names,
            builtIns: builtIns,
            selected: selected,
            dirty: dirty,
            autoSave: autoSave,
            onApply: onApply ?? (_) {},
            onDelete: onDelete ?? (_) {},
            onAutoSave: onAutoSave ?? (_) {},
            onSave: onSave ?? () {},
            onSaveAs: onSaveAs ?? () {},
          ),
        ),
      ),
    );
  }

  testWidgets('shows built-in and user names', (tester) async {
    await pump(tester);
    for (final n in names) {
      expect(find.text(n), findsOneWidget, reason: n);
    }
  });

  testWidgets('dirty marks the selected tile and offers Save', (tester) async {
    var saved = 0;
    await pump(tester, dirty: true, autoSave: false, onSave: () => saved++);
    expect(find.text('Rock *'), findsOneWidget);
    expect(find.text('Rock'), findsNothing);
    expect(find.text('Save'), findsOneWidget);
    await tester.tap(find.text('Save'));
    expect(saved, 1);
  });

  testWidgets('clean selection reads plain and has no Save', (tester) async {
    await pump(tester, dirty: false, autoSave: false);
    expect(find.text('Rock'), findsOneWidget);
    expect(find.text('Save'), findsNothing);
  });

  testWidgets('Save is absent while Auto save is on', (tester) async {
    await pump(tester, dirty: true, autoSave: true);
    expect(find.text('Rock *'), findsOneWidget);
    expect(find.text('Save'), findsNothing);
  });

  testWidgets('toggling Auto save reports the new value', (tester) async {
    final seen = <bool>[];
    await pump(tester, autoSave: true, onAutoSave: seen.add);
    await tester.tap(find.text('Auto save'));
    expect(seen, [false]);
  });

  testWidgets('turning Auto save on reports true', (tester) async {
    final seen = <bool>[];
    await pump(tester, autoSave: false, onAutoSave: seen.add);
    await tester.tap(find.text('Auto save'));
    expect(seen, [true]);
  });

  testWidgets('deleting a built-in reports its name', (tester) async {
    final deleted = <String>[];
    await pump(tester, onDelete: deleted.add);
    await tester.tap(find.byTooltip('Delete Jazz'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Jazz?'), findsOneWidget);
    expect(deleted, isEmpty, reason: 'nothing is deleted before confirming');
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deleted, ['Jazz']);
  });

  testWidgets('cancelling the delete dialog deletes nothing', (tester) async {
    final deleted = <String>[];
    await pump(tester, onDelete: deleted.add);
    await tester.tap(find.byTooltip('Delete My Mix'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(deleted, isEmpty);
    expect(find.text('Delete My Mix?'), findsNothing);
  });

  testWidgets('tapping a tile applies it; Save as is always there', (
    tester,
  ) async {
    final applied = <String>[];
    var saveAs = 0;
    await pump(tester, onApply: applied.add, onSaveAs: () => saveAs++);
    await tester.tap(find.text('My Mix'));
    expect(applied, ['My Mix']);
    await tester.tap(find.text('Save as'));
    expect(saveAs, 1);
  });
}
