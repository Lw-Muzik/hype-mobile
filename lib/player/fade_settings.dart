/// How and when Hype fades: between tracks, on a skip, on pause and on seek.
///
/// Ten settings: how tracks that end on their own meet, how a skip sounds, the
/// fades on play/pause/stop and seek, preloading and silence between tracks.
/// Everything here is plain data and pure decisions so the rules can be tested
/// without a player.
///
/// # Gapless is not a switch
///
/// Tracks always meet without a gap unless a fading mode says to blend them,
/// so there is no gapless on/off. Hype used to have a separate "Gapless
/// playback" switch that crossfade silently turned off; that switch is gone and
/// [usesGaplessQueue] decides instead.
library;

import 'package:shared_preferences/shared_preferences.dart';

/// The shortest fade there is, applied wherever Hype would otherwise cut: a
/// skip with fading off, a resume or a seek with their fades switched off,
/// the track left behind when a crossfade is interrupted. Nothing truly cuts.
const kDeclickMs = 20;

/// How long before an end-of-track crossfade is due the next track is opened.
///
/// A streamed track can take seconds to open; opened at the moment the fade
/// is due, it would start late. Opened early, both sides start together, on
/// time.
const kCrossfadePrepareLeadMs = 3000;

/// How a change of track sounds, worked out from the settings for one change.
class ChangeFade {
  const ChangeFade({
    required this.crossfadeMs,
    required this.earlyFadeOutMs,
    required this.fromSilenceMs,
  });

  /// A plain cut, declicked — for reloading what is already playing (a
  /// reorder, a change of loading path), which should not be heard at all.
  static const cut = ChangeFade(
    crossfadeMs: 0,
    earlyFadeOutMs: 0,
    fromSilenceMs: 0,
  );

  /// The overlap out of a track that is playing. Zero is a cut — declicked
  /// over [kDeclickMs] on both sides.
  final int crossfadeMs;

  /// The outgoing track starts fading the moment the change is asked for, at
  /// the rate of a full fade over this long, while the new track opens. Zero
  /// leaves it at full volume until the new one starts.
  final int earlyFadeOutMs;

  /// The fade in when nothing is playing to fade out of — a change while
  /// paused, which starts the new track the way a resume would.
  final int fromSilenceMs;
}

/// When a track that ends on its own crossfades into the next one.
enum AutoAdvanceFading {
  /// Never. Tracks meet gaplessly.
  none('No fading'),

  /// Everywhere except where the two tracks belong together — the next track
  /// of the same album — which keep meeting gaplessly. See [isGaplessPair].
  nonGapless('Non-gapless tracks'),

  /// Every track change.
  allSongs('All songs'),

  /// Only while shuffle is on. Album listening stays gapless; a shuffled mix,
  /// where neighbours never belonged together, blends.
  shuffledSongs('Shuffled songs');

  const AutoAdvanceFading(this.label);
  final String label;
}

/// How a track change the listener asked for — next, previous, a tap on a
/// song, a swipe of the card — sounds.
enum ManualChangeFading {
  /// A cut.
  none('No fading'),

  /// The old track fades out under the new one over [FadeSettings.shortCrossfadeMs].
  shortCrossfade('Short crossfade'),

  /// The same, over the full [FadeSettings.crossfadeMs].
  crossfade('Crossfade');

  const ManualChangeFading(this.label);
  final String label;
}

/// A range a length setting can take, and the step its slider moves in.
class FadeRange {
  const FadeRange(this.min, this.max, this.step, this.initial);
  final int min;
  final int max;
  final int step;
  final int initial;

  int clamp(int value) {
    final clamped = value.clamp(min, max);
    // Snapped to the step from [min], so a stored value always sits on the
    // slider's grid.
    return min + ((clamped - min) / step).round() * step;
  }
}

/// Defaults and ranges, all in milliseconds.
abstract final class FadeRanges {
  static const crossfade = FadeRange(100, 15000, 50, 5000);
  static const shortCrossfade = FadeRange(10, 1000, 10, 400);
  static const playPause = FadeRange(10, 1000, 10, 400);
  static const seek = FadeRange(10, 500, 10, 100);
  static const gaplessPreload = FadeRange(0, 5000, 100, 0);
  static const silence = FadeRange(0, 5000, 100, 0);
}

