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

  testWidgets('stall feeds silence until the bars settle', (tester) async {
    final ctl = StreamController<Float32List>();
    await tester.pumpWidget(
      _host(SpectrumBarsView(preset: _p('plain'), frames: ctl.stream)),
    );
    ctl.add(_frame(1e3));
    await tester.pump(const Duration(milliseconds: 16));
    expect(_state(tester).debugBars[0], greaterThan(0.1));
    await tester.pump(const Duration(seconds: 2));
    final bars = _state(tester).debugBars;
    for (var i = 0; i < _p('plain').barCount; i++) {
      expect(bars[i], lessThan(0.001), reason: 'bar $i');
    }
    await tester.pumpWidget(const SizedBox());
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

  testWidgets('resize drops the trail', (tester) async {
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
    expect(_state(tester).debugTrail, isNull);
    ctl.add(_frame(1e3));
    await tester.pump(const Duration(milliseconds: 16));
    expect(_state(tester).debugTrail!.width, 300);
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
