import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const Color _kAccent = Color(0xFFD4A825);

/// Circular knob for bass/treble tone controls.
///
/// Gesture model: incremental angular tracking.
/// The knob rotates in the direction the user's finger moves around the
/// knob center — clockwise increases, counter-clockwise decreases.
/// A haptic tick fires when crossing 0 dB so the user can feel the center.
/// Double-tap resets to 0 dB.
class ToneKnob extends StatefulWidget {
  final String label;
  final double value; // current dB value
  final double min;
  final double max;
  final Color activeColor;
  final ValueChanged<double> onChanged;
  final double size;

  const ToneKnob({
    super.key,
    required this.label,
    required this.value,
    this.min = 0.0,
    this.max = 15.0,
    this.activeColor = _kAccent,
    required this.onChanged,
    this.size = 250,
  });

  @override
  State<ToneKnob> createState() => _ToneKnobState();
}

class _ToneKnobState extends State<ToneKnob> {
  bool _dragging = false;

  // Angular tracking state
  double _lastAngle = 0;
  double _accumulated = 0;

  /// The knob arc sweeps 270° (from 7:30 to 4:30 on a clock face).
  static const double _sweepDeg = 270.0;

  double get _normalizedValue =>
      ((widget.value - widget.min) / (widget.max - widget.min)).clamp(0.0, 1.0);

  /// Screen angle in degrees [0, 360), clockwise from 3 o'clock.
  double _screenAngle(Offset local) {
    final cx = widget.size / 2;
    final cy = widget.size / 2;
    final rad = math.atan2(local.dy - cy, local.dx - cx);
    var deg = rad * 180.0 / math.pi;
    if (deg < 0) deg += 360.0;
    return deg;
  }

