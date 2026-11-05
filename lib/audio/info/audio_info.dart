/// What the Audio Info page says about the signal chain: the stages that are
/// doing something right now, in the order the engine runs them.
///
/// The order mirrors `RoomDSPEngine::process()` (room_dsp_engine.cpp):
/// stems, input gain (track/Replay Gain + preamp + headroom + speaker preamp),
/// speaker EQ, graphic EQ, parametric EQ, tone, MBC, crossfeed, surround,
/// reverb, master volume, stereo expand, mono, balance, limiter.
library;

import '../replay_gain/rg_native_tags.dart';
import '../replay_gain/rg_tags.dart';

/// One active stage with its key values.
class InfoStage {
  const InfoStage(this.id, this.title, this.value);

  /// Stable key (tests, widget keys).
  final String id;
  final String title;
  final String value;

  @override
  String toString() => '$id: $value';
}

/// Which tag set a Replay Gain value came from.
enum RgTagSource {
  album('album'),
  track('track'),
  untagged('untagged preamp');

  const RgTagSource(this.label);
  final String label;
}

/// "+1.5 dB" / "-3 dB" / "0 dB": one decimal, trailing ".0" dropped.
String fmtDb(double db) {
  var s = db.abs().toStringAsFixed(1);
  if (s.endsWith('.0')) s = s.substring(0, s.length - 2);
  final neg = s != '0' && db < 0;
  final sign = neg ? '-' : (s != '0' && db > 0 ? '+' : '');
  return '$sign$s dB';
}

String _hz(double hz) =>
    hz >= 1000 ? '${(hz / 1000).toStringAsFixed(hz % 1000 == 0 ? 0 : 1)} kHz' : '${hz.round()} Hz';

/// The Replay Gain line: dB and where it came from, or null when it is off
/// (or the page is in Equalizer-only mode).
String? describeReplayGain({
  required bool enabled,
  required double db,
  RgTagSource? source,
  String preferred = 'album',
}) {
  if (!enabled) return null;
  final from = source == null ? '$preferred preferred' : source.label;
  return 'Replay Gain ${fmtDb(db)} ($from)';
}

/// The headroom the engine actually applies: none while Direct Volume Control
/// runs (the user's level governs loudness) or on an output set to "No
/// headroom gain reduction". Mirrors `headroomFor` in the controller.
double effectiveHeadroomDb({
  required double headroomDb,
  required bool dvcRunning,
  required bool noHeadroomReduction,
}) => (dvcRunning || noHeadroomReduction) ? 0.0 : headroomDb;

