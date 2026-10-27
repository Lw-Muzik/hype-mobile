import 'dart:async';
import 'dart:convert';

import 'package:eq_app/global/index.dart';
import '/exports/exports.dart';

import '../data/library_repository.dart';
import '../helpers/audio_handler.dart';
import '../player/queue_sync.dart';
import '../data/streamed_track.dart';
import '../Helpers/Channel.dart';
import '../helpers/index.dart';
import '../models/eq_models.dart';
import '../models/room_preset.dart';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/cloud_file.dart';
import '../services/cloud_auth_service.dart';
import '../services/connect/remote/connect_play_router.dart';
import '../services/cloud_cache_service.dart';
import '../services/cloud_metadata_service.dart';
import '../services/google_drive_service.dart';
import '../services/dropbox_service.dart';
import '../services/lyrics_service.dart';
import '../services/artwork_service.dart';
import '../services/fingerprint_service.dart';
import '../services/cast_controller.dart';
import '../services/streaming_data_guard.dart';
import '../player/crossfade_trigger.dart';
import '../player/playback_recovery.dart';
import '../player/video/video_surface.dart';
import '../services/video/video_registry.dart';
import '../services/ytmusic/yt_audio_source.dart';
import '../services/ytmusic/yt_innertube.dart';
import '../services/ytmusic/yt_repository.dart';
import '../models/lyrics_model.dart';
import '../models/recognition_result.dart';
import '../models/speaker_profile.dart';
import '../models/track_extras.dart';
import '../services/radio/radio_queue.dart';
import '../services/radio/station_source.dart';
import '../services/playback_session.dart';
import 'queue_order.dart';
import 'visualizer_tap.dart';
import '../helpers/audio_visualizer.dart';
import 'stems_controller.dart';

enum AppMode { musicPlayer, equalizer }

class AppController with ChangeNotifier implements StationSink {
  static AppController? _instance;
  static AppController get instance => _instance!;

  /// Null-safe accessor for callers that may run before the (lazily created)
  /// provider instantiates the controller — e.g. app-lifecycle callbacks.
  static AppController? get instanceOrNull => _instance;

  // Cloud services
  late final CloudAuthService cloudAuth;
  late final CloudCacheService cloudCache;
  late final CloudMetadataService cloudMetadata;
  late final GoogleDriveService googleDriveService;
  late final DropboxService dropboxService;

  // Lyrics
  // Weak-tagged local tracks are fingerprinted before their lyrics are looked
  // up, like the desktop app (lazy: fingerprintService is set up in init).
  late final LyricsService _lyricsService = LyricsService(
    identify: (song) => fingerprintService.identifySong(song),
  );
  LyricsService get lyricsService => _lyricsService;

  // Fingerprint / track recognition
  late final FingerprintService fingerprintService;
  LyricsData? _currentLyrics;
  LyricsData? get currentLyrics => _currentLyrics;
  bool _lyricsLoading = false;
  bool get lyricsLoading => _lyricsLoading;
  int? _lyricsLoadTarget; // song id whose lyrics are currently loading

  bool get isGoogleConnected => cloudAuth.isGoogleConnected;
  bool get isDropboxConnected => cloudAuth.isDropboxConnected;

  List<int> bandValues = [0, 0, 0, 0, 0];
  // app themes
  String _selectedTheme = "light";
  final bool _isDark = false;

  bool _enableEffects = false;
  bool get enableEffects => _enableEffects;
  set enableEffects(bool value) {
    _prefs.setBool("enableEffects", value);
    _enableEffects = value;
    notifyListeners();
  }

  AppMode get appMode => _appMode;
  set appMode(AppMode value) {
    _appMode = value;
    _prefs.setInt("appMode", value.index);
    // Auto-enable global EQ when switching to equalizer mode
    if (value == AppMode.equalizer && _globalEqAvailable && !_globalEqEnabled) {
      globalEqEnabled = true;
    }
    // Auto-disable global EQ when switching to music mode
    if (value == AppMode.musicPlayer && _globalEqEnabled) {
      globalEqEnabled = false;
    }
    // EQ mode has no notification of its own: the global EQ service's
    // notification (with the preset) covers it.
    // The Stems tab exists only in music-player mode. A mix changed there
    // would otherwise keep, say, the vocals muted in a mode with no control
    // left to bring them back.
    if (value == AppMode.equalizer) stemsController.reset();
    notifyListeners();
  }

  bool get isEqMode => _appMode == AppMode.equalizer;

  final HypeAudioHandler _handler;
  HypeAudioHandler get handler => _handler;
  int _selectedRoomPreset = -1;

  // MBC compressor settings (routed to C++ pipeline)
  double _dspNoise = -10.0;
  double _kneeWidth = 0.40;
  double _expandRatio = 15.0;
  double _preGain = 20;

  // Audio feature settings
  bool _gaplessPlayback = true;
  int _crossfadeDuration = 0; // seconds, 0 = off
  bool _replayGain = false;
  bool _dvcEnabled = false;
  double _dvcGain = -30.0; // dB, range -30 to 0 (0% to 100%)
  bool _dvcFineSteps = false; // false=1.5dB (5%), true=0.3dB (1%)

  // App mode
  AppMode _appMode = AppMode.musicPlayer;

  // Global EQ (system-wide)
  bool _globalEqEnabled = false;
  bool _globalEqAvailable = false;
  List<Map<String, String>> _playingApps = [];

  // Song list/grid zoom: continuous extent (80=tiny grid, 300=list mode)
  double _songGridExtent = 300.0; // default list mode

  // Configurable EQ band count (UI-layer only, native always 32)
  int _eqBandCount = 32;

  // 32-band Graphic EQ state
  List<double> _graphicBandGains = List.filled(32, 0.0);
  bool _graphicEqEnabled = false;
  String _activePresetName = 'Flat';
  Map<String, EqPreset> _savedPresets = {};
  String _lastOutputDevice = 'speaker';
  bool _linkAllDevices = true;

  // Parametric EQ state
  List<ParametricPoint> _parametricPoints = [];

  // Preamp & MBC state
  double _preampGain = 0.0; // 0-15 dB
  bool _mbcEnabled = false;

  // Room effects state (custom DSP engine — float params 0.0-1.0)
  bool _reverbEnabled = false;
  double _dspRoomSize = 0.0;
  double _dspDecay = 0.0;
  double _dspDamping = 0.0;
  double _dspPreDelay = 0.0; // ms (0-200)
  double _dspDiffusion = 0.0;
  double _dspWetDry = 0.0;
  String _activeRoomPresetName = 'Off';

  // M/S stereo expander
  bool _stereoExpandEnabled = false;
  double _stereoWidth = 1.0; // 0.0=mono, 1.0=normal, 2.0=max

  // BS2B crossfeed
  bool _crossfeedEnabled = false;

  // 3D Surround (port of the desktop stage). Defaults match the desktop panel.
  bool _surround3dEnabled = false;
  double _surround3dIntensity = 0.6;
  double _surround3dSubwoofer = 0.35;
  bool _s3dFrontL = true;
  bool _s3dFrontR = true;
  bool _s3dSideL = true;
  bool _s3dSideR = true;
  bool _s3dSurroundL = true;
  bool _s3dSurroundR = true;
  double _crossfeedCutoff = 700.0; // Hz (100-2000)
  double _crossfeedFeed = 4.5; // dB (1-15)

  // Tone controls (bass/treble shelf filters)
  bool _toneEnabled = false;
  double _bassGain = 0.0; // 0 to 20 dB
  double _bassFreq = 80.0; // 20-500 Hz
  double _bassQ = 0.707; // 0.1-4.0
  double _trebleGain = 0.0; // 0 to 20 dB
  double _trebleFreq = 10000.0; // 1000-20000 Hz
  double _trebleQ = 0.707; // 0.1-4.0

  // Output limiter (on by default)
  bool _limiterEnabled = true;

  // Speaker correction EQ (AutoEq headphone profiles)
  bool _speakerEqEnabled = false;
  String? _activeSpeakerProfile;
  final SpeakerProfileService _speakerProfileService = SpeakerProfileService();

  // Live stems (vocals / drums / instruments). The native engine follows the
  // player by itself; this holds the mix, the model download and the
  // one-time speed test. Started at the end of the constructor.
  late final StemsController stemsController = StemsController.app(_prefs);

  // Song grid extent getters/setters
  double get songGridExtent => _songGridExtent;
  set songGridExtent(double value) {
    final clamped = value.clamp(80.0, 300.0);
    if ((clamped - _songGridExtent).abs() > 0.5) {
      _songGridExtent = clamped;
      _prefs.setDouble("songGridExtent", clamped);
      notifyListeners();
    }
  }

  // EQ band count getters/setters
  int get eqBandCount => _eqBandCount;
  set eqBandCount(int value) {
    if (BandMapping.supportedCounts.contains(value)) {
      _prefs.setInt("eqBandCount", value);
      _eqBandCount = value;
      notifyListeners();
    }
  }

  BandMapping get currentBandMapping => BandMapping.forCount(_eqBandCount);

  List<double> get displayBandGains =>
      currentBandMapping.nativeToDisplay(_graphicBandGains);

  Timer? _graphicGainsPersistTimer;

  void setDisplayBandGain(int displayBand, double gain, {bool persist = true}) {
    final mapping = currentBandMapping;
    if (displayBand >= 0 && displayBand < mapping.nativeGroups.length) {
      for (final nativeIdx in mapping.nativeGroups[displayBand]) {
        _graphicBandGains[nativeIdx] = gain;
      }
      Channel.setGraphicAllBands(_graphicBandGains);
      // During a slider drag this fires ~60-90x/sec. The native call above must
      // happen every delta for real-time audio, but the json.encode + disk write
      // must NOT — pass persist:false while dragging and call commitGraphicGains()
      // on drag-end instead.
      if (persist) {
        _persistGraphicGains();
      } else {
        // Safety net: keyboard/TalkBack value changes fire onChanged WITHOUT
        // onChangeStart/onChangeEnd (flutter/flutter#123315), so a drag-end
        // commit never comes. Debounce a persist so those edits aren't lost.
        _graphicGainsPersistTimer?.cancel();
        _graphicGainsPersistTimer = Timer(
          const Duration(seconds: 1),
          _persistGraphicGains,
        );
      }
      notifyListeners();
    }
  }

  /// Flush the current graphic EQ gains to disk once (call on drag/pan-end).
  void commitGraphicGains() {
    _graphicGainsPersistTimer?.cancel();
    _graphicGainsPersistTimer = null;
    _persistGraphicGains();
  }

  // Graphic EQ getters/setters
  List<double> get graphicBandGains => _graphicBandGains;
  bool get graphicEqEnabled => _graphicEqEnabled;
  String get activePresetName => _activePresetName;
  Map<String, EqPreset> get savedPresets => _savedPresets;
  String get lastOutputDevice => _lastOutputDevice;
  bool get linkAllDevices => _linkAllDevices;
  List<ParametricPoint> get parametricPoints => _parametricPoints;
  double get preampGain => _preampGain;
  bool get mbcEnabled => _mbcEnabled;

  set preampGain(double value) {
    _preampGain = value.clamp(-15.0, 15.0);
    _prefs.setDouble("preampGain", _preampGain);
    Channel.setPreamp(_preampGain);
    notifyListeners();
  }

  // Tone controls getters/setters
  bool get toneEnabled => _toneEnabled;
  double get bassGain => _bassGain;
  double get bassFreq => _bassFreq;
  double get bassQ => _bassQ;
  double get trebleGain => _trebleGain;
  double get trebleFreq => _trebleFreq;
  double get trebleQ => _trebleQ;
  bool get limiterEnabled => _limiterEnabled;

  set toneEnabled(bool value) {
    _toneEnabled = value;
    _prefs.setBool("toneEnabled", value);
    Channel.dspSetToneEnabled(value);
    notifyListeners();
  }

  set bassGain(double value) {
    _bassGain = value.clamp(0.0, 15.0);
    _prefs.setDouble("bassGain", _bassGain);
    Channel.dspSetBassGain(_bassGain);
    notifyListeners();
  }

  set bassFreq(double value) {
    _bassFreq = value.clamp(20.0, 250.0);
    _prefs.setDouble("bassFreq", _bassFreq);
    Channel.dspSetBassFreq(_bassFreq);
    notifyListeners();
  }

  set bassQ(double value) {
    _bassQ = value.clamp(0.1, 2.0);
    _prefs.setDouble("bassQ", _bassQ);
    Channel.dspSetBassQ(_bassQ);
    notifyListeners();
  }

  set trebleGain(double value) {
    _trebleGain = value.clamp(0.0, 15.0);
    _prefs.setDouble("trebleGain", _trebleGain);
    Channel.dspSetTrebleGain(_trebleGain);
    notifyListeners();
  }

  set trebleFreq(double value) {
    _trebleFreq = value.clamp(5000.0, 15000.0);
    _prefs.setDouble("trebleFreq", _trebleFreq);
    Channel.dspSetTrebleFreq(_trebleFreq);
    notifyListeners();
  }

  set trebleQ(double value) {
    _trebleQ = value.clamp(0.1, 2.0);
    _prefs.setDouble("trebleQ", _trebleQ);
    Channel.dspSetTrebleQ(_trebleQ);
    notifyListeners();
  }

  set limiterEnabled(bool value) {
    _limiterEnabled = value;
    _prefs.setBool("limiterEnabled", value);
    Channel.dspSetLimiterEnabled(value);
    notifyListeners();
  }

