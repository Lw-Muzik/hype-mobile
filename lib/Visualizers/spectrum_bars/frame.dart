import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:eq_app/visualizers/spectrum_bars/geometry.dart';
import 'package:eq_app/visualizers/spectrum_bars/presets.dart';
import 'package:flutter/painting.dart' show ColorFilter;

/// Per-channel amount removed after the multiply, as a 0..1 fraction.
const double _decayBias = 0.002;

/// Warp grid resolution (cells).
const int _gridX = 32, _gridY = 24;

/// RGB x [multiplier], then minus 0.002 per channel; alpha is kept.
///
/// The matrix translation column is in 0..255 units, so the bias is 0.51.
ColorFilter spectrumBarsDecayFilter(double multiplier) {
  const b = -_decayBias * 255;
  return ColorFilter.matrix(<double>[
    multiplier, 0, 0, 0, b, //
    0, multiplier, 0, 0, b, //
    0, 0, multiplier, 0, b, //
    0, 0, 0, 1, 0, //
  ]);
}

/// Vertex grid reused between frames while size and warp stay the same.
class _WarpGrid {
  _WarpGrid(this.w, this.h, this.zoom, this.zoomExp) {
    const nx = _gridX + 1, ny = _gridY + 1;
    final pos = Float32List(nx * ny * 2);
    final tex = Float32List(nx * ny * 2);
    for (var j = 0; j < ny; j++) {
      final gy = 1 - 2 * j / _gridY;
      for (var i = 0; i < nx; i++) {
        final gx = -1 + 2 * i / _gridX;
        final rad = math.min(1.0, math.sqrt(gx * gx + gy * gy) / math.sqrt2);
        final z = math.pow(zoom, -math.pow(zoomExp, 2 * rad - 1)).toDouble();
        final k = (j * nx + i) * 2;
        pos[k] = (gx + 1) / 2 * w;
        pos[k + 1] = (1 - gy) / 2 * h;
        tex[k] = (0.5 + 0.5 * gx * z) * w;
        tex[k + 1] = (0.5 - 0.5 * gy * z) * h;
      }
    }
    final idx = Uint16List(_gridX * _gridY * 6);
    var n = 0;
    for (var j = 0; j < _gridY; j++) {
      for (var i = 0; i < _gridX; i++) {
        final a = j * nx + i, b = a + 1, c = a + nx, d = c + 1;
        idx[n++] = a;
        idx[n++] = b;
        idx[n++] = d;
        idx[n++] = a;
        idx[n++] = d;
        idx[n++] = c;
      }
    }
    vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      pos,
      textureCoordinates: tex,
      indices: idx,
    );
  }

  final double w, h, zoom, zoomExp;
  late final ui.Vertices vertices;

  void dispose() => vertices.dispose();
}

_WarpGrid? _grid;

_WarpGrid _gridFor(double w, double h, double zoom, double zoomExp) {
  final g = _grid;
  if (g != null &&
      g.w == w &&
      g.h == h &&
      g.zoom == zoom &&
      g.zoomExp == zoomExp) {
    return g;
  }
  g?.dispose();
  return _grid = _WarpGrid(w, h, zoom, zoomExp);
}

/// Draws one frame: black, the previous frame decayed (and, with zoom != 1,
/// warped), then the bars.
void paintSpectrumBarsFrame(
  ui.Canvas canvas, {
  required SpectrumBarsPreset preset,
  required SpectrumBarsMesh mesh,
  ui.Image? previous,
  required double fps,
  required double width,
  required double height,
}) {
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width, height),
    ui.Paint()..color = const ui.Color(0xFF000000),
  );
  if (previous != null && preset.hasTrail) {
    final m = math.pow(preset.decayMultiplier, 60 / fps).toDouble();
    final paint = ui.Paint()
      ..colorFilter = spectrumBarsDecayFilter(m)
      ..filterQuality = ui.FilterQuality.low;
    if (preset.zoom != 1) {
      final shader = ui.ImageShader(
        previous,
        ui.TileMode.clamp,
        ui.TileMode.clamp,
        _identity,
      );
      paint.shader = shader;
      canvas.drawVertices(
        _gridFor(width, height, preset.zoom, preset.zoomExp).vertices,
        ui.BlendMode.srcOver,
        paint,
      );
      shader.dispose();
    } else {
      paint.filterQuality = ui.FilterQuality.none;
      canvas.drawImage(previous, ui.Offset.zero, paint);
    }
  }
  if (mesh.vertexCount > 0) {
    final v = mesh.toVertices();
    // Vertex colours x opaque white: symmetric, so the result does not depend
    // on which of the pair the engine calls source.
    canvas.drawVertices(
      v,
      ui.BlendMode.modulate,
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    v.dispose();
  }
}

final Float64List _identity = Float64List.fromList(<double>[
  1,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  1,
]);
