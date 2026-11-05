import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:eq_app/visualizers/spectrum_bars/presets.dart';

/// Smallest vertical step used to nudge split rectangles apart.
const double _eps = 1 / 16384;

/// Divider used by the peak colour ramp.
const double _peakDiv = 1e-4;

const ui.Color _clear = ui.Color(0x00000000);

/// Growable triangle-list mesh. The buffers only ever grow, so a mesh that is
/// rebuilt every frame stops allocating once it has seen its largest frame.
class SpectrumBarsMesh {
  /// x, y pairs in physical pixels, y down.
  Float32List positions = Float32List(0);

  /// One ARGB value per vertex.
  Int32List colors = Int32List(0);

  /// Vertices in use (a multiple of three).
  int vertexCount = 0;

  // State of the build in progress.
  SpectrumBarsPreset? _p;
  double _div = 1;
  bool _peak = false;
  double _sx = 1, _sy = 1, _w = 1, _h = 1;

  /// Snapshot of the used range as a triangle-list [ui.Vertices].
  ui.Vertices toVertices() => ui.Vertices.raw(
    ui.VertexMode.triangles,
    Float32List.sublistView(positions, 0, vertexCount * 2),
    colors: Int32List.sublistView(colors, 0, vertexCount),
  );

  void _ensure(int extra) {
    final need = vertexCount + extra;
    if (need * 2 <= positions.length) return;
    var cap = positions.length ~/ 2;
    if (cap < 256) cap = 256;
    while (cap < need) {
      cap *= 2;
    }
    final np = Float32List(cap * 2)..setRange(0, vertexCount * 2, positions);
    final nc = Int32List(cap)..setRange(0, vertexCount, colors);
    positions = np;
    colors = nc;
  }

  void _v(double x, double y) {
    final vc = vertexCount;
    final tx = 0.5 + _sx * (x - 0.5);
    final ty = 0.5 + _sy * (y - 0.5);
    positions[2 * vc] = tx * _w;
    positions[2 * vc + 1] = (1 - ty) * _h;
    final p = _p!;
    colors[vc] = _peak
        ? _argb(
            p.peakB,
            p.peakT,
            _clear,
            _clear,
            p.peakB,
            p.peakT,
            _clear,
            _clear,
            x,
            y,
            _peakDiv,
          )
        : _argb(
            p.colorB,
            p.colorT,
            p.colorL,
            p.colorR,
            p.thrB,
            p.thrT,
            p.thrL,
            p.thrR,
            x,
            y,
            _div,
          );
    vertexCount = vc + 1;
  }

  /// Axis-aligned quad as two triangles, corners (0,1,2) and (0,2,3).
  void _quad(double x0, double y0, double x1, double y1) {
    if (!(y1 > y0) || !(x1 > x0)) return;
    _ensure(6);
    _v(x0, y0);
    _v(x1, y0);
    _v(x1, y1);
    _v(x0, y0);
    _v(x1, y1);
    _v(x0, y1);
  }

  /// Half-ellipse cap: a body rectangle (when it fits) plus a 16-triangle fan.
  void _cap(
    double x,
    double base,
    double w,
    double yEnd,
    double height,
    double rx,
    double ry,
    bool top,
    bool keepRadius,
  ) {
    double cy;
    var r = ry;
    if (height >= ry) {
      cy = top ? yEnd - ry : yEnd + ry;
      if (top) {
        _quad(x, base, x + w, cy);
      } else {
        _quad(x, cy, x + w, base);
      }
    } else {
      cy = base;
      if (!keepRadius) r = height < 0 ? 0 : height;
    }
    _ensure(48);
    final cx = x + w / 2;
    final dir = top ? 1.0 : -1.0;
    for (var k = 0; k < 16; k++) {
      _v(cx, cy);
      _v(cx + rx * _rimCos[k], cy + dir * r * _rimSin[k]);
      _v(cx + rx * _rimCos[k + 1], cy + dir * r * _rimSin[k + 1]);
    }
  }
}

final Float64List _rimCos = _rim(math.cos);
final Float64List _rimSin = _rim(math.sin);

/// Rim samples from angle pi down to 0 in steps of pi/16 (17 points).
Float64List _rim(double Function(num) f) {
  final out = Float64List(17);
  for (var k = 0; k <= 16; k++) {
    out[k] = f(math.pi - k * math.pi / 16);
  }
  return out;
}

