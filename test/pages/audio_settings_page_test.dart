import 'package:eq_app/controllers/app_controller.dart';
import 'package:eq_app/pages/audio_settings_page.dart';
import 'package:eq_app/pages/audio_sub_page.dart';
import 'package:eq_app/pages/audio_info_page.dart';
import 'package:eq_app/pages/effects_settings_page.dart';
import 'package:eq_app/pages/output_profiles_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _Fake extends ChangeNotifier implements AppController {
  _Fake({this.eqMode = false});
  final bool eqMode;
  @override
  bool get isEqMode => eqMode;
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
  late List<Route<dynamic>> pushed;
  Future<void> pump(WidgetTester t, {bool eq = false, AudioSubPage? open}) async {
    t.view.physicalSize = const Size(1200, 4000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    pushed = [];
    await t.pumpWidget(ChangeNotifierProvider<AppController>.value(
      value: _Fake(eqMode: eq),
      child: MaterialApp(
        home: AudioSettingsPage(open: open),
        navigatorObservers: [_Obs(pushed)],
      ),
    ));
    await t.pump();
  }

  testWidgets('lists every sub-page in enum order', (t) async {
    await pump(t);
    final ys = [
      for (final p in AudioSubPage.values) t.getTopLeft(find.text(p.title)).dy,
    ];
    expect(ys, orderedEquals([...ys]..sort()));
    expect(ys.length, 9);
  });

  testWidgets('Equalizer-only mode lists only its pages', (t) async {
    await pump(t, eq: true);
    for (final p in AudioSubPage.values) {
      expect(find.text(p.title),
          p.inEqualizerOnlyMode ? findsOneWidget : findsNothing,
          reason: p.title);
    }
  });

  testWidgets('every tile pushes a route (and open: pushes on first frame)',
      (t) async {
    for (final p in AudioSubPage.values) {
      await t.pumpWidget(const SizedBox()); // drop the previous route stack
      await pump(t);
      final before = pushed.length;
      // The pushed page builds against a bare fake and may throw; only the
      // push is asserted here.
      await t.tap(find.text(p.title), warnIfMissed: false);
      t.takeException();
      expect(pushed.length, before + 1, reason: p.title);
    }
  });

  testWidgets('open: pushes the sub-page on the first frame', (t) async {
    await pump(t, open: AudioSubPage.equalizer);
    t.takeException();
    expect(pushed.length, 2); // the page itself + the sub-page
  });

  testWidgets('scaffold-owning sub-pages are returned as-is', (t) async {
    await pump(t);
    final ctx = t.element(find.byType(AudioSettingsPage));
    final c = _Fake();
    expect(buildAudioSubPage(ctx, c, AudioSubPage.info), isA<AudioInfoPage>());
    expect(buildAudioSubPage(ctx, c, AudioSubPage.outputs),
        isA<OutputProfilesPage>());
    expect(buildAudioSubPage(ctx, c, AudioSubPage.effects),
        isA<EffectsSettingsPage>());
  });
}
