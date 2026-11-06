import '../visualizers/visualizer_styles.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart' show AudioSession;
import 'package:eq_app/global/index.dart';
import 'package:flutter/foundation.dart' show listEquals;

import '/exports/exports.dart';

import '../audio/advanced/advanced_settings.dart';
import '../audio/advanced/fine_volume.dart';
import '../audio/dsp_core.dart';
import '../audio/dvc/dvc_saved_volumes.dart' show dvcOutputChanged;
import '../audio/dvc/dvc_settings.dart';
import '../audio/eq/eq_layout.dart';
import '../audio/eq/eq_presets.dart';
import '../audio/eq/autoeq_suggest.dart';
import '../audio/eq/eq_sync.dart';
import '../audio/eq/equalizer_settings.dart';
import '../audio/focus/audio_focus_settings.dart';
import '../audio/headset/button_presses.dart';
import '../audio/headset/headset_settings.dart';
import '../audio/headset/output_kind.dart';
import '../audio/output/output_profiles.dart';
import '../data/library_repository.dart';
import '../helpers/audio_handler.dart';
import '../player/queue_sync.dart';
import '../data/streamed_track.dart';
import '../Helpers/Channel.dart';
import '../audio/replay_gain/replay_gain.dart';
import '../helpers/index.dart';
import '../models/eq_models.dart';
import '../models/room_preset.dart';
import '../models/stereo_expand.dart';

