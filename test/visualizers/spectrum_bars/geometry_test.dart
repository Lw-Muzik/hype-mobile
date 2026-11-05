import 'dart:typed_data';

import 'package:eq_app/visualizers/spectrum_bars/geometry.dart';
import 'package:eq_app/visualizers/spectrum_bars/presets.dart';
import 'package:flutter_test/flutter_test.dart';

const double _w = 1080, _h = 2340;

SpectrumBarsPreset _preset(String id) =>
    spectrumBarsPresetById('spectrum_$id')!;

SpectrumBarsMesh _build(
  String id,
  Map<int, double> bars, {
  Map<int, double>? peaks,
  double reserve = 0,
  SpectrumBarsMesh? into,
}) {
  final p = _preset(id);
  final b = Float64List(128);
  bars.forEach((i, v) => b[i] = v);
  Float64List? pk;
  if (peaks != null) {
    pk = Float64List(128);
    peaks.forEach((i, v) => pk![i] = v);
  }
  final mesh = into ?? SpectrumBarsMesh();
  buildSpectrumBars(
    mesh,
    preset: p,
    bars: b,
    peakPos: pk,
    reserve: reserve,
    width: _w,
    height: _h,
  );
  return mesh;
}

double _px(SpectrumBarsMesh m, int v) => m.positions[2 * v];
double _py(SpectrumBarsMesh m, int v) => m.positions[2 * v + 1];
int _col(SpectrumBarsMesh m, int v) => m.colors[v].toUnsigned(32);

/// Pixel bounds (minX, minY, maxX, maxY) of vertices [from, to).
List<double> _bounds(SpectrumBarsMesh m, int from, int to) {
  var x0 = double.infinity, y0 = double.infinity;
  var x1 = -double.infinity, y1 = -double.infinity;
  for (var v = from; v < to; v++) {
    final x = _px(m, v), y = _py(m, v);
    if (x < x0) x0 = x;
    if (x > x1) x1 = x;
    if (y < y0) y0 = y;
    if (y > y1) y1 = y;
  }
  return [x0, y0, x1, y1];
}

/// Bar-space y of a vertex (identity transform presets only).
double _barY(SpectrumBarsMesh m, int v) => 1 - _py(m, v) / _h;

void main() {
  test('plain bar columns snap to whole pixels', () {
    final m = _build('plain', {0: 0.5, 1: 0.5});
    final b0 = _bounds(m, 0, 6);
    expect(b0[0], closeTo(13, 1e-3));
    expect(b0[2], closeTo(43, 1e-3));
    // bar 1 follows the first bar's quad (which is a single rect here).
    final b1 = _bounds(m, 6, 12);
    expect(b1[0], closeTo(46, 1e-3));
  });

  test('plain splits at the threshold', () {
    final m = _build('plain', {0: 0.9}, peaks: {0: 0.95}, reserve: 0.014);
    expect(m.vertexCount, 18);
    expect(_barY(m, 2), closeTo(13271 / 16384, 1e-9));
    expect(_barY(m, 6), closeTo(13272 / 16384, 1e-9));
    expect(_barY(m, 8), closeTo(0.9 * 0.986, 1e-6));
    expect(_col(m, 0), 0xFF94A2C3);
    expect(_col(m, 2), 0xFF768BBF);
    expect(_col(m, 8), 0xFFFFFFFF);
    // The peak quad comes last.
    final pk = _bounds(m, 12, 18);
    expect(1 - pk[1] / _h, closeTo(0.95 + 0.012, 1e-6));
    expect(1 - pk[3] / _h, closeTo(0.95, 1e-6));
  });

  test('wide silence draws circles', () {
    final m = _build('wide', {});
    final b = _bounds(m, 0, 96); // two half fans of 16 triangles
    expect(m.vertexCount >= 96, isTrue);
    expect(b[2] - b[0], closeTo(b[3] - b[1], 1.0));
    expect(b[3], closeTo(_h, 1.0));
  });

  test('quads narrow cells', () {
    final m = _build('quads_narrow', {0: 1.0}, reserve: 0.035);
    expect(m.vertexCount, 46 * 6);
    final first = _bounds(m, 0, 6);
    expect(first[2] - first[0], closeTo(30, 1e-3));
    expect(first[3] - first[1], closeTo(44, 1e-3));
    final second = _bounds(m, 6, 12);
    expect(first[1] - second[1], closeTo(48, 1e-3));
  });

  test('dots mirror around the middle', () {
    final m = _build('dots', {0: 1.0});
    expect(m.vertexCount, 24 * 6);
    final a = _bounds(m, 0, 6);
    expect(a[3] - a[1], closeTo(49 * 0.75, 1e-3));
    final top = _bounds(m, 0, m.vertexCount);
    const edge = 0.75 * (11 * 97 + 49) / 2340;
    expect(1 - top[1] / _h, closeTo(0.5 + edge, 1e-6));
    expect(1 - top[3] / _h, closeTo(0.5 - edge, 1e-6));
    // Row pitch (before the sy scale) is 97 px.
    final c0 = _bounds(m, 0, 6), c1 = _bounds(m, 6, 12);
    expect((c0[1] - c1[1]).abs(), closeTo(97 * 0.75, 1e-3));
  });

  test('reflected mirrors bass at the centre', () {
    final m = _build('centered_reflected', {0: 1.0});
    // Up rect + down rect for the right bar, then the same for the left.
    expect(m.vertexCount, 24);
    final right = _bounds(m, 0, 12);
    expect(right[0] / _w, closeTo(0.5 + 0.00625, 1e-6));
    final left = _bounds(m, 12, 24);
    expect(left[0] / _w, closeTo(0.5 - 0.00625 - 0.003125, 1e-6));
    expect(1 - right[3] / _h, closeTo(0.175, 1e-6));
    expect(1 - right[1] / _h, closeTo(0.825, 1e-6));
  });

  test(
    'quads reflected has 24 columns per side and up to 49 cells per side',
    () {
      final p = _preset('quads_reflected');
      expect(p.barCount, 24);
      final all = <int, double>{for (var i = 0; i < 24; i++) i: 1.0};
      final m = _build('quads_reflected', all);
      expect(m.vertexCount, 24 * 2 * 2 * 49 * 6);
    },
  );

  test('centered narrow caps', () {
    final m = _build('centered_narrow', {0: 1.0});
    final b = _bounds(m, 0, m.vertexCount);
    expect(1 - b[1] / _h, closeTo(1.0, 1e-6));
    expect(1 - b[3] / _h, closeTo(0.0, 1e-6));
    // Two caps of 16 triangles plus two body rects.
    expect(m.vertexCount, 2 * (48 + 6));
  });

  test('colour sums clamp', () {
    final p = _preset('dots');
    expect(spectrumBarsColor(p, 1, 0, p.thr), 0xFFFFFFFF);
    final m = _build('dots', {0: 1.0});
    expect(m.vertexCount > 0, isTrue);
  });

  test('buffers are reused', () {
    final m = _build('quads_narrow', {0: 1.0, 1: 1.0}, reserve: 0.035);
    final pos = m.positions;
    final first = m.vertexCount;
    _build('quads_narrow', {0: 0.2}, reserve: 0.035, into: m);
    expect(identical(m.positions, pos), isTrue);
    expect(m.vertexCount < first, isTrue);
  });
}