  @override
  Widget build(BuildContext context) {
    final isActive = widget.value > 0.05;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onDoubleTap: _onDoubleTapReset,
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: CustomPaint(
              painter: _ToneKnobPainter(
                normalizedValue: _normalizedValue,
                activeColor: widget.activeColor,
                isActive: isActive,
                isDragging: _dragging,
              ),
              child: Center(
                child: Text(
                  _formatValue(widget.value),
                  style: TextStyle(
                    fontSize: widget.size * 0.15,
                    fontWeight: FontWeight.w700,
                    color: isActive
                        ? widget.activeColor
                        : Colors.white.withValues(alpha: 0.5),
                    letterSpacing: -0.5,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          widget.label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: isActive
                ? widget.activeColor.withValues(alpha: 0.9)
                : Colors.white.withValues(alpha: 0.5),
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  String _formatValue(double v) {
    if (v < 0.05) return "0";
    return v.toStringAsFixed(1);
  }

  // ---------------------------------------------------------------------------
  // Gestures
  // ---------------------------------------------------------------------------

  void _onDoubleTapReset() {
    widget.onChanged(widget.min);
    HapticFeedback.lightImpact();
  }

  void _onPanStart(DragStartDetails details) {
    setState(() => _dragging = true);
    _lastAngle = _screenAngle(details.localPosition);
    _accumulated = widget.value.clamp(widget.min, widget.max);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final cx = widget.size / 2;
    final cy = widget.size / 2;
    final dx = details.localPosition.dx - cx;
    final dy = details.localPosition.dy - cy;

    // Ignore touches too close to center — angle becomes unreliable
    final minR = widget.size * 0.10;
    if (dx * dx + dy * dy < minR * minR) return;

    final currentAngle = _screenAngle(details.localPosition);

    // Incremental angular delta with 360° wraparound handling
    var delta = currentAngle - _lastAngle;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    _lastAngle = currentAngle;

    // Convert angular motion to value change (270° sweep = full range)
    final range = widget.max - widget.min;
    _accumulated += (delta / _sweepDeg) * range;
    _accumulated = _accumulated.clamp(widget.min, widget.max);

    // Snap to 0.5 dB increments
    final snapped = (_accumulated * 2).roundToDouble() / 2;

    widget.onChanged(snapped);
  }

  void _onPanEnd(DragEndDetails details) {
    setState(() => _dragging = false);
  }
}

// =============================================================================
// Painter (unchanged — visual appearance is the same)
// =============================================================================

class _ToneKnobPainter extends CustomPainter {
  final double normalizedValue; // 0.0 to 1.0
  final Color activeColor;
  final bool isActive;
  final bool isDragging;

  _ToneKnobPainter({
    required this.normalizedValue,
    required this.activeColor,
    required this.isActive,
    required this.isDragging,
  });

  static const double _startAngle = 135.0;
  static const double _sweepAngle = 270.0;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Outer ring shadow/glow
    if (isActive) {
      final glowIntensity = normalizedValue;
      canvas.drawCircle(
        center,
        radius - 2,
        Paint()
          ..color = activeColor.withValues(alpha: 0.08 + glowIntensity * 0.12)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      );
    }

    // Dark knob body
    final bodyGradient = RadialGradient(
      center: const Alignment(-0.3, -0.3),
      colors: [
        const Color(0xFF3A3A42),
        const Color(0xFF222228),
        const Color(0xFF1A1A1E),
      ],
      stops: const [0.0, 0.6, 1.0],
    );
    canvas.drawCircle(
      center,
      radius * 0.72,
      Paint()
        ..shader = bodyGradient.createShader(
          Rect.fromCircle(center: center, radius: radius * 0.72),
        ),
    );

    // Metallic rim
    canvas.drawCircle(
      center,
      radius * 0.72,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: 0.08),
    );

    // Track arc (inactive background)
    final arcRect = Rect.fromCircle(center: center, radius: radius * 0.85);
    canvas.drawArc(
      arcRect,
      _degToRad(_startAngle),
      _degToRad(_sweepAngle),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.06),
    );

    // Active arc: fills from start (0) to current value
    if (isActive) {
      final arcSweep = normalizedValue * _sweepAngle;

      canvas.drawArc(
        arcRect,
        _degToRad(_startAngle),
        _degToRad(arcSweep),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round
          ..color = activeColor.withValues(alpha: 0.85),
      );
    }

    // Tick marks around the arc
    final tickRadius = radius * 0.92;
    final tickInner = radius * 0.88;
    for (int i = 0; i <= 12; i++) {
      final t = i / 12.0;
      final angle = _degToRad(_startAngle + t * _sweepAngle);
      final isMajor = i == 0 || i == 6 || i == 12;
      final len = isMajor ? tickRadius - tickInner + 2 : tickRadius - tickInner;
      final outer = Offset(
        center.dx + tickRadius * math.cos(angle),
        center.dy + tickRadius * math.sin(angle),
      );
      final inner = Offset(
        center.dx + (tickRadius - len) * math.cos(angle),
        center.dy + (tickRadius - len) * math.sin(angle),
      );
      canvas.drawLine(
        outer,
        inner,
        Paint()
          ..strokeWidth = isMajor ? 1.5 : 0.8
          ..color = Colors.white.withValues(alpha: isMajor ? 0.25 : 0.1),
      );
    }

    // Notch indicator line (pointer)
    final notchAngle = _degToRad(_startAngle + normalizedValue * _sweepAngle);
    final notchInner = radius * 0.35;
    final notchOuter = radius * 0.62;
    final notchStart = Offset(
      center.dx + notchInner * math.cos(notchAngle),
      center.dy + notchInner * math.sin(notchAngle),
    );
    final notchEnd = Offset(
      center.dx + notchOuter * math.cos(notchAngle),
      center.dy + notchOuter * math.sin(notchAngle),
    );
    canvas.drawLine(
      notchStart,
      notchEnd,
      Paint()
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..color = isActive ? activeColor : Colors.white.withValues(alpha: 0.35),
    );

    // Center dot
    canvas.drawCircle(
      center,
      3,
      Paint()..color = Colors.white.withValues(alpha: 0.15),
    );

    // Dragging highlight ring
    if (isDragging) {
      canvas.drawCircle(
        center,
        radius * 0.72,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = activeColor.withValues(alpha: 0.4),
      );
    }
  }

  double _degToRad(double deg) => deg * math.pi / 180;

  @override
  bool shouldRepaint(covariant _ToneKnobPainter old) {
    return normalizedValue != old.normalizedValue ||
        isActive != old.isActive ||
        isDragging != old.isDragging ||
        activeColor != old.activeColor;
  }
}
