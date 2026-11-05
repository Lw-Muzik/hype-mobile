import 'dart:math' as math;

import 'package:flutter/material.dart';

class WaveformLineVisualizer extends CustomPainter {
  final List<double> audioData;
  final Color color;
  final double time;

  WaveformLineVisualizer({
    required this.audioData,
    required this.color,
    this.time = 0.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final midY = h / 2;
    final count = math.min(audioData.length, 200);
    if (count < 2) return;

    // Glow behind main line
    final glowPaint = Paint()
      ..color = color.withValues(alpha: 0.1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8.0
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    final linePaint = Paint()
      ..color = color.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    final path = _buildSmoothPath(w, midY, h, count);
    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, linePaint);

    // Faint center line
    canvas.drawLine(
      Offset(0, midY),
      Offset(w, midY),
      Paint()
        ..color = color.withValues(alpha: 0.06)
        ..strokeWidth = 0.5,
    );
  }

  Path _buildSmoothPath(double w, double midY, double h, int count) {
    final path = Path();
    final dx = w / (count - 1);
    final points = <Offset>[];

    for (int i = 0; i < count; i++) {
      final idx = (i * audioData.length / count).floor().clamp(
        0,
        audioData.length - 1,
      );
      final amp = audioData[idx].clamp(-1.0, 1.0); // Already signed -1..1
      final y = midY - amp * h * 0.4;
      points.add(Offset(i * dx, y));
    }

    // Catmull-Rom spline for smoothness
    path.moveTo(points[0].dx, points[0].dy);
    for (int i = 0; i < points.length - 1; i++) {
      final p0 = i > 0 ? points[i - 1] : points[i];
      final p1 = points[i];
      final p2 = points[i + 1];
      final p3 = i + 2 < points.length ? points[i + 2] : p2;

      final cp1x = p1.dx + (p2.dx - p0.dx) / 6;
      final cp1y = p1.dy + (p2.dy - p0.dy) / 6;
      final cp2x = p2.dx - (p3.dx - p1.dx) / 6;
      final cp2y = p2.dy - (p3.dy - p1.dy) / 6;

      path.cubicTo(cp1x, cp1y, cp2x, cp2y, p2.dx, p2.dy);
    }
    return path;
  }

  @override
  bool shouldRepaint(covariant WaveformLineVisualizer old) => true;
}
