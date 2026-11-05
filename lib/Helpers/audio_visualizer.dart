import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:eq_app/Helpers/Channel.dart';
import 'package:flutter/services.dart';

import '../visualizers/beat_frame.dart';

class Visualizers {
  static AudioVisualizer audioVisualizer() {
    return AudioVisualizer(channel: Channel.channel);
  }

  /// Starts or stops the native FFT/PCM tap.
  ///
  /// Desired state, suspend-on-background and redundant-call suppression all
  /// live in `VisualizerTap`, owned by `AppController`. This is the wire, not
  /// the policy — it used to keep its own `_visualDesired` copy, which was a
  /// second source of truth that no toggle updated.
  static void enableVisual(bool enable) {
    Channel.channel.invokeMethod("enableVisual", {"enableVisual": enable});
  }

  static void scaleVisualizer(bool scale) async {
    await Channel.channel.invokeMethod("setScalingMode", {"scale": scale});
  }

  static void setFrameRate(int frameRate) async {
    await Channel.channel.invokeMethod("setFrameRate", {
      "frameRate": frameRate,
    });
  }

  /// Set C++ FFT smoothing rates. Attack = how fast bands rise, decay = how fast they fall.
  static void setSmoothing(double attack, double decay) async {
    await Channel.channel.invokeMethod("setVizSmoothing", {
      "attack": attack,
      "decay": decay,
    });
  }

  /// Set FFT gain / beat sensitivity. 0.5 = subtle, 1.0 = normal, 3.0 = intense.
  static void setGain(double gain) async {
    await Channel.channel.invokeMethod("setVizGain", {"gain": gain});
  }
}

/// Unified audio visualizer that uses:
///   - Android: Custom C++ FFT via ExoPlayer AudioProcessor tap (no audio session ID)
///   - iOS: MTAudioProcessingTap + vDSP FFT via MethodChannel (existing)
class AudioVisualizer {
  final MethodChannel channel;
  final Set<FftCallback> _fftCallbacks = {};
  final Set<WaveformCallback> _waveformCallbacks = {};
  final Set<FftBandsCallback> _bandsCallbacks = {};

  // Android EventChannels for C++ FFT pipeline
  static const EventChannel _fftBandsChannel = EventChannel('eq_app/fft_bands');
  static const EventChannel _waveformChannel = EventChannel('eq_app/waveform');
  static const EventChannel _beatChannel = EventChannel('eq_app/beat');

  // iOS sends beat frames inside its FFT message; they are re-published here.
  static final StreamController<BeatFrame> _iosBeats =
      StreamController<BeatFrame>.broadcast();

  /// The native tap's bass report, one frame per visualizer tick, timed to
  /// what is being heard where the platform can (see [BeatFrame.synced]).
  ///
  /// Android computes these only while something listens, and only while a
  /// visualizer has the tap running — subscribe alongside an activated
  /// [AudioVisualizer], not instead of one.
  static final Stream<BeatFrame> beatFrames = Platform.isAndroid
      ? _beatChannel
            .receiveBroadcastStream()
            .map(BeatFrame.parse)
            .where((f) => f != null)
            .cast<BeatFrame>()
      : _iosBeats.stream;

  static const EventChannel _spectrumChannel = EventChannel('eq_app/spectrum');

  /// Bins in one spectrum frame (FFT bins 1..256 of a 512-point block).
  static const int spectrumBins = 256;

  // iOS sends the spectrum inside its FFT message; re-published here.
  static final StreamController<Float32List> _iosSpectrum =
      StreamController<Float32List>.broadcast();

  static Float32List? _parseSpectrum(Object? data) {
    final Float32List f;
    if (data is Float32List) {
      f = data;
    } else if (data is List) {
      f = Float32List.fromList(
        data.cast<num>().map((e) => e.toDouble()).toList(),
      );
    } else {
      return null;
    }
    return f.length == spectrumBins ? f : null;
  }