  set mbcEnabled(bool value) {
    _mbcEnabled = value;
    _prefs.setBool("mbcEnabled", value);
    Channel.enableMbc(value);
    notifyListeners();
  }

  // Speaker correction EQ getters/setters
  bool get speakerEqEnabled => _speakerEqEnabled;
  String? get activeSpeakerProfile => _activeSpeakerProfile;
  List<SpeakerProfile> get speakerProfiles => _speakerProfileService.profiles;

  set speakerEqEnabled(bool value) {
    _speakerEqEnabled = value;
    _prefs.setBool("speakerEqEnabled", value);
    Channel.setSpeakerEqEnabled(value);
    notifyListeners();
  }

  Future<void> loadSpeakerProfiles() async {
    await _speakerProfileService.load();
  }

  Future<void> applySpeakerProfile(String name) async {
    final profile = _speakerProfileService.profiles
        .where((p) => p.name == name)
        .firstOrNull;
    if (profile == null) return;

    _activeSpeakerProfile = name;
    _speakerEqEnabled = true;
    _prefs.setString("activeSpeakerProfile", name);
    _prefs.setBool("speakerEqEnabled", true);

    final bands = profile.filters.map((f) => f.toNativeMap()).toList();
    await Channel.setSpeakerEqBands(bands);
    await Channel.setSpeakerEqEnabled(true);
    notifyListeners();
  }

  Future<void> clearSpeakerProfile() async {
    _activeSpeakerProfile = null;
    _speakerEqEnabled = false;
    _prefs.remove("activeSpeakerProfile");
    _prefs.setBool("speakerEqEnabled", false);
    await Channel.clearSpeakerEq();
    await Channel.setSpeakerEqEnabled(false);
    notifyListeners();
  }

  List<SpeakerProfile> searchSpeakerProfiles(String query) {
    return _speakerProfileService.search(query);
  }

  set graphicEqEnabled(bool value) {
    _prefs.setBool("graphicEqEnabled", value);
    _graphicEqEnabled = value;
    notifyListeners();
  }

  set activePresetName(String value) {
    // Guard against redundant work: the EQ view used to assign 'Custom' on every
    // slider delta, re-writing prefs + firing a platform call + notify each time.
    if (_activePresetName == value) return;
    _prefs.setString("activePresetName", value);
    _activePresetName = value;
    // Update the global EQ notification with the new preset name
    if (_globalEqEnabled) {
      Channel.updateGlobalEqPreset(value);
    }
    notifyListeners();
  }

  set linkAllDevices(bool value) {
    _prefs.setBool("linkAllDevices", value);
    _linkAllDevices = value;
    notifyListeners();
  }

  void setGraphicBandGain(int band, double gain) {
    if (band >= 0 && band < _graphicBandGains.length) {
      _graphicBandGains[band] = gain;
      Channel.setGraphicBandGain(band, gain);
      _persistGraphicGains();
      notifyListeners();
    }
  }

  void setGraphicAllBands(List<double> gains) {
    _graphicBandGains = List<double>.from(gains);
    Channel.setGraphicAllBands(gains);
    _persistGraphicGains();
    notifyListeners();
  }

  void applyBuiltInPreset(String name) {
    final gains = BuiltInPresets.presets[name];
    if (gains != null) {
      setGraphicAllBands(gains);
      activePresetName = name;
    }
  }

  void savePreset(String name) {
    _savedPresets[name] = EqPreset(
      name: name,
      graphicGains: List<double>.from(_graphicBandGains),
      parametric: _parametricPoints.map((p) => p.copyWith()).toList(),
      preamp: _preampGain,
      deviceType: _linkAllDevices ? null : _lastOutputDevice,
    );
    _prefs.setString("eqPresets", EqPreset.encodeList(_savedPresets));
    notifyListeners();
  }

  void loadPreset(String name) {
    final preset = _savedPresets[name];
    if (preset != null) {
      setGraphicAllBands(preset.graphicGains);
      _parametricPoints = preset.parametric.map((p) => p.copyWith()).toList();
      _applyParametricToNative();
      preampGain = preset.preamp;
      activePresetName = name;
    }
  }

  void deletePreset(String name) {
    _savedPresets.remove(name);
    _prefs.setString("eqPresets", EqPreset.encodeList(_savedPresets));
    notifyListeners();
  }

  // Parametric EQ methods
  void addParametricPoint(double frequency, double gain) {
    _parametricPoints.add(ParametricPoint(frequency: frequency, gain: gain));
    _applyParametricToNative();
    _persistParametricPoints();
    notifyListeners();
  }

  void updateParametricPoint(
    int index, {
    double? frequency,
    double? gain,
    double? q,
    bool? enabled,
  }) {
    if (index >= 0 && index < _parametricPoints.length) {
      _parametricPoints[index] = _parametricPoints[index].copyWith(
        frequency: frequency,
        gain: gain,
        q: q,
        enabled: enabled,
      );
      _applyParametricToNative();
      _persistParametricPoints();
      notifyListeners();
    }
  }

  void removeParametricPoint(int index) {
    if (index >= 0 && index < _parametricPoints.length) {
      _parametricPoints.removeAt(index);
      _applyParametricToNative();
      _persistParametricPoints();
      notifyListeners();
    }
  }

  void resetParametricPoints() {
    _parametricPoints.clear();
    _applyParametricToNative();
    _persistParametricPoints();
    notifyListeners();
  }

  void _applyParametricToNative() {
    // Map parametric points to 32 native bands
    final freqs = List.filled(32, 1000.0);
    final gains = List.filled(32, 0.0);
    final qs = List.filled(32, 1.4);
    for (int i = 0; i < _parametricPoints.length && i < 32; i++) {
      freqs[i] = _parametricPoints[i].frequency;
      gains[i] = _parametricPoints[i].enabled ? _parametricPoints[i].gain : 0.0;
      qs[i] = _parametricPoints[i].q;
    }
    Channel.setParametricAllBands(freqs, gains, qs: qs);
  }

  void _persistGraphicGains() {
    _prefs.setString("graphicBandGains", json.encode(_graphicBandGains));
  }

  void _persistParametricPoints() {
    _prefs.setString(
      "parametricPoints",
      json.encode(_parametricPoints.map((p) => p.toJson()).toList()),
    );
  }

  Future<void> detectAndApplyDevicePreset() async {
    final device = await Channel.getAudioOutputType();
    if (device != _lastOutputDevice && !_linkAllDevices) {
      // Save current for old device
      _savedPresets['_device_$_lastOutputDevice'] = EqPreset(
        name: '_device_$_lastOutputDevice',
        graphicGains: List<double>.from(_graphicBandGains),
        parametric: _parametricPoints.map((p) => p.copyWith()).toList(),
        preamp: _preampGain,
        deviceType: _lastOutputDevice,
      );
      _prefs.setString("eqPresets", EqPreset.encodeList(_savedPresets));

      // Load preset for new device if it exists
      final devicePreset = _savedPresets['_device_$device'];
      if (devicePreset != null) {
        setGraphicAllBands(devicePreset.graphicGains);
        _parametricPoints = devicePreset.parametric
            .map((p) => p.copyWith())
            .toList();
        _applyParametricToNative();
        preampGain = devicePreset.preamp;
      }
    }
    _lastOutputDevice = device;
    _prefs.setString("lastOutputDevice", device);
    notifyListeners();
  }

  // Audio feature getters
  bool get gaplessPlayback => _gaplessPlayback;
  int get crossfadeDuration => _crossfadeDuration;
  bool get replayGain => _replayGain;
  bool get dvcEnabled => _dvcEnabled;
  double get dvcGain => _dvcGain;
  bool get dvcFineSteps => _dvcFineSteps;
  bool get globalEqEnabled => _globalEqEnabled;
  bool get globalEqAvailable => _globalEqAvailable;
  List<Map<String, String>> get playingApps => List.unmodifiable(_playingApps);

  // Audio feature setters
  set gaplessPlayback(bool value) {
    _prefs.setBool("gaplessPlayback", value);
    _gaplessPlayback = value;
    if (value && _crossfadeDuration > 0) {
      // Gapless and crossfade are mutually exclusive
      crossfadeDuration = 0;
    }
    notifyListeners();
  }

  set crossfadeDuration(int value) {
    _prefs.setInt("crossfadeDuration", value);
    _crossfadeDuration = value;
    if (value > 0 && _gaplessPlayback) {
      // Crossfade > 0 forces gapless OFF
      _gaplessPlayback = false;
      _prefs.setBool("gaplessPlayback", false);
    }
    notifyListeners();
  }

  set replayGain(bool value) {
    _prefs.setBool("replayGain", value);
    _replayGain = value;
    // Apply immediately if a song is loaded
    if (!value) {
      handler.setTrackGain(handler.player, 1.0);
    }
    notifyListeners();
  }

  set dvcEnabled(bool value) {
    _prefs.setBool("dvcEnabled", value);
    _dvcEnabled = value;
    if (value) {
      // Start at 0% (silence) so enabling DVC never blasts at full volume
      if (!_prefs.containsKey("dvcGain")) {
        _dvcGain = -30.0;
        _prefs.setDouble("dvcGain", _dvcGain);
      }
      Channel.enableDvc();
      Channel.setDvcGain(_dvcGain);
    } else {
      Channel.disableDvc();
    }
    notifyListeners();
  }

  set dvcGain(double value) {
    _prefs.setDouble("dvcGain", value);
    _dvcGain = value;
    Channel.setDvcGain(value);
    notifyListeners();
  }

  set dvcFineSteps(bool value) {
    _prefs.setBool("dvcFineSteps", value);
    _dvcFineSteps = value;
    notifyListeners();
  }

  set globalEqEnabled(bool value) {
    _prefs.setBool("globalEqEnabled", value);
    _globalEqEnabled = value;
    Channel.enableGlobalEq(value, preset: _activePresetName);
    if (value) {
      // Give the service a moment to start and detect sessions
      Future.delayed(const Duration(milliseconds: 800), refreshPlayingApps);
    } else {
      _playingApps = [];
    }
    notifyListeners();
  }

  Future<void> refreshPlayingApps() async {
    _playingApps = await Channel.getPlayingApps();
    notifyListeners();
  }

  // MBC compressor getters/setters
  double get dspNoise => _dspNoise;
  double get preGain => _preGain;
  double get kneeWidth => _kneeWidth;
  double get expandRatio => _expandRatio;

  set dspNoise(double noise) {
    _prefs.setDouble("dspNoise", noise);
    _dspNoise = noise;
    Channel.setDspNoiseThreshold(noise);
    notifyListeners();
  }

  set preGain(double gain) {
    _prefs.setDouble("preGain", gain);
    _preGain = gain;
    Channel.setPreGain(gain);
    notifyListeners();
  }

  set kneeWidth(double width) {
    _prefs.setDouble("kneeWidth", width);
    _kneeWidth = width;
    Channel.setDspKneeWidth(width);
    notifyListeners();
  }

  set expandRatio(double ratio) {
    _prefs.setDouble("expandRatio", ratio);
    _expandRatio = ratio;
    Channel.setDspExpandRatio(ratio);
    notifyListeners();
  }

  Widget _nowWidget = Container();
  Widget get nowWidget => _nowWidget;
  set nowWidget(Widget w) {
    _nowWidget = w;
    notifyListeners();
  }

  double _bgQuality = 2.0;
  int _selectedPreset = 0;
  bool _isFancy = false;
  bool _isShuffled = false;

  /// Which visualizer surfaces are on, and whether the native tap they imply is
  /// currently running. See [VisualizerTap] — there is deliberately no separate
  /// "enable visualizer" flag any more.
  final VisualizerTap _visualTap = VisualizerTap();

  // Visualizer fine-tuning
  String _visualizerStyle = 'circular';
  int _visualizerColor = 0xFFFFFFFF; // white
  int _visualizerFrameRate = 30;
  double _visualizerReactivity = 0.15; // smoothing attack factor
  double _visualizerBeatSensitivity = 1.0; // FFT gain: 0.5 subtle → 3.0 intense

  // projectM MilkDrop settings
  int _milkdropFps = 30;
  double _milkdropBeatSensitivity = 1.0;
  double _milkdropPresetDuration = 30.0; // seconds, 0 = manual only
  bool _milkdropPresetLocked = false;
  String _milkdropPresetName = '';
  int _milkdropQuality = 1; // 0=Low, 1=Medium, 2=High, 3=Ultra
  int _songId = 0;
  int _artWorkId = 0;
  // Main method.
  final OnAudioQuery _audioQuery = OnAudioQuery();
  double _opacity = 0.0;
  double _blur = 40;

  final SharedPreferences _prefs;
  List<SongModel> _songs = [];
  List<SongModel> _shuffledSongs = [];

  // Play count tracking (song ID → count)
  Map<int, int> _playCounts = {};
  Map<int, int> get playCounts => _playCounts;

  /// Library database, wired once at startup in main(). Used to persist play
  /// counts into the library DB so "Most played" reflects real listening even
  /// after the switch away from the prefs-backed map.
  static LibraryRepository? libraryRepo;

  StreamSubscription<Duration>? _positionSub;
  bool _isCrossfading = false;

  StreamSubscription<ProcessingState>? _processingSub;
  StreamSubscription<int?>? _indexSub;
  StreamSubscription<int?>? _sessionIdSub;
  StreamSubscription<String>? _dvcVolumeSub;

  // DVC volume overlay state
  bool _showDvcOverlay = false;
  Timer? _dvcOverlayTimer;

  bool get showDvcOverlay => _showDvcOverlay;

