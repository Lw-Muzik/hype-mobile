import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:eq_app/helpers/audio_visualizer.dart';
import 'package:eq_app/visualizers/spectrum_bars/analyzer.dart';
import 'package:eq_app/visualizers/spectrum_bars/frame.dart';
import 'package:eq_app/visualizers/spectrum_bars/geometry.dart';
import 'package:eq_app/visualizers/spectrum_bars/presets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Power fed in place of real frames while the heard audio is silent.
const double _floorPower = 1.5849e-13;

/// Silence tick: 30 fps.
const Duration _tick = Duration(milliseconds: 33);
const double _tickDt = 1 / 30;

/// Trail presets keep drawing at least this long once silence starts, so the
/// trail has time to fade out.
const Duration _trailSettle = Duration(seconds: 3);

/// Bar height below which a bar counts as settled.
const double _settled = 0.001;

/// Renders one built-in spectrum look from the native spectrum feed.
class SpectrumBarsView extends StatefulWidget {
  const SpectrumBarsView({
    super.key,
    required this.preset,
    this.frames,
    this.stallAfter = const Duration(milliseconds: 250),
  });

  final SpectrumBarsPreset preset;

  /// Test hook; null uses the platform source.
  final Stream<Float32List>? frames;

  /// With no frame for this long, silence is fed so the bars fall.
  final Duration stallAfter;

  @override
  State<SpectrumBarsView> createState() => SpectrumBarsViewState();
}

class SpectrumBarsViewState extends State<SpectrumBarsView> {
  late final SpectrumBarsAnalyzer _analyzer = SpectrumBarsAnalyzer(
    widget.preset,
  );
  final SpectrumBarsMesh _mesh = SpectrumBarsMesh();
  final Float32List _silence = Float32List(256)..fillRange(0, 256, _floorPower);
  final Stopwatch _clock = Stopwatch();
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);

  SpectrumFeed? _feed;
  Timer? _timer;
  ui.Image? _trail;

  double _time = 0;
  int _pw = 0, _ph = 0; // physical size in pixels
  bool _hasFrame = false;
  bool _fedSilence = false;
  bool _quiet = false; // silence phase finished; waiting for real frames
  int _idleTicks = 0;
  int _silentTicks = 0;

  @visibleForTesting
  Float64List get debugBars => _analyzer.bars;
  @visibleForTesting
  Float64List get debugPeaks => _analyzer.peaks.pos;
  @visibleForTesting
  ui.Image? get debugTrail => _trail;

  @override
  void initState() {
    super.initState();
    _subscribe();
    _timer = Timer.periodic(_tick, _onTick);
  }

  void _subscribe() {
    _feed?.dispose();
    _feed = SpectrumFeed(onFrame: _onFrame, source: widget.frames);
  }

  @override
  void didUpdateWidget(SpectrumBarsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frames != widget.frames) _subscribe();
    if (oldWidget.preset.id != widget.preset.id) {
      _analyzer.setPreset(widget.preset);
      _dropTrail();
      _quiet = false;
      _silentTicks = 0;
      _rebuildMesh();
      _repaint.value++;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _feed?.dispose();
    _feed = null;
    _dropTrail();
    _repaint.dispose();
    super.dispose();
  }

  void _dropTrail() {
    _trail?.dispose();
    _trail = null;
  }

  void _onFrame(Float32List power) {
    double dt;
    if (!_hasFrame || _fedSilence) {
      dt = _tickDt;
    } else {
      dt = _clock.elapsedMicroseconds / 1e6;
    }
    _clock
      ..reset()
      ..start();
    _hasFrame = true;
    _fedSilence = false;
    _quiet = false;
    _idleTicks = 0;
    _silentTicks = 0;
    _advance(power, dt);
  }

  void _onTick(Timer _) {
    _idleTicks++;
    if (_quiet || _tick * _idleTicks < widget.stallAfter) return;
    _fedSilence = true;
    _silentTicks++;
    _advance(_silence, _tickDt);
    if (_allSettled() &&
        (!widget.preset.hasTrail || _tick * _silentTicks >= _trailSettle)) {
      _quiet = true;
    }
  }

  bool _allSettled() {
    final n = _analyzer.preset.barCount;
    final bars = _analyzer.bars;
    for (var i = 0; i < n; i++) {
      if (bars[i] >= _settled) return false;
    }
    return true;
  }

  void _advance(Float32List power, double dt) {
    final fps = (1 / dt).clamp(5.0, 120.0);
    final step = 1 / fps;
    _time += step;
    _analyzer.update(power, fps: fps, time: _time);
    _rebuildMesh();
    if (widget.preset.hasTrail && _pw > 0 && _ph > 0) {
      final w = _pw.toDouble(), h = _ph.toDouble();
      final rec = ui.PictureRecorder();
      paintSpectrumBarsFrame(
        ui.Canvas(rec),
        preset: widget.preset,
        mesh: _mesh,
        previous: _trail,
        fps: fps,
        width: w,
        height: h,
      );
      final pic = rec.endRecording();
      final next = pic.toImageSync(_pw, _ph);
      pic.dispose();
      _trail?.dispose();
      _trail = next;
    }
    _repaint.value++;
  }

  void _rebuildMesh() {
    if (_pw <= 0 || _ph <= 0) {
      _mesh.vertexCount = 0;
      return;
    }
    final peaks = _analyzer.peaks; // setPreset replaces it: never cache
    buildSpectrumBars(
      _mesh,
      preset: widget.preset,
      bars: _analyzer.bars,
      peakPos: widget.preset.hasPeaks ? peaks.pos : null,
      reserve: peaks.reserve,
      width: _pw.toDouble(),
      height: _ph.toDouble(),
    );
  }

  void _resize(Size logical, double dpr) {
    final pw = math.max(0, (logical.width * dpr).round());
    final ph = math.max(0, (logical.height * dpr).round());
    if (pw == _pw && ph == _ph) return;
    _pw = pw;
    _ph = ph;
    _dropTrail();
    _mesh.vertexCount = 0;
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, c) {
        _resize(c.biggest, dpr);
        return RepaintBoundary(
          child: CustomPaint(
            size: Size.infinite,
            painter: _BarsPainter(this, _repaint),
          ),
        );
      },
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this._s, Listenable repaint) : super(repaint: repaint);

  final SpectrumBarsViewState _s;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF000000),
    );
    if (_s._pw <= 0 || _s._ph <= 0) return;
    canvas.save();
    canvas.scale(size.width / _s._pw, size.height / _s._ph);
    final trail = _s._trail;
    if (_s.widget.preset.hasTrail) {
      if (trail != null) {
        canvas.drawImage(
          trail,
          Offset.zero,
          Paint()..filterQuality = FilterQuality.none,
        );
      }
    } else {
      paintSpectrumBarsFrame(
        canvas,
        preset: _s.widget.preset,
        mesh: _s._mesh,
        fps: 60,
        width: _s._pw.toDouble(),
        height: _s._ph.toDouble(),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old._s != _s;
}