  /// 256 bin powers per visualizer tick (FFT bins 1..256 of a 512-point
  /// block). Frames of any other length are dropped.
  ///
  /// Like [beatFrames], subscribe alongside an activated tap (see
  /// [SpectrumFeed], which does that for you on iOS).
  static final Stream<Float32List> spectrumFrames = Platform.isAndroid
      ? _spectrumChannel
            .receiveBroadcastStream()
            .map(_parseSpectrum)
            .where((f) => f != null)
            .cast<Float32List>()
      : _iosSpectrum.stream;

  // Active stream subscriptions
  dynamic _bandsSub;
  dynamic _waveSub;

  // A MethodChannel has exactly ONE inbound handler. The old design set the
  // handler per-instance in the constructor, so each new AudioVisualizer
  // (Body background + player visual both create one) stomped the previous
  // one's — on iOS only the last-constructed instance received data, a
  // disposed instance stayed retained by the channel, and its dispose killed
  // the native tap for everyone. Now: one static handler installed once,
  // dispatching to a registry of live instances; the native iOS tap is
  // ref-counted so it turns off only when the last instance deactivates.
  static final Set<AudioVisualizer> _instances = {};
  static bool _sharedHandlerInstalled = false;
  static int _iosTapUsers = 0;
  bool _iosActive = false;

  AudioVisualizer({required this.channel}) {
    _instances.add(this);
    _ensureSharedHandler(channel);
  }

  static void _ensureSharedHandler(MethodChannel channel) {
    if (_sharedHandlerInstalled) return;
    _sharedHandlerInstalled = true;
    // The closure captures only statics — never an instance — so disposed
    // visualizers are not retained by the channel.
    channel.setMethodCallHandler((MethodCall call) async {
      switch (call.method) {
        case 'onFftVisualization':
          final beat = BeatFrame.parse(call.arguments['beat']);
          if (beat != null && _iosBeats.hasListener) _iosBeats.add(beat);
          if (_iosSpectrum.hasListener) {
            final spectrum = _parseSpectrum(call.arguments['spectrum']);
            if (spectrum != null) _iosSpectrum.add(spectrum);
          }
          final raw = call.arguments['fft'];
          if (raw == null) break;
          final List<int> samples = raw is List<int>
              ? raw
              : List<int>.from(raw);
          for (final v in List<AudioVisualizer>.of(_instances)) {
            for (final callback in v._fftCallbacks) {
              callback(samples);
            }
          }
          break;
        case 'onWaveformVisualization':
          final raw = call.arguments['waveform'];
          final List<int> samples = raw is List<int>
              ? raw
              : List<int>.from(raw);
          final int sampleRate = call.arguments['sampleRate'] as int;
          for (final v in List<AudioVisualizer>.of(_instances)) {
            for (final callback in v._waveformCallbacks) {
              callback(samples, sampleRate);
            }
          }
          break;
        default:
          break;
      }
    });
  }

