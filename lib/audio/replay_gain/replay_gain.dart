import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import 'rg_native_tags.dart';
import 'rg_tags.dart';

/// Whether, and how, a track's Replay Gain tags are applied.
enum ReplayGainMode {
  off("Don't apply"),
  apply('Apply gain'),
  applyPreventClipping('Apply gain, prevent clipping by peak');

  const ReplayGainMode(this.label);
  final String label;
}

/// Which tag set drives the gain: the album's or the track's own.
enum ReplayGainSource {
  album('Album'),
  track('Track');

  const ReplayGainSource(this.label);
  final String label;
}

const double kReplayGainPreampMinDb = -16.0;
const double kReplayGainPreampMaxDb = 16.0;

double _snap(double db) {
  if (db.isNaN) return 0.0;
  final clamped = db.clamp(kReplayGainPreampMinDb, kReplayGainPreampMaxDb);
  return (clamped * 10).round() / 10;
}

T _byName<T extends Enum>(List<T> values, String? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

/// The Replay Gain settings, saved in the preferences.
class ReplayGainSettings {
  ReplayGainSettings({
    this.mode = ReplayGainMode.off,
    this.source = ReplayGainSource.album,
    double preampDb = 0.0,
    double untaggedPreampDb = 0.0,
    this.limiterOn = true,
  }) : preampDb = _snap(preampDb),
       untaggedPreampDb = _snap(untaggedPreampDb);

  final ReplayGainMode mode;
  final ReplayGainSource source;

  /// Added to the tagged gain, dB (−16…+16, steps of 0.1).
  final double preampDb;

  /// The gain for a track with no usable tags, dB (−16…+16, steps of 0.1).
  final double untaggedPreampDb;

  /// Whether the output limiter is on — not a saved setting but the app's
  /// current state, carried here so [replayGainDb] can cap boosts by their
  /// peak when nothing downstream will catch an overshoot.
  final bool limiterOn;

  static const _kMode = 'rgMode';
  static const _kSource = 'rgSource';
  static const _kPreamp = 'rgPreampDb';
  static const _kUntagged = 'rgUntaggedPreampDb';
  static const _kLegacy = 'replayGain';

  ReplayGainSettings copyWith({
    ReplayGainMode? mode,
    ReplayGainSource? source,
    double? preampDb,
    double? untaggedPreampDb,
    bool? limiterOn,
  }) => ReplayGainSettings(
    mode: mode ?? this.mode,
    source: source ?? this.source,
    preampDb: preampDb ?? this.preampDb,
    untaggedPreampDb: untaggedPreampDb ?? this.untaggedPreampDb,
    limiterOn: limiterOn ?? this.limiterOn,
  );

  /// Reads the settings. The old on/off switch (`replayGain`) is honoured only
  /// while the new mode has never been saved: on meant apply, per track.
  static ReplayGainSettings load(SharedPreferences prefs) {
    var mode = ReplayGainMode.off;
    var source = ReplayGainSource.album;
    if (prefs.containsKey(_kMode)) {
      mode = _byName(ReplayGainMode.values, prefs.getString(_kMode), mode);
      source = _byName(
        ReplayGainSource.values,
        prefs.getString(_kSource),
        source,
      );
    } else if (prefs.getBool(_kLegacy) == true) {
      // The old switch could only turn songs down (its linear gain was capped
      // at unity), so carried-over users get the peak-capped mode: tagged
      // boosts never push a song past full scale.
      mode = ReplayGainMode.applyPreventClipping;
      source = ReplayGainSource.track;
    } else {
      source = _byName(
        ReplayGainSource.values,
        prefs.getString(_kSource),
        source,
      );
    }
    return ReplayGainSettings(
      mode: mode,
      source: source,
      preampDb: prefs.getDouble(_kPreamp) ?? 0.0,
      untaggedPreampDb: prefs.getDouble(_kUntagged) ?? 0.0,
    );
  }

  Future<void> save(SharedPreferences prefs) async {
    await prefs.setString(_kMode, mode.name);
    await prefs.setString(_kSource, source.name);
    await prefs.setDouble(_kPreamp, preampDb);
    await prefs.setDouble(_kUntagged, untaggedPreampDb);
  }

  @override
  bool operator ==(Object other) =>
      other is ReplayGainSettings &&
      other.mode == mode &&
      other.source == source &&
      other.preampDb == preampDb &&
      other.untaggedPreampDb == untaggedPreampDb &&
      other.limiterOn == limiterOn;

  @override
  int get hashCode => Object.hash(mode, source, preampDb, untaggedPreampDb, limiterOn);
}

/// The untagged preamp; with the limiter off a boost has no peak to be held
/// to, so it stops at 0 dB.
double untaggedGain(ReplayGainSettings s) =>
    !s.limiterOn && s.untaggedPreampDb > 0 ? 0.0 : s.untaggedPreampDb;

/// The gain, in dB, to give a track with [tags] under [s].
///
/// The chosen source's gain is used when the file has it, otherwise the other
/// one's; the peak comes from whichever gain was used. A file with no gain tag
/// gets the untagged preamp, which is never limited by a peak. With the output
/// limiter off ([ReplayGainSettings.limiterOn]) a positive result is capped at
/// the peak even in plain "Apply gain" (at 0 dB when there is no peak).
double replayGainDb(ReplayGainSettings s, ReplayGainTags? tags) {
  if (s.mode == ReplayGainMode.off) return 0.0;
  if (tags == null) return untaggedGain(s);

  final albumFirst = s.source == ReplayGainSource.album;
  double? gain;
  double? peak;
  if (albumFirst && tags.albumGainDb != null) {
    gain = tags.albumGainDb;
    peak = tags.albumPeak;
  } else if (tags.trackGainDb != null) {
    gain = tags.trackGainDb;
    peak = tags.trackPeak;
  } else if (tags.albumGainDb != null) {
    gain = tags.albumGainDb;
    peak = tags.albumPeak;
  }
  if (gain == null) return untaggedGain(s);

  var db = gain + s.preampDb;
  final peakCap = (peak != null && peak > 0)
      ? -20 * (math.log(peak) / math.ln10)
      : null;
  if (s.mode == ReplayGainMode.applyPreventClipping && peakCap != null) {
    db = math.min(db, peakCap);
  } else if (!s.limiterOn && db > 0) {
    // Nothing downstream catches an overshoot: a boost stops at the peak, and
    // with no peak known at unity.
    db = math.min(db, peakCap ?? 0.0);
  }
  return db;
}

/// The gain, in dB, for the track at [path] under [settings].
///
/// A local file (`/…`) is read with [read]; an iOS Music-library item
/// (`ipod-library://…`) is read by the platform with [readNative]. A stream, a
/// cloud track or a video id gets the untagged preamp without touching either.
/// A read that throws is treated as an untagged file.
Future<double> trackGainDbFor({
  required String path,
  required ReplayGainSettings settings,
  Future<ReplayGainTags> Function(String) read = readReplayGainTags,
  Future<ReplayGainTags> Function(String) readNative =
      readNativeReplayGainTags,
}) async {
  if (settings.mode == ReplayGainMode.off) return 0.0;
  final Future<ReplayGainTags> Function(String) reader;
  if (path.startsWith('/')) {
    reader = read;
  } else if (isNativeLibraryUri(path)) {
    reader = readNative;
  } else {
    return replayGainDb(settings, null);
  }
  try {
    return replayGainDb(settings, await reader(path));
  } catch (_) {
    return replayGainDb(settings, null);
  }
}

/// Whether a gain worked out for the track at [index] may still be applied,
/// after the tags were read.
///
/// Not if a newer request was made meanwhile ([requestNow] moved on), if
/// something else gave the player a gain ([gainSeqNow] moved on — a load), if
/// a queue player has since moved to another entry ([playerIndexNow] differs
/// from [index]; null when it is not a queue), or if the song at [index] is no
/// longer the one the gain was read for ([songStillMatches]).
bool shouldApplyGain({
  required int requestAtStart,
  required int requestNow,
  required int gainSeqAtStart,
  required int gainSeqNow,
  required int index,
  required int? playerIndexNow,
  required bool songStillMatches,
}) =>
    requestAtStart == requestNow &&
    gainSeqAtStart == gainSeqNow &&
    songStillMatches &&
    (playerIndexNow == null || playerIndexNow == index);

/// The queue index that plays after the current one, from just_audio's own
/// `nextIndex` (which already follows shuffle order and loop mode); null when
/// there is none or it is outside a queue of [length].
int? nextGaplessIndex({required int? playerNext, required int length}) {
  if (playerNext == null || playerNext < 0 || playerNext >= length) return null;
  return playerNext;
}
