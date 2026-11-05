/// The visualiser stream (contract §3.11, v1.1): what this phone's audio looks
/// like, sent to a browser that draws it, on the beat.
///
/// # Only while somebody is watching, and only while it plays
///
/// The native analysis (an FFT on every decoded buffer, a bass filter, a
/// platform-channel packet ~30 times a second) is not free. It runs exactly
/// while all of these hold, and is released the moment one stops:
///
/// * a controller subscribed (`viz_sub on:true` from the hub),
/// * the socket is online (a subscription belongs to a socket; the hub repeats
///   it after a reconnect), and
/// * music is playing.
///
/// Backgrounding the app does not matter by itself — a phone in a pocket
/// playing music is the very one a screen across the room visualises — but a
/// silent background app is "not playing", so it stops.
///
/// # Frame rate
///
/// The native side ticks at ~30 Hz. A frame goes out every ~[interval] (20 fps),
/// never closer than [minGap], and never more than [maxPerSecond] in any second
/// (the hub's budget). A bass onset that
/// lands between two frames is sent at once (still respecting [minGap]) rather
/// than up to 50 ms late: the whole point is to be on the beat.
///
/// # Timing
///
/// `heardAt` is when the frame's audio reaches the listener, in the *hub's*
/// clock. Android's analysis reports it as a moment on the monotonic
/// `Timeline.now` clock (usually ~200 ms ahead), so
/// `heardAt = hubNow + (heardAtUs - nowUs) / 1000`. With no playback clock (iOS)
/// the analysis time, `hubNow`, is all there is. `positionMs` is the playback
/// position *of that audio*: the position now plus the same lead, so a
/// controller can line lyrics up with a frame.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:eq_app/visualizers/bass_beat.dart';
import 'package:eq_app/visualizers/beat_frame.dart';

import 'connect_protocol.dart';

/// Bands in a frame, fixed by the contract.
const int vizBandCount = 32;

/// The range the bands span.
const double vizMinHz = 30;
const double vizMaxHz = 16000;

/// dBFS that maps to 0 (and 0 dBFS maps to 1).
const double vizFloorDb = -80;

double _round2(double v) => (v * 100).round() / 100;

/// dBFS to 0..1 linearly over [vizFloorDb]..0, clamped; NaN is silence.
double vizUnit(num db) {
  final v = db.toDouble();
  if (v.isNaN) return 0;
  return ((v - vizFloorDb) / -vizFloorDb).clamp(0.0, 1.0);
}

/// Centre frequency of each of [count] native bands: the app's 2048-point FFT
/// splits its bins with a squared curve (`bin = 1 + 1023 * (b / count)^2`, see
/// `FFTVisualizer::computeBandEdges`), so low bands are one bin (~21.5 Hz) wide
/// and high ones hundreds.
List<double> nativeBandCentres(int count, double sampleRate) {
  const half = 1024;
  final edges = List<int>.generate(
    count + 1,
    (b) => 1 + (math.pow(b / count, 2) * (half - 1)).toInt(),
  );
  for (var b = 1; b <= count; b++) {
    if (edges[b] <= edges[b - 1]) edges[b] = edges[b - 1] + 1;
  }
  final binHz = sampleRate / (2 * half);
  return [
    for (var b = 0; b < count; b++) (edges[b] + edges[b + 1]) / 2 * binHz,
  ];
}

/// Re-bins the native bands (dBFS, low first, power-curve spaced) onto the
/// contract's 32 log-spaced bands from [vizMinHz] to [vizMaxHz], each 0..1.
///
/// A target band takes the loudest native band whose centre falls inside it
/// (a bass note is as loud as its loudest bin). Where none does — the bass end,
/// where native bands are wider apart than log bands — the level is
/// interpolated between the two native bands around it, in log frequency, so
/// the bars there step smoothly instead of repeating.
List<double> vizBands(Float32List nativeDb, double sampleRate) {
  final out = List<double>.filled(vizBandCount, 0);
  final n = nativeDb.length;
  if (n == 0) return out;
  final double rate = sampleRate > 0 ? sampleRate : 44100;
  final centres = nativeBandCentres(n, rate);
  final ratio = math.pow(vizMaxHz / vizMinHz, 1 / vizBandCount).toDouble();
  var lo = vizMinHz;
  for (var i = 0; i < vizBandCount; i++) {
    final hi = lo * ratio;
    double? loudest;
    for (var b = 0; b < n; b++) {
      final c = centres[b];
      if (c >= lo && c < hi) {
        final db = nativeDb[b].toDouble();
        if (loudest == null || db > loudest) loudest = db;
      }
    }
    loudest ??= _interpolate(nativeDb, centres, math.sqrt(lo * hi));
    out[i] = _round2(vizUnit(loudest));
    lo = hi;
  }
  return out;
}

double _interpolate(Float32List db, List<double> centres, double hz) {
  if (hz <= centres.first) return db.first;
  if (hz >= centres.last) return db.last;
  var b = 1;
  while (centres[b] < hz) {
    b++;
  }
  final a = math.log(centres[b - 1]);
  final c = math.log(centres[b]);
  final t = (math.log(hz) - a) / (c - a);
  return db[b - 1] + (db[b] - db[b - 1]) * t;
}

/// Overall loudness 0..1: the mean power of the native bands, in dBFS, mapped
/// like the bands. (The mean, not the sum — each band is already a per-bin
/// level, so summing 64 of them would read ~18 dB too loud.)
double vizLevel(Float32List nativeDb) {
  if (nativeDb.isEmpty) return 0;
  var power = 0.0;
  for (final db in nativeDb) {
    if (db.isNaN) continue;
    power += math.pow(10, db / 10).toDouble();
  }
  final mean = power / nativeDb.length;
  if (mean <= 0) return 0;
  return _round2(vizUnit(10 * math.log(mean) / math.ln10));
}