/// The active stages, in the engine's chain order. Plain values in, so the
/// page and the tests feed it the same way. Values must be the EFFECTIVE ones
/// (see [effectiveHeadroomDb]); [noEqTone] is the active output's "No
/// Equalizer/Tone", which keeps graphic EQ and tone out of the signal.
///
/// [eqOnly] is Equalizer-only mode: the DSP part only, so no Replay Gain.
/// [systemWide] is Android's all-apps equalizer: the system applies the bands,
/// preamp, headroom, tone and limiter to every app (one "System equalizer"
/// stage), while Hype's own engine holds its graphic EQ, tone, preamp,
/// headroom, Replay Gain, balance, mono and stereo expand neutral. With
/// [eqOnly] too, only the system stage is listed: the part that reaches
/// other apps.
List<InfoStage> describeChain({
  bool eqOnly = false,
  bool systemWide = false,
  bool noEqTone = false,
  bool stemsActive = false,
  bool replayGainEnabled = false,
  double replayGainDb = 0,
  RgTagSource? replayGainSource,
  String replayGainPreferred = 'album',
  double headroomDb = 0,
  double preampDb = 0,
  bool graphicEqEnabled = false,
  int eqBandCount = 0,
  String eqPreset = '',
  int parametricPoints = 0,
  bool speakerEqEnabled = false,
  String? speakerProfile,
  double speakerPreampDb = 0,
  bool toneEnabled = false,
  double bassDb = 0,
  double trebleDb = 0,
  bool mbcEnabled = false,
  bool crossfeedEnabled = false,
  double crossfeedCutoffHz = 700,
  double crossfeedFeedDb = 4.5,
  bool surroundEnabled = false,
  double surroundIntensity = 0,
  bool reverbEnabled = false,
  String reverbPreset = '',
  bool dvcRunning = false,
  double dvcGainDb = 0,
  double stereoExpand = 0,
  bool mono = false,
  double balance = 0,
  bool limiterEnabled = false,
  double limiterReductionDb = 0,
}) {
  final out = <InfoStage>[];
  final graphicOn = graphicEqEnabled && !noEqTone;
  final toneOn = toneEnabled && !noEqTone && (bassDb != 0 || trebleDb != 0);

  if (systemWide) {
    final sys = <String>[];
    if (graphicOn) sys.add('$eqBandCount bands');
    if (graphicOn && preampDb != 0) sys.add('Preamp ${fmtDb(preampDb)}');
    if (headroomDb != 0) sys.add('Headroom ${fmtDb(headroomDb)}');
    if (toneOn) {
      sys.add('Bass ${fmtDb(bassDb)} · Treble ${fmtDb(trebleDb)}');
    }
    if (limiterEnabled) sys.add('Limiter');
    if (sys.isNotEmpty) {
      out.add(InfoStage('system', 'System equalizer (all apps)', sys.join(' · ')));
    }
    if (eqOnly) return out;
  }

  if (stemsActive) out.add(const InfoStage('stems', 'Stems', 'Live split'));

  // Input gain: its parts in the order they stack. The user preamp applies
  // while the graphic EQ or the speaker EQ is on (engine processEqStage).
  final parts = <String>[];
  if (!eqOnly && !systemWide) {
    final rg = describeReplayGain(
      enabled: replayGainEnabled,
      db: replayGainDb,
      source: replayGainSource,
      preferred: replayGainPreferred,
    );
    if (rg != null) parts.add(rg);
  }
  if (!systemWide && (graphicOn || speakerEqEnabled) && preampDb != 0) {
    parts.add('Preamp ${fmtDb(preampDb)}');
  }
  if (!systemWide && headroomDb != 0) {
    parts.add('Headroom ${fmtDb(headroomDb)}');
  }
  if (speakerEqEnabled && speakerPreampDb != 0) {
    parts.add('Speaker preamp ${fmtDb(speakerPreampDb)}');
  }
  if (parts.isNotEmpty) out.add(InfoStage('input', 'Input gain', parts.join(' · ')));

  if (speakerEqEnabled) {
    final name = (speakerProfile == null || speakerProfile.isEmpty)
        ? 'On'
        : speakerProfile;
    out.add(InfoStage(
      'speaker',
      'Speaker EQ',
      speakerPreampDb != 0 ? '$name · preamp ${fmtDb(speakerPreampDb)}' : name,
    ));
  }
  if (graphicOn && !systemWide) {
    final preset = eqPreset.isEmpty ? '' : ' · $eqPreset';
    out.add(InfoStage('graphic', 'Graphic EQ', '$eqBandCount bands$preset'));
  }
  // The parametric EQ keeps running for Hype's own playback system-wide too.
  if (graphicOn && parametricPoints > 0) {
    out.add(InfoStage(
      'parametric',
      'Parametric EQ',
      '$parametricPoints ${parametricPoints == 1 ? 'point' : 'points'}',
    ));
  }
  if (toneOn && !systemWide) {
    out.add(InfoStage('tone', 'Tone', 'Bass ${fmtDb(bassDb)} · Treble ${fmtDb(trebleDb)}'));
  }
  if (mbcEnabled) out.add(const InfoStage('mbc', 'Multiband compressor', 'On'));
  if (crossfeedEnabled) {
    out.add(InfoStage(
      'crossfeed',
      'Crossfeed',
      '${_hz(crossfeedCutoffHz)} · ${fmtDb(crossfeedFeedDb)}',
    ));
  }
  if (surroundEnabled) {
    out.add(InfoStage(
      'surround',
      '3D surround',
      '${(surroundIntensity * 100).round()}%',
    ));
  }
  if (reverbEnabled) {
    out.add(InfoStage('reverb', 'Reverb', reverbPreset.isEmpty ? 'On' : reverbPreset));
  }
  if (dvcRunning) {
    out.add(InfoStage('master', 'Master volume', fmtDb(dvcGainDb)));
  }
  if (stereoExpand > 0 && !systemWide) {
    out.add(InfoStage('expand', 'Stereo expand', '${(stereoExpand * 100).round()}%'));
  }
  if (mono && !systemWide) out.add(const InfoStage('mono', 'Mono', 'On'));
  if (balance != 0 && !systemWide) {
    final pct = (balance.abs() * 100).round();
    out.add(InfoStage('balance', 'Balance', '${balance < 0 ? 'Left' : 'Right'} $pct%'));
  }
  if (limiterEnabled) {
    out.add(InfoStage(
      'limiter',
      'Limiter',
      limiterReductionDb > 0.05
          ? 'reducing ${limiterReductionDb.toStringAsFixed(1)} dB'
          : 'On',
    ));
  }
  return out;
}