class FadeSettings {
  const FadeSettings({
    this.autoAdvance = AutoAdvanceFading.none,
    this.manualChange = ManualChangeFading.shortCrossfade,
    this.fadePlayPause = true,
    this.fadeSeek = true,
    this.gaplessPreloadMs = 0,
    this.silenceMs = 0,
    this.crossfadeMs = 5000,
    this.shortCrossfadeMs = 400,
    this.playPauseFadeMs = 400,
    this.seekFadeMs = 100,
  });

  final AutoAdvanceFading autoAdvance;
  final ManualChangeFading manualChange;
  final bool fadePlayPause;
  final bool fadeSeek;

  /// How far before the end of a track that is not crossfading the next one is
  /// opened, so it starts the moment this one ends. Only where Hype joins the
  /// tracks itself; a queue handed to the player whole is preloaded by the
  /// player.
  final int gaplessPreloadMs;

  /// Silence played after a track, before the next one starts. A crossfade
  /// fades over it.
  final int silenceMs;

  final int crossfadeMs;
  final int shortCrossfadeMs;
  final int playPauseFadeMs;
  final int seekFadeMs;

  /// The pause and stop fade-out — zero (an immediate pause) when switched
  /// off.
  int get playPauseMs => fadePlayPause ? playPauseFadeMs : 0;

  /// The fade in on play. Switched off, a resume still gets [kDeclickMs].
  int get resumeFadeMs => fadePlayPause ? playPauseFadeMs : kDeclickMs;

  /// The fade in after a seek. Switched off, still [kDeclickMs]. (With the
  /// switch on, a seek also fades out over [kDeclickMs] before it jumps.)
  int get seekFadeInMs => fadeSeek ? seekFadeMs : kDeclickMs;

  /// How a change the listener asked for sounds.
  ///
  /// * No fading — a cut, declicked: [kDeclickMs] out, [kDeclickMs] in.
  /// * Short crossfade — the two tracks overlap for [shortCrossfadeMs]. The
  ///   old one starts on its way out the moment the change is asked for, at
  ///   the play/pause fade's rate, while the new one opens.
  /// * Crossfade — the same over [crossfadeMs]. A new track shorter than the
  ///   crossfade plus a second gets a short crossfade instead.
  ChangeFade manualChangeFade({int? incomingDurationMs}) {
    var mode = manualChange;
    if (mode == ManualChangeFading.crossfade &&
        incomingDurationMs != null &&
        incomingDurationMs > 0 &&
        incomingDurationMs < crossfadeMs + 1000) {
      mode = ManualChangeFading.shortCrossfade;
    }
    return switch (mode) {
      ManualChangeFading.none => ChangeFade(
        crossfadeMs: 0,
        earlyFadeOutMs: 0,
        fromSilenceMs: resumeFadeMs,
      ),
      ManualChangeFading.shortCrossfade => ChangeFade(
        crossfadeMs: shortCrossfadeMs,
        earlyFadeOutMs: playPauseFadeMs,
        fromSilenceMs: resumeFadeMs,
      ),
      ManualChangeFading.crossfade => ChangeFade(
        crossfadeMs: crossfadeMs,
        earlyFadeOutMs: crossfadeMs,
        fromSilenceMs: resumeFadeMs,
      ),
    };
  }

  /// The fade for a track change the listener asked for.
  int get manualChangeMs => switch (manualChange) {
    ManualChangeFading.none => 0,
    ManualChangeFading.shortCrossfade => shortCrossfadeMs,
    ManualChangeFading.crossfade => crossfadeMs,
  };