/// Where the native analysis comes from. Listening starts it; cancelling the
/// subscription must stop it — the streamer relies on that to release it.
abstract interface class ConnectVizFeed {
  Stream<BeatFrame> get frames;
}

class ConnectVizStreamer {
  ConnectVizStreamer({
    required this.feed,
    required this.send,
    required this.isPlaying,
    required this.position,
    required this.hubNowMs,
    required this.nowUs,
    this.interval = const Duration(milliseconds: 50),
    this.minGap = const Duration(milliseconds: 25),
    this.maxPerSecond = 30,
  });

  final ConnectVizFeed feed;

  /// Sends a frame; false when no session is up.
  final bool Function(VizFrame frame) send;
  final bool Function() isPlaying;

  /// The playback position now.
  final Duration Function() position;

  /// The hub's epoch milliseconds now (see `HubClock`).
  final int Function() hubNowMs;

  /// Microseconds on the clock `BeatFrame.heardAtUs` is read from
  /// (`Timeline.now`).
  final int Function() nowUs;

  /// Target spacing of frames.
  final Duration interval;

  /// Hard floor on spacing between two frames.
  final Duration minGap;

  /// The hub drops frames beyond this many per second (§3.11), so never send
  /// more: counted over any sliding second, not by spacing alone.
  final int maxPerSecond;
  final List<int> _recentSends = [];

  int get _slackUs => interval.inMicroseconds * 2 ~/ 5;

  bool _subscribed = false;
  bool _online = false;
  StreamSubscription<BeatFrame>? _sub;

  final BassBeat _bass = BassBeat();
  int _lastSentUs = -1 << 40;
  int _dueUs = 0;
  double _pendingBeat = 0;

  /// Whether the native analysis is being listened to.
  bool get isStreaming => _sub != null;

  /// A controller started (true) or stopped (false) watching.
  void setSubscribed(bool on) {
    // A subscription belongs to a socket: one that arrives with none up is
    // stale, and the hub repeats it after the next welcome anyway.
    _subscribed = on && _online;
    refresh();
  }

  /// The socket came up or went away. A subscription does not survive its
  /// socket: the hub repeats `viz_sub` after the next `welcome`.
  void setOnline(bool online) {
    _online = online;
    if (!online) _subscribed = false;
    refresh();
  }

  /// Re-reads whether anything is playing; call when playback changes.
  void refresh() {
    final wanted = _subscribed && _online && isPlaying();
    if (wanted && _sub == null) {
      _bass.reset();
      _pendingBeat = 0;
      _dueUs = 0;
      _lastSentUs = -1 << 40;
      _recentSends.clear();
      _sub = feed.frames.listen(_onFrame, onError: (Object _) {});
    } else if (!wanted && _sub != null) {
      final sub = _sub!;
      _sub = null;
      unawaited(sub.cancel());
    }
  }

  void dispose() {
    _subscribed = false;
    _online = false;
    refresh();
  }

  void _onFrame(BeatFrame frame) {
    final now = nowUs();

    // Every frame feeds the detector, sent or not: it needs a continuous
    // signal, and a hit in a skipped frame is carried to the next one sent.
    var onset = false;
    if (frame.hops.isNotEmpty) {
      final hits = _bass.add([
        for (final h in frame.hops) h.toDouble(),
      ], frame.hopSeconds);
      for (final hit in hits) {
        if (hit.strength > _pendingBeat) _pendingBeat = hit.strength;
        if (hit.onset) onset = true;
      }
    }

    final sinceLast = now - _lastSentUs;
    if (sinceLast < minGap.inMicroseconds) return;
    _recentSends.removeWhere((t) => now - t >= 1000000);
    if (_recentSends.length >= maxPerSecond) return;
    // A tick a little before the slot counts as in it: the native side ticks
    // every ~33 ms, and insisting on arriving after the slot would turn 20 fps
    // into 15.
    final due = now + _slackUs >= _dueUs;
    if (!due && !onset) return;
    if (!isPlaying()) return;

    final hubNow = hubNowMs();
    final heardAtUs = frame.heardAtUs;
    final leadMs = heardAtUs == null ? 0 : (heardAtUs - now) / 1000;
    final heardAt = hubNow + leadMs.round();
    final lead = leadMs > 0 ? leadMs.round() : 0;
    final positionMs = math.max(0, position().inMilliseconds + lead);

    final hasBands = frame.bandsDb.isNotEmpty;
    final data = VizData(
      heardAt: heardAt,
      positionMs: positionMs,
      bands: hasBands
          ? vizBands(frame.bandsDb, frame.sampleRate)
          : List<double>.filled(vizBandCount, 0),
      level: hasBands ? vizLevel(frame.bandsDb) : _round2(_bass.level),
      beat: _round2(_pendingBeat.clamp(0.0, 1.0)),
    );
    if (!send(VizFrame(frame: data))) return;
    _pendingBeat = 0;
    _lastSentUs = now;
    _recentSends.add(now);
    if (due) {
      // Keep the cadence rather than drifting by the jitter of each arrival;
      // but after a stall do not try to catch up. An early onset frame leaves
      // the schedule alone.
      final next = _dueUs + interval.inMicroseconds;
      _dueUs = next > now ? next : now + interval.inMicroseconds;
    }
  }

  @visibleForTesting
  double get debugPendingBeat => _pendingBeat;
}
