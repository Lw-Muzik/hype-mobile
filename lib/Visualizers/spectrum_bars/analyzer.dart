import 'dart:math' as math;
import 'dart:typed_data';

import 'presets.dart';

/// Which input bins feed one bar: `count` bins starting at `start`.
class BarBand {
  final int start, count;
  const BarBand(this.start, this.count);
}

/// Decibel range that maps onto a bar's 0..1 height.
class DbWindow {
  final double lo, hi;
  const DbWindow(this.lo, this.hi);
}

const int kMaxBars = 128;

/// Falling peak caps above each bar. Positions are fractions of bar height.
class BarPeaks {
  final double height, spacing, delay, accel;
  final Float64List _pos = Float64List(kMaxBars);
  final Float64List _vel = Float64List(kMaxBars);
  final Float64List _holdStart = Float64List(kMaxBars);
  final Uint8List _state = Uint8List(kMaxBars);

  BarPeaks({
    required this.height,
    required this.spacing,
    required this.delay,
    required this.accel,
  });

  double get reserve => height == 0 ? 0 : height + spacing;

  Float64List get pos => _pos;

  void reset() {
    _pos.fillRange(0, kMaxBars, 0);
    _vel.fillRange(0, kMaxBars, 0);
    _holdStart.fillRange(0, kMaxBars, 0);
    _state.fillRange(0, kMaxBars, 0);
  }

  /// Advance the first `n` caps. `t` is preset time, `dt` the frame step (s).
  void update(Float64List bars, int n, double t, double dt) {
    if (height == 0) {
      reset();
      return;
    }
    final r = reserve;
    final a = accel < 0 ? 0.0 : accel;
    final count = n < kMaxBars ? n : kMaxBars;
    for (var i = 0; i < count; i++) {
      final b = bars[i] * (1 - r);
      final c = _pos[i] - spacing;
      switch (_state[i]) {
        case 2:
          if (c <= b) {
            _state[i] = 0;
            _pos[i] = b + spacing;
          } else {
            _pos[i] -= 0.5 * a * dt * dt + _vel[i] * dt;
            _vel[i] += a * dt;
            if (_pos[i] > 1) {
              _pos[i] = 1;
            } else if (_pos[i] < b + spacing) {
              _pos[i] = b + spacing;
            }
          }
        case 1:
          if (b <= c) {
            if (t - _holdStart[i] >= delay) {
              _state[i] = 2;
              _vel[i] = 0;
              _holdStart[i] += delay;
            }
          } else {
            _state[i] = 0;
            _pos[i] = b + spacing;
          }
        default:
          if (b < c) {
            _state[i] = 1;
            _holdStart[i] = t;
          } else {
            _pos[i] = b + spacing;
          }
      }
    }
  }
}

/// Turns a 256-bin power spectrum (93.75 Hz per bin, bin j = FFT bin j+1)
/// into smoothed 0..1 bar heights plus optional peak caps.
class SpectrumBarsAnalyzer {
  static const double _binHz = 93.75;
  static const int _binLimit = 214;
  static const double _tenOverLn10 = 4.342944819032518;
  static final Map<int, List<BarBand>> _bandCache = {};
  static final Float32List _f32Scratch = Float32List(1);

  // Band edges are accumulated in single precision so that bin boundaries
  // fall where a float32 implementation puts them (e.g. 6 * 4/3 lands on 8).
  static double _f32(double x) {
    _f32Scratch[0] = x;
    return _f32Scratch[0];
  }

  SpectrumBarsPreset _preset;
  final Float64List _bars = Float64List(kMaxBars);
  late BarPeaks _peaks;
  late List<BarBand> _bands;
  late double _nLo, _nHi, _bLo, _bHi;

  SpectrumBarsAnalyzer(SpectrumBarsPreset preset) : _preset = preset {
    _configure();
  }

  SpectrumBarsPreset get preset => _preset;
  Float64List get bars => _bars;
  BarPeaks get peaks => _peaks;

  /// Switch look; bar heights carry over, peaks start fresh.
  void setPreset(SpectrumBarsPreset p) {
    _preset = p;
    _configure();
  }

  void _configure() {
    _bands = bandsFor(_preset.barCount);
    final n = window(_preset.sens, _preset.bassSens, bass: false);
    final b = window(_preset.sens, _preset.bassSens, bass: true);
    _nLo = n.lo;
    _nHi = n.hi;
    _bLo = b.lo;
    _bHi = b.hi;
    _peaks = BarPeaks(
      height: _preset.peakHeight,
      spacing: _preset.peakSpacing,
      delay: _preset.peakDelay,
      accel: _preset.peakAccel,
    );
  }

  /// Band layout for `n` bars: one bin each over the lower half, then
  /// geometric spacing up to 20 kHz.
  static List<BarBand> bandsFor(int n) {
    return _bandCache.putIfAbsent(n, () => _buildBands(n));
  }

  static List<BarBand> _buildBands(int n) {
    final half = math.max(1, n ~/ 2);
    final step = math.max(1000 / half, _binHz);
    final out = <BarBand>[];
    var prev = 0.0;
    var cum = 0.0;
    var x0 = 0.0;
    var span = 0.0;
    for (var i = 0; i < n; i++) {
      double f;
      if (i < half) {
        f = _f32(prev + step);
      } else {
        if (i == half) {
          x0 = prev + step;
          span = math.log(20000) - math.log(x0);
        }
        f = _f32(x0 * math.pow(2, (i - half) * span / (math.ln2 * half)));
      }
      final width = _f32(_f32(f - prev) / _binHz);
      final nb = math.max(1, width.toInt());
      final c = cum.toInt();
      final start = (c + nb < _binLimit) ? c : 213 - nb;
      out.add(BarBand(start, nb));
      cum = _f32(cum + width);
      prev = f;
    }
    return List.unmodifiable(out);
  }

  /// dB range mapped to 0..1; the two lowest bars use the bass variant.
  static DbWindow window(double sens, double bassSens, {required bool bass}) {
    if (bass) {
      final c = (4.5 * bassSens).clamp(0.0, 4.5);
      final d = (60 - 46 * sens).clamp(14.0, 60.0);
      return DbWindow(45 - c - d, 45 - c);
    }
    final a = (15 * sens).clamp(0.0, 15.0);
    final b = (60 - 35 * sens).clamp(25.0, 60.0);
    return DbWindow(45 - a - b, 45 - a);
  }

  void update(Float32List power, {required double fps, required double time}) {
    final n = _preset.barCount;
    final safeFps = fps > 0 ? fps : 60.0;
    final s = math.pow(_preset.smooth, 60 / safeFps).toDouble().clamp(0.0, 1.0);
    for (var i = 0; i < n; i++) {
      final band = _bands[i];
      var sum = 0.0;
      final end = band.start + band.count;
      for (var j = band.start; j < end; j++) {
        sum += power[j];
      }
      final p = sum / band.count;
      final db = _tenOverLn10 * math.log(p);
      final lo = i < 2 ? _bLo : _nLo;
      final hi = i < 2 ? _bHi : _nHi;
      final target = ((db - lo) / (hi - lo)).clamp(0.0, 1.0);
      _bars[i] = target + s * (_bars[i] - target);
    }
    _peaks.update(_bars, n, time, 1 / safeFps);
  }
}
