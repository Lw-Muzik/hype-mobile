import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// True when [prefs] holds any key an earlier version wrote, i.e. the app was
/// used before the newer settings existed.
bool isExistingInstall(SharedPreferences prefs) =>
    DspCoreSettings._legacyKeys.any(prefs.containsKey);

/// Master volume (dB) that every player's engine applies, derived from the
/// Direct Volume Control setting.
///
/// With DVC on, the user's level (-30..0 dB, -30 = silence) is the engine's
/// master volume. With DVC off the master stays at unity (0 dB).
double masterVolumeFor({required bool dvcEnabled, required double dvcGainDb}) {
  if (!dvcEnabled) return 0.0;
  return dvcGainDb.clamp(-30.0, 0.0).toDouble();
}

/// One step of switching DVC on or off.
enum DvcStep {
  pushMasterVolume,
  flushIfPaused,
  enableDvc,
  disableDvc,

  /// A route-driven release: the engine master stage lets go, the system
  /// volume is not written (see `dvcRestoreFor`).
  releaseDvc,
}

/// Order of the native calls when DVC is toggled.
///
/// Turning on: the engine master volume goes first; the Android controller
/// then raises the system stream only after the audio already buffered at
/// unity gain has drained (it cannot be recalled), so it is never played at
/// full device volume. Turning off: the system volume is restored first, then
/// the master returns to 0 dB.
///
/// While paused, the buffered unity-gain audio would otherwise play at full
/// device volume on resume, so it is flushed before the system raise.
List<DvcStep> dvcToggleSteps({required bool enable}) => enable
    ? const [
        DvcStep.pushMasterVolume,
        DvcStep.flushIfPaused,
        DvcStep.enableDvc,
      ]
    : const [DvcStep.disableDvc, DvcStep.pushMasterVolume];

/// The steps when the route gate (not the listener) turns DVC on or off.
///
/// Turning off because the OUTPUT changed releases: the system volume is not
/// written (the saved original belongs to the old output). Turning off on the
/// SAME output (No DVC for Bluetooth absolute volume, a per-output No DVC, the
/// absolute-volume flag) is a real disable: that output's original is restored
/// before the master returns to the DVC-off value, never "master 0 dB" on a
/// device still at maximum.
List<DvcStep> dvcRouteSteps({
  required bool enable,
  required bool outputChanged,
}) => enable
    ? dvcToggleSteps(enable: true)
    : outputChanged
    ? const [DvcStep.releaseDvc, DvcStep.pushMasterVolume]
    : dvcToggleSteps(enable: false);

/// Whether Direct Volume Control is actually running: Android only, the
/// setting on, and the equalizer not applied system-wide. In system-wide mode
/// the platform equalizer owns the level other apps are heard at, so DVC is
/// suspended (the stored setting is untouched) and resumes when it ends.
bool dvcInEffect({
  required bool isAndroid,
  required bool dvcEnabled,
  required bool systemWide,
}) => isAndroid && dvcEnabled && !systemWide;

/// The DVC steps for turning system-wide mode on or off. With DVC set, going
/// on suspends it in the safe order (system volume restored first) and going
/// off resumes it; with DVC off there is nothing to do.
List<DvcStep> systemWideDvcSteps({
  required bool systemWideOn,
  required bool dvcEnabled,
}) => dvcEnabled ? dvcToggleSteps(enable: !systemWideOn) : const [];

/// Whether the DVC steps that follow system-wide mode ending must wait.
///
/// DVC's enable raises the music stream to maximum whenever any app is
/// playing, so with Hype in the background (say the notification's Stop while
/// another app plays) it would blast that app. They wait until Hype itself
/// plays or comes to the foreground.
bool deferDvcResume({required bool appInForeground, required bool hypePlaying}) =>
    !appInForeground && !hypePlaying;

/// Why a control is disabled while the equalizer applies to all apps: the
/// platform equalizer cannot carry it.
const kSystemWideReason = 'Not available while the equalizer applies to all apps';

/// Headroom (dB, <= 0) the engine applies ahead of the DSP chain.
///
/// With DVC active the user's own level control already governs loudness, so
/// the headroom attenuation is skipped.
double headroomFor({required bool dvcActive, required double headroomDb}) =>
    dvcActive ? 0.0 : headroomDb;

/// Persisted core audio settings: headroom, balance, mono, limiter, preamp
/// and tempo. Immutable; [copyWith] and [load] normalise every value.
class DspCoreSettings {
  const DspCoreSettings({
    required this.headroomDb,
    required this.balance,
    required this.mono,
    required this.limiter,
    required this.preampDb,
    required this.tempoOn,
    required this.tempo,
  });

  /// Pre-DSP attenuation, -10..0 dB in 0.5 dB steps.
  final double headroomDb;

  /// -1 (left) .. 1 (right); 0 is centre.
  final double balance;
  final bool mono;
  final bool limiter;

  /// Pre-amp gain, -24..24 dB. Stored under the long-standing `preampGain` key.
  final double preampDb;
  final bool tempoOn;

  /// Playback speed, 0.5..3.0.
  final double tempo;

  static const _kHeadroom = 'dspHeadroomDb';
  static const _kBalance = 'dspBalance';
  static const _kMono = 'dspMono';
  static const _kLimiter = 'limiterEnabled';
  static const _kPreamp = 'preampGain';
  static const _kTempoOn = 'dspTempoOn';
  static const _kTempo = 'dspTempo';