  FadeSettings copyWith({
    AutoAdvanceFading? autoAdvance,
    ManualChangeFading? manualChange,
    bool? fadePlayPause,
    bool? fadeSeek,
    int? gaplessPreloadMs,
    int? silenceMs,
    int? crossfadeMs,
    int? shortCrossfadeMs,
    int? playPauseFadeMs,
    int? seekFadeMs,
  }) => FadeSettings(
    autoAdvance: autoAdvance ?? this.autoAdvance,
    manualChange: manualChange ?? this.manualChange,
    fadePlayPause: fadePlayPause ?? this.fadePlayPause,
    fadeSeek: fadeSeek ?? this.fadeSeek,
    gaplessPreloadMs: FadeRanges.gaplessPreload.clamp(
      gaplessPreloadMs ?? this.gaplessPreloadMs,
    ),
    silenceMs: FadeRanges.silence.clamp(silenceMs ?? this.silenceMs),
    crossfadeMs: FadeRanges.crossfade.clamp(crossfadeMs ?? this.crossfadeMs),
    shortCrossfadeMs: FadeRanges.shortCrossfade.clamp(
      shortCrossfadeMs ?? this.shortCrossfadeMs,
    ),
    playPauseFadeMs: FadeRanges.playPause.clamp(
      playPauseFadeMs ?? this.playPauseFadeMs,
    ),
    seekFadeMs: FadeRanges.seek.clamp(seekFadeMs ?? this.seekFadeMs),
  );

  // -- Persistence --

  static const _kAuto = 'crossfadeAutoAdvance';
  static const _kManual = 'fadeManualAdvance';
  static const _kPlayPause = 'fadePlayPause';
  static const _kSeek = 'fadeSeek';
  static const _kPreload = 'gaplessPreloadMs';
  static const _kSilence = 'trackEndSilenceMs';
  static const _kCrossfade = 'crossfadeLengthMs';
  static const _kShort = 'fadeShortCrossfadeMs';
  static const _kPlayPauseMs = 'fadePlayPauseMs';
  static const _kSeekMs = 'fadeSeekMs';

  /// The settings saved by an earlier version: a crossfade in whole seconds,
  /// zero meaning off.
  static const legacyCrossfadeSecondsKey = 'crossfadeDuration';

  static FadeSettings load(SharedPreferences prefs) {
    const d = FadeSettings();
    var auto = _enumAt(AutoAdvanceFading.values, prefs.getInt(_kAuto));
    var crossfade = prefs.getInt(_kCrossfade);
    if (auto == null) {
      // First run of this version. Someone who had crossfade on keeps it on,
      // at the length they chose (the ceiling is now 15 s, the old slider's
      // was 30 s), for every track — which is what the old setting did.
      final legacySeconds = prefs.getInt(legacyCrossfadeSecondsKey) ?? 0;
      if (legacySeconds > 0) {
        auto = AutoAdvanceFading.allSongs;
        crossfade ??= legacySeconds * 1000;
      }
    }
    return d.copyWith(
      autoAdvance: auto ?? d.autoAdvance,
      manualChange: _enumAt(ManualChangeFading.values, prefs.getInt(_kManual)),
      fadePlayPause: prefs.getBool(_kPlayPause),
      fadeSeek: prefs.getBool(_kSeek),
      gaplessPreloadMs: prefs.getInt(_kPreload),
      silenceMs: prefs.getInt(_kSilence),
      crossfadeMs: crossfade,
      shortCrossfadeMs: prefs.getInt(_kShort),
      playPauseFadeMs: prefs.getInt(_kPlayPauseMs),
      seekFadeMs: prefs.getInt(_kSeekMs),
    );
  }

  Future<void> save(SharedPreferences prefs) => Future.wait([
    prefs.setInt(_kAuto, autoAdvance.index),
    prefs.setInt(_kManual, manualChange.index),
    prefs.setBool(_kPlayPause, fadePlayPause),
    prefs.setBool(_kSeek, fadeSeek),
    prefs.setInt(_kPreload, gaplessPreloadMs),
    prefs.setInt(_kSilence, silenceMs),
    prefs.setInt(_kCrossfade, crossfadeMs),
    prefs.setInt(_kShort, shortCrossfadeMs),
    prefs.setInt(_kPlayPauseMs, playPauseFadeMs),
    prefs.setInt(_kSeekMs, seekFadeMs),
  ]);

  static T? _enumAt<T>(List<T> values, int? index) =>
      index != null && index >= 0 && index < values.length
      ? values[index]
      : null;

