import 'dart:async';
import 'dart:typed_data';

import 'package:eq_app/pages/visual_ui.dart';
import 'package:eq_app/visualizers/spectrum_bars/presets.dart';
import 'package:eq_app/visualizers/spectrum_bars/spectrum_bars_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Float32List _frame(double v) => Float32List(256)..fillRange(0, 256, v);

Widget _host(Widget child, {double w = 200, double h = 300}) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: const MediaQueryData(devicePixelRatio: 2),
    child: Center(
      child: SizedBox(width: w, height: h, child: child),
    ),
  ),
);

SpectrumBarsPreset _p(String id) => spectrumBarsPresetById('spectrum_$id')!;

SpectrumBarsViewState _state(WidgetTester t) =>
    t.state<SpectrumBarsViewState>(find.byType(SpectrumBarsView));

void main() {
  testWidgets('renders frames without errors', (tester) async {
    for (final preset in kSpectrumBarsPresets) {
      final ctl = StreamController<Float32List>();
      await tester.pumpWidget(
        _host(
          SpectrumBarsView(
            key: UniqueKey(),
            preset: preset,
            frames: ctl.stream,
          ),
        ),
      );
      for (var i = 0; i < 3; i++) {
        ctl.add(_frame(1e-3 * (i + 1)));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.takeException(), isNull, reason: preset.id);
      await tester.pumpWidget(const SizedBox());
      unawaited(ctl.close());
    }
  });

  testWidgets('frames are processed on ticks only, newest wins', (
    tester,
  ) async {
    final ctl = StreamController<Float32List>();
    await tester.pumpWidget(
      _host(SpectrumBarsView(preset: _p('narrow'), frames: ctl.stream)),
    );
    ctl.add(_frame(1e-3));
    ctl.add(_frame(1e3));
    await tester.idle();
    expect(_state(tester).debugProcessed, 0);
    await tester.pump(const Duration(milliseconds: 16));
    expect(_state(tester).debugProcessed, 1);
    // The newest message was the one processed.
    expect(_state(tester).debugBars[0], greaterThan(0.1));
    await tester.pumpWidget(const SizedBox());
    unawaited(ctl.close());
  });

  testWidgets('stall feeds silence, then the ticker stops', (tester) async {
    final ctl = StreamController<Float32List>();
    await tester.pumpWidget(
      _host(SpectrumBarsView(preset: _p('narrow'), frames: ctl.stream)),
    );
    ctl.add(_frame(1e3));
    await tester.pump(const Duration(milliseconds: 16));
    expect(_state(tester).debugBars[0], greaterThan(0.1));
    for (var i = 0; i < 80 && _state(tester).debugTickerActive; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(_state(tester).debugTickerActive, isFalse);
    final bars = _state(tester).debugBars;
    for (var i = 0; i < _p('narrow').barCount; i++) {
      expect(bars[i], lessThan(0.001), reason: 'bar $i');
    }
    // Quiet: no frame is scheduled and nothing is processed.
    final n = _state(tester).debugProcessed;
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(_state(tester).debugProcessed, n);
    // A real frame after quiet resumes the ticker.
    ctl.add(_frame(1e3));
    await tester.pump(const Duration(milliseconds: 16));
    expect(_state(tester).debugTickerActive, isTrue);
    expect(_state(tester).debugProcessed, n + 1);
    expect(_state(tester).debugBars[0], greaterThan(0.1));
    await tester.pumpWidget(const SizedBox());
    unawaited(ctl.close());
  });

  testWidgets('silence frames are limited to about 30 per second', (
    tester,
  ) async {
    final ctl = StreamController<Float32List>();
    await tester.pumpWidget(
      _host(SpectrumBarsView(preset: _p('narrow'), frames: ctl.stream)),
    );
    ctl.add(_frame(1e3));
    await tester.pump(const Duration(milliseconds: 16));
    final before = _state(tester).debugProcessed;
    // 250 ms stall, then 1 s of 120 Hz ticks while bars are still falling.
    await tester.pump(const Duration(milliseconds: 250));
    final stalled = _state(tester).debugProcessed;
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(microseconds: 8333));
    }
    final fed = _state(tester).debugProcessed - stalled;
    expect(stalled - before, lessThanOrEqualTo(1));
    expect(fed, lessThanOrEqualTo(32));
    await tester.pumpWidget(const SizedBox());
    unawaited(ctl.close());
  });

  testWidgets('no audio at all: the ticker never runs', (tester) async {
    final ctl = StreamController<Float32List>();
    await tester.pumpWidget(
      _host(SpectrumBarsView(preset: _p('plain'), frames: ctl.stream)),
    );
    await tester.pump(const Duration(seconds: 5));
    expect(_state(tester).debugTickerActive, isFalse);
    expect(_state(tester).debugProcessed, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
    unawaited(ctl.close());
  });

  testWidgets('trail presets keep drawing for 3 s of silence', (tester) async {
    final ctl = StreamController<Float32List>();
    await tester.pumpWidget(
      _host(SpectrumBarsView(preset: _p('plain'), frames: ctl.stream)),
    );
    ctl.add(_frame(1e3));
    await tester.pump(const Duration(milliseconds: 16));
    // Stall starts after 250 ms; bars settle well inside 3 s of silence.
    await tester.pump(const Duration(milliseconds: 250));
    var silent = Duration.zero;
    while (silent < const Duration(milliseconds: 2800)) {
      await tester.pump(const Duration(milliseconds: 100));
      silent += const Duration(milliseconds: 100);
    }
    expect(_state(tester).debugTickerActive, isTrue);
    for (var i = 0; i < 10 && _state(tester).debugTickerActive; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(_state(tester).debugTickerActive, isFalse);
    await tester.pumpWidget(const SizedBox());
    unawaited(ctl.close());
  });

  testWidgets('lifecycle: pause disposes the feed, resume re-subscribes', (
    tester,
  ) async {
    var listens = 0, cancels = 0;
    final ctl = StreamController<Float32List>.broadcast(
      onListen: () => listens++,
      onCancel: () => cancels++,
    );
    await tester.pumpWidget(
      _host(SpectrumBarsView(preset: _p('narrow'), frames: ctl.stream)),
    );
    // Broadcast onListen fires once for the first listener.
    expect(listens, 1);
    ctl.add(_frame(1e3));
    await tester.pump(const Duration(milliseconds: 16));
    expect(_state(tester).debugTickerActive, isTrue);

    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.idle();
    expect(cancels, 1);
    expect(_state(tester).debugTickerActive, isFalse);
    final n = _state(tester).debugProcessed;
    ctl.add(_frame(1e3)); // nobody listens
    await tester.pump(const Duration(seconds: 1));
    expect(_state(tester).debugProcessed, n);

    for (final s in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.idle();
    expect(listens, 2);
    ctl.add(_frame(1e3));
    await tester.pump(const Duration(milliseconds: 16));
    expect(_state(tester).debugProcessed, greaterThan(n));
    await tester.pumpWidget(const SizedBox());
    expect(cancels, 2);
    unawaited(ctl.close());
  });

  testWidgets('preset change resets peaks and trail, keeps bars', (
    tester,
  ) async {
    final ctl = StreamController<Float32List>();
    await tester.pumpWidget(
      _host(SpectrumBarsView(preset: _p('plain'), frames: ctl.stream)),
    );
    for (var i = 0; i < 3; i++) {
      ctl.add(_frame(1e3));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_state(tester).debugTrail, isNotNull);
    final before = Float64List.fromList(_state(tester).debugBars);
    expect(before[0], greaterThan(0));
    await tester.pumpWidget(
      _host(SpectrumBarsView(preset: _p('quads_narrow'), frames: ctl.stream)),
    );
    final st = _state(tester);
    expect(st.debugPeaks.every((v) => v == 0), isTrue);
    expect(st.debugTrail, isNull);
    expect(st.debugBars, before);
    await tester.pumpWidget(const SizedBox());
    unawaited(ctl.close());
  });

  testWidgets('resize redraws the trail at the new size', (tester) async {
    final ctl = StreamController<Float32List>();
    await tester.pumpWidget(
      _host(SpectrumBarsView(preset: _p('plain'), frames: ctl.stream)),
    );
    ctl.add(_frame(1e3));
    await tester.pump(const Duration(milliseconds: 16));
    expect(_state(tester).debugTrail!.width, 400);
    await tester.pumpWidget(
      _host(SpectrumBarsView(preset: _p('plain'), frames: ctl.stream), w: 150),
    );
    // A fresh frame at the new size, not a blank.
    expect(_state(tester).debugTrail!.width, 300);
    await tester.pumpWidget(const SizedBox());
    unawaited(ctl.close());
  });

  testWidgets('resize while quiet keeps the resting picture', (tester) async {
    final ctl = StreamController<Float32List>();
    await tester.pumpWidget(
      _host(SpectrumBarsView(preset: _p('wide'), frames: ctl.stream)),
    );
    ctl.add(_frame(1e3));
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < 80 && _state(tester).debugTickerActive; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(_state(tester).debugTickerActive, isFalse);
    final resting = _state(tester).debugMesh.vertexCount;
    expect(resting, greaterThan(0));
    await tester.pumpWidget(
      _host(SpectrumBarsView(preset: _p('wide'), frames: ctl.stream), w: 150),
    );
    expect(_state(tester).debugMesh.vertexCount, resting);
    await tester.pumpWidget(const SizedBox());
    unawaited(ctl.close());
  });

  test('visual page wiring: spectrum ids build the view, radial does not', () {
    for (final p in kSpectrumBarsPresets) {
      expect(spectrumBarsVisualizer(p.id), isA<SpectrumBarsView>(),
          reason: p.id);
    }
    // Radial/line styles fall through to the WaveVisualizer path.
    expect(spectrumBarsVisualizer('radial'), isNull);
  });
}