double _clamp01s(double v) => v < 0 ? 0 : (v > 0.99 ? 0.99 : v);

int _argb(
  ui.Color g0,
  ui.Color g1,
  ui.Color g2,
  ui.Color g3,
  ui.Color u0,
  ui.Color u1,
  ui.Color u2,
  ui.Color u3,
  double x,
  double y,
  double div,
) {
  final d = div < 1e-5 ? 1e-5 : (div > 1 ? 1.0 : div);
  final ui.Color a, b, c, e;
  final double t;
  if (y <= d) {
    a = g0;
    b = g1;
    c = g2;
    e = g3;
    t = y / d;
  } else {
    a = u0;
    b = u1;
    c = u2;
    e = u3;
    t = (y - d) / (1 - d);
  }
  final s = 1 - t, sx = 1 - x;
  int ch(double a, double b, double c, double e) {
    final v = a * s + b * t + c * sx + e * x;
    final cl = v < 0 ? 0.0 : (v > 1 ? 1.0 : v);
    return (cl * 255).round();
  }

  return (ch(a.a, b.a, c.a, e.a) << 24) |
      (ch(a.r, b.r, c.r, e.r) << 16) |
      (ch(a.g, b.g, c.g, e.g) << 8) |
      ch(a.b, b.b, c.b, e.b);
}

/// Colour of a bar-space point, as an ARGB value. [div] is the layout's
/// divider (raw threshold, or its snapped form).
int spectrumBarsColor(SpectrumBarsPreset p, double x, double y, double div) =>
    _argb(
      p.colorB,
      p.colorT,
      p.colorL,
      p.colorR,
      p.thrB,
      p.thrT,
      p.thrL,
      p.thrR,
      x,
      y,
      div,
    );

int _clampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

