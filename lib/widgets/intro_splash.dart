import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../Themes/app_fonts.dart';
import '../Themes/ember.dart';

/// Animated launch intro: organic gold ripples, collapse into a blob, the
/// mark pops out and slides left as the "Hype Muzik" wordmark arrives.
///
/// Timeline (seconds, shared with desktop and web remote):
/// ripples 0-1.6, collapse 1.6-2.2, mark pop 2.2-2.6, slide + wordmark
/// 2.6-3.2, hold to 3.6, then a 250 ms fade into the app.
///
/// It never blocks startup: [ready] flips when the app is loaded and the
/// splash leaves at max(3.6 s, ready).
class IntroSplash extends StatefulWidget {
  const IntroSplash({super.key, required this.ready, required this.onDone});

  final ValueListenable<bool> ready;
  final VoidCallback onDone;

  static const total = 3.6;

  @override
  State<IntroSplash> createState() => _IntroSplashState();
}

typedef ValueListenable<T> = ValueNotifier<T>;

class _IntroSplashState extends State<IntroSplash>
    with TickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3600),
  );
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );
  bool _reduce = false;
  bool _leaving = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    widget.ready.addListener(_maybeLeave);
    _t.addStatusListener((s) {
      if (s == AnimationStatus.completed) _maybeLeave();
    });
    _fade.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _reduce = MediaQuery.of(context).disableAnimations;
    if (_reduce) _t.duration = const Duration(milliseconds: 600);
    _t.forward();
  }

  void _maybeLeave() {
    if (_leaving || !_t.isCompleted || !widget.ready.value) return;
    _leave();
  }

  void _leave() {
    if (_leaving) return;
    _leaving = true;
    _fade.forward();
  }

  @override
  void dispose() {
    widget.ready.removeListener(_maybeLeave);
    _t.dispose();
    _fade.dispose();
    super.dispose();
  }

  static double _c(double v) => v.clamp(0.0, 1.0);
  static double _out3(double x) => 1 - math.pow(1 - _c(x), 3).toDouble();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _leave,
      child: AnimatedBuilder(
        animation: Listenable.merge([_t, _fade]),
        builder: (context, _) {
          final secs = _reduce ? 99.0 : _t.value * IntroSplash.total;
          final fadeIn = _reduce ? _c(_t.value / 0.4) : 1.0;
          return Opacity(
            opacity: (1 - _fade.value) * fadeIn,
            child: Material(
              color: Ember.ground,
              child: LayoutBuilder(
                builder: (context, box) {
                  final size = box.biggest;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      if (!_reduce)
                        CustomPaint(painter: IntroRipplePainter(secs)),
                      _lockup(secs, size),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _lockup(double t, Size size) {
    final m = math.min(size.width, size.height) * 0.2;
    final fs = m * 0.62;
    final style = AppFonts.displayStyle(
      fontSize: fs,
      color: Ember.textPrimary,
      letterSpacing: -fs * 0.01,
    );
    final tp = TextPainter(
      text: TextSpan(text: 'Hype Muzik', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final gap = m * 0.22;
    final w = m + gap + tp.width;

    // Pop: 0.6 -> 1.08 -> 1.0
    final pt = _c((t - 2.2) / 0.4);
    double scale;
    if (pt < 0.6) {
      scale = 0.6 + 0.48 * Curves.easeOut.transform(pt / 0.6);
    } else {
      scale = 1.08 - 0.08 * Curves.easeInOut.transform((pt - 0.6) / 0.4);
    }
    final markOpacity = _c((t - 2.2) / 0.12);
    final u = _out3((t - 2.6) / 0.6);
    final markDx = (w / 2 - m / 2) * (1 - u);

    return Center(
      child: SizedBox(
        width: w,
        height: m,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: m + gap,
              top: (m - tp.height) / 2,
              child: Opacity(
                opacity: u,
                child: Transform.translate(
                  offset: Offset(-m * 0.3 * (1 - u), 0),
                  child: Text('Hype Muzik', style: style),
                ),
              ),
            ),
            Positioned(
              left: 0,
              child: Transform.translate(
                offset: Offset(markDx, 0),
                child: Opacity(
                  opacity: markOpacity,
                  child: Transform.scale(
                    scale: scale,
                    child: SizedBox(
                      width: m,
                      height: m,
                      child: Image.asset(
                        'assets/icon.png',
                        fit: BoxFit.contain,
                        color: Ember.ground,
                        colorBlendMode: BlendMode.plus,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Procedural ripples + collapsing blob. Pure function of [t] seconds.
class IntroRipplePainter extends CustomPainter {
  IntroRipplePainter(this.t);
  final double t;

  static double _c(double v) => v.clamp(0.0, 1.0);

  Path _blob(Offset c, double r, double phase, int lobes, double amp) {
    final p = Path();
    const n = 72;
    for (var i = 0; i <= n; i++) {
      final a = i / n * math.pi * 2;
      final rr =
          r *
          (1 +
              amp * math.sin(lobes * a + phase) +
              amp * 0.5 * math.sin((lobes + 1) * a - phase * 0.7));
      final pt = Offset(c.dx + rr * math.cos(a), c.dy + rr * math.sin(a));
      i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
    }
    return p..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final minD = math.min(size.width, size.height);
    final maxR =
        math.sqrt(size.width * size.width + size.height * size.height) * 0.4;
    final blobR = minD * 0.16;
    final k = Curves.easeIn.transform(_c((t - 1.6) / 0.6));
    final gold = Ember.accent;

    for (var i = 0; i < 5; i++) {
      final s = i * 0.12;
      if (t <= s) continue;
      final p = _c((t - s) / 1.2);
      var r = Curves.easeOut.transform(p) * maxR * (1 - i * 0.08);
      r = ui.lerpDouble(r, blobR * (0.55 + 0.1 * i), k)!;
      final a = math.min(1.0, p * 6) * (1 - 0.45 * p) * (1 - k);
      if (a <= 0.01 || r < 1) continue;
      final path = _blob(
        c,
        r,
        t * 0.9 + i * 1.3,
        i.isEven ? 3 : 4,
        0.035 + 0.02 * i / 4,
      );
      final shader = ui.Gradient.linear(
        Offset(c.dx, c.dy - r),
        Offset(c.dx, c.dy + r),
        [gold.withValues(alpha: 0.12 * a), gold.withValues(alpha: a)],
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..shader = ui.Gradient.linear(
            Offset(c.dx, c.dy - r),
            Offset(c.dx, c.dy + r),
            [gold.withValues(alpha: 0), gold.withValues(alpha: 0.45 * a)],
          )
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..shader = shader,
      );
    }

    final blobA = k * (1 - _c((t - 2.2) / 0.5));
    if (blobA > 0.01) {
      final r = blobR * (0.55 + 0.45 * k);
      final path = _blob(c, r, t * 1.4, 3, 0.06);
      canvas.drawPath(
        path,
        Paint()
          ..shader = ui.Gradient.radial(c, r * 1.6, [
            gold.withValues(alpha: 0.55 * blobA),
            gold.withValues(alpha: 0),
          ])
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = gold.withValues(alpha: 0.8 * blobA),
      );
    }
  }

  @override
  bool shouldRepaint(IntroRipplePainter old) => old.t != t;
}
