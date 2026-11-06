import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:eq_app/visualizers/spectrum_bars/frame.dart';
import 'package:eq_app/visualizers/spectrum_bars/geometry.dart';
import 'package:eq_app/visualizers/spectrum_bars/presets.dart';
import 'package:flutter_test/flutter_test.dart';

SpectrumBarsPreset _preset(String id) =>
    spectrumBarsPresetById('spectrum_$id')!;

SpectrumBarsMesh _mesh(String id, Map<int, double> bars, double w, double h) {
  final b = Float64List(128);
  bars.forEach((i, v) => b[i] = v);
  final m = SpectrumBarsMesh();
  buildSpectrumBars(m, preset: _preset(id), bars: b, width: w, height: h);
  return m;
}

Future<ui.Image> _render(
  String id,
  SpectrumBarsMesh mesh,
  int w,
  int h, {
  ui.Image? previous,
  double fps = 60,
}) {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  paintSpectrumBarsFrame(
    canvas,
    preset: _preset(id),
    mesh: mesh,
    previous: previous,
    fps: fps,
    width: w.toDouble(),
    height: h.toDouble(),
  );
  return rec.endRecording().toImage(w, h);
}

Future<Uint8List> _pixels(ui.Image img) async =>
    (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer
        .asUint8List();

List<int> _px(Uint8List d, int w, int x, int y) {
  final i = (y * w + x) * 4;
  return [d[i], d[i + 1], d[i + 2], d[i + 3]];
}

void main() {
  testWidgets('bars draw their vertex colours', (tester) async {
    await tester.runAsync(() async {
      final img = await _render(
        'plain',
        _mesh('plain', {0: 1}, 64, 64),
        64,
        64,
      );
      final p = _px(await _pixels(img), 64, 16, 62);
      expect(p[0], closeTo(0x94, 2));
      expect(p[1], closeTo(0xA2, 2));
      expect(p[2], closeTo(0xC3, 2));
      expect(p[3], 255);
    });
  });

  testWidgets('trail decays by the multiplier', (tester) async {
    await tester.runAsync(() async {
      final f1 = await _render('plain', _mesh('plain', {0: 1}, 64, 64), 64, 64);
      final v = _px(await _pixels(f1), 64, 16, 62);
      final f2 = await _render(
        'plain',
        SpectrumBarsMesh(),
        64,
        64,
        previous: f1,
        fps: 60,
      );
      final p = _px(await _pixels(f2), 64, 16, 62);
      for (var c = 0; c < 3; c++) {
        expect(p[c], closeTo((v[c] * 239 / 255 - 0.51).round(), 1));
      }
    });
  });

  testWidgets('decay bias is 0.002 of full scale per channel', (tester) async {
    await tester.runAsync(() async {
      // 4 * 239/255 = 3.75, minus 0.51 = 3.24 -> 3. Without the bias it is 4.
      final rec = ui.PictureRecorder();
      ui.Canvas(rec).drawRect(
        const ui.Rect.fromLTWH(0, 0, 8, 8),
        ui.Paint()..color = const ui.Color(0xFF040404),
      );
      final prev = await rec.endRecording().toImage(8, 8);
      final out = await _render(
        'plain',
        SpectrumBarsMesh(),
        8,
        8,
        previous: prev,
        fps: 60,
      );
      expect(_px(await _pixels(out), 8, 4, 4).sublist(0, 3), [3, 3, 3]);
    });
  });

  testWidgets('no-trail preset clears', (tester) async {
    await tester.runAsync(() async {
      final f1 = await _render(
        'narrow',
        _mesh('narrow', {0: 1}, 64, 64),
        64,
        64,
      );
      final f2 = await _render(
        'narrow',
        SpectrumBarsMesh(),
        64,
        64,
        previous: f1,
      );
      final d = await _pixels(f2);
      expect(_px(d, 64, 0, 62).sublist(0, 3), [0, 0, 0]);
      expect(_px(d, 64, 16, 62).sublist(0, 3), [0, 0, 0]);
    });
  });

  Future<double> dotsCentroid(int frames, double fps) async {
    // A 4 px wide bright bar centred on x = 180. A one pixel column would be
    // smeared to nothing by the filtered sampling before 50 frames pass.
    final rec = ui.PictureRecorder();
    ui.Canvas(rec)
      ..drawRect(
        const ui.Rect.fromLTWH(0, 0, 200, 200),
        ui.Paint()..color = const ui.Color(0xFF000000),
      )
      ..drawRect(
        const ui.Rect.fromLTWH(178, 0, 4, 200),
        ui.Paint()..color = const ui.Color(0xFFFFFFFF),
      );
    var img = await rec.endRecording().toImage(200, 200);
    for (var i = 0; i < frames; i++) {
      final next = await _render(
        'dots',
        SpectrumBarsMesh(),
        200,
        200,
        previous: img,
        fps: fps,
      );
      img.dispose();
      img = next;
    }
    final d = await _pixels(img);
    var sum = 0.0, weighted = 0.0;
    for (var x = 0; x < 200; x++) {
      final v = _px(d, 200, x, 100)[0].toDouble();
      sum += v;
      weighted += v * (x + 0.5);
    }
    expect(sum, greaterThan(0));
    return weighted / sum;
  }

  testWidgets('dots trail drifts inward', (tester) async {
    await tester.runAsync(() async {
      // Content at 80 px from the centre shrinks by 1.001007^50 (about 4 px).
      expect(await dotsCentroid(50, 60), closeTo(176, 2));
    });
  });

  testWidgets('dots drift is fps-compensated: 25 frames at 30 fps ~ 50 at 60', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final at60 = await dotsCentroid(50, 60);
      final at30 = await dotsCentroid(25, 30);
      expect(at30, closeTo(176, 2));
      expect((at30 - at60).abs(), lessThan(1.0));
    });
  });
}