/// The Source section's rows from a `getAudioInfo` map; missing keys are
/// skipped. Null map gives an empty list.
List<InfoStage> describeSource(Map<String, dynamic>? info, {String? path}) {
  if (info == null) return const [];
  final out = <InfoStage>[];
  final native = info['codec'];
  final codec = (native is String && native.isNotEmpty)
      ? native
      : codecFromPath(path);
  if (codec != null) out.add(InfoStage('codec', 'Codec', codec));
  final pcm = info['pcm'];
  if (pcm is String && pcm.isNotEmpty) {
    out.add(InfoStage('pcm', 'Decoded format', pcm));
  }
  final sr = info['sampleRate'];
  if (sr is num && sr > 0) {
    final khz = sr / 1000;
    out.add(InfoStage('rate', 'Sample rate',
        '${khz.toStringAsFixed(khz % 1 == 0 ? 0 : 1)} kHz'));
  }
  final ch = info['channels'];
  if (ch is num && ch > 0) {
    out.add(InfoStage('channels', 'Channels',
        ch == 1 ? 'Mono' : ch == 2 ? 'Stereo' : '${ch.toInt()}'));
  }
  final br = info['bitrate'];
  if (br is num && br > 0) {
    out.add(InfoStage('bitrate', 'Bitrate', '${(br / 1000).round()} kbps'));
  }
  return out;
}

/// Which tag set `replayGainDb` used for [tags] when [albumFirst] is set:
/// the album's if preferred and present, else the track's, else the album's
/// as a last resort, else the untagged preamp.
RgTagSource rgSourceOf({
  required bool albumFirst,
  required double? albumGainDb,
  required double? trackGainDb,
}) {
  if (albumFirst && albumGainDb != null) return RgTagSource.album;
  if (trackGainDb != null) return RgTagSource.track;
  if (albumGainDb != null) return RgTagSource.album;
  return RgTagSource.untagged;
}

/// Which tag set the gain for [path] came from, read the way `trackGainDbFor`
/// routes: a file path with [read], an iOS Music-library URI with
/// [readNative]; anything else (stream, cloud, video) is untagged.
Future<RgTagSource> resolveRgSource({
  required String path,
  required bool albumFirst,
  required Future<ReplayGainTags> Function(String) read,
  required Future<ReplayGainTags> Function(String) readNative,
}) async {
  final Future<ReplayGainTags> Function(String) reader;
  if (path.startsWith('/')) {
    reader = read;
  } else if (isNativeLibraryUri(path)) {
    reader = readNative;
  } else {
    return RgTagSource.untagged;
  }
  try {
    final t = await reader(path);
    return rgSourceOf(
      albumFirst: albumFirst,
      albumGainDb: t.albumGainDb,
      trackGainDb: t.trackGainDb,
    );
  } catch (_) {
    return RgTagSource.untagged;
  }
}

/// A codec label from a local file's extension; null when unknown. ".m4a"
/// could be AAC or ALAC, so it reads "M4A".
String? codecFromPath(String? path) {
  if (path == null || !path.startsWith('/')) return null;
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot < path.lastIndexOf('/')) return null;
  return switch (path.substring(dot + 1).toLowerCase()) {
    'mp3' => 'MP3',
    'flac' => 'FLAC',
    'm4a' || 'mp4' => 'M4A',
    'aac' => 'AAC',
    'ogg' || 'oga' => 'Ogg Vorbis',
    'opus' => 'Opus',
    'wav' => 'WAV',
    _ => null,
  };
}
