import 'package:eq_app/navigation/library/library_navigator.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'library_harness.dart';

// On Android 14+ with gesture navigation one edge swipe reaches the app twice:
// as a system back gesture, and as pointers for the app's own swipe detector
// until the system pilfers them. Either can arrive first. Whatever the order it
// must be one swipe: one page popped, and the navigator free afterwards. A leaked
// didStartUserGesture leaves every page in the library ignoring touches.

const _secondKey = LibraryPageKey('album', {'albumId': 6, 'album': 'Six'});

PredictiveBackEvent _ev(double p) => PredictiveBackEvent.fromMap({
  'touchOffset': [0.0, 400.0],
  'progress': p,
  'swipeEdge': 0,
});

NavigatorState _nested(WidgetTester tester) => tester.state<NavigatorState>(
  find
      .descendant(
        of: find.byType(LibraryNavigator),
        matching: find.byType(Navigator),
      )
      .first,
);

Widget _tappablePage(VoidCallback onTap) => Scaffold(
  body: GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: const SizedBox.expand(key: ValueKey('tappable')),
  ),
);

/// A finger drag from the left edge, far enough for the swipe detector to take
/// it.
Future<TestGesture> _edgeDrag(WidgetTester tester) async {
  final g = await tester.startGesture(const Offset(4, 400));
  await g.moveBy(const Offset(60, 0));
  await tester.pump(const Duration(milliseconds: 16));
  await g.moveBy(const Offset(60, 0));
  await tester.pump(const Duration(milliseconds: 16));
  return g;
}

void main() {
  late GlobalKey<LibraryNavigatorState> nav;
  late LibraryNavigatorState s;
  var taps = 0;

  /// Library root, a tappable page, and a page over it to swipe away.
  Future<void> openTwoPages(WidgetTester tester) async {
    taps = 0;
    nav = await pumpNavigator(tester);
    s = nav.currentState!..systemBackEnabled = true;
    s.openPage(_tappablePage(() => taps++), key: albumKey);
    await tester.pumpAndSettle();
    s.openPage(albumPage(), key: _secondKey);
    await tester.pumpAndSettle();
  }

  Future<void> expectOnePageLeftAndLive(WidgetTester tester) async {
    expect(s.path, [albumKey], reason: 'exactly one page popped');
    expect(
      _nested(tester).userGestureInProgress,
      isFalse,
      reason: 'the navigator must be free again',
    );
    await tester.tap(find.byKey(const ValueKey('tappable')));
    await tester.pump();
    expect(taps, 1, reason: 'the page under it must take taps');
  }

  testWidgets('system first, then the finger, pilfered, committed', (
    tester,
  ) async {
    await openTwoPages(tester);
    expect(s.handleStartBackGesture(_ev(0)), isTrue);
    final g = await _edgeDrag(tester);
    s.handleUpdateBackGestureProgress(_ev(0.3));
    await g.cancel();
    await tester.pump();
    s.handleCommitBackGesture();
    await tester.pumpAndSettle();
    await expectOnePageLeftAndLive(tester);
  });

  testWidgets('finger first, then the system, pilfered, committed', (
    tester,
  ) async {
    await openTwoPages(tester);
    final g = await _edgeDrag(tester);
    expect(s.handleStartBackGesture(_ev(0)), isTrue);
    s.handleUpdateBackGestureProgress(_ev(0.3));
    await g.cancel();
    await tester.pump();
    s.handleCommitBackGesture();
    await tester.pumpAndSettle();
    await expectOnePageLeftAndLive(tester);
  });

  testWidgets('finger first, not pilfered: the release and the commit are '
      'one back, not two', (tester) async {
    await openTwoPages(tester);
    final g = await _edgeDrag(tester);
    expect(s.handleStartBackGesture(_ev(0)), isTrue);
    await g.up();
    s.handleCommitBackGesture();
    await tester.pumpAndSettle();
    await expectOnePageLeftAndLive(tester);
  });

  testWidgets('system first, finger released, then committed: one back', (
    tester,
  ) async {
    await openTwoPages(tester);
    expect(s.handleStartBackGesture(_ev(0)), isTrue);
    final g = await _edgeDrag(tester);
    await g.up();
    s.handleCommitBackGesture();
    await tester.pumpAndSettle();
    await expectOnePageLeftAndLive(tester);
  });

  testWidgets('a system cancel in the race keeps the page and frees the '
      'navigator', (tester) async {
    await openTwoPages(tester);
    expect(s.handleStartBackGesture(_ev(0)), isTrue);
    final g = await _edgeDrag(tester);
    await g.cancel();
    await tester.pump();
    s.handleCancelBackGesture();
    await tester.pumpAndSettle();
    expect(s.path, [albumKey, _secondKey]);
    expect(_nested(tester).userGestureInProgress, isFalse);
  });

  testWidgets('the finger still swipes on its own after a system back', (
    tester,
  ) async {
    await openTwoPages(tester);
    expect(s.handleStartBackGesture(_ev(0)), isTrue);
    s.handleCommitBackGesture();
    await tester.pumpAndSettle();
    expect(s.path, [albumKey]);
    final g = await tester.startGesture(const Offset(100, 400));
    await g.moveBy(const Offset(200, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await g.moveBy(const Offset(400, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await g.up();
    await tester.pumpAndSettle();
    expect(s.path, isEmpty);
    expect(_nested(tester).userGestureInProgress, isFalse);
  });
}
