import 'package:eq_app/audio/dsp_core.dart';
import 'package:eq_app/controllers/app_controller.dart';
import 'package:eq_app/pages/dynamics_view.dart';
import 'package:eq_app/pages/effects_settings_page.dart';
import 'package:eq_app/pages/space_view.dart';
import 'package:eq_app/pages/speaker_eq_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _Fake extends ChangeNotifier implements AppController {
  bool tone = true;
  bool limiter = false;
  @override
  bool get toneEnabled => tone;
  @override
  set toneEnabled(bool v) {
    tone = v;
    notifyListeners();
  }

  @override
  bool get limiterEnabled => limiter;
  @override
  set limiterEnabled(bool v) {
    limiter = v;
    notifyListeners();
  }

  @override
  DspCoreSettings get dspCore => const DspCoreSettings(headroomDb: -6, balance: 0, mono: false, limiter: false, preampDb: 0, tempoOn: false, tempo: 1);
  @override
  double get stereoExpand => 0;
  @override
  String? get systemWideDisabledReason => null;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Obs extends NavigatorObserver {
  _Obs(this.log);
  final List<Route<dynamic>> log;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previous) =>
      log.add(route);
}

void main() {
  late _Fake c;
  late List<Route<dynamic>> pushed;
  Future<void> pump(WidgetTester t) async {
    t.view.physicalSize = const Size(1200, 4000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    c = _Fake();
    pushed = [];
    await t.pumpWidget(ChangeNotifierProvider<AppController>.value(
      value: c,
      child: MaterialApp(
        home: const EffectsSettingsPage(),
        navigatorObservers: [_Obs(pushed)],
      ),
    ));
  }

  testWidgets('lists Space, Dynamics, Speaker Correction, tone, limiter, volume',
      (t) async {
    await pump(t);
    for (final s in ['Space', 'Dynamics', 'Speaker Correction', 'Tone controls', 'Limiter']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    expect(find.text('Volume'), findsOneWidget);
  });

  testWidgets('limiter switch writes through', (t) async {
    await pump(t);
    await t.tap(find.text('Limiter'));
    await t.pump();
    expect(c.limiter, isTrue);
  });

  for (final (label, type) in [
    ('Space', SpaceView),
    ('Dynamics', DynamicsView),
    ('Speaker Correction', SpeakerEqView),
  ]) {
    testWidgets('$label opens its page', (t) async {
      await pump(t);
      await t.tap(find.text(label));
      // The route is recorded synchronously; its page is built, not pumped
      // (the real views need the full controller).
      final route = pushed.last as MaterialPageRoute;
      final wrapper = route.builder(t.element(find.byType(EffectsSettingsPage)));
      // Wrapped in a Scaffold with the page title; the bare view is its body.
      expect(wrapper, isA<Scaffold>());
      final scaffold = wrapper as Scaffold;
      expect(((scaffold.appBar as AppBar).title as Text).data, label);
      expect(scaffold.body.runtimeType, type);
      // The same app bar on a stub body shows a back button, no exception.
      final key = GlobalKey<NavigatorState>();
      await t.pumpWidget(MaterialApp(navigatorKey: key, home: const Text('x')));
      key.currentState!.push(MaterialPageRoute(
        builder: (_) =>
            Scaffold(appBar: scaffold.appBar, body: const SizedBox()),
      ));
      await t.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.text(label), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