  /// Keys earlier versions wrote; any of them means the app was used before
  /// this headroom setting existed.
  static const _legacyKeys = [
    'appMode', 'selectedPreset', 'isShuffled', 'loopMode', 'replayGain',
    'dvcEnabled', 'limiterEnabled', 'eqBandCount', 'fancyMode',
    'visualizerStyle', 'lastOutputDevice',
  ];

  static double normHeadroom(double v) =>
      (v.clamp(-10.0, 0.0) * 2).round() / 2;

  static double normBalance(double v) {
    final c = v.clamp(-1.0, 1.0).toDouble();
    return c.abs() <= 0.02 + 1e-9 ? 0.0 : c;
  }

  static double normPreamp(double v) => v.clamp(-24.0, 24.0).toDouble();

  static double normTempo(double v) {
    final c = v.clamp(0.5, 3.0).toDouble();
    return (c - 1.0).abs() <= 0.02 + 1e-9 ? 1.0 : c;
  }

  /// Headroom that stands in for the auto-gain earlier versions applied.
  ///
  /// Auto-gain lowered the input by the largest positive gain among the EQ
  /// curves and the tone shelves. Without it an existing install with boosts
  /// would come out louder and clip, so the first headroom is minus that peak
  /// (the stored preamp does not count: it was always applied as-is), snapped to 0.5 dB and clamped
  /// to -10..0. No boost gives 0.
  static double headroomFromBoost(SharedPreferences prefs) {
    var peak = 0.0;
    void take(num? v) {
      if (v != null && v > peak) peak = v.toDouble();
    }

    // The EQ curves count while the EQ is on, the shelves while tone is on.
    if (prefs.getBool('graphicEqEnabled') ?? false) {
      final graphic = prefs.getString('graphicBandGains');
      if (graphic != null) {
        try {
          for (final g in json.decode(graphic) as List) {
            take(g as num);
          }
        } catch (_) {}
      }
      final parametric = prefs.getString('parametricPoints');
      if (parametric != null) {
        try {
          for (final p in json.decode(parametric) as List) {
            final m = p as Map<String, dynamic>;
            if (m['enabled'] as bool? ?? true) take(m['gain'] as num?);
          }
        } catch (_) {}
      }
    }
    if (prefs.getBool('toneEnabled') ?? false) {
      take(prefs.getDouble('bassGain'));
      take(prefs.getDouble('trebleGain'));
    }
    return normHeadroom(-peak);
  }

  /// Reads the settings. An absent headroom defaults, on installs that predate
  /// it, to minus the old auto-gain amount ([headroomFromBoost]) so an update
  /// never makes users louder or clipped; on a fresh install to 0 on iOS and
  /// -6 dB on Android.
  static DspCoreSettings load(SharedPreferences prefs, {required bool isIos}) {
    final existingInstall = isExistingInstall(prefs);
    final defaultHeadroom = existingInstall
        ? headroomFromBoost(prefs)
        : (isIos ? 0.0 : -6.0);
    return DspCoreSettings(
      headroomDb: normHeadroom(prefs.getDouble(_kHeadroom) ?? defaultHeadroom),
      balance: normBalance(prefs.getDouble(_kBalance) ?? 0.0),
      mono: prefs.getBool(_kMono) ?? false,
      limiter: prefs.getBool(_kLimiter) ?? true,
      preampDb: normPreamp(prefs.getDouble(_kPreamp) ?? 0.0),
      tempoOn: prefs.getBool(_kTempoOn) ?? false,
      tempo: normTempo(prefs.getDouble(_kTempo) ?? 1.0),
    );
  }

  Future<void> save(SharedPreferences prefs) async {
    await Future.wait([
      prefs.setDouble(_kHeadroom, headroomDb),
      prefs.setDouble(_kBalance, balance),
      prefs.setBool(_kMono, mono),
      prefs.setBool(_kLimiter, limiter),
      prefs.setDouble(_kPreamp, preampDb),
      prefs.setBool(_kTempoOn, tempoOn),
      prefs.setDouble(_kTempo, tempo),
    ]);
  }

  DspCoreSettings copyWith({
    double? headroomDb,
    double? balance,
    bool? mono,
    bool? limiter,
    double? preampDb,
    bool? tempoOn,
    double? tempo,
  }) => DspCoreSettings(
    headroomDb: normHeadroom(headroomDb ?? this.headroomDb),
    balance: normBalance(balance ?? this.balance),
    mono: mono ?? this.mono,
    limiter: limiter ?? this.limiter,
    preampDb: normPreamp(preampDb ?? this.preampDb),
    tempoOn: tempoOn ?? this.tempoOn,
    tempo: normTempo(tempo ?? this.tempo),
  );

  @override
  bool operator ==(Object other) =>
      other is DspCoreSettings &&
      other.headroomDb == headroomDb &&
      other.balance == balance &&
      other.mono == mono &&
      other.limiter == limiter &&
      other.preampDb == preampDb &&
      other.tempoOn == tempoOn &&
      other.tempo == tempo;

  @override
  int get hashCode => Object.hash(
    headroomDb, balance, mono, limiter, preampDb, tempoOn, tempo,
  );

  @override
  String toString() =>
      'DspCoreSettings(headroom $headroomDb, balance $balance, mono $mono, '
      'limiter $limiter, preamp $preampDb, tempo ${tempoOn ? tempo : "off"})';
}