/// Rebuilds [into] for one frame. Sizes are in physical pixels.
void buildSpectrumBars(
  SpectrumBarsMesh into, {
  required SpectrumBarsPreset preset,
  required Float64List bars,
  Float64List? peakPos,
  double reserve = 0,
  required double width,
  required double height,
}) {
  final m = into
    ..vertexCount = 0
    .._p = preset
    .._peak = false
    .._sx = preset.sx
    .._sy = preset.sy
    .._w = width
    .._h = height;
  final px = 1 / width, py = 1 / height, asp = width / height;
  final n = preset.barCount;
  final thr = preset.thr;
  final showPeaks = peakPos != null && reserve != 0;

  switch (preset.layout) {
    case BarsLayout.bottom:
    case BarsLayout.centred:
      final sp = _clamp01s(preset.spacingX);
      var w = 1 / (sp * (n + 1) / (1 - sp) + n);
      var g = w * sp / (1 - sp);
      g = (g / px).floorToDouble() * px;
      w = (w / px).floorToDouble() * px;
      final x0 = ((0.5 - (n * w + (n - 1) * g) / 2) / px).floorToDouble() * px;
      final rx = w / 2, ry = asp * rx;
      final keep = preset.rounding == 2;
      if (preset.layout == BarsLayout.bottom) {
        final thrS = (thr * 16384).floorToDouble() / 16384;
        m._div = thrS;
        for (var i = 0; i < n; i++) {
          final x = x0 + i * (w + g);
          final bar = bars[i];
          if (preset.rounding == 0) {
            final h = bar * (1 - reserve);
            m._quad(x, 0, x + w, h < thrS ? h : thrS);
            if (h > thrS) m._quad(x, thrS + _eps, x + w, h);
          } else if (preset.rounding == 1) {
            if (bar > 0) m._cap(x, 0, w, bar, bar, rx, ry, true, false);
          } else {
            final yEnd = ry + (1 - ry) * bar;
            m._cap(x, ry, w, 0, ry, rx, ry, false, true);
            m._cap(x, ry, w, yEnd, yEnd - ry, rx, ry, true, true);
          }
        }
        if (showPeaks && preset.rounding == 0) {
          m._peak = true;
          for (var i = 0; i < n; i++) {
            final pos = peakPos[i];
            if (pos <= 0) continue;
            final x = x0 + i * (w + g);
            m._quad(x, pos, x + w, pos + preset.peakHeight);
          }
        }
      } else {
        m._div = thr;
        for (var i = 0; i < n; i++) {
          final x = x0 + i * (w + g);
          final h = bars[i] / 2;
          if (h <= 0) continue;
          if (preset.rounding == 0) {
            m._quad(x, 0.5, x + w, 0.5 + h);
            m._quad(x, 0.5 - h, x + w, 0.5);
          } else {
            m._cap(x, 0.5, w, 0.5 + h, h - _eps, rx, ry, true, keep);
            m._cap(x, 0.5, w, 0.5 - h, h - _eps, rx, ry, false, keep);
          }
        }
      }

    case BarsLayout.bottomCells:
    case BarsLayout.centredCells:
      final isDots = preset.layout == BarsLayout.centredCells;
      var pitchX = 1 / n;
      var gx = _clamp01s(preset.spacingX) * pitchX;
      final ny = _clampInt(preset.numY, isDots ? 2 : 1, 128);
      var pitchY = 1 / ny;
      var gy = preset.spacingY * pitchY;
      pitchX = (pitchX / px).floorToDouble() * px;
      gx = (gx / px).floorToDouble() * px;
      pitchY = (pitchY / py).floorToDouble() * py;
      gy = (gy / py).floorToDouble() * py;
      final w = pitchX - gx, ch = pitchY - gy;
      if (isDots) {
        m._div = thr;
        final maxK = ny >> 1;
        for (var i = 0; i < n; i++) {
          final x = i * pitchX;
          final k = math.min((0.5 * ny * bars[i]).floor(), maxK);
          for (var j = 0; j < k; j++) {
            final y = 0.5 + j * pitchY;
            m._quad(x, y, x + w, y + ch);
          }
          for (var j = 0; j < k; j++) {
            final y = 0.5 - j * pitchY;
            m._quad(x, y - ch, x + w, y);
          }
        }
      } else {
        m._div = (thr / pitchY).floorToDouble() * pitchY;
        for (var i = 0; i < n; i++) {
          final x = i * pitchX;
          final k = math.min(((1 - reserve) * ny * bars[i]).floor(), ny);
          for (var j = 0; j < k; j++) {
            final y = j * pitchY;
            m._quad(x, y, x + w, y + ch);
          }
        }
        if (showPeaks) {
          m._peak = true;
          for (var i = 0; i < n; i++) {
            final cell = math.min((peakPos[i] * ny).floor(), ny);
            if (peakPos[i] <= 0) continue;
            final x = i * pitchX;
            final y = pitchY * cell;
            m._quad(x, y, x + w, y + preset.peakHeight);
          }
        }
      }

    case BarsLayout.reflected:
    case BarsLayout.reflectedCells:
      m._div = thr;
      final total = _clampInt(preset.numX, 1, 128);
      final pitch = 1 / total;
      final gap = _clamp01s(preset.spacingX) * pitch;
      final hg = gap / 2;
      final w = pitch - gap;
      if (preset.layout == BarsLayout.reflected) {
        final rx = w / 2, ry = asp * rx;
        final keep = preset.rounding == 2;
        for (var i = 0; i < n; i++) {
          final h = bars[i] / 2;
          if (h <= 0) continue;
          for (var side = 0; side < 2; side++) {
            final x = side == 0
                ? 0.5 + hg + i * pitch
                : 0.5 - hg - w - i * pitch;
            if (preset.rounding == 0) {
              m._quad(x, 0.5 + _eps, x + w, 0.5 + h);
              m._quad(x, 0.5 - h, x + w, 0.5);
            } else {
              m._cap(x, 0.5, w, 0.5 + h, h - _eps, rx, ry, true, keep);
              m._cap(x, 0.5, w, 0.5 - h, h - _eps, rx, ry, false, keep);
            }
          }
        }
      } else {
        final ny = _clampInt(preset.numY, 2, 128);
        final pitchY = 1 / ny;
        final gy = preset.spacingY * pitchY;
        final hgy = gy / 2;
        final ch = pitchY - gy;
        final maxK = ny >> 1;
        for (var i = 0; i < n; i++) {
          final k = math.min((0.5 * ny * bars[i]).floor(), maxK);
          if (k <= 0) continue;
          for (var side = 0; side < 2; side++) {
            final x = side == 0
                ? 0.5 + hg + i * pitch
                : 0.5 - hg - w - i * pitch;
            for (var j = 0; j < k; j++) {
              final y = 0.5 + hgy + j * pitchY;
              m._quad(x, y, x + w, y + ch);
            }
            for (var j = 0; j < k; j++) {
              final y = 0.5 - hgy - j * pitchY;
              m._quad(x, y - ch, x + w, y);
            }
          }
        }
      }
  }
  m._peak = false;
}