  /// DVC gain as 0–100 percentage (−30 dB = 0%, 0 dB = 100%).
  int get dvcVolumePercent =>
      ((_dvcGain + 30) / 30 * 100).round().clamp(0, 100);

  void _showDvcVolumeOverlay() {
    _showDvcOverlay = true;
    _dvcOverlayTimer?.cancel();
    _dvcOverlayTimer = Timer(const Duration(seconds: 2), () {
      _showDvcOverlay = false;
      notifyListeners();
    });
    notifyListeners();
  }

  AppController(this._prefs, this._handler) {
    _loadSettings();
    _loadPlayCounts();

    // Wire up notification skip controls
    _handler.onSkipToNext = next;
    _handler.onSkipToPrevious = prev;
    _handler.onPlaybackError = _recoverFromPlaybackError;

    // The last session comes back as a queue and a position; the player stays
    // empty until the first press of play, which is what loads it.
    _handler.onBeforePlay = _resumePendingSession;
    // The ticker only runs while playing, so without this a pause followed by a
    // swipe-kill loses up to its whole interval. The store debounces, so this
    // costs one write.
    _handler.onPaused = _saveSession;
    unawaited(_restoreSession());
    _startSessionTicker();

    // When crossfade starts, notify UI so waveform binds to the new track player
    _handler.onCrossfadeStarted = () {
      // The incoming track is now the audible one, so the picture moves to its
      // player at the same moment the audio starts fading over. The sound
      // dissolves; the picture cuts, because dissolving it would mean decoding
      // two videos at once.
      unawaited(VideoSurface.instance.rebind());
      notifyListeners();
    };

    // Re-bind all player streams after a crossfade player swap
    _handler.onPlayerSwapped = _rebindPlayerStreams;

    // Apply DVC state on startup
    if (_dvcEnabled) {
      Channel.enableDvc();
      Channel.setDvcGain(_dvcGain);
    }

    // Global EQ: check availability and restore state
    _initGlobalEq();

    _bindDvcVolumeButtons();
    _bindProcessingState();
    _bindCurrentIndex();
    _bindPositionSampling();
    _setupCrossfadeListener();
    _bindAudioSessionId();

    // Fingerprint service
    fingerprintService = FingerprintService(_prefs);

    // Cloud services
    _instance = this;
    cloudAuth = CloudAuthService();
    cloudCache = CloudCacheService(_prefs);
    googleDriveService = GoogleDriveService(cloudAuth);
    dropboxService = DropboxService(cloudAuth);
    cloudMetadata = CloudMetadataService(
      cloudAuth,
      cloudCache,
      googleDriveService,
      dropboxService,
    );
    _initCloudServices();

    // Hands the stems engine its YouTube exclusions and looks for the model.
    stemsController.start();
  }

  /// Listen to audio session ID changes and rebind session-bound native effects.
  /// EQ, MBC, and room effects are NOT session-bound (C++ pipeline), only
  /// LoudnessEnhancer (DVC) needs rebinding.
  void _bindAudioSessionId() {
    _sessionIdSub?.cancel();
    _sessionIdSub = _handler.player.androidAudioSessionIdStream.listen((
      sessionId,
    ) {
      if (sessionId != null) {
        Channel.setSessionId(sessionId);
        // Re-apply DVC state after session change (LoudnessEnhancer is session-bound)
        if (_dvcEnabled) {
          Channel.enableDvc();
          Channel.setDvcGain(_dvcGain);
        }
      }
    });
  }

  /// Listen to hardware volume button events forwarded by DvcController.
  /// Android-only: iOS has no volume button interception API.
  void _bindDvcVolumeButtons() {
    if (!Platform.isAndroid) return;
    _dvcVolumeSub?.cancel();
    _dvcVolumeSub = Channel.dvcVolumeButtonStream.listen((direction) {
      if (!_dvcEnabled) return;
      final step = _dvcFineSteps ? 0.3 : 1.5;
      if (direction == "up") {
        dvcGain = (_dvcGain + step).clamp(-30.0, 0.0);
      } else if (direction == "down") {
        dvcGain = (_dvcGain - step).clamp(-30.0, 0.0);
      }
      _showDvcVolumeOverlay();
    });
  }

  /// Subscribe to the active player's processingStateStream.
  /// Called once at init and again after every crossfade swap.
  void _bindProcessingState() {
    _processingSub?.cancel();
    _processingSub = handler.player.processingStateStream.listen(
      (event) {
        if (event == ProcessingState.ready) {
          // Something opened. Whatever was rescued is no longer the failure being
          // guarded against, and the next one — hours later, on a URL that has
          // since expired — deserves its own second chance.
          _rescuingSongId = null;
          _rescueAttempts = 0;
          preCacheNextCloudTracks();
          // On iOS, the MTAudioProcessingTap calls dsp_reinit() when a new
          // AVPlayerItem starts, resetting all DSP filters to defaults.
          // Re-apply all EQ/reverb/tone settings to the native engine.
          if (Platform.isIOS) {
            _applyAllDspParams();
          }
        }
        if (event == ProcessingState.completed) {
          // Repeat-all wraps instead of stopping. `next()` has always done this
          // for the skip button, but a track ending on its own reached here and
          // stopped — so the setting appeared to work right up until the user put
          // the phone down, which is the only time it matters.
          final repeatAll = handler.loopMode == LoopMode.all;
          if (_gaplessPlayback && handler.player.audioSources.length > 1) {
            final idx = handler.player.currentIndex ?? 0;
            if (idx >= songs.length - 1 && !repeatAll) {
              handler.player.stop();
            }
          } else if (!_isCrossfading) {
            if (songId >= songs.length - 1) {
              if (repeatAll && songs.isNotEmpty) {
                songId = 0;
                artWorkId = songs[0].id;
                unawaited(loadTrackAt(0));
              } else {
                handler.player.stop();
              }
            } else {
              // Both branches assign through the `songId` setter, which tops the
              // radio up for every path at once.
              songId += 1;
              artWorkId = songs[songId].id;
              unawaited(loadTrackAt(songId));
            }
          }
        }
      },
      // Same reasoning as [_bindCurrentIndex]: this stream carries the
      // player's errors as well as its states, and one place recovers from
      // them.
      onError: (Object _) {},
    );
  }

  /// Subscribe to currentIndexStream for gapless mode index tracking.
  /// Only updates songId when the player actually has a multi-source queue
  /// loaded (audioSources.length > 1). When a single source is loaded via
  /// loadAudioSource(), the player always emits index 0 which would
  /// incorrectly overwrite the real songId.
  void _bindCurrentIndex() {
    _indexSub?.cancel();
    _indexSub = handler.player.currentIndexStream.listen(
      (index) {
        if (index != null &&
            _gaplessPlayback &&
            songs.isNotEmpty &&
            index < songs.length &&
            handler.player.audioSources.length > 1) {
          _songId = index;
          _artWorkId = songs[index].id;
          // Same history every other advance path records — see
          // [_onTrackStarted] for why this cannot be left to the setter.
          _onTrackStarted(index);
          _updateMediaItemForIndex(index);
          // The gapless path advances the index here rather than through the
          // setter, so this is where a session learns the track changed.
          _saveSession();
          notifyListeners();
          _loadLyricsForCurrentSong();
          // Endless radio: tops the queue up before it runs out. A no-op unless a
          // YouTube queue is playing and Autoplay is on.
          unawaited(RadioQueue.instance.onIndexChanged(this, index));
        }
      },
      // Derived from the same event stream as the handler's, so a dead track
      // surfaces here too. Recovery belongs in one place — see
      // [_recoverFromPlaybackError] — and this listener only has to decline
      // to become a second, unhandled copy of the same error.
      onError: (Object _) {},
    );
  }

  /// Called by HypeAudioHandler after crossfade completes and players are swapped.
  /// Re-binds all subscriptions to the new active player and notifies the UI
  /// so StreamBuilders (waveform, playing state) reconnect to the new player.
  void _rebindPlayerStreams() {
    // The picture belongs to a player, and the players have just traded places.
    unawaited(VideoSurface.instance.rebind());
    _bindProcessingState();
    _bindCurrentIndex();
    _setupCrossfadeListener();
    _bindAudioSessionId();
    // After crossfade swap, the new player's tap has reinited the DSP engine
    if (Platform.isIOS) {
      _applyAllDspParams();
    }
    notifyListeners();
  }

  /// Set while a track is being loaded into the player.
  ///
  /// Read by the crossfade trigger, which must not start a fade out of a track
  /// that is in the middle of being replaced — see [shouldStartCrossfade].
  bool _loadingTrack = false;

  void _setupCrossfadeListener() {
    _positionSub?.cancel();
    _positionSub = handler.player.positionStream.listen((position) {
      if (shouldStartCrossfade(
        crossfadeSeconds: _crossfadeDuration,
        repeatOne: handler.loopMode == LoopMode.one,
        alreadyCrossfading: _isCrossfading,
        loadingTrack: _loadingTrack,
        duration: handler.player.duration,
        position: position,
        index: songId,
        queueLength: songs.length,
      )) {
        _beginCrossfade();
      }
    });
  }

  /// Index that failed to crossfade — don't retry it every position tick;
  /// the normal end-of-track advance handles it instead. Cleared on track change.
  int _crossfadeFailedIdx = -1;

  Future<void> _beginCrossfade() async {
    if (_isCrossfading) return;
    final nextIdx = songId + 1;
    if (nextIdx == _crossfadeFailedIdx) return;
    _isCrossfading = true;
    final nextSong = songs[nextIdx];
    final prevId = _songId;
    final prevArtId = _artWorkId;

    try {
      // Deliberately not through the `songId` setter — a crossfade must not
      // fire the setter's play-count and session work mid-fade — so the radio
      // top-up the setter does has to be repeated here. Without it a station
      // played with crossfade on never grows past its first page, because a
      // crossfaded track never reaches the natural-end handler either.
      _songId = nextIdx;
      _artWorkId = nextSong.id;
      // A crossfaded track is still a track that was listened to. This is the
      // third of the three advance paths — see [_onTrackStarted].
      _onTrackStarted(nextIdx);
      unawaited(RadioQueue.instance.onIndexChanged(this, nextIdx));
      _loadLyricsForCurrentSong();

      final AudioSource nextSource;
      // Videos first, for the same reason every other source-construction site
      // checks: a video's `data` is an identity, and what the player opens
      // lives in the registry.
      if (VideoRegistry.instance.sourceFor(nextSong.id) case final video?) {
        nextSource = video.toAudioSource();
      } else if (nextSong.data.startsWith('http')) {
        // YouTube stream — direct URI with its headers. Must not go through the
        // cloud-cache branch below: these targets are single-use, keyed by
        // nothing the cache understands, and need no auth exchange.
        if (YtInnerTube.isStreamUrl(nextSong.data)) {
          nextSource = ytAudioSource(nextSong.data);
        } else {
          final fileId = nextSong.id.toString();
          if (cloudCache.isCached(fileId)) {
            nextSource = AudioSource.file(cloudCache.cacheFile(fileId).path);
          } else {
            final headers = nextSong.data.contains('googleapis.com')
                ? await cloudAuth.getGoogleAuthHeaders()
                : <String, String>{};
            nextSource = AudioSource.uri(
              Uri.parse(nextSong.data),
              headers: headers,
            );
          }
        }
      } else {
        nextSource = nextSong.data.startsWith('/')
            ? AudioSource.file(nextSong.data)
            : AudioSource.uri(Uri.parse(nextSong.data));
      }

      await handler.beginCrossfade(
        nextSource,
        nextSong,
        Duration(seconds: _crossfadeDuration),
        replayGain: _replayGain,
      );
    } catch (e) {
      // Crossfade failed (dead cloud URL, auth error, ...). Roll back the
      // already-advanced track state so UI and audio agree. Latch the failed
      // index so the position listener doesn't hammer the dead URL every tick
      // — the normal end-of-track advance takes over instead.
      _crossfadeFailedIdx = nextIdx;
      // Only if this crossfade is still what the track state describes. Press
      // next while the fade is loading and `next()` has already moved the index
      // on; rolling back then would drag the user back to the track they just
      // left, while the load they triggered plays on underneath — the queue
      // looking stuck on the old track with the button doing nothing.
      if (_songId == nextIdx) {
        _songId = prevId;
        _artWorkId = prevArtId;
        _loadLyricsForCurrentSong();
      }
      notifyListeners();
    } finally {
      // Without this a single failure left _isCrossfading stuck true and
      // silently disabled crossfade until app restart.
      _isCrossfading = false;
    }
  }

  Future<void> _updateMediaItemForIndex(int index) async {
    if (index >= songs.length) return;
    final song = songs[index];
    Uri? artUri;
    if (song.data.startsWith('http') &&
        song.album != null &&
        song.album!.startsWith('http')) {
      final downloaded = await _downloadCloudArtwork(song.album!, song.id);
      artUri = downloaded != null ? Uri.file(downloaded) : null;
    } else {
      final image = await fetchArtworkUrl(song.data, song.id);
      artUri = Uri.file(image);
    }
    handler.setCurrentMediaItem(
      MediaItem(
        id: song.data,
        album: song.album,
        title: song.title,
        artist: song.artist,
        duration: Duration(milliseconds: song.duration ?? 0),
        artUri: artUri,
      ),
    );
  }