  void activate(int sessionID) {
    if (Platform.isAndroid) {
      // Android: start C++ FFT pipeline via EventChannel subscription
      _bandsSub = _fftBandsChannel.receiveBroadcastStream().listen((data) {
        if (data == null) return;
        // No one is listening (e.g. an orphaned/idle instance) — skip all
        // deserialization and allocation work this frame.
        if (_bandsCallbacks.isEmpty && _fftCallbacks.isEmpty) return;
        final Float32List bands;
        if (data is Float32List) {
          bands = data;
        } else if (data is List) {
          bands = Float32List.fromList(data.cast<double>());
        } else {
          return;
        }
        for (final cb in _bandsCallbacks) {
          cb(bands);
        }
        // Only build the legacy int representation when a legacy painter needs
        // it — this allocation used to run every frame regardless.
        if (_fftCallbacks.isNotEmpty) {
          // Map float [0.0-1.0] to int [0-255] for compatibility
          final legacyFft = List<int>.generate(
            bands.length * 2,
            (i) => i.isEven ? (bands[i ~/ 2] * 255).round().clamp(0, 255) : 0,
          );
          for (final cb in _fftCallbacks) {
            cb(legacyFft);
          }
        }
      });
      _waveSub = _waveformChannel.receiveBroadcastStream().listen((data) {
        if (data == null) return;
        if (_waveformCallbacks.isEmpty) return;
        final List<int> waveform;
        if (data is Uint8List) {
          waveform = data.toList();
        } else if (data is List) {
          // byte[] from Android arrives as signed bytes
          waveform = List<int>.generate(
            data.length,
            (i) => ((data[i] as int) + 128) & 0xFF, // signed → unsigned
          );
        } else {
          return;
        }
        for (final cb in _waveformCallbacks) {
          cb(waveform, 44100);
        }
      });
    } else {
      // iOS: ref-counted — the native MTAudioProcessingTap is activated by
      // the first live instance only, so co-mounted visualizers share it.
      if (!_iosActive) {
        _iosActive = true;
        _iosTapUsers++;
        if (_iosTapUsers == 1) {
          channel.invokeMethod('activate_visualizer', {"sessionID": sessionID});
        }
      }
    }
  }

  void deactivate() {
    if (Platform.isAndroid) {
      _bandsSub?.cancel();
      _bandsSub = null;
      _waveSub?.cancel();
      _waveSub = null;
    } else {
      // Only the LAST instance out turns the native tap off — one widget's
      // dispose no longer kills the tap for other live visualizers.
      if (_iosActive) {
        _iosActive = false;
        _iosTapUsers--;
        if (_iosTapUsers <= 0) {
          _iosTapUsers = 0;
          channel.invokeMethod('deactivate_visualizer');
        }
      }
    }
  }

  void dispose() {
    deactivate();
    _instances.remove(this);
    _fftCallbacks.clear();
    _waveformCallbacks.clear();
    _bandsCallbacks.clear();
  }

  void addListener({
    FftCallback? fftCallback,
    WaveformCallback? waveformCallback,
    FftBandsCallback? bandsCallback,
  }) {
    if (null != fftCallback) {
      _fftCallbacks.add(fftCallback);
    }
    if (null != waveformCallback) {
      _waveformCallbacks.add(waveformCallback);
    }
    if (null != bandsCallback) {
      _bandsCallbacks.add(bandsCallback);
    }
  }

  void removeListener({
    FftCallback? fftCallback,
    WaveformCallback? waveformCallback,
    FftBandsCallback? bandsCallback,
  }) {
    if (null != fftCallback) {
      _fftCallbacks.remove(fftCallback);
    }
    if (null != waveformCallback) {
      _waveformCallbacks.remove(waveformCallback);
    }
    if (null != bandsCallback) {
      _bandsCallbacks.remove(bandsCallback);
    }
  }
}

/// Delivers [AudioVisualizer.spectrumFrames] to [onFrame] until [dispose].
///
/// Without [source] it feeds from the platform: on iOS it owns an activated
/// [AudioVisualizer] (ref-counted native tap) and releases it on dispose; on
/// Android it only subscribes. With [source] it only listens (tests).
class SpectrumFeed {
  StreamSubscription<Float32List>? _sub;
  AudioVisualizer? _visualizer;

  SpectrumFeed({
    required void Function(Float32List power) onFrame,
    Stream<Float32List>? source,
  }) {
    _sub = (source ?? AudioVisualizer.spectrumFrames).listen(onFrame);
    if (source == null && !Platform.isAndroid) {
      _visualizer = AudioVisualizer(channel: Channel.channel)..activate(0);
    }
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _visualizer?.dispose();
    _visualizer = null;
  }
}

typedef FftCallback = void Function(List<int> fftSamples);
typedef WaveformCallback = void Function(
  List<int> waveformSamples,
  int sampleRate,
);

/// Pre-computed log-frequency bands (64 floats, 0.0-1.0) from C++ FFT.
typedef FftBandsCallback = void Function(Float32List bands);
