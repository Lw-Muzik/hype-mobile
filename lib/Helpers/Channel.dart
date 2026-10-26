// ignore_for_file: constant_identifier_names
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class Channel {
  static MethodChannel channel = const MethodChannel("eq_app");

  static Future<T?> _invoke<T>(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      debugPrint('Channel error [$method]: ${e.message}');
      return null;
    } on MissingPluginException {
      debugPrint('Channel method not found: $method');
      return null;
    }
  }

  static Future<T> _invokeRequired<T>(
    String method,
    T fallback, [
    Map<String, dynamic>? args,
  ]) async {
    final result = await _invoke<T>(method, args);
    return result ?? fallback;
  }

  /// initializing Equalizer
  static void dispose() async {
    await _invoke("release");
  }

  static void showNativeMessage(String message) async {
    await _invoke("showNativeMessage", {"message": message});
  }

  static Future<List<Map<String, dynamic>>> getPreset() async {
    final result = await _invoke("getPresetNames");
    if (result == null) return [];
    List<String> p = (result as List).cast<String>();
    return List.generate(
      p.length,
      (index) => {"id": index, "preset": p[index]},
    );
  }

  static void setPreset(String p) async {
    await _invoke("setPreset", {"preset": p});
  }

  static void setBandLevel(int band, int level) async {
    await _invoke("setBandLevel", {"band": band, "level": level});
  }

  static Future<List<int>> getBandLevelRange() async {
    final result = await _invoke("getBandLevelRange");
    if (result == null) return [0, 0];
    return (result as List).cast<int>();
  }

  static Future<int> getBandLevel(int band) async {
    return await _invokeRequired<int>("getBandLevel", 0, {"_band": band});
  }

  static Future<bool> isEnabled() async {
    return await _invokeRequired<bool>("isEnabled", false);
  }

  static Future<String> getSetting() async {
    return await _invokeRequired<String>("getSettings", "");
  }

  static void setEqSettings({int nBands = 5}) async {
    await _invoke("setSettings", {"nBands": nBands});
  }

  static Future<List<int>> getBandFreq() async {
    final result = await _invoke("getBandFreq");
    if (result == null) return [];
    return (result as List).cast<int>();
  }

  static void enableEq(bool enabled) async {
    await _invoke("enableEq", {"enable": enabled});
  }

  static void enableBass(bool enable) async {
    await _invoke("enableBassBoost", {"enableBass": enable});
  }

  static Future<bool> isBassEnabled() async {
    return await _invokeRequired<bool>("isBassEnabled", false);
  }

  static Future<int> getBassStrength() async {
    return await _invokeRequired<int>("bassBoostStrength", 0);
  }

  static void setBassStrength(int strength) async {
    await _invoke("setBassBoostStrength", {"strength": strength});
  }

  /// Loudness enhancer (session-aware init — used by both legacy and DVC)
  static void _initLoudnessEnhancer(int sessionId) async {
    await _invoke("initLoudnessEnhancer", {"sessionId": sessionId});
  }

  static void enableLoudnessEnhancer(bool enable) async {
    await _invoke("enableLoudnessEnhancer", {"enableLoud": enable});
  }

  /// Sets the target gain (millibels)
  static void setTargetGain(int strength) async {
    await _invoke("setLoudnessEnhancerStrength", {"strength": strength});
  }

  /// Retrieves the target gain value
  static Future<double> getTargetGain() async {
    return await _invokeRequired<double>("loudnessEnhancerStrength", 0.0);
  }

  // ==================== DVC (Direct Volume Control) ====================

  /// Enable DVC: saves system volume, maxes STREAM_MUSIC, enables LoudnessEnhancer
  static Future<void> enableDvc() async {
    await _invoke("enableDvc", {});
  }

  /// Disable DVC: restores saved system volume, disables LoudnessEnhancer
  static Future<void> disableDvc() async {
    await _invoke("disableDvc", {});
  }

  /// Set DVC gain in dB. Native side handles system volume crossover
  /// for true silence at the bottom of the range.
  static Future<void> setDvcGain(double dB) async {
    await _invoke("setDvcGain", {"gain": dB});
  }

  /// Get current DVC internal gain
  static Future<double> getDvcGain() async {
    return await _invokeRequired<double>("getDvcGain", 0.0);
  }

  /// Check if DVC is currently active
  static Future<bool> isDvcActive() async {
    return await _invokeRequired<bool>("isDvcActive", false);
  }

  /// Get current system music volume
  static Future<int> getSystemVolume() async {
    return await _invokeRequired<int>("getSystemVolume", 0);
  }

  /// Get maximum system music volume
  static Future<int> getSystemMaxVolume() async {
    return await _invokeRequired<int>("getSystemMaxVolume", 15);
  }

  /// EventChannel for hardware volume button events when DVC is active.
  /// Emits "up" or "down" strings.
  static const EventChannel _dvcVolumeButtonChannel = EventChannel(
    "eq_app/dvc_volume_button",
  );

  static Stream<String> get dvcVolumeButtonStream => _dvcVolumeButtonChannel
      .receiveBroadcastStream()
      .map((event) => event.toString());

  // ==================== Global EQ (System-Wide) ====================

  /// Enable or disable global EQ (applies EQ to all apps). [preset] is the
  /// name shown in its notification.
  /// Returns true if the command was accepted, false if API < 28.
  static Future<bool> enableGlobalEq(bool enable, {String? preset}) async {
    return await _invokeRequired<bool>("enableGlobalEq", false, {
      "enable": enable,
      "preset": preset,
    });
  }

  /// Update the preset name shown in the global EQ notification.
  static Future<bool> updateGlobalEqPreset(String preset) async {
    return await _invokeRequired<bool>("updateGlobalEqPreset", false, {
      "preset": preset,
    });
  }

  /// Check if global EQ is currently running.
  static Future<bool> isGlobalEqEnabled() async {
    return await _invokeRequired<bool>("isGlobalEqEnabled", false);
  }

  /// Check if global EQ is available on this device (API 28+).
  static Future<bool> isGlobalEqAvailable() async {
    return await _invokeRequired<bool>("isGlobalEqAvailable", false);
  }

  /// Returns list of {package, name} maps for apps currently playing audio.
  static Future<List<Map<String, String>>> getPlayingApps() async {
    final result = await _invoke<List<dynamic>>("getPlayingApps");
    if (result == null) return [];
    return result.map((e) => Map<String, String>.from(e as Map)).toList();
  }

  /// Returns the PNG icon bytes for a given package name, or null if unavailable.
  static Future<Uint8List?> getAppIcon(String packageName) async {
    return await _invoke<Uint8List>("getAppIcon", {"package": packageName});
  }

  /// Check if battery optimization is disabled (app is unrestricted).
  static Future<bool> isBatteryOptimizationDisabled() async {
    return await _invokeRequired<bool>("isBatteryOptimizationDisabled", false);
  }

  /// Request the user to disable battery optimization for this app.
  static Future<bool> requestDisableBatteryOptimization() async {
    return await _invokeRequired<bool>(
      "requestDisableBatteryOptimization",
      false,
    );
  }

  // ==================== Custom DSP Room Effects ====================

  /// Enable/disable FDN reverb
  static Future<void> dspSetReverbEnabled(bool enabled) async {
    await _invoke("dspSetReverbEnabled", {"enabled": enabled});
  }

  /// Room size (0.0 - 1.0) — scales delay line lengths
  static Future<void> dspSetRoomSize(double value) async {
    await _invoke("dspSetRoomSize", {"value": value});
  }

  /// Decay (0.0 - 1.0) — maps to RT60 (0.1s - 15s)
  static Future<void> dspSetDecay(double value) async {
    await _invoke("dspSetDecay", {"value": value});
  }

  /// Damping (0.0 - 1.0) — feedback lowpass (0=bright, 1=dark)
  static Future<void> dspSetDamping(double value) async {
    await _invoke("dspSetDamping", {"value": value});
  }

  /// Pre-delay in ms (0 - 200)
  static Future<void> dspSetPreDelay(double ms) async {
    await _invoke("dspSetPreDelay", {"value": ms});
  }

  /// Diffusion (0.0 - 1.0) — echo density
  static Future<void> dspSetDiffusion(double value) async {
    await _invoke("dspSetDiffusion", {"value": value});
  }

  /// Reverb wet/dry mix (0.0 - 1.0)
  static Future<void> dspSetReverbWetDry(double value) async {
    await _invoke("dspSetReverbWetDry", {"value": value});
  }

  /// Enable/disable M/S stereo expansion
  static Future<void> dspSetStereoExpandEnabled(bool enabled) async {
    await _invoke("dspSetStereoExpandEnabled", {"enabled": enabled});
  }

  /// Stereo width (0.0 = mono, 1.0 = normal, 2.0 = max expansion)
  static Future<void> dspSetStereoWidth(double value) async {
    await _invoke("dspSetStereoWidth", {"value": value});
  }

  /// Enable/disable BS2B crossfeed
  static Future<void> dspSetCrossfeedEnabled(bool enabled) async {
    await _invoke("dspSetCrossfeedEnabled", {"enabled": enabled});
  }

  /// Set crossfeed filter params (cutoffHz: 100-2000, feedLevelDb: 1-15)
  static Future<void> dspSetCrossfeedParams(
    double cutoffHz,
    double feedLevelDb,
  ) async {
    await _invoke("dspSetCrossfeedParams", {
      "cutoff": cutoffHz,
      "feed": feedLevelDb,
    });
  }

  // ==================== 3D Surround ====================
  //
  // A port of the desktop stage (crates/hm-dsp/src/surround3d.rs). Both
  // platforms answer these three names with the same C++ underneath, so
  // nothing here needs to know which one it is talking to.

  /// Turn the virtual speaker ring on or off.
  static Future<void> dspSetSurround3dEnabled(bool enabled) async {
    await _invoke("dspSetSurround3dEnabled", {"enabled": enabled});
  }

  /// [intensity] is the dry/wet mix (0–1); [subwoofer] the LFE level (0–1).
  static Future<void> dspSetSurround3dParams(
    double intensity,
    double subwoofer,
  ) async {
    await _invoke("dspSetSurround3dParams", {
      "intensity": intensity,
      "subwoofer": subwoofer,
    });
  }

  /// Which speakers in the ring are switched on.
  ///
  /// Switching a side ("tweeter") off folds its highs back into the front
  /// speaker rather than dropping them, so the result is a different image, not
  /// a duller one.
  static Future<void> dspSetSurround3dSpeakers({
    required bool frontL,
    required bool frontR,
    required bool sideL,
    required bool sideR,
    required bool surroundL,
    required bool surroundR,
  }) async {
    await _invoke("dspSetSurround3dSpeakers", {
      "frontL": frontL,
      "frontR": frontR,
      "sideL": sideL,
      "sideR": sideR,
      "surroundL": surroundL,
      "surroundR": surroundR,
    });
  }

  // ==================== Tone Controls (Bass/Treble) ====================

  /// Enable/disable tone controls (independent bass/treble shelf filters)
  static Future<void> dspSetToneEnabled(bool enabled) async {
    await _invoke("dspSetToneEnabled", {"enabled": enabled});
  }

  /// Bass gain (-15 to +15 dB)
  static Future<void> dspSetBassGain(double dB) async {
    await _invoke("dspSetBassGain", {"value": dB});
  }

  /// Bass frequency (20 - 500 Hz, default 80)
  static Future<void> dspSetBassFreq(double hz) async {
    await _invoke("dspSetBassFreq", {"value": hz});
  }

  /// Bass Q (0.1 - 4.0, default 0.707)
  static Future<void> dspSetBassQ(double q) async {
    await _invoke("dspSetBassQ", {"value": q});
  }

  /// Treble gain (-15 to +15 dB)
  static Future<void> dspSetTrebleGain(double dB) async {
    await _invoke("dspSetTrebleGain", {"value": dB});
  }

  /// Treble frequency (1000 - 20000 Hz, default 10000)
  static Future<void> dspSetTrebleFreq(double hz) async {
    await _invoke("dspSetTrebleFreq", {"value": hz});
  }

  /// Treble Q (0.1 - 4.0, default 0.707)
  static Future<void> dspSetTrebleQ(double q) async {
    await _invoke("dspSetTrebleQ", {"value": q});
  }

  // ==================== Output Limiter ====================

  /// Enable/disable output limiter (on by default — safety net)
  static Future<void> dspSetLimiterEnabled(bool enabled) async {
    await _invoke("dspSetLimiterEnabled", {"enabled": enabled});
  }

  /// Limiter ceiling (0.01 - 1.0, default 0.98)
  static Future<void> dspSetLimiterCeiling(double value) async {
    await _invoke("dspSetLimiterCeiling", {"value": value});
  }

  /// Limiter release time in ms (10 - 500, default 50)
  static Future<void> dspSetLimiterRelease(double ms) async {
    await _invoke("dspSetLimiterRelease", {"value": ms});
  }

  /// Limiter soft knee width in dB (0 - 12, default 6)
  static Future<void> dspSetLimiterKnee(double dB) async {
    await _invoke("dspSetLimiterKnee", {"value": dB});
  }

  // ==================== Speaker Correction EQ (AutoEq) ====================

  static Future<void> setSpeakerEqEnabled(bool enabled) async {
    await _invoke("setSpeakerEqEnabled", {"enabled": enabled});
  }

  static Future<void> setSpeakerEqBands(
    List<Map<String, dynamic>> bands,
  ) async {
    final freqs = bands.map((b) => (b['fc'] as num).toDouble()).toList();
    final gains = bands.map((b) => (b['gain'] as num).toDouble()).toList();
    final qs = bands.map((b) => (b['q'] as num).toDouble()).toList();
    final types = bands.map((b) => (b['type'] as int)).toList();
    await _invoke("setSpeakerEqBands", {
      "freqs": freqs,
      "gains": gains,
      "qs": qs,
      "types": types,
    });
  }

  static Future<void> clearSpeakerEq() async {
    await _invoke("clearSpeakerEq");
  }

  // ----------- MBC Compressor (C++ pipeline) ------------------

  static void setDspNoiseThreshold(double noiseValue) async {
    await _invoke("setDspNoiseThreshold", {"noiseThreshold": noiseValue});
  }

  static void setDspKneeWidth(double kneeWidth) async {
    await _invoke("kneeWidth", {"kneeWidth": kneeWidth});
  }

  static void setPreGain(double preGain) async {
    await _invoke("setPreGain", {"preGain": preGain});
  }

  static void setDspExpandRatio(double expandRatio) async {
    await _invoke("expandRatio", {"expandRatio": expandRatio});
  }

  /// Deletes a FOLDER and everything in it. Returns whether it worked.
  ///
  /// Used to be `void` over a native handler that never answered, so the future
  /// never completed and no caller could tell success from failure.
  static Future<bool> deleteManager(String path) async {
    final ok = await _invoke<bool>("deleteManager", {"filePath": path});
    return ok ?? false;
  }

  /// Deletes ONE track from the device. Returns whether the file is now gone.
  ///
  /// On Android 11+ a track the app did not write needs the user's consent, so
  /// this can show a system dialog and only completes once they answer — false
  /// means they declined or it failed, and the caller must not remove the track
  /// from the library on that answer.
  static Future<bool> deleteAudio(String path) async {
    final ok = await _invoke<bool>("deleteAudio", {"filePath": path});
    return ok ?? false;
  }

  // ==================== 32-Band Graphic EQ (Pre-EQ) ====================

  static Future<void> setGraphicBandGain(int band, double gain) async {
    await _invoke("setGraphicBandGain", {"band": band, "gain": gain});
  }

  static Future<double> getGraphicBandGain(int band) async {
    return await _invokeRequired<double>("getGraphicBandGain", 0.0, {
      "band": band,
    });
  }

  static Future<void> setGraphicAllBands(List<double> gains) async {
    await _invoke("setGraphicAllBands", {"gains": gains});
  }

  static Future<List<double>> getGraphicAllBands() async {
    final result = await _invoke("getGraphicAllBands");
    if (result == null) return List.filled(32, 0.0);
    return (result as List).map((e) => (e as num).toDouble()).toList();
  }

  // ==================== 32-Band Parametric EQ (Post-EQ) ====================

  static Future<void> setParametricBand(
    int band,
    double freq,
    double gain, {
    double q = 1.4,
    int filterType = 0,
    bool enabled = true,
  }) async {
    await _invoke("setParametricBand", {
      "band": band,
      "freq": freq,
      "gain": gain,
      "q": q,
      "filterType": filterType,
      "enabled": enabled,
    });
  }

  static Future<void> setParametricAllBands(
    List<double> freqs,
    List<double> gains, {
    List<double>? qs,
  }) async {
    await _invoke("setParametricAllBands", {
      "freqs": freqs,
      "gains": gains,
      if (qs != null) "qs": qs,
    });
  }

  // ==================== Preamp ====================

  static Future<void> setPreamp(double gain) async {
    await _invoke("setPreamp", {"gain": gain});
  }

  static Future<double> getPreamp() async {
    return await _invokeRequired<double>("getPreamp", 0.0);
  }

  // ==================== MBC Toggle ====================

  static Future<void> enableMbc(bool enable) async {
    await _invoke("enableMbc", {"enable": enable});
  }

  static Future<bool> isMbcEnabled() async {
    return await _invokeRequired<bool>("isMbcEnabled", false);
  }

  // ==================== Device Detection ====================

  static Future<bool> isDynamicsProcessingAvailable() async {
    return await _invokeRequired<bool>("isDynamicsProcessingAvailable", false);
  }

  static Future<String> getAudioOutputType() async {
    return await _invokeRequired<String>("getAudioOutputType", "speaker");
  }

  static void setSessionId(int sessionId) async {
    _initLoudnessEnhancer(sessionId);
    await _invoke("init", {"sessionId": sessionId});
  }

  // ==================== Audio Fingerprinting ====================

  /// Generates a Chromaprint fingerprint from an audio file.
  /// Returns {fingerprint: String, duration: int (seconds)} or null on failure.
  static Future<Map<String, dynamic>?> generateFingerprint(
    String filePath,
  ) async {
    final result = await _invoke<Map>("generateFingerprint", {
      "filePath": filePath,
    });
    if (result == null) return null;
    return Map<String, dynamic>.from(result);
  }

  /// Writes metadata tags to an audio file (fill-empty policy).
  /// Supports MP3, M4A, FLAC, OGG, WMA via JAudioTagger.
  /// [artworkPath] optional local path to cover art image to embed.
  static Future<bool> writeTags(
    String filePath,
    Map<String, String> tags, {
    String? artworkPath,
  }) async {
    return await _invokeRequired<bool>("writeTags", false, {
      "filePath": filePath,
      "tags": tags,
      if (artworkPath != null) "artworkPath": artworkPath,
    });
  }

  /// Opens the system share sheet with [text] (a song's link).
  static Future<bool> shareText(String text) =>
      _invokeRequired<bool>("shareText", false, {"text": text});

  /// Opens the system share sheet with the audio file at [filePath]. False
  /// when it can't be shared — on Android, a file the media library doesn't
  /// list.
  static Future<bool> shareAudio(String filePath) =>
      _invokeRequired<bool>("shareAudio", false, {"filePath": filePath});

  /// Triggers Android MediaStore re-scan for the given file path.
  /// Call after writing tags so queries return updated metadata.
  static Future<void> scanMediaFile(String filePath) async {
    await _invoke("scanMediaFile", {"filePath": filePath});
  }

  // ==================== YouTube downloads ====================

  /// Why the last [finishYtDownload] failed (native text), null after a success.
  static String? lastFinishError;

  /// Writes [src] (YouTube's untagged streaming MP4) to [dst] as a plain,
  /// tagged .m4a — the audio copied as is. [tags] is
  /// `YtSongTags.toChannel()`. False when it couldn't; [dst] is then absent
  /// and [lastFinishError] holds the native reason.
  static Future<bool> finishYtDownload(
    String src,
    String dst,
    Map<String, Object?> tags,
  ) async {
    // Native answers true, or the failure text.
    final answer = await _invoke<Object>("finishYtDownload", {
      "src": src,
      "dst": dst,
      "tags": tags,
    });
    if (answer == true) {
      lastFinishError = null;
      return true;
    }
    lastFinishError = answer is String ? answer : 'no answer from native';
    return false;
  }

  /// Writes each `replacement` file over its `path` — another app's files
  /// after one consent dialog for the batch (Android) — and re-scans them.
  /// Answers path → whether it was replaced.
  static Future<Map<String, bool>> replaceAudioFiles(
    List<({String path, String replacement})> files,
  ) async {
    final answer = await _invoke<Object>("replaceAudioFiles", {
      "files": [
        for (final f in files) {"path": f.path, "replacement": f.replacement},
      ],
    });
    if (answer is! Map) return const {};
    return {
      for (final e in answer.entries)
        if (e.key is String) e.key as String: e.value == true,
    };
  }

  // ==================== Audio Metadata Extraction ====================

  /// Extracts metadata from any audio format via MediaMetadataRetriever.
  /// Works with HTTP URLs (for cloud files) using auth headers.
  /// Returns: {title, artist, album, durationMs, hasArtwork}
  static Future<Map<String, dynamic>?> extractAudioMetadata({
    required String url,
    Map<String, String> headers = const {},
    String? artworkPath,
  }) async {
    final result = await _invoke<Map>("extractAudioMetadata", {
      "url": url,
      "headers": headers,
      "artworkPath": artworkPath,
    });
    if (result == null) return null;
    return Map<String, dynamic>.from(result);
  }

  // ==================== Live Stems ====================
  //
  // Vocals / drums / instruments while a song plays. The native engine
  // separates ahead of the playhead and follows the player by itself, so Dart
  // never says which song is playing — it only supplies the model, the levels,
  // and whether the engine should be working at all. Same names and shapes on
  // Android and iOS.

  // The answers below are read as `Object` and checked, rather than cast by
  // `invokeMethod<T>`: a native side that answers with the wrong type must
  // read as "no", not throw a TypeError into the UI.

  /// Loads `vocals.onnx`, `drums.onnx`, `bass.onnx` and `other.onnx` from
  /// [dir]. False when the files can't be loaded — or the engine isn't there.
  static Future<bool> stemsLoadModel(String dir) async {
    return await _invoke<Object>("stemsLoadModel", {"dir": dir}) == true;
  }

  static Future<void> stemsUnloadModel() async {
    await _invoke("stemsUnloadModel");
  }

  /// Times a short separation on the loaded model:
  /// `{ok: bool, rtf: double, millis: int, error: String?}`, or null when the
  /// engine didn't answer.
  static Future<Map<String, dynamic>?> stemsBenchmark() async {
    final result = await _invoke<Object>("stemsBenchmark");
    return result is Map ? Map<String, dynamic>.from(result) : null;
  }

  /// Armed = the Stems tab is on screen, or the mix differs from the
  /// original. Disarmed, the engine stops separating and plays the original.
  static Future<void> stemsSetArmed(bool armed) async {
    await _invoke("stemsSetArmed", {"armed": armed});
  }

  /// Effective gains, 0–1 (a muted stem is 0). 1/1/1 is the original.
  static Future<void> stemsSetLevels({
    required double vocals,
    required double drums,
    required double instruments,
  }) async {
    await _invoke("stemsSetLevels", {
      "vocals": vocals,
      "drums": drums,
      "instruments": instruments,
    });
  }

  /// A local copy of the stream the player is playing from [url] (the exact
  /// URI string it was given): the engine separates the copy instead of
  /// reporting the track as a stream it can't read ahead of the playhead.
  static Future<void> stemsProvideStream(String url, String path) async {
    await _invoke("stemsProvideStream", {"url": url, "path": path});
  }

  /// The engine's current state, shaped like a [stemsEvents] event.
  static Future<Map<String, dynamic>?> stemsGetStatus() async {
    final result = await _invoke<Object>("stemsGetStatus");
    return result is Map ? Map<String, dynamic>.from(result) : null;
  }

  static const EventChannel _stemsEventChannel = EventChannel(
    "eq_app/stems_events",
  );

  /// `{state: idle|preparing|ready|unavailable|error, reason: String?,
  /// progress: 0–1, aheadSeconds: double, trackKey: String?}`.
  static Stream<Map<String, dynamic>> get stemsEvents => _stemsEventChannel
      .receiveBroadcastStream()
      .where((event) => event is Map)
      .map((event) => Map<String, dynamic>.from(event as Map));

  // ==================== Lyrics ====================

  /// Reads embedded lyrics from any audio format (MP3, M4A, FLAC, OGG, WMA).
  static Future<String?> readLyrics(String filePath) async {
    return await _invoke<String>("readLyrics", {"filePath": filePath});
  }

  /// Writes lyrics text into the ID3v2 USLT frame of an MP3 file.
  static Future<bool> writeLyrics(String filePath, String lyrics) async {
    return await _invokeRequired<bool>("writeLyrics", false, {
      "filePath": filePath,
      "lyrics": lyrics,
    });
  }
}