  Future<String?> _downloadCloudArtwork(String url, int songId) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/cloud_art_$songId.png');
      if (file.existsSync()) return file.path;
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        return file.path;
      }
    } catch (_) {}
    return null;
  }

  /// Central method for playing a song selected from any list.
  /// Properly handles gapless queue vs single-source loading.
  ///
  /// Returns the load, which finishes once the player holds the track (it does
  /// not wait for playback to end). Taps ignore it, as they always did; Hype
  /// Connect awaits it so a remote `pause` cannot overtake the `play` before
  /// it. [initialPosition] starts the track part-way in, which a controller
  /// handing over a song mid-way asks for.
  Future<void> playSongFromList(
    List<SongModel> songList,
    int index, {
    Duration? initialPosition,
  }) {
    // Another device is the player: play there (Hype Connect remote mode).
    final routed = ConnectPlayRouter.songs(
      songList,
      index,
      here: () => playSongFromList(
        songList,
        index,
        initialPosition: initialPosition,
      ),
    );
    if (routed != null) return routed;
    // The user picked something rather than resuming. Whatever was waiting from
    // the last session is no longer what is about to play.
    _pendingResume = null;
    _queueGeneration++;
    songs = songList;
    // A new list arriving while shuffle is already on has to *be* shuffled. The
    // `songs` setter copies the incoming order into both lists verbatim, so
    // without this the button reads "shuffle on" over a queue in perfect
    // original order — which is how the setting appeared to do nothing at all
    // for anyone who left it switched on between sessions.
    var startIndex = index;
    if (_isShuffled) {
      _shuffledSongs = QueueOrder.shuffle(_songs, songList[index]);
      startIndex = 0;
    }
    songId = startIndex;
    artWorkId = songList[index].id;
    // Anything that isn't a YouTube stream has taken over the player, so the
    // radio must stop topping up a queue that no longer exists — and the
    // playlist still filling in the background must stop appending to it.
    //
    // A music video counts as a YouTube stream even though its `data` is a local
    // manifest rather than a googlevideo URL. Reading only the URL would detach
    // the radio the moment a video started, which is exactly the case that
    // wanted it attached.
    if (!YtInnerTube.isStreamUrl(songList[index].data) &&
        !VideoRegistry.instance.isVideo(songList[index].id)) {
      RadioQueue.instance.detach();
      VideoRegistry.instance.clear();
    }
    // When casting to a desktop, send the track there instead of playing it
    // locally (the desktop pulls + plays it through its DSP chain).
    if (CastController.instance.isCasting) {
      CastController.instance.cast(songList[index]);
      return Future.value();
    }
    if (_gaplessPlayback && _crossfadeDuration == 0) {
      return loadGaplessQueue(startIndex, initialPosition: initialPosition);
    }
    return loadAudioSource(
      handler,
      songList[index],
      replayGain: _replayGain,
      initialPosition: initialPosition,
    );
  }

  /// Puts [extra] right after the playing track — "play next".
  ///
  /// With nothing after the playing track this is [appendToQueue]. Otherwise
  /// [QueueOrder.insertNext] places the tracks in both orderings (while
  /// shuffled, [songs] is [_shuffledSongs], so they must land after the playing
  /// song *there*), and the player is then handed the new order the way a
  /// reorder hands it one — serialised with appends, so neither sees a
  /// half-built list.
  Future<void> insertNext(List<SongModel> extra) {
    if (extra.isEmpty) return Future.value();
    final spliced = QueueOrder.insertNext(
      original: _songs,
      shuffled: _shuffledSongs,
      isShuffled: _isShuffled,
      playingIndex: _songId,
      extra: extra,
    );
    if (spliced == null) return appendToQueue(extra);
    _songs = spliced.original;
    _shuffledSongs = spliced.shuffled;
    notifyListeners();
    _saveSession();
    return _queueSync.serial(_reloadQueueOrder);
  }

  /// Plays [seed] alone and builds a station behind it.
  ///
  /// The other door out of [playSongFromList]. That one queues the whole list
  /// the user tapped in, because a list is usually a running order — an album,
  /// a playlist, a folder, an artist page. Search results are not a running
  /// order: they are twenty answers to one question, and what a person means by
  /// tapping one of them is "play this", not "play this and then the nineteen
  /// other things I was choosing between".
  ///
  /// Deliberately **not** gated on the Autoplay preference. That setting governs
  /// stations the app decides to start on its own as a queue runs out; this is
  /// one the user asked for by tapping.
  Future<void> playStation(SongModel seed, StationSource source) async {
    // Another device is the player: it starts the radio (Hype Connect).
    final routed = ConnectPlayRouter.songs(
      [seed],
      0,
      radio: true,
      here: () => playStation(seed, source),
    );
    if (routed != null) return routed;
    // First, because playSongFromList detaches whatever station was running.
    playSongFromList([seed], 0);
    RadioQueue.instance.attach(source);
    await RadioQueue.instance.fill(this, force: true);
  }

  /// Makes everything after the playing track [source]'s station, leaving the
  /// track itself playing where it is.
  ///
  /// "Start radio" on the song that is already playing. [playStation] starts
  /// its seed from the top, which here would restart the very song the user
  /// asked to hear more like. The queue is cut back to that one song and the
  /// station grows behind it; in gapless mode the player is handed the shorter
  /// queue the way a reorder hands it a new order — at the current position,
  /// playing or paused as it was.
  Future<void> continueAsStation(StationSource source) async {
    if (_songId < 0 || _songId >= songs.length) return;
    final playing = songs[_songId];
    // The fill of the old queue, if one is still resolving, stops appending.
    _queueGeneration++;
    _songs = [playing];
    _shuffledSongs = [playing];
    _songId = 0;
    _artWorkId = playing.id;
    notifyListeners();
    if (_gaplessPlayback &&
        _crossfadeDuration == 0 &&
        handler.player.audioSources.length > 1) {
      await loadGaplessQueue(
        0,
        initialPosition: handler.player.position,
        autoPlay: handler.player.playing,
      );
    }
    RadioQueue.instance.attach(source);
    await RadioQueue.instance.fill(this, force: true);
    _saveSession();
  }

  /// Appends already-resolved tracks to the end of the live queue.
  ///
  /// Exists for streaming sources whose URLs can only be resolved one request at
  /// a time — a YouTube playlist starts playing on its first resolved track and
  /// grows behind it, rather than making the user wait for fifty resolves before
  /// hearing anything.
  ///
  /// Appending rather than reloading is the whole point: rebuilding the queue
  /// with [playSongFromList] would restart the track the user is already
  /// listening to. In gapless mode the player's own source list is extended in
  /// step with [songs], which is what keeps `currentIndexStream` aligned with
  /// it; otherwise the list alone is enough, since that path loads each track as
  /// the previous one finishes.
  ///
  /// Gapless loads are not awaited by [playSongFromList], so an append can land
  /// while the player is still being handed the new list — and that load then
  /// replaced the player's sources with a snapshot taken before the append.
  /// The model said twenty-five tracks; the player held one, and a mix played a
  /// single song. Player-side appends therefore wait for any load in flight,
  /// run one at a time, and add whatever the player is missing rather than
  /// assuming it holds everything but [extra].
  @override
  Future<void> appendToQueue(List<SongModel> extra) {
    if (extra.isEmpty) return Future.value();
    // Extend the model first so a currentIndex event that lands mid-append
    // always finds a song at its index.
    _songs.addAll(extra);
    _shuffledSongs.addAll(extra);
    notifyListeners();

    return _queueSync.serial(_syncPlayerQueue);
  }

  /// Player-side queue work, serialised so two appends can't both decide the
  /// same tracks are missing.
  final PlayerQueueSync _queueSync = PlayerQueueSync();

  /// The gapless load most recently started, until it settles.
  Future<void>? _gaplessLoad;

  /// Bumped whenever a new queue replaces the old one, so background fills
  /// (a mix resolving its streams) can tell the queue they were growing is gone.
  int _queueGeneration = 0;
  int get queueGeneration => _queueGeneration;

  /// Brings the gapless player's source list level with [songs].
  Future<void> _syncPlayerQueue() async {
    if (!(_gaplessPlayback && _crossfadeDuration == 0)) return;
    final player = handler.player;
    await PlayerQueueSync.catchUp(
      pendingLoad: _gaplessLoad,
      playerLength: () => player.audioSources.length,
      modelLength: () => songs.length,
      addFrom: (from) async {
        try {
          await player.addAudioSources([
            for (final s in songs.sublist(from)) _gaplessSourceFor(s),
          ]);
        } catch (e) {
          // A queue that won't extend still plays what it already holds.
          debugPrint('Queue append: $e');
        }
      },
    );
  }

  /// The player source for an appended track. Cloud tracks only reach the
  /// queue already resolved to a playable link, so their URI is used as is.
  AudioSource _gaplessSourceFor(SongModel s) {
    // A video's playable location is not its `data` — that is a manifest this
    // app wrote, held by the registry beside the queue.
    if (VideoRegistry.instance.sourceFor(s.id) case final video?) {
      return video.toAudioSource();
    }
    if (YtInnerTube.isStreamUrl(s.data)) return ytAudioSource(s.data);
    if (s.data.startsWith('/')) return AudioSource.file(s.data);
    return AudioSource.uri(Uri.parse(s.data));
  }

  /// Build and load a queue for gapless playback.
  /// Cached cloud tracks play from disk; uncached ones stream with auth headers.
  bool _loadingQueue = false;
  Future<void> loadGaplessQueue(
    int startIndex, {
    Duration? initialPosition,
    bool autoPlay = true,
  }) {
    final load = _loadGaplessQueue(
      startIndex,
      initialPosition: initialPosition,
      autoPlay: autoPlay,
    );
    _gaplessLoad = load;
    load.whenComplete(() {
      if (identical(_gaplessLoad, load)) _gaplessLoad = null;
    }).ignore();
    return load;
  }

  Future<void> _loadGaplessQueue(
    int startIndex, {

    /// Where the track at [startIndex] should resume from.
    ///
    /// Reloading is the only way to change a gapless queue's order, and
    /// reordering must not restart the song the user is listening to — so the
    /// position is carried across explicitly. Null starts from the beginning,
    /// which is what every caller other than a reorder wants.
    Duration? initialPosition,

    /// Whether to start playing once loaded. False preserves a paused player
    /// through a reorder.
    bool autoPlay = true,
  }) async {
    if (songs.isEmpty) return;
    // If already loading, the new call will interrupt the old one in just_audio.
    // That's fine — just_audio handles cancellation gracefully.
    _loadingQueue = true;
    final sources = <AudioSource>[];

    // Get auth headers once (reused for all cloud tracks of same provider)
    Map<String, String>? gdriveHeaders;
    Map<String, String>? dropboxHeaders;

    for (int i = 0; i < songs.length; i++) {
      final s = songs[i];
      // Videos first: a video's `data` is an identity, not something to fetch.
      // The manifest or HLS URL to open lives in the registry.
      if (VideoRegistry.instance.sourceFor(s.id) case final video?) {
        sources.add(video.toAudioSource());
      } else if (s.data.startsWith('http')) {
        // YouTube streams — direct URI with the headers the CDN checks against
        // the client that resolved it. Never cached: the target is single-use
        // and carries its own expiry.
        if (YtInnerTube.isStreamUrl(s.data)) {
          sources.add(ytAudioSource(s.data));
        } else {
          final fileId = s.id.toString();
          if (cloudCache.isCached(fileId)) {
            sources.add(AudioSource.file(cloudCache.cacheFile(fileId).path));
          } else {
            Map<String, String> headers;
            if (s.data.contains('googleapis.com')) {
              gdriveHeaders ??= await cloudAuth.getGoogleAuthHeaders();
              headers = gdriveHeaders;
            } else {
              dropboxHeaders ??= <String, String>{};
              headers = dropboxHeaders;
            }
            sources.add(AudioSource.uri(Uri.parse(s.data), headers: headers));
          }
        }
      } else {
        // Local file paths start with "/", use AudioSource.file to handle spaces/special chars
        if (s.data.startsWith('/')) {
          sources.add(AudioSource.file(s.data));
        } else {
          sources.add(AudioSource.uri(Uri.parse(s.data)));
        }
      }
    }
    try {
      await handler.player.setAudioSources(
        sources,
        initialIndex: startIndex,
        initialPosition: initialPosition,
      );
      await _updateMediaItemForIndex(startIndex);
      if (autoPlay) handler.player.play();
    } catch (e) {
      // "Loading interrupted" — a newer load replaced this one; safe to ignore
      debugPrint('Gapless queue load: $e');
    } finally {
      _loadingQueue = false;
    }
  }

  void _loadSettings() {
    _appMode = AppMode.values[_prefs.getInt("appMode") ?? 0];
    _enableEffects = _prefs.getBool("enableEffects") ?? false;
    _selectedPreset = _prefs.getInt("selectedPreset") ?? 0;
    _isFancy = _prefs.getBool("fancyMode") ?? false;
    _isShuffled = _prefs.getBool("isShuffled") ?? false;
    // Repeat is restored the same way shuffle always has been. Applied to the
    // players rather than merely remembered, or the button would show a mode
    // nothing is obeying. Stored as the enum index, clamped in case a future
    // version removes a mode and an old value outlives it.
    final storedLoop = _prefs.getInt("loopMode") ?? LoopMode.off.index;
    unawaited(
      handler.setLoopMode(
        LoopMode.values[storedLoop.clamp(0, LoopMode.values.length - 1)],
      ),
    );
    // Restore both visualizer surfaces, then tell the native tap once. The
    // player visual used to be the odd one out: its setter never wrote to prefs
    // and nothing read it back, so it silently reset to off on every launch.
    _visualTap.backgroundVisual =
        _prefs.getBool("isVisualInBackground") ?? false;
    _visualTap.playerVisual = _prefs.getBool("playerVisual") ?? false;
    _syncVisualTap();
    _bgQuality = _prefs.getDouble("bgQuality") ?? 2.0;
    _blur = _prefs.getDouble("blur") ?? 40.0;
    _selectedRoomPreset = _prefs.getInt("selectedRoomPreset") ?? 0;
    // MBC compressor
    _dspNoise = _prefs.getDouble("dspNoise") ?? 0.0;
    _expandRatio = _prefs.getDouble("expandRatio") ?? 15.0;
    _preGain = _prefs.getDouble("preGain") ?? 20.0;
    _kneeWidth = _prefs.getDouble("kneeWidth") ?? 0.4;
    // Audio features
    _gaplessPlayback = _prefs.getBool("gaplessPlayback") ?? true;
    _crossfadeDuration = _prefs.getInt("crossfadeDuration") ?? 0;
    _replayGain = _prefs.getBool("replayGain") ?? false;
    _dvcEnabled = _prefs.getBool("dvcEnabled") ?? false;
    _dvcGain = _prefs.getDouble("dvcGain") ?? -30.0;
    _dvcFineSteps = _prefs.getBool("dvcFineSteps") ?? false;
    _globalEqEnabled = _prefs.getBool("globalEqEnabled") ?? false;
    // Song grid extent (migrate from old int scale if needed)
    if (_prefs.containsKey("songGridExtent")) {
      _songGridExtent = (_prefs.getDouble("songGridExtent") ?? 300.0).clamp(
        80.0,
        300.0,
      );
    } else {
      // Migrate from old songGridScale: 0=list→300, 1=2-col→180, 2=3-col→120
      final oldScale = _prefs.getInt("songGridScale") ?? 0;
      _songGridExtent = oldScale == 0
          ? 300.0
          : oldScale == 1
          ? 180.0
          : 120.0;
    }
    // EQ band count
    _eqBandCount = _prefs.getInt("eqBandCount") ?? 32;
    // Preamp & MBC
    _preampGain = _prefs.getDouble("preampGain") ?? 0.0;
    _mbcEnabled = _prefs.getBool("mbcEnabled") ?? false;
    // Speaker correction EQ
    _speakerEqEnabled = _prefs.getBool("speakerEqEnabled") ?? false;
    _activeSpeakerProfile = _prefs.getString("activeSpeakerProfile");
    // 32-band Graphic EQ
    _graphicEqEnabled = _prefs.getBool("graphicEqEnabled") ?? false;
    _activePresetName = _prefs.getString("activePresetName") ?? 'Flat';
    _linkAllDevices = _prefs.getBool("linkAllDevices") ?? true;
    _lastOutputDevice = _prefs.getString("lastOutputDevice") ?? 'speaker';
    final graphicJson = _prefs.getString("graphicBandGains");
    if (graphicJson != null) {
      try {
        _graphicBandGains = (json.decode(graphicJson) as List)
            .map((e) => (e as num).toDouble())
            .toList();
      } catch (_) {}
    }
    final parametricJson = _prefs.getString("parametricPoints");
    if (parametricJson != null) {
      try {
        _parametricPoints = (json.decode(parametricJson) as List)
            .map((e) => ParametricPoint.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }
    final presetsJson = _prefs.getString("eqPresets");
    if (presetsJson != null) {
      try {
        _savedPresets = EqPreset.decodeList(presetsJson);
      } catch (_) {}
    }
    // Visualizer fine-tuning
    _visualizerStyle = _prefs.getString("visualizerStyle") ?? 'circular';
    _visualizerColor = _prefs.getInt("visualizerColor") ?? 0xFFFFFFFF;
    _visualizerFrameRate = _prefs.getInt("visualizerFrameRate") ?? 30;
    _visualizerReactivity = _prefs.getDouble("visualizerReactivity") ?? 0.15;
    _visualizerBeatSensitivity =
        _prefs.getDouble("visualizerBeatSensitivity") ?? 1.0;

    // projectM MilkDrop settings
    _milkdropFps = _prefs.getInt("milkdropFps") ?? 30;
    _milkdropBeatSensitivity =
        _prefs.getDouble("milkdropBeatSensitivity") ?? 1.0;
    _milkdropPresetDuration =
        _prefs.getDouble("milkdropPresetDuration") ?? 30.0;
    _milkdropPresetLocked = _prefs.getBool("milkdropPresetLocked") ?? false;
    _milkdropPresetName = _prefs.getString("milkdropPresetName") ?? '';
    _milkdropQuality = _prefs.getInt("milkdropQuality") ?? 1;
    // Room effects (custom DSP)
    _reverbEnabled = _prefs.getBool("reverbEnabled") ?? false;
    _dspRoomSize = _prefs.getDouble("dspRoomSize") ?? 0.0;
    _dspDecay = _prefs.getDouble("dspDecay") ?? 0.0;
    _dspDamping = _prefs.getDouble("dspDamping") ?? 0.0;
    _dspPreDelay = _prefs.getDouble("dspPreDelay") ?? 0.0;
    _dspDiffusion = _prefs.getDouble("dspDiffusion") ?? 0.0;
    _dspWetDry = _prefs.getDouble("dspWetDry") ?? 0.0;
    _activeRoomPresetName = _prefs.getString("activeRoomPresetName") ?? 'Off';
    _stereoExpandEnabled = _prefs.getBool("stereoExpandEnabled") ?? false;
    _stereoWidth = _prefs.getDouble("dspStereoWidth") ?? 1.0;
    _crossfeedEnabled = _prefs.getBool("crossfeedEnabled") ?? false;
    _crossfeedCutoff = _prefs.getDouble("crossfeedCutoff") ?? 700.0;
    _crossfeedFeed = _prefs.getDouble("crossfeedFeed") ?? 4.5;
    _surround3dEnabled = _prefs.getBool("surround3dEnabled") ?? false;
    _surround3dIntensity = _prefs.getDouble("surround3dIntensity") ?? 0.6;
    _surround3dSubwoofer = _prefs.getDouble("surround3dSubwoofer") ?? 0.35;
    _s3dFrontL = _prefs.getBool("s3dFrontL") ?? true;
    _s3dFrontR = _prefs.getBool("s3dFrontR") ?? true;
    _s3dSideL = _prefs.getBool("s3dSideL") ?? true;
    _s3dSideR = _prefs.getBool("s3dSideR") ?? true;
    _s3dSurroundL = _prefs.getBool("s3dSurroundL") ?? true;
    _s3dSurroundR = _prefs.getBool("s3dSurroundR") ?? true;
    // Tone controls
    _toneEnabled = _prefs.getBool("toneEnabled") ?? false;
    _bassGain = _prefs.getDouble("bassGain") ?? 0.0;
    _bassFreq = _prefs.getDouble("bassFreq") ?? 80.0;
    _bassQ = _prefs.getDouble("bassQ") ?? 0.707;
    _trebleGain = _prefs.getDouble("trebleGain") ?? 0.0;
    _trebleFreq = _prefs.getDouble("trebleFreq") ?? 10000.0;
    _trebleQ = _prefs.getDouble("trebleQ") ?? 0.707;
    // Output limiter
    _limiterEnabled = _prefs.getBool("limiterEnabled") ?? true;
    // Load speaker profiles from asset, then apply DSP params
    loadSpeakerProfiles().then((_) => _applyAllDspParams());
  }

  // ---------------------------------------------------------------------------
  // Play count tracking
  // ---------------------------------------------------------------------------

  void _loadPlayCounts() {
    final raw = _prefs.getString('playCounts');
    if (raw != null) {
      try {
        final decoded = json.decode(raw) as Map<String, dynamic>;
        _playCounts = decoded.map((k, v) => MapEntry(int.parse(k), v as int));
      } catch (_) {
        _playCounts = {};
      }
    }
  }

  // ---- Listening history ----

  /// The track being listened to right now, and when it started.
  ///
  /// Held so the *outgoing* track's event can be written when the next one
  /// begins: how long something played is only known once it stops.
  int? _markedSongId;
  int _markedStartSec = 0;
  int _markedDurationMs = 0;

  /// The most recent position seen on the player.
  ///
  /// Sampled rather than read at flush time because the gapless path notices a
  /// track change only *after* the player has moved on, by which point the
  /// position has already reset to zero — and an outgoing track that reports
  /// zero looks like a track abandoned instantly.
  int _lastPositionMs = 0;
  StreamSubscription<Duration>? _positionSampleSub;

  /// Keeps [_lastPositionMs] current. Assigns an int and nothing else — no
  /// notify, no disk — so this costs the same as the progress bar's own listen.
  void _bindPositionSampling() {
    _positionSampleSub?.cancel();
    _positionSampleSub = handler.player.positionStream.listen(
      (position) => _lastPositionMs = position.inMilliseconds,
      onError: (Object _) {},
    );
  }

  /// Called by every path that makes a different track current.
  ///
  /// There are three — the `songId` setter, the gapless index stream and the
  /// crossfade — and until now only the first incremented the play count. So a
  /// user with gapless or crossfade switched on accumulated almost no history,
  /// and any feature built on that history quietly described somebody else's
  /// listening. Same shape as the radio top-up that was wired to one of three
  /// paths; the fix is the same, one method all three call.
  void _onTrackStarted(int index) {
    if (index < 0 || index >= songs.length) return;
    _flushPlayEvent();
    final song = songs[index];
    _incrementPlayCount(song.id);
    // A streamed song leaves only an id in the play log; remembering what it
    // was is what lets Home build mixes from streaming as well as files.
    final streamed = StreamedTrack.fromSong(
      song,
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    if (streamed != null) {
      unawaited(libraryRepo?.rememberStreamed(streamed) ?? Future<void>.value());
    }
    _markedSongId = song.id;
    _markedDurationMs = song.duration ?? 0;
    _markedStartSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _lastPositionMs = 0;
  }

  /// Writes the outgoing track's listening event, if there is one.
  ///
  /// A track that played almost all the way through counts as completed even if
  /// the last moment was a skip: the difference between finishing something and
  /// leaving in the final seconds is not a difference in taste.
  void _flushPlayEvent() {
    final songId = _markedSongId;
    if (songId == null) return;
    _markedSongId = null;

    // The setter path still has the outgoing track loaded, so the live position
    // is the better answer there; the gapless path has already reset it, so the
    // sample is. Whichever is larger is the one that saw more of the track.
    final live = handler.player.position.inMilliseconds;
    final played = live > _lastPositionMs ? live : _lastPositionMs;
    final completed =
        _markedDurationMs > 0 && played >= _markedDurationMs * 0.95;

    unawaited(
      libraryRepo?.recordPlayEvent(
            songId: songId,
            atSec: _markedStartSec,
            msPlayed: played,
            completed: completed,
          ) ??
          Future<void>.value(),
    );
  }

  Timer? _playCountPersistTimer;

  void _incrementPlayCount(int songId) {
    _playCounts[songId] = (_playCounts[songId] ?? 0) + 1;
    // Mirror into the library DB (fire-and-forget) so discovery surfaces read
    // from the same source of truth as the rest of the library.
    libraryRepo?.incrementPlayCount(
      songId,
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    // Debounce disk persistence. Encoding the whole map + setString used to run
    // synchronously on the UI isolate on EVERY track change (plus a redundant
    // notifyListeners) — a hitch at the exact moment of the transition that
    // worsened as the map grew. The in-memory count is updated immediately;
    // only the write is coalesced (and flushed on background via
    // flushPendingWrites()). No notify here — the songId setter already fires one.
    _playCountPersistTimer?.cancel();
    _playCountPersistTimer = Timer(
      const Duration(seconds: 3),
      _persistPlayCounts,
    );
  }

  void _persistPlayCounts() {
    _playCountPersistTimer?.cancel();
    _playCountPersistTimer = null;
    _prefs.setString(
      'playCounts',
      json.encode(_playCounts.map((k, v) => MapEntry(k.toString(), v))),
    );
  }

  /// Flush any debounced disk writes immediately (call when the app is
  /// backgrounded so nothing is lost if the process is killed).
  void flushPendingWrites() {
    if (_playCountPersistTimer?.isActive ?? false) _persistPlayCounts();
    if (_graphicGainsPersistTimer?.isActive ?? false) commitGraphicGains();
    StreamingDataGuard.instance.flushPendingUsage();
  }

  int getPlayCount(int songId) => _playCounts[songId] ?? 0;

  List<SongModel> getMostPlayed({int limit = 50}) {
    if (_playCounts.isEmpty) return [];
    // Build a set of song IDs that exist in the current library
    final songMap = <int, SongModel>{};
    for (final s in _songs) {
      songMap[s.id] = s;
    }
    // Sort by play count descending
    final sorted =
        _playCounts.entries
            .where((e) => e.value > 0 && songMap.containsKey(e.key))
            .toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(limit).map((e) => songMap[e.key]!).toList();
  }

  List<SongModel> getRecentlyAdded({int limit = 50}) {
    final sorted = List<SongModel>.from(_songs)
      ..sort((a, b) => (b.dateAdded ?? 0).compareTo(a.dateAdded ?? 0));
    return sorted.take(limit).toList();
  }

  bool get isDark {
    return _isDark;
  }

  bool get isShuffled => _isShuffled;

  int get selectedPreset {
    return _selectedPreset;
  }

  bool get playerVisual => _visualTap.playerVisual;
  double get bgQuality => _bgQuality;
  bool get isFancy {
    return _isFancy;
  }

  String get selectedTheme {
    return _selectedTheme;
  }

  bool get isVisualInBackground => _visualTap.backgroundVisual;
  set isVisualInBackground(bool b) {
    _prefs.setBool("isVisualInBackground", b);
    _visualTap.backgroundVisual = b;
    _syncVisualTap();
    notifyListeners();
  }

  /// Starts or stops the native capture to match the surfaces now on screen.
  ///
  /// Safe to call on any state change: [VisualizerTap.pendingPush] swallows
  /// everything that is not a real transition, so nothing reaches the platform
  /// channel unless the tap genuinely has to start or stop.
  void _syncVisualTap() {
    final push = _visualTap.pendingPush();
    if (push != null) Visualizers.enableVisual(push);
  }

  /// Hype Connect: a controller is (or stops) watching the visualiser. Keeps the
  /// native tap running even while the app is backgrounded.
  void setRemoteVisual(bool on) {
    if (_visualTap.remoteVisual == on) return;
    _visualTap.remoteVisual = on;
    _syncVisualTap();
  }

  /// Silences the capture while the app is backgrounded, and restores exactly
  /// what was on screen when it comes back.
  void suspendVisualTap() {
    _visualTap.suspended = true;
    _syncVisualTap();
  }

  void resumeVisualTap() {
    _visualTap.suspended = false;
    _syncVisualTap();
  }

  // Visualizer fine-tuning getters
  String get visualizerStyle => _visualizerStyle;
  int get visualizerColor => _visualizerColor;
  int get visualizerFrameRate => _visualizerFrameRate;
  double get visualizerReactivity => _visualizerReactivity;
  double get visualizerBeatSensitivity => _visualizerBeatSensitivity;

  // Visualizer fine-tuning setters
  set visualizerStyle(String v) {
    _prefs.setString("visualizerStyle", v);
    _visualizerStyle = v;
    notifyListeners();
  }

  set visualizerColor(int c) {
    _prefs.setInt("visualizerColor", c);
    _visualizerColor = c;
    notifyListeners();
  }

  set visualizerFrameRate(int fps) {
    _prefs.setInt("visualizerFrameRate", fps);
    _visualizerFrameRate = fps;
    notifyListeners();
  }

  set visualizerReactivity(double r) {
    _prefs.setDouble("visualizerReactivity", r);
    _visualizerReactivity = r;
    notifyListeners();
  }

  set visualizerBeatSensitivity(double s) {
    _prefs.setDouble("visualizerBeatSensitivity", s);
    _visualizerBeatSensitivity = s;
    notifyListeners();
  }

  // projectM MilkDrop getters/setters
  int get milkdropFps => _milkdropFps;
  set milkdropFps(int v) {
    _prefs.setInt("milkdropFps", v);
    _milkdropFps = v;
    notifyListeners();
  }

  double get milkdropBeatSensitivity => _milkdropBeatSensitivity;
  set milkdropBeatSensitivity(double v) {
    _prefs.setDouble("milkdropBeatSensitivity", v);
    _milkdropBeatSensitivity = v;
    notifyListeners();
  }

  double get milkdropPresetDuration => _milkdropPresetDuration;
  set milkdropPresetDuration(double v) {
    _prefs.setDouble("milkdropPresetDuration", v);
    _milkdropPresetDuration = v;
    notifyListeners();
  }

  bool get milkdropPresetLocked => _milkdropPresetLocked;
  set milkdropPresetLocked(bool v) {
    _prefs.setBool("milkdropPresetLocked", v);
    _milkdropPresetLocked = v;
    notifyListeners();
  }

  String get milkdropPresetName => _milkdropPresetName;
  set milkdropPresetName(String v) {
    _prefs.setString("milkdropPresetName", v);
    _milkdropPresetName = v;
  }

  int get milkdropQuality => _milkdropQuality;
  set milkdropQuality(int v) {
    _prefs.setInt("milkdropQuality", v);
    _milkdropQuality = v;
    notifyListeners();
  }

  int get songId {
    return _songId;
  }

  int get selectedRoomPreset => _selectedRoomPreset;
  set selectedRoomPreset(int x) {
    _prefs.setInt("selectedRoomPreset", x);
    _selectedRoomPreset = x;
    notifyListeners();
  }

  // ==================== Custom DSP Room Effects Getters/Setters ====================

  bool get reverbEnabled => _reverbEnabled;
  set reverbEnabled(bool v) {
    _prefs.setBool("reverbEnabled", v);
    final wasOff = !_reverbEnabled;
    _reverbEnabled = v;
    Channel.dspSetReverbEnabled(v);

    // When turning on for the first time (or from Off), reset to zeros
    // so the user starts with a clean slate before picking a preset.
    if (v && wasOff && _activeRoomPresetName == 'Off') {
      _dspRoomSize = 0.0;
      _dspDecay = 0.0;
      _dspDamping = 0.0;
      _dspPreDelay = 0.0;
      _dspDiffusion = 0.0;
      _dspWetDry = 0.0;
      Channel.dspSetRoomSize(0.0);
      Channel.dspSetDecay(0.0);
      Channel.dspSetDamping(0.0);
      Channel.dspSetPreDelay(0.0);
      Channel.dspSetDiffusion(0.0);
      Channel.dspSetReverbWetDry(0.0);
    }
    notifyListeners();
  }

  double get dspRoomSize => _dspRoomSize;
  set dspRoomSize(double v) {
    _prefs.setDouble("dspRoomSize", v);
    _dspRoomSize = v;
    Channel.dspSetRoomSize(v);
    notifyListeners();
  }

  double get dspDecay => _dspDecay;
  set dspDecay(double v) {
    _prefs.setDouble("dspDecay", v);
    _dspDecay = v;
    Channel.dspSetDecay(v);
    notifyListeners();
  }

  double get dspDamping => _dspDamping;
  set dspDamping(double v) {
    _prefs.setDouble("dspDamping", v);
    _dspDamping = v;
    Channel.dspSetDamping(v);
    notifyListeners();
  }

  double get dspPreDelay => _dspPreDelay;
  set dspPreDelay(double v) {
    _prefs.setDouble("dspPreDelay", v);
    _dspPreDelay = v;
    Channel.dspSetPreDelay(v);
    notifyListeners();
  }

  double get dspDiffusion => _dspDiffusion;
  set dspDiffusion(double v) {
    _prefs.setDouble("dspDiffusion", v);
    _dspDiffusion = v;
    Channel.dspSetDiffusion(v);
    notifyListeners();
  }

  double get dspWetDry => _dspWetDry;
  set dspWetDry(double v) {
    _prefs.setDouble("dspWetDry", v);
    _dspWetDry = v;
    Channel.dspSetReverbWetDry(v);
    notifyListeners();
  }

  String get activeRoomPresetName => _activeRoomPresetName;
  set activeRoomPresetName(String v) {
    _prefs.setString("activeRoomPresetName", v);
    _activeRoomPresetName = v;
    notifyListeners();
  }

  bool get stereoExpandEnabled => _stereoExpandEnabled;
  set stereoExpandEnabled(bool v) {
    _prefs.setBool("stereoExpandEnabled", v);
    _stereoExpandEnabled = v;
    Channel.dspSetStereoExpandEnabled(v);
    if (v && _crossfeedEnabled) {
      // Mutually exclusive — disable crossfeed
      _crossfeedEnabled = false;
      _prefs.setBool("crossfeedEnabled", false);
      Channel.dspSetCrossfeedEnabled(false);
    }
    notifyListeners();
  }

  double get stereoWidth => _stereoWidth;
  set stereoWidth(double v) {
    _prefs.setDouble("dspStereoWidth", v);
    _stereoWidth = v;
    Channel.dspSetStereoWidth(v);
    notifyListeners();
  }

  // ── 3D Surround ───────────────────────────────────────────────────────────

  bool get surround3dEnabled => _surround3dEnabled;
  set surround3dEnabled(bool v) {
    _prefs.setBool("surround3dEnabled", v);
    _surround3dEnabled = v;
    Channel.dspSetSurround3dEnabled(v);
    notifyListeners();
  }

  double get surround3dIntensity => _surround3dIntensity;
  set surround3dIntensity(double v) {
    _prefs.setDouble("surround3dIntensity", v);
    _surround3dIntensity = v;
    Channel.dspSetSurround3dParams(_surround3dIntensity, _surround3dSubwoofer);
    notifyListeners();
  }

  double get surround3dSubwoofer => _surround3dSubwoofer;
  set surround3dSubwoofer(double v) {
    _prefs.setDouble("surround3dSubwoofer", v);
    _surround3dSubwoofer = v;
    Channel.dspSetSurround3dParams(_surround3dIntensity, _surround3dSubwoofer);
    notifyListeners();
  }

  bool get s3dFrontL => _s3dFrontL;
  bool get s3dFrontR => _s3dFrontR;
  bool get s3dSideL => _s3dSideL;
  bool get s3dSideR => _s3dSideR;
  bool get s3dSurroundL => _s3dSurroundL;
  bool get s3dSurroundR => _s3dSurroundR;

  /// Toggle one speaker in the ring, keyed the way the desktop panel keys them.
  void setSurroundSpeaker(String key, bool on) {
    switch (key) {
      case 'frontL':
        _s3dFrontL = on;
      case 'frontR':
        _s3dFrontR = on;
      case 'sideL':
        _s3dSideL = on;
      case 'sideR':
        _s3dSideR = on;
      case 'surroundL':
        _s3dSurroundL = on;
      case 'surroundR':
        _s3dSurroundR = on;
      default:
        return;
    }
    _prefs.setBool('s3d${key[0].toUpperCase()}${key.substring(1)}', on);
    _pushSurroundSpeakers();
    notifyListeners();
  }

  void _pushSurroundSpeakers() {
    Channel.dspSetSurround3dSpeakers(
      frontL: _s3dFrontL,
      frontR: _s3dFrontR,
      sideL: _s3dSideL,
      sideR: _s3dSideR,
      surroundL: _s3dSurroundL,
      surroundR: _s3dSurroundR,
    );
  }

  bool get crossfeedEnabled => _crossfeedEnabled;
  set crossfeedEnabled(bool v) {
    _prefs.setBool("crossfeedEnabled", v);
    _crossfeedEnabled = v;
    Channel.dspSetCrossfeedEnabled(v);
    if (v && _stereoExpandEnabled) {
      // Mutually exclusive — disable stereo expand
      _stereoExpandEnabled = false;
      _prefs.setBool("stereoExpandEnabled", false);
      Channel.dspSetStereoExpandEnabled(false);
    }
    notifyListeners();
  }

  double get crossfeedCutoff => _crossfeedCutoff;
  set crossfeedCutoff(double v) {
    _prefs.setDouble("crossfeedCutoff", v);
    _crossfeedCutoff = v;
    Channel.dspSetCrossfeedParams(_crossfeedCutoff, _crossfeedFeed);
    notifyListeners();
  }

  double get crossfeedFeed => _crossfeedFeed;
  set crossfeedFeed(double v) {
    _prefs.setDouble("crossfeedFeed", v);
    _crossfeedFeed = v;
    Channel.dspSetCrossfeedParams(_crossfeedCutoff, _crossfeedFeed);
    notifyListeners();
  }

  /// Check global EQ availability and restore state if previously enabled.
  Future<void> _initGlobalEq() async {
    _globalEqAvailable = await Channel.isGlobalEqAvailable();
    if (_globalEqAvailable && _globalEqEnabled) {
      Channel.enableGlobalEq(true, preset: _activePresetName);
    }
  }

  /// Applies all DSP params to the native C++ engine on startup.
  void _applyAllDspParams() {
    // Speaker correction EQ (restore profile if was active)
    if (_speakerEqEnabled && _activeSpeakerProfile != null) {
      applySpeakerProfile(_activeSpeakerProfile!);
    }
    // EQ
    Channel.enableEq(_graphicEqEnabled);
    Channel.setPreamp(_preampGain);
    Channel.setGraphicAllBands(_graphicBandGains);
    _applyParametricToNative();
    // MBC
    Channel.enableMbc(_mbcEnabled);
    Channel.setDspNoiseThreshold(_dspNoise);
    Channel.setDspKneeWidth(_kneeWidth);
    Channel.setDspExpandRatio(_expandRatio);
    Channel.setPreGain(_preGain);
    // Room effects
    Channel.dspSetReverbEnabled(_reverbEnabled);
    Channel.dspSetRoomSize(_dspRoomSize);
    Channel.dspSetDecay(_dspDecay);
    Channel.dspSetDamping(_dspDamping);
    Channel.dspSetPreDelay(_dspPreDelay);
    Channel.dspSetDiffusion(_dspDiffusion);
    Channel.dspSetReverbWetDry(_dspWetDry);
    Channel.dspSetStereoExpandEnabled(_stereoExpandEnabled);
    Channel.dspSetStereoWidth(_stereoWidth);
    Channel.dspSetCrossfeedEnabled(_crossfeedEnabled);
    Channel.dspSetCrossfeedParams(_crossfeedCutoff, _crossfeedFeed);
    Channel.dspSetSurround3dEnabled(_surround3dEnabled);
    Channel.dspSetSurround3dParams(_surround3dIntensity, _surround3dSubwoofer);
    _pushSurroundSpeakers();
    // Tone controls
    Channel.dspSetToneEnabled(_toneEnabled);
    Channel.dspSetBassGain(_bassGain);
    Channel.dspSetBassFreq(_bassFreq);
    Channel.dspSetBassQ(_bassQ);
    Channel.dspSetTrebleGain(_trebleGain);
    Channel.dspSetTrebleFreq(_trebleFreq);
    Channel.dspSetTrebleQ(_trebleQ);
    // Output limiter
    Channel.dspSetLimiterEnabled(_limiterEnabled);
  }

  /// Applies a room preset, updating all parameters at once.
  void applyRoomPreset(RoomPreset preset) {
    _dspRoomSize = preset.roomSize;
    _dspDecay = preset.decay;
    _dspDamping = preset.damping;
    _dspPreDelay = preset.preDelay;
    _dspDiffusion = preset.diffusion;
    _dspWetDry = preset.wetDry;
    _activeRoomPresetName = preset.name;
    // Persist all
    _prefs.setDouble("dspRoomSize", _dspRoomSize);
    _prefs.setDouble("dspDecay", _dspDecay);
    _prefs.setDouble("dspDamping", _dspDamping);
    _prefs.setDouble("dspPreDelay", _dspPreDelay);
    _prefs.setDouble("dspDiffusion", _dspDiffusion);
    _prefs.setDouble("dspWetDry", _dspWetDry);
    _prefs.setString("activeRoomPresetName", _activeRoomPresetName);
    // Apply to native DSP
    Channel.dspSetRoomSize(_dspRoomSize);
    Channel.dspSetDecay(_dspDecay);
    Channel.dspSetDamping(_dspDamping);
    Channel.dspSetPreDelay(_dspPreDelay);
    Channel.dspSetDiffusion(_dspDiffusion);
    Channel.dspSetReverbWetDry(_dspWetDry);
    notifyListeners();
  }

  double get opacity => _opacity;
  double get blur => _blur;
  int get artWorkId => _artWorkId;
  List<SongModel> get songs {
    return isShuffled ? _shuffledSongs : _songs;
  }

  List<SongModel> get shuffledSongs => _shuffledSongs;

  OnAudioQuery get audioQuery => _audioQuery;

  // No `isShuffled` setter. Flipping the flag on its own is what the bug was:
  // it changes which list `songs` returns without moving the playing index into
  // that list or telling the player, so the track shown and the track heard
  // come apart. Use [setShuffled], which does all three or none.

  set selectedTheme(String t) {
    _prefs.setString("selectedTheme", t);
    _selectedTheme = t;
    notifyListeners();
  }

  // ========================
  set selectedPreset(int pr) {
    _prefs.setInt("selectedPreset", pr);
    _selectedPreset = pr;
    notifyListeners();
  }

  set playerVisual(bool pV) {
    _prefs.setBool("playerVisual", pV);
    _visualTap.playerVisual = pV;
    _syncVisualTap();
    notifyListeners();
  }

  /// adjusting player's background
  set bgQuality(double q) {
    _prefs.setDouble("bgQuality", q);
    _bgQuality = q;
    notifyListeners();
  }

  set isFancy(bool fancy) {
    _prefs.setBool("fancyMode", fancy);
    _isFancy = fancy;
    notifyListeners();
  }

  set songs(List<SongModel> value) {
    _songs = List.from(value);
    _shuffledSongs = List.from(value);
    notifyListeners();
  }

  set artWorkId(int id) {
    _artWorkId = id;
    notifyListeners();
  }

  set opacity(double op) {
    _opacity = op;
    notifyListeners();
  }

  set blur(double bl) {
    _prefs.setDouble("blur", bl);
    _blur = bl;
    notifyListeners();
  }

  // ---- Resuming where the user left off ----

  /// Where the restored session was paused, until it is actually resumed.
  ///
  /// Non-null means: the queue below came off disk and the player holds nothing.
  /// Loading is deferred to the moment the user presses play, because restoring
  /// a streamed queue costs a network request and reopening an app is not a
  /// request to hear anything.
  Duration? _pendingResume;

  /// Whether the current queue is one restored from the last run and not yet
  /// started. The UI can show the track and its position; the player is empty.
  bool get hasPendingResume => _pendingResume != null;

  /// Whether there is a current track to put in front of the user.
  ///
  /// This is the gate for the bottom player, and it deliberately does NOT ask
  /// whether audio is coming out. The bar is a handle on the current track, not
  /// an indicator that it is sounding — gating it on `playing` took the only
  /// visible transport away at exactly the two moments it is wanted: after a
  /// pause, and on a session restored from disk, which starts paused by design
  /// and so could never be resumed from the UI at all.
  bool get hasNowPlaying {
    final queue = songs;
    return queue.isNotEmpty && _songId >= 0 && _songId < queue.length;
  }

  /// Whether the bottom player should show: a local track, or another device
  /// that this phone is controlling (Hype Connect remote mode).
  bool get hasMiniPlayer =>
      hasNowPlaying ||
      (ConnectPlayRouter.instance?.session.isRemote ?? false);

  /// Remote mode started or ended: redraw the bottom players and the player.
  void refreshRemoteMode() => notifyListeners();

  Timer? _sessionTicker;

  /// Notes the position periodically while something is playing.
  ///
  /// The position is the one part of a session that changes continuously, and
  /// subscribing to `positionStream` would mean a save several times a second.
  /// A slow tick that only fires while playing costs one debounced write every
  /// few seconds and bounds what a sudden kill can lose to roughly that.
  void _startSessionTicker() {
    _sessionTicker?.cancel();
    _sessionTicker = Timer.periodic(const Duration(seconds: 10), (_) {
      if (handler.player.playing) _saveSession();
    });
  }

  /// Records the current queue and position for the next launch.
  ///
  /// Debounced inside the store, so calling this on every track change and once
  /// a few seconds while playing costs one write.
  void _saveSession() {
    if (_songs.isEmpty) return;
    PlaybackSessionStore.instance.save(
      PlaybackSession(
        songs: _songs,
        shuffledOrder: _isShuffled
            ? [for (final s in _shuffledSongs) s.id]
            : null,
        shuffled: _isShuffled,
        index: _songId,
        // While a resume is still pending the player is empty and would report
        // zero, which would overwrite the very position being restored.
        position: _pendingResume ?? handler.player.position,
        loopMode: handler.loopMode.index,
        videoMode: VideoRegistry.instance.videoMode,
      ),
    );
  }

  /// Writes the session immediately. For the app going to the background, which
  /// is the moment most likely to be followed by the process being killed.
  Future<void> flushSession() async {
    // The track playing when the app is backgrounded may never get a "next
    // track" to be flushed by, and a process that is killed never reaches any
    // teardown. This is the last honest moment to record what was heard.
    _flushPlayEvent();
    _saveSession();
    await PlaybackSessionStore.instance.flush();
  }

  /// Reads back the last session, without loading anything into the player.
  ///
  /// Deliberately silent about playback: a restored session is paused. An app
  /// that starts making noise because it was opened is a bad guest.
  Future<void> _restoreSession() async {
    final session = await PlaybackSessionStore.instance.load();
    if (session == null) return;
    // The user was faster than the disk and has already started something.
    // Their choice wins.
    if (_songs.isNotEmpty) return;

    _songs = List<SongModel>.of(session.songs);
    _isShuffled = session.shuffled;
    _shuffledSongs = session.effectiveQueue;
    _songId = session.index.clamp(0, songs.length - 1);
    if (songs.isNotEmpty) _artWorkId = songs[_songId].id;
    _pendingResume = session.position;
    // Set before anything re-resolves, so a queue that was being watched keeps
    // resolving as video from the first track the resume touches.
    VideoRegistry.instance.videoMode = session.videoMode;

    await handler.setLoopMode(
      LoopMode.values[session.loopMode.clamp(0, LoopMode.values.length - 1)],
    );
    await _updateMediaItemForIndex(_songId);
    notifyListeners();
    _loadLyricsForCurrentSong();
  }

  /// Loads the restored queue and starts it from where it stopped.
  ///
  /// Called from [HypeAudioHandler.onBeforePlay], so it runs once, on the first
  /// press of play, whether that press came from the app, the lock screen or a
  /// headset.
  Future<void> _resumePendingSession() async {
    final position = _pendingResume;
    if (position == null) return;
    // Cleared before the first await: two rapid presses of play must not both
    // decide they are the one doing the restoring.
    _pendingResume = null;
    if (songs.isEmpty) return;

    // One request, for the track being resumed. The rest of the queue is
    // refreshed as each becomes current — reopening the app should not cost a
    // resolve per track in a queue the user may skip out of immediately.
    await _refreshTarget(_songId);

    // A queue holding expired links cannot be handed to the player whole: the
    // gapless path loads every source up front and the dead ones fail as they
    // are reached. Such a queue plays one track at a time instead, each
    // refreshed on the way in, until nothing stale is left.
    final anyStale = songs.any((song) => !song.hasFreshTarget);
    if (_gaplessPlayback && _crossfadeDuration == 0 && !anyStale) {
      await loadGaplessQueue(
        _songId,
        initialPosition: position,
        autoPlay: false,
      );
    } else {
      await loadAudioSource(
        handler,
        songs[_songId],
        replayGain: _replayGain,
        initialPosition: position,
        autoPlay: false,
      );
    }
  }

  /// Loads the track at [index], resolving it again first if its link has died.
  ///
  /// Every advance inside this controller goes through here. A YouTube URL is
  /// good for about six hours, which is shorter than a queue's life and much
  /// shorter than a saved session's, so "the URL in the queue still works" is
  /// an assumption that has to be checked rather than made.
  Future<void> loadTrackAt(int index, {Duration? position}) async {
    if (index < 0 || index >= songs.length) return;
    // Skipping is starting something, so there is no longer a paused session
    // waiting to be resumed — and leaving the mark set would save the old
    // track's position against the new one.
    _pendingResume = null;
    // Held across the whole load, not just the resolve: the outgoing track goes
    // on playing — and goes on being near its end — until the new source is
    // actually set, and that is the window the crossfade trigger must sit out.
    _loadingTrack = true;
    try {
      await _refreshTarget(index);
      if (index >= songs.length) return;
      await loadAudioSource(
        handler,
        songs[index],
        replayGain: _replayGain,
        initialPosition: position,
      );
    } finally {
      _loadingTrack = false;
    }
  }

  /// The track currently being rescued, and how many fresh sessions have been
  /// spent on it — so a track that is dead however it is asked for moves on
  /// instead of being resolved for ever.
  ///
  /// Held by song id rather than index: the index of a track changes when the
  /// queue is shuffled or appended to, and this has to name *this* track.
  int? _rescuingSongId;
  int _rescueAttempts = 0;

  /// Answers a player that has refused the current track.
  ///
  /// The common cause is a stream URL that is no longer honoured — expired, or
  /// gated by YouTube after being issued. Both are fixed by asking for another
  /// one, which is why the first response is always to re-resolve rather than
  /// to skip: skipping would silently drop a track that plays perfectly well on
  /// a URL thirty seconds newer.
  ///
  /// Only the second failure of the same track advances the queue. Doing
  /// nothing — which is what this app did before — leaves the player parked on
  /// a track that will never start, and turns the end of every track into the
  /// end of the session.
  Future<void> _recoverFromPlaybackError(Object error) async {
    if (songs.isEmpty) return;
    final index = _songId.clamp(0, songs.length - 1);
    final song = songs[index];
    debugPrint('Playback error on "${song.title}": $error');

    if (_rescuingSongId != song.id) {
      _rescuingSongId = song.id;
      _rescueAttempts = 0;
    }

    switch (recoveryFor(
      isStream: song.ytVideoId != null,
      attempts: _rescueAttempts,
      hasNext: index < songs.length - 1,
    )) {
      case PlaybackRecovery.reResolve:
        _rescueAttempts++;
        // The next failure carries the same error code as this one, and the
        // handler reports only changes — so without this a second dead url
        // would look like an echo of the first and go unanswered.
        handler.clearPlaybackError();
        // A new session, not merely a new request. The url was not refused
        // because it aged — it was minted by a session YouTube decided would
        // need a proof-of-origin token, and every url that session mints will
        // be refused the same way. Asking again on it produces another dead
        // link; drawing a new one is the whole of the fix.
        await YtMusicRepository.instance.resetSession();
        // Everything the burned session minted is dead, not just this track, so
        // the whole queue is marked for re-resolution — otherwise the next
        // track looks fresh, is loaded unasked, and fails identically.
        _staleAllStreamTargets();
        await loadTrackAt(index);
      case PlaybackRecovery.skip:
        // Deliberately not `next()`. That honours the loop mode, and under
        // repeat-one it would seek the very track that just refused to open
        // back to zero and play it again — for ever, at one failed request per
        // pass. "Repeat this track" cannot mean "retry a dead url until the
        // battery is flat"; it is the one setting a broken track overrules.
        songId = index + 1;
        artWorkId = songs[songId].id;
        unawaited(loadTrackAt(songId));
      case PlaybackRecovery.stop:
        // Not a wrap, even under repeat-all: a queue whose tracks have all
        // expired would otherwise walk itself round and round, re-resolving
        // and failing, with nothing audible to say what is happening.
        await handler.player.stop();
    }
  }

  /// Re-resolves the track at [index] when its stream URL has expired.
  ///
  /// A no-op for local files, cloud tracks and anything still fresh — which is
  /// almost everything, almost always.
  Future<void> _refreshTarget(int index) async {
    if (index < 0 || index >= songs.length) return;
    final song = songs[index];
    final videoId = song.ytVideoId;
    // A video needs a staged manifest as well as a live deadline: manifests are
    // swept at every launch, so a fresh deadline is not evidence the file the
    // player would open still exists.
    if (!song.needsRefresh(staged: VideoRegistry.instance.isVideo(song.id))) {
      return;
    }
    if (videoId == null) return;

    try {
      if (song.isYtVideo) {
        // The manifest is gone — they are swept at every launch — so the video
        // is staged again before its entry is handed to the player.
        final target = await YtMusicRepository.instance.videoTarget(videoId);
        await VideoRegistry.instance.adopt(
          songId: song.id,
          videoId: videoId,
          target: target,
        );
        _replaceSong(song.id, song.withTarget(song.data, target.expiresAt));
      } else {
        final target = await YtMusicRepository.instance.audioTarget(videoId);
        _replaceSong(song.id, song.withTarget(target.url, target.expiresAt));
      }
    } catch (e) {
      // A track that will not resolve is one that will not play; the ordinary
      // playback error path takes it from here rather than this becoming a
      // second, competing failure mode.
      debugPrint('Re-resolve failed for $videoId: $e');
    }
  }

  /// Marks every YouTube entry in the queue as needing a new URL.
  ///
  /// The entries have not expired — `expiresAt` is hours away — so nothing else
  /// would ask for them again. But they were minted by a session that has just
  /// been proved gated, which the entry itself has no way to represent. Clearing
  /// the deadline is how that fact is written down: [_refreshTarget] treats the
  /// track as stale and re-resolves it on the way in, one request per track,
  /// which is what the queue fill would have spent anyway.
  void _staleAllStreamTargets() {
    for (final list in [_songs, _shuffledSongs]) {
      for (var i = 0; i < list.length; i++) {
        final song = list[i];
        if (song.ytVideoId == null) continue;
        list[i] = song.withTarget(song.data, null);
      }
    }
  }

  /// Swaps a track for an updated copy of itself in both orderings.
  void _replaceSong(int id, SongModel updated) {
    for (final list in [_songs, _shuffledSongs]) {
      final at = list.indexWhere((song) => song.id == id);
      if (at >= 0) list[at] = updated;
    }
  }

  /// The repeat mode, as the app remembers it.
  ///
  /// Read from here rather than from the player: the player that holds it
  /// changes when a crossfade swaps them, and a UI bound to one player's stream
  /// goes stale at exactly the moment the mode matters.
  LoopMode get loopMode => handler.loopMode;

  /// Sets repeat off / all / one, and remembers it across launches.
  ///
  /// Shuffle has always been persisted; repeat was not, so it silently reset
  /// every launch while its neighbour in the same row did not.
  Future<void> setLoopMode(LoopMode mode) async {
    await handler.setLoopMode(mode);
    unawaited(_prefs.setInt('loopMode', mode.index));
    notifyListeners();
  }

  /// Turns shuffle on or off.
  ///
  /// # One call, because the order of the steps is the bug
  ///
  /// This replaces a flag setter and two methods that callers had to invoke in
  /// the right sequence. They could not: [songs] switches which list it returns
  /// the moment [_isShuffled] changes, so setting the flag first made
  /// unshuffling read the playing track out of the *original* list at a
  /// *shuffled* index — restoring the user to a track they had never chosen.
  /// Reading the playing track once, before anything moves, is the whole fix.
  ///
  /// # The player is reordered too
  ///
  /// Shuffling the app's list alone was a relabelling. ExoPlayer holds its own
  /// copy of the queue in gapless mode and goes on advancing through the order
  /// it was given, so the next track was the unshuffled one and the index it
  /// reported landed in a list that had since been reordered — the track shown
  /// and the track heard drifted apart. The queue is rebuilt so the two agree.
  ///
  /// Playback is not interrupted: the current track keeps its position.
  Future<void> setShuffled(bool value) async {
    if (_isShuffled == value) return;

    // Before anything moves. Everything below depends on this being the track
    // that is actually playing.
    final playing = (_songId >= 0 && _songId < songs.length)
        ? songs[_songId]
        : null;

    _shuffledSongs = value
        ? QueueOrder.shuffle(_songs, playing)
        : List<SongModel>.of(_songs);

    _isShuffled = value;
    unawaited(_prefs.setBool('isShuffled', value));

    _songId = QueueOrder.indexOf(songs, playing);
    if (songs.isNotEmpty) _artWorkId = songs[_songId].id;
    notifyListeners();

    await _reloadQueueOrder();
  }

  /// Rebuilds the player's source list so it plays the order the app is showing.
  ///
  /// Only gapless mode needs this. The other paths load one track at a time
  /// from `songs[songId]`, so they pick up a new order for free on the next
  /// advance; a gapless queue is handed to the player once and has to be handed
  /// over again to change.
  Future<void> _reloadQueueOrder() async {
    if (!(_gaplessPlayback && _crossfadeDuration == 0)) return;
    if (handler.player.audioSources.length <= 1) return;
    // Reordering must not resume a queue the user had paused, nor restart the
    // song they are in the middle of.
    await loadGaplessQueue(
      _songId,
      initialPosition: handler.player.position,
      autoPlay: handler.player.playing,
    );
  }

  set songId(int id) {
    _songId = id;
    _crossfadeFailedIdx = -1; // new track — allow crossfade again
    // Every ordinary track change funnels through here — the skip buttons, a
    // card swipe, a queue tap, a track ending — so this is where an endless
    // station is kept topped up. It used to be asked only from the two
    // branches of the natural-end handler, which meant that skipping by hand,
    // or listening with crossfade on (which advances the index itself and
    // never reaches that handler), grew the queue exactly once and then let a
    // station that was supposed to be endless stop dead.
    unawaited(RadioQueue.instance.onIndexChanged(this, id));
    // Update play count (no notify, debounced write) BEFORE the single
    // notifyListeners, so the track change is one synchronous rebuild pass
    // instead of the previous 2-3 (setter + play-count).
    if (songs.isNotEmpty && id >= 0 && id < songs.length) {
      _onTrackStarted(id);
    }
    _saveSession();
    notifyListeners();
    _loadLyricsForCurrentSong();
  }

  Future<void> _loadLyricsForCurrentSong() async {
    if (songs.isEmpty || _songId < 0 || _songId >= songs.length) return;
    final target = songs[_songId];
    // Skip if already loading for the same song (prevents double-call flicker).
    // Keyed by song id, not queue index: a new queue can reuse the index.
    if (_lyricsLoadTarget == target.id) return;
    _lyricsLoadTarget = target.id;
    _lyricsLoading = true;
    _currentLyrics = null;
    notifyListeners();
    bool stale() =>
        _songId < 0 || _songId >= songs.length || songs[_songId].id != target.id;
    try {
      final result = await _lyricsService.loadLyrics(
        target,
        isCancelled: stale,
      );
      if (stale()) return;
      _currentLyrics = result;
    } catch (_) {
      if (stale()) return;
      _currentLyrics = null;
    }
    _lyricsLoadTarget = null;
    _lyricsLoading = false;
    notifyListeners();
  }

  /// Reloads lyrics for the current song (e.g. after editing/saving).
  Future<void> reloadCurrentLyrics() async {
    if (songs.isEmpty || _songId < 0 || _songId >= songs.length) return;
    _lyricsService.invalidateCache(songs[_songId].id);
    _lyricsLoadTarget = null; // force reload even if same song
    await _loadLyricsForCurrentSong();
  }

  /// Updates any song's in-memory metadata after tag writing.
  /// Mutates SongModel.getMap directly, invalidates artwork cache,
  /// and notifies all listeners so every screen rebuilds with fresh data.
  /// If the song is the currently playing track, also updates the media
  /// notification and reloads lyrics.
  Future<void> updateSongMetadata(
    SongModel song,
    RecognitionResult result, {
    String? newArtworkPath,
  }) async {
    // Mutate the in-memory SongModel fields
    if (result.title != null && result.title!.isNotEmpty) {
      song.getMap['title'] = result.title;
    }
    if (result.artist != null && result.artist!.isNotEmpty) {
      song.getMap['artist'] = result.artist;
    }
    if (result.album != null && result.album!.isNotEmpty) {
      song.getMap['album'] = result.album;
    }

    // New artwork becomes the song's artwork everywhere it shows, at once.
    // For songs that already had artwork, TagWriter skips embedding (fill-empty),
    // but showing the higher-quality Cover Art Archive art is fine.
    //
    // It used to be copied into temp under the file's bare name, which is not
    // the name ArtworkService reads (it replaces spaces), and behind a path the
    // database and memory cache already held — so it rarely showed at all.
    if (newArtworkPath != null && File(newArtworkPath).existsSync()) {
      try {
        await ArtworkService.instance.setChosenArtwork(
          song.id,
          await File(newArtworkPath).readAsBytes(),
        );
      } catch (_) {}
    }

    // Invalidate fingerprint cache for this file
    fingerprintService.invalidateCache(song.data);

    notifyListeners();

    // If this is the currently playing song, also update notification + lyrics
    final isCurrentSong =
        songs.isNotEmpty &&
        _songId >= 0 &&
        _songId < songs.length &&
        songs[_songId].id == song.id;

    if (isCurrentSong) {
      _lyricsService.invalidateCache(song.id);
      _lyricsLoadTarget = null;
      loadAudioSource(_handler, song, replayGain: _replayGain);
      _loadLyricsForCurrentSong();
    }
  }

  void next() {
    if (songs.isEmpty) return;
    final loopMode = handler.loopMode;

    if (loopMode == LoopMode.one) {
      // Repeat-one: restart current track
      handler.player.seek(Duration.zero);
      handler.player.play();
      return;
    }

    if (songId >= songs.length - 1) {
      if (loopMode == LoopMode.all) {
        // Repeat-all: wrap to first song
        songId = 0;
        artWorkId = songs[0].id;
        unawaited(loadTrackAt(0));
      } else {
        // No repeat: stop at end
        songId = 0;
        handler.player.stop();
      }
    } else if (_gaplessPlayback && handler.player.audioSources.length > 1) {
      handler.player.seekToNext();
    } else {
      songId += 1;
      artWorkId = songs[songId].id;
      unawaited(loadTrackAt(songId));
    }
  }

  void prev() {
    if (songs.isEmpty) return;
    final loopMode = handler.loopMode;

    // If more than 3 seconds in, restart current track (standard behavior)
    final position = handler.player.position;
    if (position.inSeconds > 3) {
      handler.player.seek(Duration.zero);
      return;
    }

    if (loopMode == LoopMode.one) {
      handler.player.seek(Duration.zero);
      handler.player.play();
      return;
    }

    if (songId == 0) {
      if (loopMode == LoopMode.all) {
        // Repeat-all: wrap to last song
        songId = songs.length - 1;
        artWorkId = songs[songId].id;
        unawaited(loadTrackAt(songId));
      } else {
        // No repeat: restart first song
        handler.player.seek(Duration.zero);
      }
    } else if (_gaplessPlayback && handler.player.audioSources.length > 1) {
      handler.player.seekToPrevious();
    } else {
      songId -= 1;
      artWorkId = songs[songId].id;
      unawaited(loadTrackAt(songId));
    }
  }

  // --- Cloud services ---

  Future<void> _initCloudServices() async {
    await cloudCache.init();
    await cloudAuth.restoreGoogleSession();
    await cloudAuth.restoreDropboxSession();
    notifyListeners();
    // Kick off background metadata preload from cached file lists.
    _preloadMetadataFromCache();
  }

  /// Start background ID3 extraction for any cached cloud file lists.
  void _preloadMetadataFromCache() {
    if (isGoogleConnected) {
      final files = cloudCache.loadFileList(CloudProvider.googleDrive);
      if (files != null && files.isNotEmpty) {
        cloudMetadata.preloadAll(CloudProvider.googleDrive, files);
      }
    }
    if (isDropboxConnected) {
      final files = cloudCache.loadFileList(CloudProvider.dropbox);
      if (files != null && files.isNotEmpty) {
        cloudMetadata.preloadAll(CloudProvider.dropbox, files);
      }
    }
  }

  /// Trigger metadata preload for a provider's file list (called by CloudView
  /// after an API refresh saves a fresh file list).
  void preloadCloudMetadata(CloudProvider provider, List<CloudFile> files) {
    cloudMetadata.preloadAll(provider, files);
  }

  Future<bool> connectGoogle() async {
    final result = await cloudAuth.signInGoogle();
    notifyListeners();
    return result;
  }

  Future<void> disconnectGoogle() async {
    cloudMetadata.cancel(CloudProvider.googleDrive);
    await cloudAuth.signOutGoogle();
    notifyListeners();
  }

  Future<bool> connectDropbox() async {
    final result = await cloudAuth.signInDropbox();
    notifyListeners();
    return result;
  }

  Future<void> disconnectDropbox() async {
    cloudMetadata.cancel(CloudProvider.dropbox);
    await cloudAuth.signOutDropbox();
    notifyListeners();
  }

  /// Pre-cache the next [count] cloud tracks in the queue.
  void preCacheNextCloudTracks({int count = 2}) {
    for (int i = songId + 1; i <= songId + count && i < songs.length; i++) {
      final song = songs[i];
      if (!song.data.startsWith('http')) continue;
      // A video is megabytes per minute and its manifest expires; pre-fetching
      // one into a cache keyed by song id would spend a phone's data plan on
      // something that has to be re-resolved before it can play anyway.
      if (VideoRegistry.instance.isVideo(song.id)) continue;
      final fileId = song.id.toString();
      if (cloudCache.isCached(fileId)) continue;
      // Fire-and-forget
      _preCacheSingle(song, fileId);
    }
  }

  Future<void> _preCacheSingle(SongModel song, String fileId) async {
    try {
      final headers = song.data.contains('googleapis.com')
          ? await cloudAuth.getGoogleAuthHeaders()
          : <String, String>{};
      await cloudCache.preCacheTrack(song.data, fileId, headers);
    } catch (_) {}
  }
}
