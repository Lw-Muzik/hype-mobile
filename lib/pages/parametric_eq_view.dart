import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '/controllers/app_controller.dart';
import '/models/eq_models.dart';
import '../themes/ember.dart';

/// Accent color used throughout the parametric EQ view.
/// The app's one accent, not a fifth colour invented for this screen.
///
/// This page used to carry four: a red tab indicator from the theme, a muted
/// gold for boost, a cyan for cut, and white knobs. None of them was the logo's.
const Color _kAccent = Ember.accent;

/// A cut is the same colour as a boost, dimmed — not a second hue.
///
/// Cyan against gold read as two unrelated controls rather than one control
/// pushed either side of flat.
const Color _kCut = Color(0xFFB08A2E);

const double _kMinGain = -15.0;
const double _kMaxGain = 15.0;

/// A set of distinct hue-shifted colors for individual control points.
const List<Color> _kPointColors = [
  Color(0xFFD4A825),
  _kCut,
  Color(0xFFD45E7A),
  Color(0xFF7AD45E),
  Color(0xFFB05ED4),
  Color(0xFFD4915E),
  Color(0xFF5E86D4),
  Color(0xFFD4D25E),
];

/// Frequency labels for the X-axis grid.
const List<double> _kFreqLabels = [
  20,
  50,
  100,
  200,
  500,
  1000,
  2000,
  5000,
  10000,
  20000,
];

/// dB tick marks for the Y-axis grid.
const List<double> _kDbTicks = [-15, -10, -5, 0, 5, 10, 15];

// ---------------------------------------------------------------------------
// Coordinate mapping helpers (logarithmic frequency, linear gain)
// ---------------------------------------------------------------------------

double _freqToNorm(double freq) {
  return log(freq / 20.0) / log(1000.0);
}

double _normToFreq(double norm) {
  return 20.0 * pow(1000.0, norm).toDouble();
}

double _gainToNorm(double gain) {
  return (_kMaxGain - gain) / (_kMaxGain - _kMinGain);
}

double _normToGain(double norm) {
  return _kMaxGain - norm * (_kMaxGain - _kMinGain);
}

// ---------------------------------------------------------------------------
// ParametricEqView
// ---------------------------------------------------------------------------

class ParametricEqView extends StatefulWidget {
  const ParametricEqView({super.key});

  @override
  State<ParametricEqView> createState() => _ParametricEqViewState();
}