import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/cloud_file.dart';
import '../services/autoeq_suggestions.dart';
import '../services/cloud_auth_service.dart';
import '../services/connect/remote/connect_ui_host.dart';
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
import '../player/fade_settings.dart';
import '../player/playback_recovery.dart';
import '../player/remote_command_gate.dart';
import '../services/audio_focus_service.dart';
import '../services/volume_feed.dart';
import '../widgets/volume_panel_overlay.dart';
import '../services/headset_service.dart';
import '../services/output_profile_service.dart';
import '../services/media_button_service.dart';
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
import '../navigation/playback_origin.dart';
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

  /// What headset, Bluetooth, notification and lock-screen commands pass
  /// through on their way to the handler; null in a test.
  final RemoteCommandGate? _remote;

  /// Audio focus (calls, other apps, resume on start); null in a test.
  final AudioFocusService? _audioFocus;

  /// Headset plugs, unplugs and Bluetooth connects.
  HeadsetService? _headset;

  /// Headset and Bluetooth media keys (Android only; null elsewhere).
  MediaButtonService? _mediaButtons;

  AudioFocusSettings _audioFocusSettings = const AudioFocusSettings();
  HeadsetSettings _headsetSettings = const HeadsetSettings();

  AudioFocusSettings get audioFocusSettings => _audioFocusSettings;
  set audioFocusSettings(AudioFocusSettings value) {
    _audioFocusSettings = value;
    unawaited(value.save(_prefs));
    notifyListeners();
  }

  AdvancedSettings _advanced = const AdvancedSettings();
  AdvancedSettings get advancedSettings => _advanced;
  set advancedSettings(AdvancedSettings value) {
    _advanced = value;
    unawaited(value.save(_prefs));
    if (value.musicFx) unawaited(refreshMusicFxAvailable());
    _pushVolumeKeys();
    notifyListeners();
  }

  /// Hype's own volume panel (Advanced tweaks → Volume panel).
  final volumePanel = VolumePanelController();
  PauseOnVolume? _pauseOnVolume;
  StreamSubscription<double>? _volumePanelSub;
  StreamSubscription<double>? _fineFeedSub;
  int? _audioSessionId;

  /// Whether an app answers the system audio effects panel (MusicFX).
  bool musicFxAvailable = false;

  /// Whether the MusicFX button shows (Android, switched on, and answered).
  bool get musicFxVisible =>
      Platform.isAndroid && _advanced.musicFx && musicFxAvailable;

  Future<void> refreshMusicFxAvailable() async {
    if (!Platform.isAndroid) return;
    final ok = await Channel.hasMusicFx();
    if (ok == musicFxAvailable) return;
    musicFxAvailable = ok;
    notifyListeners();
  }

  /// Tells Android whether Hype takes the volume keys itself (Volume panel
  /// on; the native side also checks that DVC is off) and in how many steps.
  void _pushVolumeKeys() {
    if (!Platform.isAndroid) return;
    unawaited(
      Channel.setVolumeKeys(
        consume: _advanced.volumePanel,
        levels: _advanced.volumeLevels.levels ?? 0,
        // The system keys keep their meaning while the equalizer applies to
        // all apps (the native side also checks DVC and calls).
        systemWide: systemWideActive,
        fine: _fineModeSent = fineVolumeActive,
      ),
    );
  }

  // ---- Fine volume steps (Volume levels without DVC) ----

  /// Whether Hype takes the volume keys to give exactly the chosen number of
  /// levels: a level other than System default, DVC not running and the
  /// equalizer not system-wide. Android's index does the coarse part and the
  /// engine master gain trims in between.
  bool get fineVolumeActive =>
      Platform.isAndroid &&
      _advanced.volumeLevels.levels != null &&
      !dvcRunning &&
      !systemWideActive;

  bool _fineModeSent = false;
  int? _fineLevel; // null = not synced with the system volume yet
  int? _fineIndex; // the music-stream index Hype believes is set
  int _fineMax = 0;
  double _fineTrimDb = 0;
  final List<int> _fineEchoes = []; // indices Hype set, echo still expected
  final Map<int, double> _fineDbCache = {};
  Future<void> _fineQueue = Future.value();

  @override
  void notifyListeners() {
    super.notifyListeners();
    _refreshFineMode();
  }

  /// Entering or leaving fine mode (levels, DVC and system-wide all feed it):
  /// the native side learns it and any trim is dropped.
  void _refreshFineMode() {
    if (!Platform.isAndroid || fineVolumeActive == _fineModeSent) return;
    _resetFine();
    _pushVolumeKeys();
  }

  /// A volume change Hype did not make, or leaving fine mode: forget the
  /// synced level and let the master return to unity.
  void _resetFine() {
    final hadTrim = _fineTrimDb != 0;
    _fineLevel = null;
    _fineIndex = null;
    _fineTrimDb = 0;
    _fineEchoes.clear();
    if (hadTrim) _pushMasterVolume();
  }

  /// The system volume feed: an index Hype did not set is an outside change.
  void _onSystemVolumeForFine(double fraction) {
    if (_fineLevel == null || _fineMax <= 0) return;
    final index = (fraction * _fineMax).round();
    final echo = _fineEchoes.indexOf(index);
    if (echo >= 0) {
      _fineEchoes.removeRange(0, echo + 1);
      return;
    }
    if (index == _fineIndex) return;
    _resetFine();
  }

  void _enqueueFineStep(bool up) {
    _fineQueue = _fineQueue.then((_) => _fineStep(up)).catchError(
      (Object e) => debugPrint('Fine volume step failed: $e'),
    );
  }

  Future<void> _fineStep(bool up) async {
    final levels = _advanced.volumeLevels.levels;
    if (levels == null || !fineVolumeActive) return;
    if (_fineMax <= 0) _fineMax = await Channel.getSystemMaxVolume();
    final max = _fineMax;
    if (max <= 0) return;
    if (_fineLevel == null) {
      final index = await Channel.getSystemVolume();
      _fineIndex = index;
      _fineLevel = fineLevelFromIndex(index: index, maxIndex: max, levels: levels);
    }
    if (_fineDbCache.isEmpty) {
      for (var i = 1; i <= max; i++) {
        final db = await Channel.getMusicStreamDb(i);
        if (db != null && !db.isNaN) _fineDbCache[i] = db;
      }
    }
    if (!fineVolumeActive) return; // changed while awaiting
    final step = fineVolumeStep(
      level: _fineLevel!,
      levels: levels,
      up: up,
      maxIndex: max,
      dbAt: (i) => _fineDbCache[i] ?? 20 * math.log(i / max) / math.ln10,
    );
    _fineLevel = step.level;
    if (step.systemIndex != _fineIndex) {
      _fineIndex = step.systemIndex;
      _fineEchoes.add(step.systemIndex);
      await Channel.setMusicStreamIndex(step.systemIndex);
    }
    _fineTrimDb = step.trimDb;
    _pushMasterVolume();
    volumePanel.show(step.level / levels);
  }

  Future<bool> openMusicFx() => Channel.openMusicFx(_audioSessionId ?? 0);

  /// Resets the room/reverb settings to the factory default built-in preset
  /// (tweaks rename the active preset to "Custom", so the name cannot be used).
  void restoreReverbPresets() => applyRoomPreset(factoryRoomPreset());

  /// The system volume feed: pause/resume on volume (both platforms) and
  /// Hype's volume panel (Android). Absent in tests and on desktop hosts.
  void _bindVolumeFeed() {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    final feed = VolumeFeed.stream.asBroadcastStream();
    _pauseOnVolume?.dispose();
    _pauseOnVolume = PauseOnVolume(
      volume: feed,
      playingChanges: _handler.playingStream,
      isPlaying: () => _handler.playing,
      enabled: () => _advanced.pauseResumeOnVolume,
      visible: () =>
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed ||
          _handler.playbackState.value.processingState !=
              AudioProcessingState.idle,
      pause: () => _handler.pause(),
      play: () => _handler.play(),
    )..start();
    // Hype's panel shows only for changes its own key handling made (not for
    // DVC raise/restore or a route switch).
    _volumePanelSub?.cancel();
    _volumePanelSub = Platform.isAndroid
        ? VolumeKeysFeed.stream.listen((v) {
            if (_advanced.volumePanel &&
                WidgetsBinding.instance.lifecycleState ==
                    AppLifecycleState.resumed) {
              volumePanel.show(v);
            }
          })
        : null;
    _fineFeedSub?.cancel();
    _fineFeedSub = Platform.isAndroid ? feed.listen(_onSystemVolumeForFine) : null;
    _pushVolumeKeys();
    unawaited(refreshMusicFxAvailable());
    _audioFocus?.configureForceAudio(
      enabled: () => Platform.isAndroid && _advanced.forceAudioOnFocusChange,
      position: () => _handler.player.position,
      seekInPlace: () => _handler.player.seek(_handler.player.position),
      buffering: () {
        final st = _handler.player.processingState;
        return st == ProcessingState.loading || st == ProcessingState.buffering;
      },
    );
  }

  HeadsetSettings get headsetSettings => _headsetSettings;
  set headsetSettings(HeadsetSettings value) {
    _headsetSettings = value;
    _remote?.settings = value;
    unawaited(_mediaButtons?.pushPolicy());
    unawaited(value.save(_prefs));
    notifyListeners();
  }

  /// Whether another Hype Connect device is the active player. Set by
  /// [HypeConnect.attach].
  bool Function()? connectYielded;

  /// Whether Hype Connect is on and has not yet heard from the hub which device
  /// is the active player. Set by [HypeConnect.attach].
  bool Function()? connectAnswerPending;

  /// [connectAnswerPending], false when Hype Connect is not in use.
  bool get connectAnswerIsPending => connectAnswerPending?.call() ?? false;

  /// Whether Hype may start music on its own (resume on start, reopen, wired,
  /// Bluetooth, focus gain): there is a queue to resume, the app is a music
  /// player, and no other Connect device is the one that should be playing.
  ///
  /// With [requireUiSeen] (the default) it is also false in a process whose UI
  /// has never been in the foreground (Hype Connect's background service,
  /// started by a reboot or a car's Bluetooth). The resume after a call or a
  /// loss of focus passes false: its hold exists only because the listener
  /// started the music there.
  bool canResumePlayback({bool requireUiSeen = true}) => mayResumeAutomatically(
    eqMode: isEqMode,
    hasQueue: songs.isNotEmpty,
    otherDeviceActive: connectYielded?.call() ?? false,
    uiSeen: _audioFocus?.uiHasBeenForeground ?? true,
    requireUiSeen: requireUiSeen,
  );
  int _selectedRoomPreset = -1;

  // MBC compressor settings (routed to C++ pipeline)
  double _dspNoise = -10.0;
  double _kneeWidth = 0.40;
  double _expandRatio = 15.0;
  double _preGain = 20;

  // Audio feature settings
  /// Crossfade, fade and gapless behaviour — see `lib/player/fade_settings.dart`.
  FadeSettings _fades = const FadeSettings();
  ReplayGainSettings _replayGain = ReplayGainSettings();
  bool _dvcEnabled = false;
  DvcSettings _dvcSettings = const DvcSettings();

  // What DVC knows about the route: on Bluetooth, and whether the headset's
  // absolute volume is off (null = unknown). See [dvcAllowedOnRoute].
  bool _routeBluetooth = false;
  bool? _btAbsoluteVolumeOff;

  // DVC does not start until the route has been read once, so a start on
  // Bluetooth with absolute volume never raises the system volume.
  bool _routeProbed = false;
  // The output profile's "No DVC", as last applied by [_refreshDvcRoute], so
  // a change of it runs the same safe steps as a route change.
  bool _perOutputNoDvcApplied = false;
  StreamSubscription<dynamic>? _dvcRouteSub;
  Timer? _dvcSettleTimer;
  final Completer<void> _firstOutputResolved = Completer<void>();
  Future<void> _dvcRouteQueue = Future<void>.value();
  double _dvcGain = -30.0; // dB, range -30 to 0 (0% to 100%)

  // App mode
  AppMode _appMode = AppMode.musicPlayer;

  // Global EQ (system-wide)
  bool _globalEqEnabled = false;
  bool _globalEqAvailable = false;
  // False until the first availability probe has answered. The channel can be
  // missing (a headless start has none), which reads as "not available".
  bool _globalEqProbed = false;
  // System-wide mode ended while Hype was in the background: DVC's steps wait
  // for Hype to play or come to the foreground (see [deferDvcResume]).
  bool _dvcResumePending = false;
  List<Map<String, String>> _playingApps = [];

  // Graphic EQ: layout/tone/Auto save settings and the preset list + live
  // curve. `_eq.live` is on `_eq.live.hz`, which is `bandCentres(_eqSettings)`.
  late EqualizerSettings _eqSettings;
  late EqState _eq;
  Timer? _eqPersistTimer;
  bool _graphicEqEnabled = false;
  String _lastOutputDevice = 'speaker';
  bool _linkAllDevices = true;

  // Per-output profiles (EQ preset, bypass, focus, DVC and headroom flags per
  // output kind and named device). See `lib/audio/output/output_profiles.dart`.
  OutputProfiles _outputProfiles = const OutputProfiles();
  OutputProfile _outputEffective = const OutputProfile();
  OutputProfileService? _outputService;
  final List<StreamSubscription<dynamic>> _outputRouteSubs = [];
  EqCurve? _outputAppliedCurve;
  String _outputAppliedName = '';
  static const _kOutputLastRoute = 'outputLastRoute';

  /// Told when the active output's No DVC flag changes, so the DVC gate can
  /// take the route into account at once.
  VoidCallback? onPerOutputNoDvcChanged;

  // Parametric EQ state
  List<ParametricPoint> _parametricPoints = [];

  // Preamp & MBC state
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

  // Stereo Expand: 0..1, 0 = off — see `models/stereo_expand.dart`.
  double _stereoExpand = StereoExpand.initial;

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
  // Frequency and Q live in [_eqSettings].
  bool _toneEnabled = false;
  double _bassGain = 0.0; // 0 to 22.5 dB
  double _trebleGain = 0.0; // 0 to 15 dB

  // Output limiter (on by default)
  /// Headroom, balance, mono, limiter, preamp and tempo (see dsp_core.dart).
  late DspCoreSettings _dspCore;

  // Speaker correction EQ (AutoEq headphone profiles)
  bool _speakerEqEnabled = false;
  String? _activeSpeakerProfile;
  final SpeakerProfileService _speakerProfileService = SpeakerProfileService();

  /// Offers an AutoEq preset when headphones connect (Equalizer settings).
  late final AutoEqSuggestions _autoEq = AutoEqSuggestions(
    enabled: () => _eqSettings.suggestAutoEq,
    systemWide: () => systemWideActive,
    activeProfile: () => _activeSpeakerProfile,
    apply: applySpeakerProfile,
    onApplied: _bindAutoEqToDevice,
    profiles: () async {
      if (_speakerProfileService.profiles.isEmpty) {
        await _speakerProfileService.load();
      }
      return _speakerProfileService.profiles;
    },
    prefs: _prefs,
    navigatorKey: ConnectUiHost.navigatorKey,
  );

  // Live stems (vocals / drums / instruments). The native engine follows the
  // player by itself; this holds the mix, the model download and the
  // one-time speed test. Started at the end of the constructor.
  late final StemsController stemsController = StemsController.app(_prefs);

  // ---------------------------------------------------------------------------
  // Equalizer
  // ---------------------------------------------------------------------------

  EqualizerSettings get eqSettings => _eqSettings;

  /// Saves the settings. A different layout re-interpolates the curve onto the
  /// new centres and sends layout and gains together; changed tone
  /// frequencies and Qs go to the engine.
  set eqSettings(EqualizerSettings value) {
    final old = _eqSettings;
    if (value == old) return;
    _eqSettings = value;
    unawaited(value.save(_prefs));
    final centres = bandCentres(value);
    if (!listEquals(centres, _eq.live.hz)) {
      _setEq(_eq.withLayout(centres), notify: false);
    }
    if (value.bassFreq != old.bassFreq) Channel.dspSetBassFreq(value.bassFreq);
    if (value.bassQ != old.bassQ) Channel.dspSetBassQ(value.bassQ);
    if (value.trebleFreq != old.trebleFreq) {
      Channel.dspSetTrebleFreq(value.trebleFreq);
    }
    if (value.trebleQ != old.trebleQ) Channel.dspSetTrebleQ(value.trebleQ);
    if (value.smoothGains != old.smoothGains) {
      Channel.dspSetSmoothGains(value.smoothGains);
    }
    notifyListeners();
  }

  EqState get eq => _eq;

  /// Band centres of the current layout, in Hz.
  List<double> get eqCentres => _eq.live.hz;

  /// Gain of each band in dB, on [eqCentres].
  List<double> get eqGains => _eq.live.db;

  /// The selected preset's curve has been edited and not saved.
  bool get eqPresetDirty => _eq.dirty;

  /// The selected preset's name, or '' when none is selected (also what the
  /// system-wide EQ notification gets: no name, not "Custom").
  String get activePresetName => _eq.selected;

  /// Makes [next] the equalizer state: sends what the engine needs to hear,
  /// saves it (at once, or after a pause while a drag is going on) and tells
  /// listeners.
  void _setEq(EqState next, {bool persist = true, bool notify = true}) {
    final prev = _eq;
    if (identical(next, prev)) return;
    _eq = next;
    for (final push in eqPushes(prev, next)) {
      _pushEq(push);
    }
    if (next.selected != prev.selected && _globalEqEnabled) {
      Channel.updateGlobalEqPreset(next.selected);
    }
    if (persist) {
      commitEqGains();
    } else {
      // Keyboard/TalkBack value changes fire onChanged WITHOUT
      // onChangeStart/onChangeEnd (flutter/flutter#123315), so a drag-end
      // commit never comes. Debounce a save so those edits aren't lost.
      _eqPersistTimer?.cancel();
      _eqPersistTimer = Timer(const Duration(seconds: 1), commitEqGains);
    }
    if (notify) notifyListeners();
  }

  void _pushEq(EqPush push) {
    switch (push.kind) {
      case EqPushKind.layout:
        Channel.setGraphicLayout(push.values!, push.cutoffs!, push.gains!);
      case EqPushKind.allGains:
        Channel.setGraphicAllBands(push.values!);
      case EqPushKind.bandGain:
        Channel.setGraphicBandGain(push.band!, push.values!.first);
    }
  }

  /// Layout and gains in one call, whatever the engine had.
  void _pushEqLayout() {
    final centres = _eq.live.hz;
    _pushEq(
      EqPush.layout(centres, platformBandCutoffs(centres), _eq.live.db),
    );
  }

  /// Sets one band. While dragging pass `persist: false` (the engine is
  /// updated on every delta, the disk is not) and call [commitEqGains] on
  /// drag end.
  void setEqBandGain(int band, double db, {bool persist = true}) {
    if (band < 0 || band >= _eq.live.db.length) return;
    final gain = db.clamp(-15.0, 15.0).toDouble();
    if (gain == _eq.live.db[band]) return;
    _setEq(
      _eq.withBandGain(band, gain, autoSave: _eqSettings.autoSave),
      persist: persist,
    );
  }

  /// Saves the equalizer state to disk now (call on drag/pan end).
  void commitEqGains() {
    _eqPersistTimer?.cancel();
    _eqPersistTimer = null;
    unawaited(_eq.saveTo(_prefs));
  }

  /// Zeroes the curve and selects Flat.
  void flattenEq() => _setEq(_eq.flatten());

  /// Applies a preset: its curve, and its preamp and parametric points when it
  /// carries them (null means the preset leaves them alone).
  void applyEqPreset(String name) {
    final p = _eq.preset(name);
    if (p == null) return;
    _setEq(_eq.applyPreset(name));
    final preamp = p.preampDb;
    if (preamp != null) dspCore = _dspCore.copyWith(preampDb: preamp);
    final points = p.parametric;
    if (points != null) _restoreParametric(points);
  }

  /// Saves the curve as a new preset (with the preamp and parametric points)
  /// and selects it.
  void saveEqPresetAs(String name) {
    final next = _eq.saveAs(name, preampDb: _dspCore.preampDb);
    _setEq(
      _withParametric(
        next,
        next.selected,
        deviceType: _linkAllDevices ? null : _lastOutputDevice,
      ),
    );
  }

  /// Writes the curve into the selected preset, and the preamp only when that
  /// preset already carries one (a built-in does not gain one).
  void saveEqPreset() {
    final carriesPreamp = _eq.preset(_eq.selected)?.preampDb != null;
    final next = _eq.save(preampDb: carriesPreamp ? _dspCore.preampDb : null);
    final p = next.preset(next.selected);
    // A user preset also stores the current parametric points.
    _setEq(p == null || p.builtIn ? next : _withParametric(next, p.name));
  }

  void deleteEqPreset(String name) => _setEq(_eq.delete(name));

  /// Brings back every factory preset at its factory curve.
  void restoreEqPresets() => _setEq(_eq.restoreFactory());

  /// Android headset and Bluetooth keys: the platform forwards them raw and
  /// [MediaButtonService] recognises the presses and runs the commands through
  /// the remote gate. Beep volume follows DVC, which holds the system volume
  /// at maximum, so the beep stays 20 dB under the music.
  void _startMediaButtons() {
    final remote = _remote;
    if (remote == null || !Platform.isAndroid) return;
    _mediaButtons = MediaButtonService(
      events: Channel.mediaButtonEvents,
      execute: remote.execute,
      settings: () => _headsetSettings,
      playing: () => _handler.playbackState.value.playing,
      playingStream: _handler.playbackState
          .map((s) => s.playing)
          .distinct(),
      feedback: (f, toneVolume) => Channel.buttonFeedback(
        beeps: f.beeps,
        toneVolume: toneVolume,
        vibrate: f.vibrate,
      ),
      toneVolume: () =>
          beepToneVolume(dvcInEffect: dvcRunning, dvcGainDb: _dvcGain),
      pushPolicy: Channel.setButtonPolicy,
    )..start();
  }

  /// Forgets the devices the user said "Don't ask" for.
  Future<void> resetAutoEqSuggestions() => AutoEqDismissals.reset(_prefs);

  @override
  void dispose() {
    _audioFocus?.dispose();
    _pauseOnVolume?.dispose();
    _volumePanelSub?.cancel();
    _fineFeedSub?.cancel();
    volumePanel.dispose();
    _headset?.dispose();
    _outputService?.dispose();
    for (final sub in _outputRouteSubs) {
      unawaited(sub.cancel());
    }
    _mediaButtons?.dispose();
    _globalEqStoppedSub?.cancel();
    _dvcRouteSub?.cancel();
    _dvcSettleTimer?.cancel();
    unawaited(_autoEq.dispose());
    super.dispose();
  }

  /// [s] with the current parametric points stored in preset [name].
  EqState _withParametric(EqState s, String name, {String? deviceType}) =>
      EqState(
        presets: [
          for (final p in s.presets)
            p.name == name
                ? EqPreset(
                    name: p.name,
                    curve: p.curve,
                    preampDb: p.preampDb,
                    parametric: [for (final e in _parametricPoints) e.copyWith()],
                    builtIn: p.builtIn,
                    deviceType: deviceType ?? p.deviceType,
                  )
                : p,
        ],
        selected: s.selected,
        dirty: s.dirty,
        live: s.live,
      );

  void _restoreParametric(List<ParametricPoint> points) {
    _parametricPoints = [for (final e in points) e.copyWith()];
    _applyParametricToNative();
    _persistParametricPoints();
  }

  // Graphic EQ getters/setters
  bool get graphicEqEnabled => _graphicEqEnabled;
  String get lastOutputDevice => _lastOutputDevice;
  bool get linkAllDevices => _linkAllDevices;
  List<ParametricPoint> get parametricPoints => _parametricPoints;
  double get preampGain => _dspCore.preampDb;
  bool get mbcEnabled => _mbcEnabled;

  /// The preamp also belongs to the selected preset when that preset has one:
  /// with Auto save the preset takes the new value, otherwise it reads as
  /// unsaved.
  set preampGain(double value) {
    dspCore = _dspCore.copyWith(preampDb: value);
    _setEq(
      _eq.withPreamp(_dspCore.preampDb, autoSave: _eqSettings.autoSave),
      persist: false,
    );
  }

  // Tone controls getters/setters
  bool get toneEnabled => _toneEnabled;
  double get bassGain => _bassGain;
  double get bassFreq => _eqSettings.bassFreq;
  double get bassQ => _eqSettings.bassQ;
  double get trebleGain => _trebleGain;
  double get trebleFreq => _eqSettings.trebleFreq;
  double get trebleQ => _eqSettings.trebleQ;
  bool get limiterEnabled => _dspCore.limiter;

  DspCoreSettings get dspCore => _dspCore;

  set toneEnabled(bool value) {
    _toneEnabled = value;
    _prefs.setBool("toneEnabled", value);
    Channel.dspSetToneEnabled(value && !_outputEffective.noEqTone);
    notifyListeners();
  }

  set bassGain(double value) {
    _bassGain = EqualizerSettings.normBassGainDb(value);
    _prefs.setDouble("bassGain", _bassGain);
    Channel.dspSetBassGain(_bassGain);
    notifyListeners();
  }

  set bassFreq(double value) =>
      eqSettings = _eqSettings.copyWith(bassFreq: value);

  set bassQ(double value) => eqSettings = _eqSettings.copyWith(bassQ: value);

  set trebleGain(double value) {
    _trebleGain = EqualizerSettings.normTrebleGainDb(value);
    _prefs.setDouble("trebleGain", _trebleGain);
    Channel.dspSetTrebleGain(_trebleGain);
    notifyListeners();
  }

  set trebleFreq(double value) =>
      eqSettings = _eqSettings.copyWith(trebleFreq: value);

  set trebleQ(double value) =>
      eqSettings = _eqSettings.copyWith(trebleQ: value);

  set limiterEnabled(bool value) => dspCore = _dspCore.copyWith(limiter: value);

  /// Saves the core settings and pushes only the values that changed.
  set dspCore(DspCoreSettings value) {
    final old = _dspCore;
    _dspCore = value;
    unawaited(value.save(_prefs));
    if (value.headroomDb != old.headroomDb) _pushHeadroom();
    if (value.balance != old.balance) Channel.dspSetBalance(value.balance);
    if (value.mono != old.mono) Channel.dspSetMono(value.mono);
    if (value.limiter != old.limiter) {
      Channel.dspSetLimiterEnabled(value.limiter);
      // With the limiter off, Replay Gain boosts are peak-capped.
      _regainAll();
    }
    if (value.preampDb != old.preampDb) Channel.setPreamp(value.preampDb);
    if (value.tempoOn != old.tempoOn || value.tempo != old.tempo) {
      _pushTempo();
    }
    notifyListeners();
  }

  /// Headroom is skipped while DVC owns the level (Android only). In
  /// system-wide mode DVC is suspended, so the headroom is the user's again
  /// (the platform equalizer applies it to everything).
  void _pushHeadroom() => Channel.dspSetHeadroomDb(
    headroomFor(
      dvcActive: dvcRunning,
      // The active output's "No headroom gain reduction" skips it.
      headroomDb: _outputEffective.noHeadroomReduction
          ? 0.0
          : _dspCore.headroomDb,
    ),
  );

  void _pushTempo() =>
      unawaited(_handler.setTempo(_dspCore.tempoOn ? _dspCore.tempo : 1.0));

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
    // The profile's own preamp (AutoEq profiles sit well below 0 dB) keeps
    // the corrected response from clipping; the engine adds it to the input
    // gain while the speaker EQ is on. This runs from _applyAllDspParams too.
    await Channel.dspSetSpeakerPreampDb(profile.preamp);
    await Channel.setSpeakerEqEnabled(true);
    notifyListeners();
  }

  Future<void> clearSpeakerProfile() async {
    _activeSpeakerProfile = null;
    _speakerEqEnabled = false;
    _prefs.remove("activeSpeakerProfile");
    _prefs.setBool("speakerEqEnabled", false);
    await Channel.clearSpeakerEq();
    await Channel.dspSetSpeakerPreampDb(0.0);
    await Channel.setSpeakerEqEnabled(false);
    notifyListeners();
  }

  List<SpeakerProfile> searchSpeakerProfiles(String query) {
    return _speakerProfileService.search(query);
  }

  set graphicEqEnabled(bool value) {
    _prefs.setBool("graphicEqEnabled", value);
    _graphicEqEnabled = value;
    Channel.enableEq(value && !_outputEffective.noEqTone);
    notifyListeners();
  }

  set linkAllDevices(bool value) {
    _prefs.setBool("linkAllDevices", value);
    _linkAllDevices = value;
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

  void _persistParametricPoints() {
    _prefs.setString(
      "parametricPoints",
      json.encode(_parametricPoints.map((p) => p.toJson()).toList()),
    );
  }

  /// Notes the output now in use (the legacy `lastOutputDevice`) and has the
  /// output profile service look at the route: the per-device curve of the
  /// old "link all devices" switch is a kind's EQ preset now, applied there.
  Future<void> detectAndApplyDevicePreset() async {
    _lastOutputDevice = await Channel.getAudioOutputType();
    _prefs.setString("lastOutputDevice", _lastOutputDevice);
    await _outputService?.refresh();
    notifyListeners();
  }

  // -- Per-output profiles ---------------------------------------------------

  OutputProfiles get outputProfiles => _outputProfiles;

  /// The output audio is going to now; null before the first reading.
  ActiveRoute? get activeOutputRoute => _outputService?.route;

  /// The profile of the active output.
  OutputProfile get activeOutputProfile => _outputEffective;

  /// The EQ presets an output can be given.
  List<String> get outputPresetNames => _eq.visibleNames;

  /// The active output's flags; read at each audio focus event.
  /// Android only: iOS reports interruptions, not focus changes.
  bool get outputNoDuck => Platform.isAndroid && _outputEffective.noDuck;
  bool get outputIgnoreFocus =>
      Platform.isAndroid && _outputEffective.ignoreFocus;

  /// True on Android while the active output has No DVC; the DVC gate reads
  /// it (DVC stays off on that route, the stored setting is untouched).
  bool get perOutputNoDvc => Platform.isAndroid && _outputEffective.noDvc;

  void setOutputKindProfile(AudioOutputKind kind, OutputProfile p) {
    _outputProfiles = _outputProfiles.withKind(kind, p);
    _commitOutputProfiles();
  }

  /// [p] null: the device follows its kind again.
  void setOutputDeviceProfile(
    String name,
    AudioOutputKind kind,
    OutputProfile? p,
  ) {
    _outputProfiles = _outputProfiles.withDevice(name, kind, p);
    _commitOutputProfiles();
  }

  void forgetOutputDevice(String name) {
    _outputProfiles = _outputProfiles.forgetDevice(name);
    _commitOutputProfiles();
  }

  void _commitOutputProfiles() {
    unawaited(_outputProfiles.save(_prefs));
    notifyListeners();
    unawaited(_outputService?.refresh());
  }

  /// An AutoEq profile applied for a device belongs to that device from now
  /// on (it starts with the kind's settings when the device had none).
  void _bindAutoEqToDevice(String profileName, OutputDeviceEvent device) {
    final own = _outputProfiles.devices[normaliseDeviceName(device.name)]
        ?.profile;
    final base =
        own ?? resolveProfile(_outputProfiles, kind: device.kind);
    setOutputDeviceProfile(
      device.name,
      device.kind,
      base.copyWith(autoEq: profileName),
    );
  }

  void _loadOutputProfiles() {
    final r = loadOutputProfiles(_prefs, [for (final p in _eq.presets) p.name]);
    _outputProfiles = r.profiles;
    if (r.migrated) unawaited(_outputProfiles.save(_prefs));
  }

  void _startOutputProfiles() {
    final c = StreamController<void>.broadcast();
    AudioSession.instance
        .then((s) {
          void ping(Object? _) => c.add(null);
          _outputRouteSubs
            ..add(s.devicesChangedEventStream.listen(ping, onError: (_) {}))
            ..add(s.becomingNoisyEventStream.listen(ping, onError: (_) {}));
        })
        .catchError((Object e) => debugPrint('Output route events: $e'));
    _outputRouteSubs.add(c.stream.listen(null)); // keeps [c] alive to close
    // An output's "No DVC" goes through the DVC route check (safe steps).
    onPerOutputNoDvcChanged ??= () => unawaited(refreshDvcRoute());
    final service = OutputProfileService(
      profiles: () => _outputProfiles,
      readRoute: _readOutputRoute,
      routeEvents: c.stream,
      applyEqPreset: _applyOutputEqPreset,
      curveEdited: _outputCurveEdited,
      applySpeakerProfile: applySpeakerProfile,
      clearSpeakerProfile: clearSpeakerProfile,
      activeSpeakerProfile: () => _activeSpeakerProfile,
      onEffective: _onOutputEffective,
      onRoute: _onOutputRoute,
      beforeRouteChange: _keepLegacyDeviceCurve,
      lastRouteKey: _prefs.getString(_kOutputLastRoute),
    );
    _outputService = service;
    unawaited(
      service.start().catchError(
        (Object e) => debugPrint('Output profiles start failed: $e'),
      ),
    );
  }

  Future<ActiveRoute> _readOutputRoute() async {
    final type = await Channel.getAudioOutputType();
    var outs = <({String name, AudioOutputKind kind})>[];
    try {
      final devices = await (await AudioSession.instance).getDevices(
        includeInputs: false,
      );
      outs = [
        for (final d in devices)
          if (d.isOutput)
            // ignore: experimental_member_use
            (name: d.name, kind: outputKindOf(d.type)),
      ];
    } catch (e) {
      debugPrint('Listing the outputs failed: $e');
    }
    return activeRouteOf(type, outs);
  }

  /// Applies an output's EQ preset. A hidden `_device_` curve (kept by the old
  /// per-device switch) goes in unnamed and unsaved, as it always did, so Auto
  /// save cannot write it into whichever preset was selected.
  void _applyOutputEqPreset(String name) {
    final p = _eq.preset(name);
    if (p == null) return;
    if (name.startsWith('_device_')) {
      _setEq(_eq.withDeviceCurve(p.curve), notify: false);
      final points = p.parametric;
      if (points != null) _restoreParametric(points);
      dspCore = _dspCore.copyWith(preampDb: p.preampDb ?? 0.0);
      _outputAppliedName = '';
    } else {
      applyEqPreset(name);
      _outputAppliedName = name;
    }
    _outputAppliedCurve = _eq.live;
    notifyListeners();
  }

  /// The listener changed the curve (or chose another preset) since the
  /// output's preset was applied.
  bool _outputCurveEdited() {
    final applied = _outputAppliedCurve;
    if (applied == null) return false;
    return _eq.selected != _outputAppliedName || !_eq.live.sameAs(applied);
  }

  /// With "link all devices" off, the curve in use is kept for the output
  /// being left, as a hidden preset that becomes its EQ preset (when it has
  /// none, or already uses one).
  void _keepLegacyDeviceCurve(ActiveRoute? prev, ActiveRoute next) {
    if (prev == null || _linkAllDevices) return;
    final key = '_device_${prev.legacyType}';
    final current = resolveProfile(
      _outputProfiles,
      kind: prev.kind,
      deviceName: prev.deviceName,
    ).eqPreset;
    if (current != null && current != key) return;
    final saved = EqPreset(
      name: key,
      curve: _eq.live,
      preampDb: _dspCore.preampDb,
      parametric: [for (final p in _parametricPoints) p.copyWith()],
      deviceType: prev.legacyType,
    );
    _setEq(
      EqState(
        presets: [
          for (final p in _eq.presets)
            if (p.name != key) p,
          saved,
        ],
        selected: _eq.selected,
        dirty: _eq.dirty,
        live: _eq.live,
      ),
      notify: false,
    );
    if (current == null) {
      final base = _outputProfiles.kinds[prev.kind] ?? const OutputProfile();
      _outputProfiles = _outputProfiles.withKind(
        prev.kind,
        base.copyWith(eqPreset: key),
      );
      unawaited(_outputProfiles.save(_prefs));
    }
  }

  void _onOutputRoute(ActiveRoute route) {
    // A new output has its own volume curve and its own volume.
    _fineDbCache.clear();
    _resetFine();
    unawaited(_prefs.setString(_kOutputLastRoute, route.key));
    final name = route.deviceName;
    if (name != null) {
      final next = _outputProfiles.rememberDevice(name, route.kind);
      if (!identical(next, _outputProfiles)) {
        _outputProfiles = next;
        unawaited(_outputProfiles.save(_prefs));
      }
    }
  }

  void _onOutputEffective(OutputProfile profile, ActiveRoute route) {
    final old = _outputEffective;
    _outputEffective = profile;
    if (!_firstOutputResolved.isCompleted) _firstOutputResolved.complete();
    if (old.noEqTone != profile.noEqTone) {
      // The engine's own enable paths ramp the change.
      Channel.enableEq(_graphicEqEnabled && !profile.noEqTone);
      Channel.dspSetToneEnabled(_toneEnabled && !profile.noEqTone);
    }
    if (old.noHeadroomReduction != profile.noHeadroomReduction) {
      _pushHeadroom();
    }
    if (old.noDvc != profile.noDvc) onPerOutputNoDvcChanged?.call();
    notifyListeners();
  }

  // Audio feature getters
  FadeSettings get fadeSettings => _fades;
  ReplayGainSettings get replayGainSettings => _replayGain;

  /// Whether Replay Gain is applied at all — what the current Settings switch
  /// shows. Setting it picks "apply gain, prevent clipping by peak" per track;
  /// clearing it turns it off.
  bool get replayGain => _replayGain.mode != ReplayGainMode.off;
  bool get dvcEnabled => _dvcEnabled;

  /// True on Android while the equalizer applies to all apps. The engine then
  /// holds its own graphic EQ, tone, preamp, headroom, replay gain, balance,
  /// mono and stereo expand neutral, so the controls that cannot be carried
  /// system-wide are disabled with [kSystemWideReason].
  bool get systemWideActive =>
      Platform.isAndroid &&
      _globalEqEnabled &&
      (!_globalEqProbed || _globalEqAvailable);

  /// Whether Direct Volume Control is actually running: the setting is on and
  /// the equalizer is not applied system-wide. [dvcEnabled] is the stored
  /// setting and is never changed by system-wide mode.
  bool get dvcRunning =>
      !_dvcResumePending &&
      dvcInEffect(
        isAndroid: Platform.isAndroid,
        dvcEnabled: _dvcEnabled,
        systemWide: systemWideActive,
      ) &&
      _dvcRouteAllowed;

  /// Whether the current route lets DVC run (not on Bluetooth with absolute
  /// volume while "No DVC for Bluetooth absolute volume" is on).
  bool get _dvcRouteAllowed =>
      !Platform.isAndroid ||
      (_routeProbed &&
          !_perOutputNoDvcApplied &&
          dvcAllowedOnRoute(
            isAndroid: true,
            dvcEnabled: true,
            onBluetooth: _routeBluetooth,
            btAbsoluteVolumeOff: _btAbsoluteVolumeOff,
            noDvcForBtAbsolute: _dvcSettings.noDvcForBluetoothAbsoluteVolume,
            systemWide: false,
          ));

  DvcSettings get dvcSettings => _dvcSettings;
  set dvcSettings(DvcSettings value) {
    _dvcSettings = value;
    unawaited(value.save(_prefs));
    unawaited(refreshDvcRoute());
    notifyListeners();
  }

  /// Reads the output route and the Bluetooth absolute-volume flag, and, if
  /// that changes whether DVC may run, runs the usual safe steps (disabling
  /// restores the system volume first) without touching [dvcEnabled].
  ///
  /// [routeEvent] is true only for a device/route event: only those can change
  /// the output, which decides release (output changed) or a real disable (same
  /// output, the gate changed) when DVC turns off.
  Future<void> refreshDvcRoute({bool routeEvent = false}) {
    if (!Platform.isAndroid) return Future<void>.value();
    return _dvcRouteQueue = _dvcRouteQueue.then(
      (_) => _refreshDvcRoute(routeEvent),
    );
  }

  /// The device key (type + stable id) at the last route read.
  String? _dvcRouteKey;

  Future<void> _refreshDvcRoute(bool routeEvent) async {
    try {
      // Hold the first probe until the output profile's No DVC is known (a
      // short bound), so DVC is not enabled and released again at launch.
      if (!_firstOutputResolved.isCompleted) {
        await _firstOutputResolved.future
            .timeout(const Duration(milliseconds: 1500), onTimeout: () {});
      }
      final type = await Channel.probeAudioOutputType();
      // A failed read (no platform side, as in a headless start) is not
      // "speaker": leave the route unprobed so DVC stays off.
      if (!dvcRouteReadValid(type)) return;
      final off = await Channel.isBtAbsoluteVolumeDisabled();
      final key = await Channel.probeDvcDeviceKey() ?? type!;
      final outputChanged = dvcOutputChanged(
        previous: _dvcRouteKey,
        next: key,
        routeEvent: routeEvent,
      );
      _dvcRouteKey = key;
      final before = dvcRunning;
      unawaited(Channel.applyPendingDvcRestore());
      _routeBluetooth = type == 'bluetooth';
      _btAbsoluteVolumeOff = off;
      _routeProbed = true;
      _perOutputNoDvcApplied = perOutputNoDvc;
      final after = dvcRunning;
      if (before == after) return;
      final gen = ++_dvcToggleGen;
      unawaited(_runDvcSteps(
        dvcRouteSteps(enable: after, outputChanged: outputChanged),
        gen,
        stillWanted: () => dvcRunning == after,
      ));
      _pushHeadroom();
      notifyListeners();
    } catch (e) {
      debugPrint('DVC route check failed: $e');
    }
  }

  /// Route changes (Bluetooth connecting or leaving) re-evaluate DVC.
  void _bindDvcRoute() {
    if (!Platform.isAndroid) return;
    unawaited(refreshDvcRoute());
    unawaited(() async {
      try {
        final session = await AudioSession.instance;
        _dvcRouteSub = session.devicesChangedEventStream.listen(
          (_) {
            // Let the route settle (as the output profiles do) before reading.
            _dvcSettleTimer?.cancel();
            _dvcSettleTimer = Timer(
              const Duration(milliseconds: 400),
              () => unawaited(refreshDvcRoute(routeEvent: true)),
            );
          },
          onError: (Object e) => debugPrint('DVC route events: $e'),
        );
      } catch (e) {
        debugPrint('DVC route events unavailable: $e');
      }
    }());
  }

  /// The reason shown beside controls system-wide mode disables; null when
  /// they are usable.
  String? get systemWideDisabledReason =>
      systemWideActive ? kSystemWideReason : null;
  double get dvcGain => _dvcGain;
  bool get globalEqEnabled => _globalEqEnabled;
  bool get globalEqAvailable => _globalEqAvailable;
  List<Map<String, String>> get playingApps => List.unmodifiable(_playingApps);

  // Audio feature setters

  /// Replaces the crossfade/fade settings and saves them.
  ///
  /// Some changes move playback onto the other way of loading tracks — a whole
  /// gapless queue on one player, or a track at a time — and what is playing
  /// is moved across at once, at its position, rather than at the next track.
  set fadeSettings(FadeSettings value) {
    if (value == _fades) return;
    final wasQueue = _gaplessQueue;
    _fades = value;
    _handler.fades = value;
    unawaited(value.save(_prefs));
    notifyListeners();
    if (wasQueue != _gaplessQueue) unawaited(_switchLoadingPath());
  }

  /// Whether the queue is handed to the player whole, so tracks join without a
  /// gap. Decided by the fading mode — see [usesGaplessQueue].
  bool get _gaplessQueue => usesGaplessQueue(_fades, shuffled: _isShuffled);

  set replayGain(bool value) {
    if (value == replayGain) return;
    replayGainSettings = value
        ? _replayGain.copyWith(
            mode: ReplayGainMode.applyPreventClipping,
            source: ReplayGainSource.track,
          )
        : _replayGain.copyWith(mode: ReplayGainMode.off);
  }

  /// The settings in force: the saved ones plus the output limiter's state,
  /// which decides whether a boost must be peak-capped.
  ReplayGainSettings get _rgNow =>
      _replayGain.copyWith(limiterOn: _dspCore.limiter);

  /// Re-gains both players for the settings in force (a crossfade in flight
  /// has one on each track).
  void _regainAll() {
    _rgDbCache.clear();
    for (final player in handler.enginePlayers) {
      unawaited(_regainPlayer(player));
    }
  }

  /// Replaces the Replay Gain settings, saves them and re-gains what is
  /// playing now.
  set replayGainSettings(ReplayGainSettings value) {
    if (value == _replayGain) return;
    _replayGain = value;
    unawaited(value.save(_prefs));
    _regainAll();
    notifyListeners();
  }

  /// Gains already worked out, by song path; cleared when the settings change.
  final Map<String, double> _rgDbCache = {};

  /// The Replay Gain for [song] in dB under the current settings.
  Future<double> _replayGainDbFor(SongModel song) async {
    // A video's `data` is an identity, not a file with tags.
    // A cloud track that plays from its cache file has tags to read there.
    final fileId = song.id.toString();
    final path = VideoRegistry.instance.sourceFor(song.id) != null
        ? ''
        : (song.data.startsWith('http') && cloudCache.isCached(fileId))
        ? cloudCache.cacheFile(fileId).path
        : song.data;
    final cached = _rgDbCache[path];
    if (cached != null) return cached;
    final settings = _rgNow;
    final db = await trackGainDbFor(path: path, settings: settings);
    // A settings change while the file was being read makes this stale.
    if (settings == _rgNow) {
      if (_rgDbCache.length > 500) _rgDbCache.clear();
      _rgDbCache[path] = db;
    }
    return db;
  }

  /// Newest Replay Gain request per player; an older one finishing late
  /// must not overwrite it.
  final Map<AudioPlayer, int> _rgRequest = Map.identity();

  /// Gives the player now playing the Replay Gain of the track at [index].
  ///
  /// Used wherever one player changes track without a load of its own: a
  /// gapless queue moving on. A tag read that finishes after something newer —
  /// another request, a load, the queue moving on — is dropped; see
  /// [shouldApplyGain].
  Future<void> _applyReplayGain(int index) async {
    if (index < 0 || index >= songs.length) return;
    final player = handler.player;
    // The index stream replays its last value (and may repeat the outgoing
    // item's): nothing to redo for an index already gained.
    if (_gainedIndex[player] == index) return;
    final song = songs[index];
    final request = _rgRequest[player] = (_rgRequest[player] ?? 0) + 1;
    final seq = handler.engineGainSeqOf(player);
    final db = await _replayGainDbFor(song);
    final isQueue = player.audioSources.length > 1;
    if (!shouldApplyGain(
      requestAtStart: request,
      requestNow: _rgRequest[player] ?? 0,
      gainSeqAtStart: seq,
      gainSeqNow: handler.engineGainSeqOf(player),
      index: index,
      playerIndexNow: isQueue ? player.currentIndex : null,
      songStillMatches:
          identical(handler.player, player) &&
          index < songs.length &&
          songs[index].id == song.id,
    )) {
      return;
    }
    handler.setEngineTrackGainDb(player, db, subject: song);
    _gainedIndex[player] = index;
    unawaited(_sendNextGain(player, index));
  }

  /// Works the Replay Gain out again for what [player] was last gained for —
  /// after a settings change, for each of the two players.
  Future<void> _regainPlayer(AudioPlayer player) async {
    var song = handler.engineGainSubjectOf(player);
    if (song is! SongModel) {
      if (!identical(player, handler.player) ||
          _songId < 0 ||
          _songId >= songs.length) {
        return;
      }
      song = songs[_songId];
    }
    final request = _rgRequest[player] = (_rgRequest[player] ?? 0) + 1;
    final seq = handler.engineGainSeqOf(player);
    final db = await _replayGainDbFor(song);
    if (request != (_rgRequest[player] ?? 0) ||
        seq != handler.engineGainSeqOf(player)) {
      return;
    }
    handler.setEngineTrackGainDb(player, db, subject: song);
    // Setting a current gain clears the native side's pending next gain (on
    // both platforms), so a queue player is told its next item's again.
    final at = player.currentIndex;
    if (at != null) unawaited(_sendNextGain(player, at));
  }

  /// The queue index that plays after [index] on [player] (just_audio's own
  /// `nextIndex` for the current item; the same rule applied to another item
  /// for a seek's target).
  int? _nextQueueIndex(AudioPlayer player, int index) {
    int? next;
    if (index == player.currentIndex) {
      next = player.nextIndex;
    } else if (player.loopMode == LoopMode.one) {
      next = index;
    } else {
      final order = player.effectiveIndices;
      final pos = order.indexOf(index);
      if (pos >= 0) {
        if (pos + 1 < order.length) {
          next = order[pos + 1];
        } else if (player.loopMode == LoopMode.all && order.isNotEmpty) {
          next = order.first;
        }
      }
    }
    return nextGaplessIndex(playerNext: next, length: songs.length);
  }

  /// The URL the platform player is given for the queue entry at [index]: the
  /// uri of its source, however the song is stored (a cached cloud track plays
  /// from a cache file, a video from a manifest). Null for a source with no
  /// plain uri.
  String? _gainUriAt(AudioPlayer player, int index) {
    final sources = player.audioSources;
    if (index < 0 || index >= sources.length) return null;
    var source = sources[index];
    if (source is ClippingAudioSource) source = source.child;
    return source is UriAudioSource ? source.uri.toString() : null;
  }

  final List<StreamSubscription<Object?>> _gainSubs = [];

  /// Keeps the native "next item" gain right across a platform-id rebuild
  /// (stop(), an error to idle) and across a seek, which can land the sink
  /// on the other side of a boundary it has already crossed.
  void _bindGainRecovery() {
    for (final player in handler.enginePlayers) {
      _gainSubs.add(
        player.platformIdStream.listen((id) {
          if (id == null || id.isEmpty) return;
          _gainedIndex.remove(player);
          final at = player.currentIndex;
          if (identical(handler.player, player) &&
              player.audioSources.length > 1 &&
              at != null) {
            unawaited(_sendNextGain(player, at));
          }
        }),
      );
      _gainSubs.add(
        player.positionDiscontinuityStream.listen((d) {
          if (d.reason != PositionDiscontinuityReason.seek) return;
          if (!identical(handler.player, player) ||
              player.audioSources.length <= 1) {
            return;
          }
          final at = player.currentIndex;
          if (at == null) return;
          // The seek event fires inside seek(), before the index moves: a
          // seek to another item still reports the outgoing index here, and
          // the skip path has already gained the target. Only a seek within
          // the item last gained needs re-applying.
          if (_gainedIndex[player] != at) return;
          _gainedIndex.remove(player);
          unawaited(_applyReplayGain(at));
        }),
      );
    }
  }

  /// Newest next-gain request per player; an older tag read must not land last.
  final Map<AudioPlayer, int> _nextGainRequest = Map.identity();

  /// The queue index each player's gain was last worked out for, so the index
  /// stream replaying a value does not re-send it.
  final Map<AudioPlayer, int> _gainedIndex = Map.identity();

  /// Where a skip inside a queue is seeking to, and when it started. Until the
  /// player's index reaches it, index events still naming another item (seek
  /// replays the old index before the platform answers) must not re-gain the
  /// player. Expires so a seek that never lands cannot block re-gains.
  final Map<AudioPlayer, ({int index, DateTime at})> _seekTarget =
      Map.identity();

  /// Whether an index event for [player] should drive its Replay Gain.
  bool _indexEventGains(AudioPlayer player, int index) {
    final t = _seekTarget[player];
    if (t == null) return true;
    if (index == t.index ||
        DateTime.now().difference(t.at) > const Duration(seconds: 3)) {
      _seekTarget.remove(player);
      return true;
    }
    return false;
  }

  /// Tells the native side the gain of the item that plays after [index], so
  /// it is applied at the sample boundary rather than when `currentIndex`
  /// catches up. Gapless queues only. Failures are swallowed: the Dart-side
  /// re-gain on the index change is still there.
  Future<void> _sendNextGain(AudioPlayer player, int index) async {
    if (player.audioSources.length <= 1) return;
    final next = _nextQueueIndex(player, index);
    if (next == null) return;
    final song = songs[next];
    final request = _nextGainRequest[player] =
        (_nextGainRequest[player] ?? 0) + 1;
    try {
      final db = await _replayGainDbFor(song);
      final id = player.playerId;
      if (id.isEmpty || !identical(handler.player, player)) return;
      if (request != (_nextGainRequest[player] ?? 0)) return;
      if (next >= songs.length || songs[next].id != song.id) return;
      final uri = _gainUriAt(player, next);
      if (uri == null) return;
      await Channel.dspSetNextTrackGainDb(id, uri, db);
    } catch (e) {
      debugPrint('dspSetNextTrackGainDb: $e');
    }
  }

  /// Works out the gain of the track after [index] ahead of time, so the next
  /// boundary of a gapless queue needs no tag read.
  void _prefetchReplayGain(int index) {
    if (index < 0 || index + 1 >= songs.length) return;
    _replayGainDbFor(songs[index + 1]).then<void>((_) {}, onError: (_) {});
  }

  set dvcEnabled(bool value) {
    _prefs.setBool("dvcEnabled", value);
    _dvcEnabled = value;
    _dvcResumePending = false;
    if (value) {
      // Never blasts at full volume: until the level is first stored it is
      // silent, and the first enable seeds it from the system volume
      // ([_seedDvcGainIfNew]) before DVC raises that.
      if (!_prefs.containsKey("dvcGain")) _dvcGain = -30.0;
    }
    final gen = ++_dvcToggleGen;
    // Suspended while the equalizer applies to all apps: only the setting
    // changes, and the steps run when system-wide mode ends.
    // A route DVC may not run on (Bluetooth absolute volume) is left alone
    // too: it starts when the route allows.
    if (!systemWideActive && (!value || _dvcRouteAllowed)) {
      unawaited(_runDvcSteps(
        dvcToggleSteps(enable: value),
        gen,
        stillWanted: () =>
            _dvcEnabled == value &&
            !systemWideActive &&
            (!value || _dvcRouteAllowed),
      ));
    }
    _pushHeadroom();
    notifyListeners();
  }

  int _dvcToggleGen = 0;

  /// Runs [steps] in order. A newer toggle (a later [_dvcToggleGen]) or a
  /// [stillWanted] that has turned false supersedes it (e.g. DVC switched off
  /// while the paused-buffer flush was awaited): stop so a stale enable cannot
  /// fire.
  Future<void> _runDvcSteps(
    List<DvcStep> steps,
    int gen, {
    required bool Function() stillWanted,
  }) async {
    // A first enable plays at the level the listener already had: read before
    // DVC raises the system volume, so there is no silent start and no jump.
    if (steps.contains(DvcStep.enableDvc)) await _seedDvcGainIfNew();
    for (final step in steps) {
      if (gen != _dvcToggleGen || !stillWanted()) return;
      switch (step) {
        case DvcStep.pushMasterVolume:
          _pushMasterVolume();
        case DvcStep.flushIfPaused:
          await _flushIfPaused();
        case DvcStep.enableDvc:
          Channel.enableDvc();
        case DvcStep.disableDvc:
          Channel.disableDvc();
        case DvcStep.releaseDvc:
          Channel.disableDvc(release: true);
      }
    }
  }

  Future<void> _seedDvcGainIfNew() async {
    if (_prefs.containsKey("dvcGain") || !Platform.isAndroid) return;
    try {
      final max = await Channel.getSystemMaxVolume();
      final index = await Channel.getSystemVolume();
      final db = await Channel.getMusicStreamDb(index);
      if (_prefs.containsKey("dvcGain")) return;
      _dvcGain = dvcGainFromSystemVolume(index, max, streamDb: db);
      await _prefs.setDouble("dvcGain", _dvcGain);
      notifyListeners();
    } catch (e) {
      debugPrint('Seeding the DVC level failed: $e');
    }
  }

  /// A seek in place empties the AudioTrack's buffered unity-gain audio, so a
  /// paused track does not blast at the raised system volume on resume.
  Future<void> _flushIfPaused() async {
    final p = handler.player;
    if (p.processingState == ProcessingState.idle || p.playing) return;
    try {
      await p.seek(p.position).timeout(const Duration(milliseconds: 500));
    } catch (_) {} // timeout or seek failure: continue the enable
  }

  set dvcGain(double value) {
    _prefs.setDouble("dvcGain", value);
    _dvcGain = value;
    _pushMasterVolume();
    notifyListeners();
  }

  /// DVC level -> every player's engine master volume (0 dB when DVC is off).
  void _pushMasterVolume() {
    if (!Platform.isAndroid) return; // iOS has no DVC; master stays at 0 dB
    Channel.dspSetMasterVolumeDb(
      masterVolumeFor(
        dvcEnabled: dvcRunning,
        dvcGainDb: _dvcGain,
        fineTrimDb: fineVolumeActive ? _fineTrimDb : 0,
      ),
    );
  }


  set globalEqEnabled(bool value) {
    _prefs.setBool("globalEqEnabled", value);
    _globalEqEnabled = value;
    // DVC is suspended while the equalizer applies to all apps and resumes
    // after (the stored setting never changes). Going on, the steps come first
    // so the system volume is back before the platform equalizer starts;
    // going off, the equalizer stops first.
    final dvcSteps = Platform.isAndroid
        ? systemWideDvcSteps(
            systemWideOn: value,
            dvcEnabled: _dvcEnabled && (value || _dvcRouteAllowed),
          )
        : const <DvcStep>[];
    if (value) _globalEqRequestedAt = DateTime.now();
    _dvcResumePending = false;
    final gen = ++_dvcToggleGen;
    void runDvc() => unawaited(_runDvcSteps(
      dvcSteps,
      gen,
      stillWanted: () => _globalEqEnabled == value && _dvcEnabled,
    ));
    if (value) runDvc();
    Channel.enableGlobalEq(value, preset: _eq.selected);
    if (!value) {
      // DVC's enable raises the music stream to max whenever any app plays:
      // from the background (the notification's Stop) that would blast another
      // app, so it waits until Hype plays or is in front.
      if (dvcSteps.isNotEmpty &&
          deferDvcResume(
            appInForeground: _appInForeground,
            hypePlaying: _handler.player.playing,
          )) {
        _dvcResumePending = true;
      } else {
        runDvc();
      }
    }
    // Headroom is the user's again (or DVC's, 0) with the mode change.
    _pushHeadroom();
    _pushVolumeKeys();
    if (value) {
      // Give the service a moment to start and detect sessions
      Future.delayed(const Duration(milliseconds: 800), refreshPlayingApps);
    } else {
      _playingApps = [];
    }
    notifyListeners();
  }

  bool get _appInForeground {
    try {
      return WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    } catch (_) {
      return false; // no binding: a headless isolate
    }
  }

  /// Runs the DVC steps that were held back when system-wide mode ended in the
  /// background. Called when Hype plays and when it comes to the foreground.
  void resumeDvcIfPending() {
    if (!_dvcResumePending) {
      unawaited(_ensureDvcNative());
      return;
    }
    _dvcResumePending = false;
    if (systemWideActive ||
        !_dvcEnabled ||
        !Platform.isAndroid ||
        !_dvcRouteAllowed) {
      return;
    }
    final gen = ++_dvcToggleGen;
    unawaited(_runDvcSteps(
      dvcToggleSteps(enable: true),
      gen,
      stillWanted: () => _dvcEnabled && !systemWideActive && _dvcRouteAllowed,
    ));
    _pushHeadroom();
    notifyListeners();
  }

  /// After a headless start (Hype Connect after a reboot) the DVC start-up ran
  /// with no activity to answer, so the native side never came up. When the
  /// activity attaches (first resume), or Hype plays, bring it up if DVC should
  /// be running and is not.
  Future<void> _ensureDvcNative() async {
    if (!Platform.isAndroid) return;
    // The route must be known before DVC may raise the system volume: after a
    // headless start it was never read (a Bluetooth headset with absolute
    // volume must not be raised to maximum on attach).
    await refreshDvcRoute();
    if (!dvcRunning) return;
    final gen = _dvcToggleGen;
    try {
      if (await Channel.isDvcActive()) return;
    } catch (_) {
      return;
    }
    if (gen != _dvcToggleGen || !dvcRunning) return;
    unawaited(_runDvcSteps(
      dvcToggleSteps(enable: true),
      gen,
      stillWanted: () => dvcRunning,
    ));
    _pushHeadroom();
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
  String _visualizerStyle = 'radial';
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

  StreamSubscription<ProcessingState>? _processingSub;
  StreamSubscription<int?>? _indexSub;
  StreamSubscription<int?>? _sessionIdSub;
  StreamSubscription<String>? _dvcVolumeSub;
  StreamSubscription<bool>? _globalEqStoppedSub;
  DateTime _globalEqRequestedAt = DateTime.fromMillisecondsSinceEpoch(0);

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

  AppController(
    this._prefs,
    this._handler, {
    RemoteCommandGate? remote,
    AudioFocusService? audioFocus,
    // The fields are private, so a named parameter cannot initialise them.
    // ignore: prefer_initializing_formals
  }) : _remote = remote,
       // ignore: prefer_initializing_formals
       _audioFocus = audioFocus {
    _loadSettings();
    _loadPlayCounts();

    // Wire up notification skip controls
    _handler.onSkipToNext = next;
    _handler.onSkipToPrevious = prev;
    _handler.onPlaybackError = _recoverFromPlaybackError;

    // The last session comes back as a queue and a position; the player stays
    // empty until the first press of play, which is what loads it.
    _handler.onBeforePlay = () async {
      resumeDvcIfPending();
      await _resumePendingSession();
    };
    // The ticker only runs while playing, so without this a pause followed by a
    // swipe-kill loses up to its whole interval. The store debounces, so this
    // costs one write.
    _handler.onPaused = _saveSession;
    // What reaches the app from outside is judged by the gate; it asks for the
    // modes the app keeps.
    final remote = _remote;
    if (remote != null) {
      remote.settings = _headsetSettings;
      remote.onRemoteRepeat = (mode) => unawaited(setLoopMode(mode));
      remote.onRemoteShuffle = (on) => unawaited(setShuffled(on));
    }
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

    // Apply DVC state on startup (not while the equalizer applies to all apps)
    // DVC starts once the route is known ([_bindDvcRoute] reads it first and
    // runs the enable steps, master volume before the system raise).
    _bindDvcRoute();

    // Global EQ: check availability and restore state
    _initGlobalEq();

    // Headphone suggestions; a missing audio session just means none.
    unawaited(_autoEq.start().catchError(
      (Object e) => debugPrint('AutoEq start failed: $e'),
    ));

    // After the handler callbacks above: the focus service answers to the
    // handler (its play asks it for focus) and the headset service to the
    // gate's settings.
    _audioFocus?.start();
    _bindVolumeFeed();
    _headset = HeadsetService.forPlatform(
      target: _handler,
      onBluetoothConnected: (nowMs) => _remote?.bluetoothConnectedAtMs = nowMs,
      settings: () => _headsetSettings,
      canResume: () => canResumePlayback(),
      waitingForFocus: () => _audioFocus?.waitingForFocus ?? false,
      onCancelHold: () => _audioFocus?.cancelHold(),
    );
    unawaited(
      _headset!.start().catchError(
        (Object e) => debugPrint('Headset service start failed: $e'),
      ),
    );
    _startOutputProfiles();
    _startMediaButtons();

    _bindDvcVolumeButtons();
    _bindGainRecovery();
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
  /// EQ, MBC, room effects and the DVC master volume live in the C++ engine
  /// and are not session-bound, so nothing here needs re-applying.
  void _bindAudioSessionId() {
    _sessionIdSub?.cancel();
    _sessionIdSub = _handler.player.androidAudioSessionIdStream.listen((
      sessionId,
    ) {
      if (sessionId != null) {
        _audioSessionId = sessionId;
        Channel.setSessionId(sessionId);
      }
    });
  }

  /// Listen to hardware volume button events forwarded by DvcController.
  /// Android-only: iOS has no volume button interception API.
  void _bindDvcVolumeButtons() {
    if (!Platform.isAndroid) return;
    _dvcVolumeSub?.cancel();
    _dvcVolumeSub = Channel.dvcVolumeButtonStream.listen((direction) {
      if (!dvcRunning) {
        // Fine mode: the native side forwards the key instead of stepping.
        if (fineVolumeActive && (direction == "up" || direction == "down")) {
          _enqueueFineStep(direction == "up");
        }
        return;
      }
      final step = _advanced.volumeLevels.dvcStepDb;
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
          // A crossfade owns the end of the track it is fading out of: the next
          // track is already open, or already playing underneath.
          if (handler.crossfadeInFlight) return;
          // Repeat-all wraps instead of stopping. `next()` has always done this
          // for the skip button, but a track ending on its own reached here and
          // stopped — so the setting appeared to work right up until the user put
          // the phone down, which is the only time it matters.
          final repeatAll = handler.loopMode == LoopMode.all;
          if (handler.player.audioSources.length > 1) {
            final idx = handler.player.currentIndex ?? 0;
            if (idx >= songs.length - 1 && !repeatAll) {
              handler.player.stop();
            }
          } else {
            unawaited(_advanceAfterNaturalEnd(repeatAll: repeatAll));
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
        // The outgoing player of a crossfade runs on into its own next entry
        // while it fades; that is not the app changing track.
        if (handler.crossfadeInFlight) return;
        // A queue being installed reports its first entry before the player
        // reaches the start index; `songId` already names the track picked.
        // Taken as a change, that one moment recorded a play of the list's
        // first song, showed it in the notification and saved it.
        if (_loadingQueue) return;
        // A queue shares one player, so its Replay Gain follows the index —
        // whoever moved it.
        if (index != null &&
            handler.player.audioSources.length > 1 &&
            _indexEventGains(handler.player, index)) {
          unawaited(_applyReplayGain(index));
          _prefetchReplayGain(index);
        }
        // Already the current track: whoever made it so — the `songId` setter
        // ahead of a skip, a crossfade's start, a reorder — has done the work
        // below. Re-running it counted the track twice, and the stream replays
        // its last value to every new listener, which is every crossfade.
        if (index == _songId) return;
        if (index != null &&
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
    // The listening history samples the position of the player being heard.
    // Left on the old one, every track after the first swap was recorded as
    // barely played — and now that a skip swaps players, that is every track.
    _bindPositionSampling();
    // After crossfade swap, the new player's tap has reinited the DSP engine
    if (Platform.isIOS) {
      _applyAllDspParams();
    }
    notifyListeners();
  }

  /// Set while a track is being loaded into the player.
  ///
  /// Read by the crossfade trigger, which must not start a fade out of a track
  /// that is in the middle of being replaced — see `crossfade_trigger.dart`.
  bool _loadingTrack = false;

  /// Whether a track change that has been waiting — out its silence between
  /// tracks, on the network, for a crossfade it fell back from — has been
  /// overtaken by a newer one. See `HypeAudioHandler.beginLoad`.
  bool _overtaken(int token) => token != handler.loadToken;

  void _setupCrossfadeListener() {
    _positionSub?.cancel();
    _positionSub = handler.player.positionStream.listen((position) {
      if (_isCrossfading || handler.crossfadeInFlight || _loadingTrack) return;
      if (_songId < 0 || _songId >= songs.length) return;
      final nextIdx = _autoNextIndex();
      if (nextIdx == null || nextIdx == _crossfadeFailedIdx) return;
      final fadeMs = autoCrossfadeMs(
        _fades,
        shuffled: _isShuffled,
        repeatOne: handler.loopMode == LoopMode.one,
        current: _trackRef(songs[_songId]),
        next: _trackRef(songs[nextIdx]),
      );
      final duration = handler.player.duration;
      if (crossfadeFits(duration, fadeMs)) {
        if (shouldPrepareCrossfade(
          fadeMs: fadeMs,
          leadMs: kCrossfadePrepareLeadMs,
          duration: duration,
          position: position,
        )) {
          unawaited(_beginAutoCrossfade(nextIdx, fadeMs));
        }
        return;
      }
      // Not crossfading. Where Hype joins tracks itself — a track at a time —
      // the next one is opened "Preload gapless tracks" early and started the
      // instant this one ends. A queue on one player is preloaded by the
      // player.
      if (handler.player.audioSources.length <= 1 &&
          shouldPrepareHandoff(
            preloadMs: _fades.gaplessPreloadMs,
            duration: duration,
            position: position,
          )) {
        unawaited(_beginAutoCrossfade(nextIdx, 0));
      }
    });
  }

  /// The track a track ending on its own goes on to, or null for none.
  int? _autoNextIndex() {
    if (handler.loopMode == LoopMode.one) return null;
    final next = _songId + 1;
    if (next < songs.length) return next;
    // Repeat-all goes round, and blends going round like anywhere else.
    if (handler.loopMode == LoopMode.all && songs.length > 1) return 0;
    return null;
  }

  static TrackRef _trackRef(SongModel song) =>
      TrackRef(album: song.album, albumId: song.albumId, track: song.track);

  /// Index that failed to crossfade — don't retry it every position tick;
  /// the normal end-of-track advance handles it instead. Cleared on track change.
  int _crossfadeFailedIdx = -1;

  /// Held from the moment an end-of-track crossfade is decided on until it
  /// settles, so the position listener — which fires several times a second —
  /// starts it once.
  bool _isCrossfading = false;

  /// Crossfades out of a track that is ending on its own into [nextIdx] — or,
  /// with [fadeMs] zero, hands over to it the instant this one ends (after the
  /// silence between tracks, if set).
  ///
  /// The next track is opened early on the spare player —
  /// [kCrossfadePrepareLeadMs] before a crossfade, "Preload gapless tracks"
  /// before a handoff — and started exactly when it is due. Nothing about the current track changes until
  /// then: the queue, the notification and the screen all move when the new
  /// track becomes audible, not when it starts loading.
  ///
  /// A queue the player holds whole is taken over whole: the spare player gets
  /// the same queue positioned at the next track, so the boundaries after this
  /// one stay gapless.
  Future<void> _beginAutoCrossfade(int nextIdx, int fadeMs) async {
    if (_isCrossfading) return;
    _isCrossfading = true;
    final outgoing = handler.player;
    final duration = outgoing.duration;
    final nextSong = songs[nextIdx];
    final inQueue = outgoing.audioSources.length > 1;
    // Anything loaded while this one was still being prepared — a skip during
    // the network fetch — has replaced the track it was meant to end. So has a
    // queue player that moved on to the next entry by itself while the spare
    // one was still being given the queue.
    final token = handler.loadToken;
    final startIndex = outgoing.currentIndex;
    final startSongId = _songId;
    bool stale() =>
        _overtaken(token) ||
        !identical(handler.player, outgoing) ||
        outgoing.currentIndex != startIndex ||
        _songId != startSongId;
    Future<void>? queueLoad;

    try {
      if (duration == null) return;
      final handoff = fadeMs <= 0;

      final Future<void> Function(AudioPlayer) load;
      final FutureOr<MediaItem?> Function() item;
      if (inQueue) {
        final sources = await _queueSources();
        final queueDb = await _replayGainDbFor(nextSong);
        load = (p) {
          handler.setEngineTrackGainDb(p, queueDb, subject: nextSong);
          _gainedIndex.remove(p);
          return p.setAudioSources(sources, initialIndex: nextIdx);
        };
        item = () => _mediaItemFor(nextSong);
      } else {
        // An expired stream link is renewed on the way in, as every other
        // advance does; a crossfade used to skip it and fade into silence.
        await _refreshTarget(nextIdx);
        final song = _songAt(nextIdx, nextSong.id);
        if (song == null) return;
        final prepared = await prepareTrack(song, replayGain: _rgNow);
        if (prepared == null) {
          _crossfadeFailedIdx = nextIdx;
          return;
        }
        load = (p) {
          handler.setEngineTrackGainDb(p, prepared.rgDb, subject: song);
          return p.setAudioSource(prepared.source);
        };
        item = () => prepared.item;
      }

      if (stale()) return;
      final fade = handler.crossfade(
        load: load,
        fadeMs: fadeMs,
        mediaItem: item,
        startAt: handoff ? null : duration - Duration(milliseconds: fadeMs),
        startAtEnd: handoff,
        gapAfterEnd: handoff
            ? Duration(milliseconds: _fades.silenceMs)
            : Duration.zero,
        token: token,
        // A track ending on its own gives way to a change already in flight.
        replace: false,
        onStart: () {
          if (_overtaken(token)) return;
          // Found again by identity: an append while the track was opening is
          // fine, and anything that reorders the queue aborts the crossfade.
          final at = _songAt(nextIdx, nextSong.id) != null
              ? nextIdx
              : songs.indexWhere((s) => s.id == nextSong.id);
          if (at < 0) return;
          // Deliberately not through the `songId` setter, so it is repeated
          // here: the play count and history (see [_onTrackStarted]), the radio
          // top-up — without which a station played with crossfade on never
          // grows past its first page — lyrics and the saved session.
          _songId = at;
          _artWorkId = nextSong.id;
          _crossfadeFailedIdx = -1;
          _onTrackStarted(at);
          unawaited(RadioQueue.instance.onIndexChanged(this, at));
          _saveSession();
          _loadLyricsForCurrentSong();
          notifyListeners();
        },
      );
      if (inQueue) {
        queueLoad = fade;
        _trackQueueLoad(fade);
      }
      await fade;
    } catch (e) {
      // Crossfade failed (dead cloud URL, auth error, ...) before the new track
      // started, so nothing has moved. Latch the failed index so the position
      // listener doesn't hammer the dead URL every tick — the normal
      // end-of-track advance takes over instead.
      debugPrint('Crossfade into "${nextSong.title}" failed: $e');
      _crossfadeFailedIdx = nextIdx;
      notifyListeners();
      // The end of the track arrived while this was in flight and was left to
      // it; with it failed, nothing else is going to move the queue on.
      if (!_overtaken(token) &&
          identical(handler.player, outgoing) &&
          outgoing.processingState == ProcessingState.completed) {
        unawaited(
          _advanceAfterNaturalEnd(repeatAll: handler.loopMode == LoopMode.all),
        );
      }
    } finally {
      _isCrossfading = false;
      if (queueLoad != null && identical(_gaplessLoad, queueLoad)) {
        _gaplessLoad = null;
      }
    }
  }

  /// The song at [index] if it is still the one with [id].
  SongModel? _songAt(int index, int id) =>
      index >= 0 && index < songs.length && songs[index].id == id
      ? songs[index]
      : null;

  /// Crossfades from what is playing into the queue at [index], played on the
  /// spare player — how a skip sounds while the whole queue is on one player.
  ///
  /// The new player gets the whole queue, positioned at [index], so playback
  /// carries on gaplessly from there. Falls back to a cut if the crossfade
  /// cannot start and nothing else has been asked for in the meantime.
  Future<void> _crossfadeQueueTo(
    int index,
    ChangeFade fade, {
    Duration? initialPosition,
  }) {
    final token = handler.beginLoad();
    final song = songs[index];
    final load = () async {
      await handler.abortCrossfade();
      final sources = await _queueSources();
      final rgDb = await _replayGainDbFor(song);
      if (_overtaken(token)) return;
      await handler.crossfade(
        load: (p) {
          handler.setEngineTrackGainDb(p, rgDb, subject: song);
          _gainedIndex.remove(p);
          return p.setAudioSources(
            sources,
            initialIndex: index,
            initialPosition: initialPosition,
          );
        },
        fadeMs: fade.crossfadeMs,
        earlyFadeOutMs: fade.earlyFadeOutMs,
        mediaItem: () => _mediaItemFor(song),
        token: token,
      );
    }();
    _trackQueueLoad(load);
    return load.catchError((Object e) async {
      debugPrint('Queue crossfade: $e');
      if (_overtaken(token)) return;
      await loadGaplessQueue(
        index,
        initialPosition: initialPosition,
        fade: fade,
      );
    });
  }

  /// Marks [load] as the queue load in flight, for appends to wait on.
  void _trackQueueLoad(Future<void> load) {
    _gaplessLoad = load;
    load.whenComplete(() {
      if (identical(_gaplessLoad, load)) _gaplessLoad = null;
    }).ignore();
  }

  /// Moves on after a track that ended on its own, a track at a time.
  ///
  /// With silence between tracks set, the next track is opened at once — the
  /// screen moves to it — and started once the silence has passed.
  Future<void> _advanceAfterNaturalEnd({required bool repeatAll}) async {
    final int next;
    if (_songId >= songs.length - 1) {
      if (!repeatAll || songs.isEmpty) {
        await handler.player.stop();
        return;
      }
      next = 0;
    } else {
      next = _songId + 1;
    }
    // Through the `songId` setter, which tops the radio up for every path at
    // once.
    songId = next;
    artWorkId = songs[next].id;
    final silence = _fades.silenceMs;
    if (silence <= 0) {
      await loadTrackAt(next);
      return;
    }
    final watch = Stopwatch()..start();
    await loadTrackAt(next, autoPlay: false);
    final token = handler.loadToken;
    final remaining = Duration(milliseconds: silence) - watch.elapsed;
    if (remaining > Duration.zero) await Future<void>.delayed(remaining);
    if (_overtaken(token) || _songId != next) return;
    if (!handler.player.playing) handler.startPlayback();
  }

  /// The notification's description of [song].
  Future<MediaItem> _mediaItemFor(SongModel song) async {
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
    return MediaItem(
      id: song.data,
      album: song.album,
      title: song.title,
      artist: song.artist,
      duration: Duration(milliseconds: song.duration ?? 0),
      artUri: artUri,
    );
  }

  Future<void> _updateMediaItemForIndex(int index) async {
    if (index >= songs.length) return;
    handler.setCurrentMediaItem(await _mediaItemFor(songs[index]));
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
      here: () =>
          playSongFromList(songList, index, initialPosition: initialPosition),
    );
    if (routed != null) return routed;
    // The user picked something rather than resuming. Whatever was waiting from
    // the last session is no longer what is about to play.
    _pendingResume = null;
    _queueGeneration++;
    // One origin per queue: the list action that started this one records its
    // own once the queue is running, so none carries over from the last.
    _playbackOrigin = originForInstall(
      _playbackOrigin,
      oldIds: _songs.map((s) => s.id),
      newIds: songList.map((s) => s.id),
    );
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
    // A tap on a song is a track change the listener asked for, so it sounds
    // like one — see [FadeSettings.manualChangeFade].
    final fade = _fades.manualChangeFade(
      incomingDurationMs: songList[index].duration,
    );
    if (_gaplessQueue) {
      if (fade.crossfadeMs > 0 && handler.isAudible) {
        return _crossfadeQueueTo(
          startIndex,
          fade,
          initialPosition: initialPosition,
        );
      }
      return loadGaplessQueue(
        startIndex,
        initialPosition: initialPosition,
        fade: fade,
      );
    }
    return loadAudioSource(
      handler,
      songList[index],
      replayGain: _rgNow,
      initialPosition: initialPosition,
      fade: fade,
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
    if (handler.player.audioSources.length > 1) {
      await loadGaplessQueue(
        0,
        initialPosition: handler.player.position,
        autoPlay: handler.player.playing,
        fade: ChangeFade.cut,
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
    if (!_gaplessQueue) return;
    await PlayerQueueSync.catchUp(
      pendingLoad: _gaplessLoad,
      // Read after the pending load, never captured before it: a load can be a
      // crossfade, which ends with the *other* player holding the queue.
      playerLength: () => handler.player.audioSources.length,
      modelLength: () => songs.length,
      addFrom: (from) async {
        try {
          await handler.player.addAudioSources([
            for (final s in songs.sublist(from)) _gaplessSourceFor(s),
          ]);
          // The last item's "next" may now exist.
          final at = handler.player.currentIndex;
          if (at != null) unawaited(_sendNextGain(handler.player, at));
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

    /// How the change sounds; null for one that should not be heard as a
    /// change at all. Never a crossfade — that is [_crossfadeQueueTo].
    ChangeFade? fade,
  }) {
    final load = _loadGaplessQueue(
      startIndex,
      token: handler.beginLoad(),
      initialPosition: initialPosition,
      autoPlay: autoPlay,
      fade: fade,
    );
    _trackQueueLoad(load);
    return load;
  }

  Future<void> _loadGaplessQueue(
    int startIndex, {
    required int token,

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
    ChangeFade? fade,
  }) async {
    if (songs.isEmpty) return;
    // A crossfade in flight belongs to the queue being replaced.
    await handler.abortCrossfade();
    // Out of something playing, declicked — see [loadAudioSource].
    final wasAudible = fade != null && handler.isAudible;
    if (wasAudible) await handler.declickOut();
    // If already loading, the new call will interrupt the old one in just_audio.
    // That's fine — just_audio handles cancellation gracefully.
    _loadingQueue = true;
    final sources = await _queueSources();
    // The starting track's Replay Gain, worked out before the overtaken check
    // so a newer load arriving during the tag read is caught by it. A start
    // index outside the queue gets the untagged preamp rather than failing the
    // whole load.
    final startSong = startIndex >= 0 && startIndex < songs.length
        ? songs[startIndex]
        : null;
    final startDb = startSong != null
        ? await _replayGainDbFor(startSong)
        : await trackGainDbFor(path: '', settings: _rgNow);
    if (_overtaken(token)) {
      _loadingQueue = false;
      return;
    }
    // A player that finished its track still reports `playing`, and would
    // start whatever it is given at once.
    if (!autoPlay && handler.player.playing) await handler.player.pause();
    try {
      // Ahead of its source; later tracks are gained as the index moves — see
      // [_bindCurrentIndex].
      handler.setEngineTrackGainDb(handler.player, startDb, subject: startSong);
      await handler.player.setAudioSources(
        sources,
        initialIndex: startIndex,
        initialPosition: initialPosition,
      );
      // The item after the first one, gained at the boundary into it.
      _gainedIndex[handler.player] = startIndex;
      unawaited(_sendNextGain(handler.player, startIndex));
      // Player volume stays at unity — and says so, rather than inheriting
      // whatever the last video or crossfade left on this player.
      handler.setTrackGain(handler.player, 1.0);
      await _updateMediaItemForIndex(startIndex);
      if (autoPlay) {
        handler.startPlayback(
          fadeInMs: fade == null
              ? 0
              : wasAudible
              ? kDeclickMs
              : fade.fromSilenceMs,
        );
      } else {
        handler.resetLevels(handler.player);
      }
    } catch (e) {
      // "Loading interrupted" — a newer load replaced this one; safe to ignore
      debugPrint('Gapless queue load: $e');
    } finally {
      _loadingQueue = false;
    }
  }

  /// The player sources for the whole queue, in [songs] order.
  /// Cached cloud tracks play from disk; uncached ones stream with auth headers.
  Future<List<AudioSource>> _queueSources() async {
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
    return sources;
  }

  void _loadSettings() {
    // First: it inspects which prefs earlier versions wrote, and reads the
    // legacy curve for the boost-seeded headroom.
    _dspCore = DspCoreSettings.load(_prefs, isIos: Platform.isIOS);
    // Then the equalizer, before anything below writes a prefs key that
    // `isExistingInstall` looks at (DspCoreSettings.save writes
    // `limiterEnabled`): a fresh install must still read as fresh here.
    _eqSettings = EqualizerSettings.load(_prefs);
    _eq = EqState.load(_prefs, centres: bandCentres(_eqSettings));
    _loadOutputProfiles();
    // Pin what the loads decided so it survives later launches. Without it a
    // fresh install would read as existing from its second launch
    // (`detectAndApplyDevicePreset` writes the legacy `lastOutputDevice` on
    // every launch), and a migration would run again.
    unawaited(_eqSettings.save(_prefs));
    unawaited(_eq.saveTo(_prefs));
    // Pin the install-dependent headroom default so it survives later launches.
    if (!_prefs.containsKey("dspHeadroomDb")) unawaited(_dspCore.save(_prefs));
    _appMode = AppMode.values[_prefs.getInt("appMode") ?? 0];
    _enableEffects = _prefs.getBool("enableEffects") ?? false;
    _selectedPreset = _prefs.getInt("selectedPreset") ?? 0;
    _isFancy = _prefs.getBool("fancyMode") ?? false;
    _isShuffled = _prefs.getBool("isShuffled") ?? false;
    _handler.shuffleEnabled = _isShuffled;
    _audioFocusSettings = AudioFocusSettings.load(_prefs);
    _headsetSettings = HeadsetSettings.load(_prefs);
    _advanced = AdvancedSettings.load(_prefs);
    // Pin the migrated volume levels so the legacy switch is read only once.
    if (!_prefs.containsKey('advVolumeLevels')) unawaited(_advanced.save(_prefs));
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
    // Restore the player visualizer, then tell the native tap once. The
    // player visual used to be the odd one out: its setter never wrote to prefs
    // and nothing read it back, so it silently reset to off on every launch.
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
    _fades = FadeSettings.load(_prefs);
    _handler.fades = _fades;
    _replayGain = ReplayGainSettings.load(_prefs);
    // DVC starts off: turning it on raises the system volume to maximum, which
    // made music loud on a fresh install. Whoever turned it on keeps it.
    _dvcEnabled = _prefs.getBool("dvcEnabled") ?? false;
    _dvcSettings = DvcSettings.load(_prefs);
    _dvcGain = _prefs.getDouble("dvcGain") ?? -30.0;
    _globalEqEnabled = _prefs.getBool("globalEqEnabled") ?? false;
    // Preamp & MBC
    _mbcEnabled = _prefs.getBool("mbcEnabled") ?? false;
    // Speaker correction EQ
    _speakerEqEnabled = _prefs.getBool("speakerEqEnabled") ?? false;
    _activeSpeakerProfile = _prefs.getString("activeSpeakerProfile");
    // Graphic EQ (the curve and presets are loaded above)
    _graphicEqEnabled = _prefs.getBool("graphicEqEnabled") ?? false;
    _linkAllDevices = _prefs.getBool("linkAllDevices") ?? true;
    _lastOutputDevice = _prefs.getString("lastOutputDevice") ?? 'speaker';
    final parametricJson = _prefs.getString("parametricPoints");
    if (parametricJson != null) {
      try {
        _parametricPoints = (json.decode(parametricJson) as List)
            .map((e) => ParametricPoint.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }
    // Visualizer fine-tuning
    final storedStyle = _prefs.getString("visualizerStyle");
    _visualizerStyle = migrateVisualizerStyle(
      storedStyle,
      isIos: Platform.isIOS,
    );
    if (storedStyle != null && storedStyle != _visualizerStyle) {
      _prefs.setString("visualizerStyle", _visualizerStyle);
    }
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
    _stereoExpand = StereoExpand.clamp(
      _prefs.getDouble(StereoExpand.prefKey) ??
          StereoExpand.migrate(
            legacyEnabled: _prefs.getBool(StereoExpand.legacyEnabledKey),
            legacyWidth: _prefs.getDouble(StereoExpand.legacyWidthKey),
          ),
    );
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
    _trebleGain = _prefs.getDouble("trebleGain") ?? 0.0;
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
      unawaited(
        libraryRepo?.rememberStreamed(streamed) ?? Future<void>.value(),
      );
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
    if (_eqPersistTimer?.isActive ?? false) commitEqGains();
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

  /// Stereo Expand, 0..1 (0–100 %). Zero is off.
  double get stereoExpand => _stereoExpand;

  /// Whether Stereo Expand is doing anything — any amount above zero.
  bool get stereoExpandEnabled => _stereoExpand > 0;

  set stereoExpand(double v) {
    final amount = StereoExpand.clamp(v);
    _prefs.setDouble(StereoExpand.prefKey, amount);
    _stereoExpand = amount;
    Channel.dspSetStereoExpand(amount);
    if (amount > 0 && _crossfeedEnabled) {
      // Mutually exclusive — one widens, the other narrows.
      _crossfeedEnabled = false;
      _prefs.setBool("crossfeedEnabled", false);
      Channel.dspSetCrossfeedEnabled(false);
    }
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
    if (v && stereoExpandEnabled) {
      // Mutually exclusive — stereo expand back to 0
      _stereoExpand = 0;
      _prefs.setDouble(StereoExpand.prefKey, 0);
      Channel.dspSetStereoExpand(0);
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
    _globalEqProbed = true;
    if (_globalEqAvailable && _globalEqEnabled) {
      _globalEqRequestedAt = DateTime.now();
      Channel.enableGlobalEq(true, preset: _eq.selected);
    } else if (Platform.isAndroid && _globalEqEnabled && dvcRunning) {
      // System-wide mode is on in the settings but cannot run here (no channel
      // yet, as in a headless start): the DVC start-up held back for it runs.
      _pushMasterVolume();
      Channel.enableDvc();
      _pushHeadroom();
    }
    _pushVolumeKeys();
    notifyListeners();
    // The notification's Stop ends the service without Dart's involvement.
    if (Platform.isAndroid && _globalEqAvailable) {
      _globalEqStoppedSub?.cancel();
      _globalEqStoppedSub = Channel.globalEqStoppedStream.listen(
        (_) => _globalEqEnded(),
        onError: (Object e) => debugPrint('Global EQ stop events: $e'),
      );
    }
  }

  /// The service is no longer running although system-wide mode is on here:
  /// take the same path as switching it off (DVC resumes, controls unlock).
  void _globalEqEnded() {
    if (_globalEqEnabled) globalEqEnabled = false;
  }

  /// Compares system-wide mode with the service on app resume, for the case
  /// the stop event could not be delivered (no engine at the time). A service
  /// that was only just asked to start is given a few seconds to come up.
  Future<void> resyncGlobalEq() async {
    if (!Platform.isAndroid) return;
    if (!_globalEqAvailable) {
      // A headless start has no channels: ask again now that there may be
      // some. The setting may also have been turned off by the notification's
      // Stop while no isolate was alive; read what native wrote.
      await _prefs.reload();
      _globalEqEnabled = _prefs.getBool("globalEqEnabled") ?? false;
      await _initGlobalEq();
      return;
    }
    if (!_globalEqEnabled) return;
    if (DateTime.now().difference(_globalEqRequestedAt) <
        const Duration(seconds: 5)) {
      return;
    }
    // A channel error is "unknown", not "stopped".
    final running = await Channel.isGlobalEqRunning();
    if (running != false) return;
    if (await Channel.globalEqStoppedByUser() == true) {
      _globalEqEnded();
    } else {
      // Not running and nobody stopped it: a start that failed. The setting
      // stays on and the start is tried again.
      _globalEqRequestedAt = DateTime.now();
      Channel.enableGlobalEq(true, preset: _eq.selected);
    }
  }

  /// Applies all DSP params to the native C++ engine on startup.
  void _applyAllDspParams() {
    // Speaker correction EQ (restore profile if was active)
    if (_speakerEqEnabled && _activeSpeakerProfile != null) {
      applySpeakerProfile(_activeSpeakerProfile!);
    }
    // EQ
    Channel.enableEq(_graphicEqEnabled && !_outputEffective.noEqTone);
    Channel.setPreamp(_dspCore.preampDb);
    // Layout and gains in one call, even when it is the legacy grid, so both
    // platforms run the same Q-from-spacing layout from the first track.
    _pushEqLayout();
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
    Channel.dspSetStereoExpand(_stereoExpand);
    Channel.dspSetCrossfeedEnabled(_crossfeedEnabled);
    Channel.dspSetCrossfeedParams(_crossfeedCutoff, _crossfeedFeed);
    Channel.dspSetSurround3dEnabled(_surround3dEnabled);
    Channel.dspSetSurround3dParams(_surround3dIntensity, _surround3dSubwoofer);
    _pushSurroundSpeakers();
    // Tone controls
    Channel.dspSetToneEnabled(_toneEnabled && !_outputEffective.noEqTone);
    Channel.dspSetBassGain(_bassGain);
    Channel.dspSetBassFreq(_eqSettings.bassFreq);
    Channel.dspSetBassQ(_eqSettings.bassQ);
    Channel.dspSetTrebleGain(_trebleGain);
    Channel.dspSetTrebleFreq(_eqSettings.trebleFreq);
    Channel.dspSetTrebleQ(_eqSettings.trebleQ);
    Channel.dspSetSmoothGains(_eqSettings.smoothGains);
    // Output limiter
    Channel.dspSetLimiterEnabled(_dspCore.limiter);
    // Core: headroom, balance, mono, tempo
    _pushHeadroom();
    Channel.dspSetBalance(_dspCore.balance);
    Channel.dspSetMono(_dspCore.mono);
    _pushTempo();
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
      hasNowPlaying || (ConnectPlayRouter.instance?.session.isRemote ?? false);

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

  /// The library pages the current queue was started from. Saved with the
  /// session so the player can lead back to them after a restart.
  PlaybackOrigin? _playbackOrigin;
  PlaybackOrigin? get playbackOrigin => _playbackOrigin;
  set playbackOrigin(PlaybackOrigin? value) {
    if (value == _playbackOrigin) return;
    _playbackOrigin = value;
    _saveSession();
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
        origin: _playbackOrigin,
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
    try {
      await _readSavedSession();
    } finally {
      // Every way out, including "nothing saved": a resume on start that came
      // first has been waiting for this to know whether there is a queue.
      _audioFocus?.sessionRestored();
    }
  }

  Future<void> _readSavedSession() async {
    final session = await PlaybackSessionStore.instance.load();
    if (session == null) return;
    // The user was faster than the disk and has already started something.
    // Their choice wins.
    if (_songs.isNotEmpty) return;

    _songs = List<SongModel>.of(session.songs);
    _isShuffled = session.shuffled;
    _handler.shuffleEnabled = _isShuffled;
    _shuffledSongs = session.effectiveQueue;
    _songId = session.index.clamp(0, songs.length - 1);
    if (songs.isNotEmpty) _artWorkId = songs[_songId].id;
    _pendingResume = session.position;
    // Set before anything re-resolves, so a queue that was being watched keeps
    // resolving as video from the first track the resume touches.
    VideoRegistry.instance.videoMode = session.videoMode;
    _playbackOrigin = session.origin;

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
    if (_gaplessQueue && !anyStale) {
      await loadGaplessQueue(
        _songId,
        initialPosition: position,
        autoPlay: false,
      );
    } else {
      await loadAudioSource(
        handler,
        songs[_songId],
        replayGain: _rgNow,
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
  Future<void> loadTrackAt(
    int index, {
    Duration? position,

    /// How the change sounds — for a change the listener asked for, see
    /// [FadeSettings.manualChangeFade]. Null for a track ending on its own,
    /// whose fade, if any, has already happened.
    ChangeFade? fade,
    bool autoPlay = true,
  }) async {
    if (index < 0 || index >= songs.length) return;
    // Synchronously, before the network: a crossfade in flight stops now, not
    // once the link has been renewed.
    handler.beginLoad();
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
        replayGain: _rgNow,
        initialPosition: position,
        autoPlay: autoPlay,
        fade: fade,
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
    // The item after this one depends on the loop mode (repeat-one: itself).
    final at = handler.player.currentIndex;
    if (at != null) unawaited(_sendNextGain(handler.player, at));
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

    // "Shuffled songs" fading blends a shuffled queue and keeps an ordered one
    // gapless, so turning shuffle over can move playback to the other way of
    // loading tracks.
    final wasQueue = _gaplessQueue;
    _isShuffled = value;
    _handler.shuffleEnabled = value;
    unawaited(_prefs.setBool('isShuffled', value));

    _songId = QueueOrder.indexOf(songs, playing);
    if (songs.isNotEmpty) _artWorkId = songs[_songId].id;
    notifyListeners();

    if (wasQueue != _gaplessQueue) {
      await _switchLoadingPath();
    } else {
      await _reloadQueueOrder();
    }
  }

  /// Rebuilds the player's source list so it plays the order the app is showing.
  ///
  /// Only gapless mode needs this. The other paths load one track at a time
  /// from `songs[songId]`, so they pick up a new order for free on the next
  /// advance; a gapless queue is handed to the player once and has to be handed
  /// over again to change.
  Future<void> _reloadQueueOrder() async {
    if (handler.player.audioSources.length <= 1) return;
    // Reordering must not resume a queue the user had paused, nor restart the
    // song they are in the middle of.
    await loadGaplessQueue(
      _songId,
      initialPosition: handler.player.position,
      autoPlay: handler.player.playing,
      fade: ChangeFade.cut,
    );
  }

  /// Moves what is playing onto the other way of loading tracks — the whole
  /// queue on one player, or a track at a time — at the same position, playing
  /// or paused as it was. Called when a setting or shuffle changes which one
  /// the fading mode wants.
  Future<void> _switchLoadingPath() async {
    if (songs.isEmpty || _songId < 0 || _songId >= songs.length) return;
    // Nothing loaded yet, or a restored session waiting for its first play:
    // whichever loads next will follow the rules in force by then.
    if (_pendingResume != null || handler.player.audioSources.isEmpty) return;
    final position = handler.player.position;
    final playing = handler.player.playing;
    if (_gaplessQueue) {
      // A queue holding expired links goes on a track at a time — see
      // [_resumePendingSession].
      if (songs.any((song) => !song.hasFreshTarget)) return;
      await loadGaplessQueue(
        _songId,
        initialPosition: position,
        autoPlay: playing,
        fade: ChangeFade.cut,
      );
    } else {
      await loadTrackAt(
        _songId,
        position: position,
        autoPlay: playing,
        fade: ChangeFade.cut,
      );
    }
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
        _songId < 0 ||
        _songId >= songs.length ||
        songs[_songId].id != target.id;
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
    // Its tags may have changed, and with them its Replay Gain.
    _rgDbCache.remove(song.data);

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
      loadAudioSource(_handler, song, replayGain: _rgNow);
      _loadLyricsForCurrentSong();
    }
  }

  void next() {
    if (songs.isEmpty) return;
    final loopMode = handler.loopMode;

    if (loopMode == LoopMode.one) {
      // Repeat-one: restart current track
      _restartCurrent();
      return;
    }

    if (songId >= songs.length - 1) {
      if (loopMode == LoopMode.all) {
        // Repeat-all: wrap to first song
        _changeTrackTo(0);
      } else {
        // No repeat: stop at end
        songId = 0;
        unawaited(handler.stop());
      }
    } else {
      _changeTrackTo(songId + 1);
    }
  }

  void prev() {
    if (songs.isEmpty) return;
    final loopMode = handler.loopMode;

    // If more than 3 seconds in, restart current track (standard behavior).
    // Measured on the track being heard: during a crossfade that is the one
    // coming in, so previous early in a fade goes back to the track fading
    // out rather than restarting the new one.
    final position = handler.currentTrackPlayer.position;
    if (position.inSeconds > 3) {
      unawaited(handler.seek(Duration.zero));
      return;
    }

    if (loopMode == LoopMode.one) {
      _restartCurrent();
      return;
    }

    if (songId == 0) {
      if (loopMode == LoopMode.all) {
        // Repeat-all: wrap to last song
        _changeTrackTo(songs.length - 1);
      } else {
        // No repeat: restart first song
        unawaited(handler.seek(Duration.zero));
      }
    } else {
      _changeTrackTo(songId - 1);
    }
  }

  /// Plays the track at [index] of the queue — a swipe of the player card, or
  /// any other jump straight to a track. Sounds like next and previous do.
  void skipTo(int index) {
    if (index == songId) return;
    _changeTrackTo(index);
  }

  /// A track change the listener asked for: next, previous, a swipe, a jump.
  ///
  /// Every one of them used to cut. They fade now, the way
  /// [FadeSettings.manualChange] says: out of something playing, the old track
  /// fades out under the new one; out of silence, the new one fades in.
  ///
  /// The `songId` setter runs first, before the player is touched, so the
  /// outgoing track's listening is recorded against the position it actually
  /// reached.
  void _changeTrackTo(int index) {
    if (index < 0 || index >= songs.length) return;
    final fade = _fades.manualChangeFade(
      incomingDurationMs: songs[index].duration,
    );
    final inQueue = handler.player.audioSources.length > 1;
    songId = index;
    artWorkId = songs[index].id;
    if (!inQueue) {
      unawaited(loadTrackAt(index, fade: fade));
      return;
    }
    // The whole queue is on one player.
    if (fade.crossfadeMs > 0 && handler.isAudible) {
      unawaited(_crossfadeQueueTo(index, fade));
      return;
    }
    // A cut within the queue, declicked like any other.
    final token = handler.beginLoad();
    unawaited(() async {
      await handler.abortCrossfade();
      if (_overtaken(token)) return;
      final wasAudible = handler.isAudible;
      await handler.declickOut();
      // Re-gained before the seek, or the new track's first moments play at
      // the old one's gain.
      if (index >= 0 && index < songs.length) {
        final song = songs[index];
        final db = await _replayGainDbFor(song);
        if (_overtaken(token)) return;
        handler.setEngineTrackGainDb(handler.player, db, subject: song);
        _gainedIndex[handler.player] = index;
        // Then the item after it, and only then the seek.
        await _sendNextGain(handler.player, index);
        if (_overtaken(token)) return;
      }
      _seekTarget[handler.player] = (index: index, at: DateTime.now());
      await handler.player.seek(Duration.zero, index: index);
      if (wasAudible) {
        handler.startPlayback(fadeInMs: kDeclickMs);
      } else {
        handler.resetLevels(handler.player);
      }
    }());
  }

  /// Repeat-one's answer to next and previous: the same track from the top.
  void _restartCurrent() {
    unawaited(() async {
      await handler.seek(Duration.zero);
      if (!handler.player.playing) unawaited(handler.play());
    }());
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