  @override
  bool operator ==(Object other) =>
      other is FadeSettings &&
      other.autoAdvance == autoAdvance &&
      other.manualChange == manualChange &&
      other.fadePlayPause == fadePlayPause &&
      other.fadeSeek == fadeSeek &&
      other.gaplessPreloadMs == gaplessPreloadMs &&
      other.silenceMs == silenceMs &&
      other.crossfadeMs == crossfadeMs &&
      other.shortCrossfadeMs == shortCrossfadeMs &&
      other.playPauseFadeMs == playPauseFadeMs &&
      other.seekFadeMs == seekFadeMs;

  @override
  int get hashCode => Object.hash(
    autoAdvance,
    manualChange,
    fadePlayPause,
    fadeSeek,
    gaplessPreloadMs,
    silenceMs,
    crossfadeMs,
    shortCrossfadeMs,
    playPauseFadeMs,
    seekFadeMs,
  );
}

/// What the fading rules need to know about a track.
class TrackRef {
  const TrackRef({this.album, this.albumId, this.track});

  final String? album;
  final int? albumId;

  /// The track number as the media store reports it. Android folds the disc
  /// in as `disc * 1000 + track`, which [isGaplessPair] relies on: the last
  /// track of disc one and the first of disc two are not consecutive.
  final int? track;
}

/// Whether [next] follows [current] on the same album, so the two were
/// recorded to run into each other and must not be crossfaded.
bool isGaplessPair(TrackRef current, TrackRef next) {
  final a = current.track, b = next.track;
  if (a == null || b == null || a <= 0 || b <= 0) return false;
  if (b != a + 1) return false;
  return _sameAlbum(current, next);
}

bool _sameAlbum(TrackRef a, TrackRef b) {
  final idA = a.albumId, idB = b.albumId;
  if (idA != null && idB != null && idA != 0 && idB != 0) return idA == idB;
  final nameA = _albumName(a.album), nameB = _albumName(b.album);
  return nameA != null && nameA == nameB;
}

/// An album name worth comparing — not empty, not a placeholder, and not the
/// artwork URL that streamed tracks keep in this field.
String? _albumName(String? album) {
  final name = album?.trim().toLowerCase();
  if (name == null || name.isEmpty) return null;
  if (name.startsWith('http')) return null;
  if (name == '<unknown>' || name == 'unknown' || name == 'unknown album') {
    return null;
  }
  return name;
}

/// The crossfade for the boundary between [current] and [next] when the
/// current track ends on its own, or zero for none.
///
/// [next] is null at the end of a queue that does not repeat.
int autoCrossfadeMs(
  FadeSettings settings, {
  required bool shuffled,
  required bool repeatOne,
  required TrackRef current,
  required TrackRef? next,
}) {
  // Repeat-one and a crossfade are contradictory instructions: the fade exists
  // to reach the *next* track, which is the one thing repeat-one says not to do.
  if (next == null || repeatOne) return 0;
  return switch (settings.autoAdvance) {
    AutoAdvanceFading.none => 0,
    AutoAdvanceFading.allSongs => settings.crossfadeMs,
    AutoAdvanceFading.shuffledSongs => shuffled ? settings.crossfadeMs : 0,
    AutoAdvanceFading.nonGapless =>
      isGaplessPair(current, next) ? 0 : settings.crossfadeMs,
  };
}

/// Whether the whole queue should be handed to one player, which joins tracks
/// without a gap, rather than loaded a track at a time.
///
/// True whenever most boundaries are gapless: no fading, non-gapless mode
/// (album runs stay gapless and only the boundaries between albums fade), and
/// shuffled mode while shuffle is off. A crossfade from inside the queue still
/// happens — the second player takes over the queue at the next track.
///
/// Silence between tracks needs the boundary to be Hype's rather than the
/// player's, so it always plays a track at a time.
bool usesGaplessQueue(FadeSettings settings, {required bool shuffled}) {
  if (settings.silenceMs > 0) return false;
  return switch (settings.autoAdvance) {
    AutoAdvanceFading.none || AutoAdvanceFading.nonGapless => true,
    AutoAdvanceFading.shuffledSongs => !shuffled,
    AutoAdvanceFading.allSongs => false,
  };
}