class _ParametricEqViewState extends State<ParametricEqView> {
  int _dragIndex = -1;
  int _selectedIndex = 0;
  Offset? _dragPosition; // live position for floating readout

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, controller, child) {
        final points = controller.parametricPoints;

        if (_selectedIndex >= points.length) {
          _selectedIndex = points.isEmpty ? 0 : points.length - 1;
        }

        return Column(
          children: [
            // -- Canvas --
            Expanded(
              flex: 50,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: _buildCanvas(controller, points),
              ),
            ),

            // -- Point editor panel with Q control --
            Expanded(flex: 30, child: _buildEditorPanel(controller, points)),

            // -- Quick actions --
            Expanded(flex: 20, child: _buildQuickActions(controller, points)),
          ],
        );
      },
    );
  }

  // -------------------------------------------------------------------------
  // Canvas
  // -------------------------------------------------------------------------

  Widget _buildCanvas(AppController controller, List<ParametricPoint> points) {
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final canvasWidth = constraints.maxWidth;
          final canvasHeight = constraints.maxHeight;

          return GestureDetector(
            onLongPressStart: (details) {
              _handleLongPress(controller, details, canvasWidth, canvasHeight);
            },
            onPanStart: (details) {
              _handleDragStart(points, details, canvasWidth, canvasHeight);
            },
            onPanUpdate: (details) {
              _handleDragUpdate(controller, details, canvasWidth, canvasHeight);
            },
            onPanEnd: (_) {
              setState(() {
                _dragIndex = -1;
                _dragPosition = null;
              });
            },
            child: GestureDetector(
              onDoubleTapDown: (details) {
                _handleDoubleTap(
                  controller,
                  points,
                  details,
                  canvasWidth,
                  canvasHeight,
                );
              },
              onDoubleTap: () {},
              child: CustomPaint(
                size: Size(canvasWidth, canvasHeight),
                painter: _ParametricEqPainter(
                  points: points,
                  selectedIndex: _selectedIndex,
                  dragIndex: _dragIndex,
                  dragPosition: _dragPosition,
                  canvasWidth: canvasWidth,
                  canvasHeight: canvasHeight,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _handleLongPress(
    AppController controller,
    LongPressStartDetails details,
    double width,
    double height,
  ) {
    final normX = (details.localPosition.dx / width).clamp(0.0, 1.0);
    final normY = (details.localPosition.dy / height).clamp(0.0, 1.0);
    final freq = _normToFreq(normX).clamp(20.0, 20000.0);
    final gain = _normToGain(normY).clamp(_kMinGain, _kMaxGain);
    controller.addParametricPoint(freq, gain);
    setState(() {
      _selectedIndex = controller.parametricPoints.length - 1;
    });
  }

  void _handleDragStart(
    List<ParametricPoint> points,
    DragStartDetails details,
    double width,
    double height,
  ) {
    const hitRadius = 30.0;
    double bestDist = double.infinity;
    int bestIndex = -1;

    for (int i = 0; i < points.length; i++) {
      final px = _freqToNorm(points[i].frequency) * width;
      final py = _gainToNorm(points[i].gain) * height;
      final dist = (Offset(px, py) - details.localPosition).distance;
      if (dist < hitRadius && dist < bestDist) {
        bestDist = dist;
        bestIndex = i;
      }
    }

    _dragIndex = bestIndex;
    if (bestIndex >= 0) {
      setState(() {
        _selectedIndex = bestIndex;
        _dragPosition = details.localPosition;
      });
    }
  }

  void _handleDragUpdate(
    AppController controller,
    DragUpdateDetails details,
    double width,
    double height,
  ) {
    if (_dragIndex < 0) return;

    final normX = (details.localPosition.dx / width).clamp(0.0, 1.0);
    final normY = (details.localPosition.dy / height).clamp(0.0, 1.0);
    final freq = _normToFreq(normX).clamp(20.0, 20000.0);
    final gain = _normToGain(normY).clamp(_kMinGain, _kMaxGain);

    controller.updateParametricPoint(_dragIndex, frequency: freq, gain: gain);
    setState(() {
      _dragPosition = details.localPosition;
    });
  }

  void _handleDoubleTap(
    AppController controller,
    List<ParametricPoint> points,
    TapDownDetails details,
    double width,
    double height,
  ) {
    const hitRadius = 30.0;
    for (int i = 0; i < points.length; i++) {
      final px = _freqToNorm(points[i].frequency) * width;
      final py = _gainToNorm(points[i].gain) * height;
      final dist = (Offset(px, py) - details.localPosition).distance;
      if (dist < hitRadius) {
        controller.removeParametricPoint(i);
        return;
      }
    }
  }

  // -------------------------------------------------------------------------
  // Editor panel with Q control
  // -------------------------------------------------------------------------

  Widget _buildEditorPanel(
    AppController controller,
    List<ParametricPoint> points,
  ) {
    if (points.isEmpty) {
      return Center(
        child: Text(
          "Long-press the canvas to add a point",
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 13,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          // -- Chip row --
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: points.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final isSelected = index == _selectedIndex;
                final color = _kPointColors[index % _kPointColors.length];
                return ChoiceChip(
                  label: Text(
                    "P${index + 1}",
                    style: TextStyle(
                      color: isSelected ? Colors.black : Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  selected: isSelected,
                  selectedColor: color,
                  backgroundColor: color.withValues(alpha: 0.25),
                  side: BorderSide.none,
                  onSelected: (_) => setState(() => _selectedIndex = index),
                );
              },
            ),
          ),
          const SizedBox(height: 8),

          // -- Selected point details + Q slider --
          if (_selectedIndex >= 0 && _selectedIndex < points.length)
            _buildPointDetail(controller, points[_selectedIndex]),
        ],
      ),
    );
  }

  Widget _buildPointDetail(AppController controller, ParametricPoint point) {
    final index = _selectedIndex;
    final freqLabel = point.frequency >= 1000
        ? "${(point.frequency / 1000).toStringAsFixed(1)} kHz"
        : "${point.frequency.toStringAsFixed(0)} Hz";
    final gainLabel =
        "${point.gain >= 0 ? "+" : ""}${point.gain.toStringAsFixed(1)} dB";

    return Column(
      children: [
        Row(
          children: [
            // Frequency readout
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "FREQ",
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.2,
                      ),
                    ),
                    Text(
                      freqLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),

            // Gain readout
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "GAIN",
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.2,
                      ),
                    ),
                    Text(
                      gainLabel,
                      style: TextStyle(
                        color: point.gain > 0
                            ? _kAccent
                            : point.gain < 0
                            ? _kCut
                            : Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),

            // Enable/disable toggle
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(8),
              ),
              child: IconButton(
                icon: Icon(
                  point.enabled ? Icons.visibility : Icons.visibility_off,
                  color: point.enabled
                      ? _kAccent
                      : Colors.white.withValues(alpha: 0.3),
                  size: 20,
                ),
                onPressed: () {
                  controller.updateParametricPoint(
                    index,
                    enabled: !point.enabled,
                  );
                },
                tooltip: point.enabled ? "Disable point" : "Enable point",
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),

        // Q / Bandwidth slider
        Row(
          children: [
            Text(
              "Q",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              point.q.toStringAsFixed(1),
              style: const TextStyle(
                color: _kAccent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 3,
                  activeTrackColor: _kAccent,
                  inactiveTrackColor: Colors.white12,
                  thumbColor: _kAccent,
                  overlayColor: _kAccent.withValues(alpha: 0.1),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                ),
                child: Slider(
                  value: point.q.clamp(0.3, 10.0),
                  min: 0.3,
                  max: 10.0,
                  onChanged: (v) {
                    controller.updateParametricPoint(
                      index,
                      q: (v * 10).roundToDouble() / 10,
                    );
                  },
                ),
              ),
            ),
            SizedBox(
              width: 50,
              child: Text(
                point.q < 1.0
                    ? "Wide"
                    : point.q > 5.0
                    ? "Narrow"
                    : "",
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.3),
                  fontSize: 10,
                ),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Quick actions
  // -------------------------------------------------------------------------

  Widget _buildQuickActions(
    AppController controller,
    List<ParametricPoint> points,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _buildActionButton(
            icon: Icons.add_circle_outline,
            label: "Add Point",
            onTap: () {
              controller.addParametricPoint(1000.0, 0.0);
              setState(() {
                _selectedIndex = controller.parametricPoints.length - 1;
              });
            },
          ),
          const SizedBox(width: 8),
          _buildActionButton(
            icon: Icons.restart_alt,
            label: "Reset All",
            onTap: () {
              controller.resetParametricPoints();
              setState(() => _selectedIndex = 0);
            },
          ),
          const SizedBox(width: 8),
          _buildActionButton(
            icon: Icons.content_copy,
            label: "Copy from Graphic",
            onTap: () => _copyFromGraphic(controller),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Material(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: _kAccent, size: 22),
                const SizedBox(height: 4),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _copyFromGraphic(AppController controller) {
    final gains = controller.eqGains;
    final centres = controller.eqCentres;
    if (gains.isEmpty) return;

    controller.resetParametricPoints();

    final int bandCount = gains.length;
    final List<int> keyBands = [0];
    for (int i = 1; i < bandCount - 1; i++) {
      final prev = gains[i - 1];
      final curr = gains[i];
      final next = gains[i + 1];
      if ((curr >= prev && curr >= next) ||
          (curr <= prev && curr <= next) ||
          curr.abs() > 3.0) {
        if (keyBands.last != i - 1 || curr.abs() > 2.0) {
          keyBands.add(i);
        }
      }
    }
    keyBands.add(bandCount - 1);

    final uniqueBands = keyBands.toSet().toList()..sort();
    final selected = uniqueBands.length <= 8
        ? uniqueBands
        : _evenlySpacedSubset(uniqueBands, 8);

    for (final band in selected) {
      final freq = centres[band];
      final gain = gains[band].clamp(_kMinGain, _kMaxGain);
      if (gain.abs() > 0.1) {
        controller.addParametricPoint(freq.toDouble(), gain);
      }
    }

    setState(() => _selectedIndex = 0);
  }

  List<int> _evenlySpacedSubset(List<int> items, int count) {
    if (items.length <= count) return items;
    final result = <int>[];
    for (int i = 0; i < count; i++) {
      final idx = (i * (items.length - 1) / (count - 1)).round();
      result.add(items[idx]);
    }
    return result;
  }
}

// ---------------------------------------------------------------------------
// CustomPainter — with crosshair, floating readout, Q-aware bell curves
// ---------------------------------------------------------------------------

class _ParametricEqPainter extends CustomPainter {
  final List<ParametricPoint> points;
  final int selectedIndex;
  final int dragIndex;
  final Offset? dragPosition;
  final double canvasWidth;
  final double canvasHeight;

  _ParametricEqPainter({
    required this.points,
    required this.selectedIndex,
    this.dragIndex = -1,
    this.dragPosition,
    required this.canvasWidth,
    required this.canvasHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _drawBackground(canvas, size);
    _drawGrid(canvas, size);
    _drawBellCurves(canvas, size);
    _drawCombinedCurve(canvas, size);
    _drawCrosshair(canvas, size);
    _drawControlPoints(canvas, size);
    _drawFloatingReadout(canvas, size);
    _drawFrequencyLabels(canvas, size);
    _drawDbLabels(canvas, size);
  }

  void _drawBackground(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF1A1A2E), Color(0xFF0F0F1A)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height),
        const Radius.circular(12),
      ),
      paint,
    );
  }

  void _drawGrid(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 0.5;
    final zeroPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.2)
      ..strokeWidth = 1.0;

    for (final db in _kDbTicks) {
      final y = _gainToNorm(db) * size.height;
      final paint = db == 0 ? zeroPaint : linePaint;
      _drawDashedLine(
        canvas,
        Offset(0, y),
        Offset(size.width, y),
        paint,
        dashWidth: db == 0 ? size.width : 4.0,
        gapWidth: db == 0 ? 0 : 4.0,
      );
    }

    for (final freq in _kFreqLabels) {
      final x = _freqToNorm(freq) * size.width;
      _drawDashedLine(
        canvas,
        Offset(x, 0),
        Offset(x, size.height),
        linePaint,
        dashWidth: 4.0,
        gapWidth: 4.0,
      );
    }
  }

  void _drawDashedLine(
    Canvas canvas,
    Offset start,
    Offset end,
    Paint paint, {
    double dashWidth = 4.0,
    double gapWidth = 4.0,
  }) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final totalLen = sqrt(dx * dx + dy * dy);
    if (totalLen == 0) return;

    final ux = dx / totalLen;
    final uy = dy / totalLen;

    double drawn = 0;
    while (drawn < totalLen) {
      final segEnd = min(drawn + dashWidth, totalLen);
      canvas.drawLine(
        Offset(start.dx + ux * drawn, start.dy + uy * drawn),
        Offset(start.dx + ux * segEnd, start.dy + uy * segEnd),
        paint,
      );
      drawn = segEnd + gapWidth;
    }
  }

  // -- Bell curves using per-point Q --

  void _drawBellCurves(Canvas canvas, Size size) {
    for (int i = 0; i < points.length; i++) {
      final pt = points[i];
      if (!pt.enabled || pt.gain.abs() < 0.05) continue;

      final color = _kPointColors[i % _kPointColors.length];
      final fillPaint = Paint()
        ..color = color.withValues(alpha: 0.12)
        ..style = PaintingStyle.fill;

      final path = Path();
      final zeroY = _gainToNorm(0) * size.height;
      path.moveTo(0, zeroY);

      const steps = 200;
      for (int s = 0; s <= steps; s++) {
        final norm = s / steps;
        final freq = _normToFreq(norm);
        final gain = _bellGain(pt.frequency, pt.gain, pt.q, freq);
        final x = norm * size.width;
        final y = _gainToNorm(gain) * size.height;
        path.lineTo(x, y);
      }

      path.lineTo(size.width, zeroY);
      path.close();
      canvas.drawPath(path, fillPaint);
    }
  }

  void _drawCombinedCurve(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    final curvePaint = Paint()
      ..color = _kAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    final path = Path();
    const steps = 300;
    bool started = false;

    for (int s = 0; s <= steps; s++) {
      final norm = s / steps;
      final freq = _normToFreq(norm);
      double totalGain = 0;
      for (final pt in points) {
        if (!pt.enabled) continue;
        totalGain += _bellGain(pt.frequency, pt.gain, pt.q, freq);
      }
      totalGain = totalGain.clamp(_kMinGain, _kMaxGain);

      final x = norm * size.width;
      final y = _gainToNorm(totalGain) * size.height;

      if (!started) {
        path.moveTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, curvePaint);
  }

  // -- Crosshair on dragged/selected point --

  void _drawCrosshair(Canvas canvas, Size size) {
    final idx = dragIndex >= 0 ? dragIndex : selectedIndex;
    if (idx < 0 || idx >= points.length) return;

    final pt = points[idx];
    final cx = _freqToNorm(pt.frequency) * size.width;
    final cy = _gainToNorm(pt.gain) * size.height;
    final color = _kPointColors[idx % _kPointColors.length];

    final paint = Paint()
      ..color = color.withValues(alpha: 0.3)
      ..strokeWidth = 0.8;

    // Horizontal
    canvas.drawLine(Offset(0, cy), Offset(size.width, cy), paint);
    // Vertical
    canvas.drawLine(Offset(cx, 0), Offset(cx, size.height), paint);
  }

  void _drawControlPoints(Canvas canvas, Size size) {
    for (int i = 0; i < points.length; i++) {
      final pt = points[i];
      final color = _kPointColors[i % _kPointColors.length];
      final cx = _freqToNorm(pt.frequency) * size.width;
      final cy = _gainToNorm(pt.gain) * size.height;
      final isSelected = i == selectedIndex;
      final isDragging = i == dragIndex;
      final radius = isDragging
          ? 13.0
          : isSelected
          ? 11.0
          : 9.0;

      if (isSelected || isDragging) {
        canvas.drawCircle(
          Offset(cx, cy),
          18,
          Paint()..color = color.withValues(alpha: 0.2),
        );
      }

      final fillPaint = Paint()
        ..color = pt.enabled ? color : color.withValues(alpha: 0.3)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cx, cy), radius, fillPaint);

      final borderPaint = Paint()
        ..color = pt.enabled
            ? Colors.white.withValues(alpha: 0.9)
            : Colors.white.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = isSelected ? 2.5 : 1.5;
      canvas.drawCircle(Offset(cx, cy), radius, borderPaint);

      final textPainter = TextPainter(
        text: TextSpan(
          text: "${i + 1}",
          style: TextStyle(
            color: pt.enabled
                ? Colors.white
                : Colors.white.withValues(alpha: 0.4),
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        Offset(cx - textPainter.width / 2, cy - textPainter.height / 2),
      );
    }
  }

  // -- Floating readout near dragged point --

  void _drawFloatingReadout(Canvas canvas, Size size) {
    if (dragIndex < 0 || dragIndex >= points.length) return;

    final pt = points[dragIndex];
    final cx = _freqToNorm(pt.frequency) * size.width;
    final cy = _gainToNorm(pt.gain) * size.height;

    final freqStr = pt.frequency >= 1000
        ? "${(pt.frequency / 1000).toStringAsFixed(1)}kHz"
        : "${pt.frequency.toStringAsFixed(0)}Hz";
    final gainStr = "${pt.gain >= 0 ? "+" : ""}${pt.gain.toStringAsFixed(1)}dB";
    final label = "$freqStr  $gainStr";

    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // Position above the point, flip if near top
    double rx = cx - tp.width / 2;
    double ry = cy - 28;
    if (ry < 4) ry = cy + 18;
    rx = rx.clamp(2.0, size.width - tp.width - 2);

    final bg = RRect.fromRectAndRadius(
      Rect.fromLTWH(rx - 4, ry - 2, tp.width + 8, tp.height + 4),
      const Radius.circular(4),
    );
    canvas.drawRRect(bg, Paint()..color = const Color(0xCC1A1A2E));
    tp.paint(canvas, Offset(rx, ry));
  }

  void _drawFrequencyLabels(Canvas canvas, Size size) {
    for (final freq in _kFreqLabels) {
      final x = _freqToNorm(freq) * size.width;
      final label = freq >= 1000
          ? "${(freq / 1000).toStringAsFixed(0)}k"
          : freq.toStringAsFixed(0);
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.35),
            fontSize: 9,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, size.height - tp.height - 2));
    }
  }

  void _drawDbLabels(Canvas canvas, Size size) {
    for (final db in _kDbTicks) {
      final y = _gainToNorm(db) * size.height;
      final label = db > 0
          ? "+${db.toStringAsFixed(0)}"
          : db.toStringAsFixed(0);
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: db == 0 ? 0.45 : 0.3),
            fontSize: 9,
            fontWeight: db == 0 ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(4, y - tp.height / 2));
    }
  }

  /// Gaussian bell on octave axis, using per-point Q for bandwidth.
  /// Higher Q = narrower bell, lower Q = wider bell.
  /// bandwidth (in octaves) = 1 / Q approximately.
  static double _bellGain(
    double centerFreq,
    double peakGain,
    double q,
    double queryFreq,
  ) {
    final logDist = log(queryFreq / centerFreq) / ln2;
    final bandwidth = 1.0 / q;
    final exponent = -(logDist * logDist) / (2.0 * bandwidth * bandwidth);
    return peakGain * exp(exponent);
  }

  @override
  bool shouldRepaint(_ParametricEqPainter oldDelegate) {
    if (oldDelegate.selectedIndex != selectedIndex) return true;
    if (oldDelegate.dragIndex != dragIndex) return true;
    if (oldDelegate.dragPosition != dragPosition) return true;
    if (oldDelegate.points.length != points.length) return true;
    for (int i = 0; i < points.length; i++) {
      final a = oldDelegate.points[i];
      final b = points[i];
      if (a.frequency != b.frequency ||
          a.gain != b.gain ||
          a.q != b.q ||
          a.enabled != b.enabled) {
        return true;
      }
    }
    return false;
  }
}
