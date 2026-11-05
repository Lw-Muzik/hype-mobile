import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'radial_motion.dart';

/// The brand gold the scene draws its bars, rim and rings from.
const Color kRadialGold = Color(0xFFF6C544); // rgb(246,197,68)

/// The green the bars fade to as a band approaches full scale.
const Color kRadialGreen = Color(0xFF4ADE80); // rgb(74,222,128)

/// The radial spectrum.
///
/// # What moves on a bass hit
///
/// Everything here is drawn from [RadialMotion], which the host advances once
/// per tick: the core swells and springs back ([swell]), the crown flares and
/// a gold glow blooms behind the core ([flare]), and a shockwave ring leaves
/// the core. The crown itself is [crown]: absolute band levels of the audio
/// being heard, so a kick lifts the bass bars and they fall between kicks.
///
/// # Where it differs from desktop, and why
///
/// It began as the desktop scene, number for number: 96 bars swept once round
/// the circle, a core pulsing `0.92 + 0.12 * beat`, rings when the beat crossed
/// 0.5. On a phone that read as barely moving — the pulse came from the whole
/// mix's level and peaked around 0.3, so the core moved ~3% and rings almost
/// never fired, and the bass bars were pinned at full length by per-frame
/// normalisation. Now the bars are mirrored, bass at the top, so a kick lifts
/// both sides of the crown at once instead of one sixth of the ring; the
/// identity — 96 bars, gold to green by level, cover art in the core, gold
/// shockwaves — is unchanged.
class RadialBurstVisualizer extends CustomPainter {
  const RadialBurstVisualizer({
    required this.crown,
    required this.swell,
    required this.flare,
    required this.rings,
    this.cover,
  });

  /// Bar levels 0..1, bass first; [kCrownBars] of them.
  final List<double> crown;

  /// How much bigger than rest the core is (see [RadialMotion.swell]).
  final double swell;

  /// The hit flare, 0..1 (see [RadialMotion.flare]).
  final double flare;

  /// Live shockwaves; radius and width are fractions of the smaller side.
  final List<RadialRing> rings;

  /// Cover art for the core, or null to draw the brand gradient instead.
  final ui.Image? cover;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final minDim = math.min(size.width, size.height);
    final coreR = minDim * kRadialCore * (1 + swell);
    final maxLen = minDim * 0.26;

    // ── Glow behind the core, blooming on a hit ─────────────────────────────
    final glowR = coreR * (1.32 + 0.28 * flare);
    canvas.drawCircle(
      c,
      glowR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            kRadialGold.withValues(alpha: 0.10 + 0.42 * flare),
            kRadialGold.withValues(alpha: 0.0),
          ],
          stops: const [0.62, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: glowR)),
    );

    // ── Shockwaves ──────────────────────────────────────────────────────────
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    for (final ring in rings) {
      if (ring.a <= 0) continue;
      ringPaint
        ..color = kRadialGold.withValues(alpha: ring.a.clamp(0.0, 1.0))
        ..strokeWidth = math.max(1.0, ring.width * minDim);
      canvas.drawCircle(c, ring.r * minDim, ringPaint);
    }

    // ── The crown ───────────────────────────────────────────────────────────
    final barPaint = Paint()
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true
      ..strokeWidth = math.max(2.0, minDim * 0.0065);
    final start = coreR + minDim * 0.014;
    final push = flare * minDim * 0.03;
    final stretch = 0.9 + 0.25 * flare;
    const total = kCrownBars * 2;
    for (var i = 0; i < total; i++) {
      final band = i < kCrownBars ? i : total - 1 - i;
      final v = band < crown.length ? crown[band].clamp(0.0, 1.0) : 0.0;
      final ang = (i + 0.5) / total * math.pi * 2 - math.pi / 2;
      final cosA = math.cos(ang);
      final sinA = math.sin(ang);
      final from = start + push * 0.5;
      final to = from + minDim * 0.006 + v * maxLen * stretch + push;
      barPaint.color = Color.lerp(
        kRadialGold,
        kRadialGreen,
        v,
      )!.withValues(alpha: math.min(1.0, 0.35 + 0.65 * v + 0.2 * flare));
      canvas.drawLine(
        Offset(c.dx + cosA * from, c.dy + sinA * from),
        Offset(c.dx + cosA * to, c.dy + sinA * to),
        barPaint,
      );
    }

    // ── Core: cover art, or the brand gradient ──────────────────────────────
    final coreRect = Rect.fromCircle(center: c, radius: coreR);
    final img = cover;
    if (img != null) {
      canvas.save();
      canvas.clipPath(Path()..addOval(coreRect));
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        coreRect,
        Paint()
          ..isAntiAlias = true
          ..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
    } else {
      canvas.drawCircle(
        c,
        coreR,
        Paint()
          ..isAntiAlias = true
          ..shader = const RadialGradient(
            colors: [
              Color(0xE6F6C544), // gold, alpha 0.9
              Color(0xE6F6C544),
              Color(0x264ADE80), // green, alpha 0.15
            ],
            stops: [0.0, 0.2, 1.0],
          ).createShader(coreRect),
      );
    }
    // A rim that lights with the hit, so the swell reads even on dark art.
    canvas.drawCircle(
      c,
      coreR,
      Paint()
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true
        ..strokeWidth = math.max(1.5, minDim * 0.004)
        ..color = kRadialGold.withValues(alpha: 0.22 + 0.6 * flare),
    );
  }

  @override
  bool shouldRepaint(covariant RadialBurstVisualizer old) => true;
}
