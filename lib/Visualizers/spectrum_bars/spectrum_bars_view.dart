import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:eq_app/helpers/audio_visualizer.dart';
import 'package:eq_app/visualizers/spectrum_bars/analyzer.dart';
import 'package:eq_app/visualizers/spectrum_bars/frame.dart';
import 'package:eq_app/visualizers/spectrum_bars/geometry.dart';
import 'package:eq_app/visualizers/spectrum_bars/presets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Power fed in place of real frames while the heard audio is silent.
const double _floorPower = 1.5849e-13;

/// Silence frames are fed at most this often (about 30 per second).
const Duration _silenceEvery = Duration(milliseconds: 30);
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

class SpectrumBarsViewState extends State<SpectrumBarsView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final SpectrumBarsAnalyzer _analyzer = SpectrumBarsAnalyzer(
    widget.preset,
  );
  final SpectrumBarsMesh _mesh = SpectrumBarsMesh();
  final Float32List _silence = Float32List(256)..fillRange(0, 256, _floorPower);
  // Newest native frame, copied here; processed by the next tick only.
  final Float32List _pending = Float32List(256);
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);

  late final Ticker _ticker = createTicker(_onTick);
  SpectrumFeed? _feed;
  ui.Image? _trail;

  int _pw = 0, _ph = 0; // physical size in pixels
  double _time = 0;
  bool _hasPending = false;
  bool _everFrame = false;
  bool _quiet = true; // nothing left to animate; ticker stopped
  bool _inBackground = false;

  // Ticker-clock bookkeeping, reset whenever the ticker is (re)started.
  Duration? _lastProcessed;
  Duration _lastRealAt = Duration.zero;
  Duration? _silenceSince;
  Duration? _lastSilenceAt;

  @visibleForTesting
  Float64List get debugBars => _analyzer.bars;
  @visibleForTesting
  Float64List get debugPeaks => _analyzer.peaks.pos;
  @visibleForTesting
  ui.Image? get debugTrail => _trail;
  @visibleForTesting
  SpectrumBarsMesh get debugMesh => _mesh;
  @visibleForTesting
  bool get debugTickerActive => _ticker.isActive;
  @visibleForTesting
  int debugProcessed = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscribe();
  }

  void _subscribe() {
    _feed?.dispose();
    _feed = SpectrumFeed(onFrame: _onFrame, source: widget.frames);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        if (_inBackground) return;
        _inBackground = true;
        _feed?.dispose();
        _feed = null;
        _hasPending = false;
        if (_ticker.isActive) _ticker.stop();
      case AppLifecycleState.resumed:
        if (!_inBackground) return;
        _inBackground = false;
        _subscribe();
        // Music may have stopped while away: let the stall rule settle it.
        if (_everFrame && !_quiet) _startTicker();
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  void didUpdateWidget(SpectrumBarsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frames != widget.frames && !_inBackground) _subscribe();
    if (oldWidget.preset.id != widget.preset.id) {
      _analyzer.setPreset(widget.preset);
      _dropTrail();
      _silenceSince = null;
      _rebuildMesh();
      _repaint.value++;
      if (_everFrame && !_inBackground) _startTicker();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
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

  /// Native frame: keep only the newest, the ticker does the work.
  void _onFrame(Float32List power) {
    if (power.length != _pending.length) return;
    _pending.setAll(0, power);
    _hasPending = true;
    _everFrame = true;
    _quiet = false;
    _startTicker();
  }

  void _startTicker() {
    _quiet = false;
    if (_ticker.isActive) return;
    _lastProcessed = null;
    _lastRealAt = Duration.zero;
    _silenceSince = null;
    _lastSilenceAt = null;
    _ticker.start();
  }

  void _onTick(Duration elapsed) {
    if (_hasPending) {
      _hasPending = false;
      final last = _lastProcessed;
      var dt = _tickDt;
      if (last != null) {
        final d = (elapsed - last).inMicroseconds / 1e6;
        if (d > 0) dt = d;
      }
      _lastProcessed = elapsed;
      _lastRealAt = elapsed;
      _silenceSince = null;
      _lastSilenceAt = null;
      _advance(_pending, dt);
      return;
    }
    if (elapsed - _lastRealAt < widget.stallAfter) return;
    final since = _silenceSince ??= elapsed;
    final lastS = _lastSilenceAt;
    if (lastS != null && elapsed - lastS < _silenceEvery) return;
    _lastSilenceAt = elapsed;
    _lastProcessed = elapsed;
    _advance(_silence, _tickDt);
    if (_allSettled() &&
        (!widget.preset.hasTrail || elapsed - since >= _trailSettle)) {
      _quiet = true;
      _ticker.stop();
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
    debugProcessed++;
    final fps = (1 / dt).clamp(5.0, 120.0);
    final step = 1 / fps;
    _time += step;
    _analyzer.update(power, fps: fps, time: _time);
    _rebuildMesh();
    _drawTrail(fps, _trail);
    _repaint.value++;
  }

  /// Renders the next trail image (trail presets only) over [previous].
  void _drawTrail(double fps, ui.Image? previous) {
    if (!widget.preset.hasTrail || _pw <= 0 || _ph <= 0) return;
    final w = _pw.toDouble(), h = _ph.toDouble();
    final rec = ui.PictureRecorder();
    paintSpectrumBarsFrame(
      ui.Canvas(rec),
      preset: widget.preset,
      mesh: _mesh,
      previous: previous,
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
    // Keep the resting picture: rebuild at the new size from the current
    // bars and peaks, and redraw a fresh trail frame.
    _rebuildMesh();
    _drawTrail(60, null);
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
