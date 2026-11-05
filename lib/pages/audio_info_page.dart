import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart' show SongModel;
import 'package:provider/provider.dart';

import '../audio/headset/output_kind.dart';
import '../audio/info/audio_info.dart';
import '../audio/replay_gain/replay_gain.dart';
import '../audio/replay_gain/rg_native_tags.dart';
import '../audio/replay_gain/rg_tags.dart';
import '../audio/dsp_core.dart' show headroomFor;
import '../controllers/app_controller.dart';
import '../Helpers/Channel.dart';

/// Reads the engine's live numbers; null when there is no platform side.
typedef AudioInfoSource = Future<Map<String, dynamic>?> Function();

/// Everything the page shows that does not poll: built from the controller.
class AudioInfoData {
  const AudioInfoData({
    required this.processing,
    required this.systemWide,
    required this.eqOnly,
    required this.route,
    this.sourceKind,
    this.playing = true,
    this.sourcePath,
  });

  /// Local file path of the current song, for the codec label.
  final String? sourcePath;

  /// Whether audio is playing: a limiter reading is only live then.
  final bool playing;

  final List<InfoStage> processing;
  final bool systemWide;
  final bool eqOnly;

  /// "Speaker", "Wired headphones", "Bluetooth · Name"…
  final String route;

  /// File / stream / cloud / video; null when nothing is playing.
  final String? sourceKind;
}

String _routeLine(AppController app) {
  final r = app.activeOutputRoute;
  if (r == null) return 'Unknown';
  final label = switch (r.kind) {
    AudioOutputKind.speaker => 'Speaker',
    AudioOutputKind.wired => 'Wired headphones',
    AudioOutputKind.bluetooth => 'Bluetooth',
    AudioOutputKind.usb => 'USB audio',
    AudioOutputKind.other => 'Other output',
  };
  final n = r.deviceName;
  return (n == null || n.isEmpty) ? label : '$label · $n';
}

/// The read-only Audio Info page: Source, Processing and Output.
///
/// Reads the settings from [AppController]; polls the engine every 250 ms
/// (through [infoSource], which tests replace) only while it is on screen.
class AudioInfoPage extends StatefulWidget {
  const AudioInfoPage({super.key, this.infoSource});

  final AudioInfoSource? infoSource;

  @override
  State<AudioInfoPage> createState() => _AudioInfoPageState();
}

class _AudioInfoPageState extends State<AudioInfoPage> {
  RgTagSource? _rgSource;
  Object? _rgSubject;
  ReplayGainSource? _rgPref;
  bool _rgTried = false;

  /// Reads the tags again when the song or the Album/Track setting changes.
  Future<void> _readRgSource(AppController app, Object? subject) async {
    final pref = app.replayGainSettings.source;
    if (_rgTried && identical(subject, _rgSubject) && pref == _rgPref) return;
    _rgTried = true;
    _rgSubject = subject;
    _rgPref = pref;
    RgTagSource? found;
    if (subject is SongModel) {
      found = await resolveRgSource(
        path: subject.data,
        albumFirst: pref == ReplayGainSource.album,
        read: readReplayGainTags,
        readNative: readNativeReplayGainTags,
      );
    } else if (subject != null) {
      found = RgTagSource.untagged;
    }
    if (mounted && identical(subject, _rgSubject) && pref == _rgPref) {
      setState(() => _rgSource = found);
    }
  }

  AudioInfoData _build(AppController app) {
    final rg = app.replayGainSettings;
    final player = app.handler.player;
    final subject = app.handler.engineGainSubjectOf(player);
    if (rg.mode != ReplayGainMode.off) {
      unawaited(_readRgSource(app, subject));
    }
    final core = app.dspCore;
    final item = app.handler.mediaItem.value;
    final chain = describeChain(
      eqOnly: app.isEqMode,
      systemWide: app.systemWideActive,
      noEqTone: app.activeOutputProfile.noEqTone,
      replayGainEnabled: rg.mode != ReplayGainMode.off,
      replayGainDb: app.handler.engineTrackGainDbOf(player),
      replayGainSource: _rgSource,
      replayGainPreferred: rg.source.name,
      headroomDb: headroomFor(
        dvcActive: app.dvcRunning,
        headroomDb: app.activeOutputProfile.noHeadroomReduction
            ? 0.0
            : core.headroomDb,
      ),
      preampDb: core.preampDb,
      graphicEqEnabled: app.graphicEqEnabled,
      eqBandCount: app.eqCentres.length,
      eqPreset: app.activePresetName,
      parametricPoints: app.parametricPoints.where((p) => p.enabled).length,
      speakerEqEnabled: app.speakerEqEnabled,
      speakerProfile: app.activeSpeakerProfile,
      speakerPreampDb: [
        for (final p in app.speakerProfiles)
          if (p.name == app.activeSpeakerProfile) p.preamp,
      ].firstOrNull ?? 0,
      toneEnabled: app.toneEnabled,
      bassDb: app.bassGain,
      trebleDb: app.trebleGain,
      mbcEnabled: app.mbcEnabled,
      crossfeedEnabled: app.crossfeedEnabled,
      crossfeedCutoffHz: app.crossfeedCutoff,
      crossfeedFeedDb: app.crossfeedFeed,
      surroundEnabled: app.surround3dEnabled,
      surroundIntensity: app.surround3dIntensity,
      reverbEnabled: app.reverbEnabled,
      reverbPreset: app.activeRoomPresetName,
      dvcRunning: app.dvcRunning,
      dvcGainDb: app.dvcGain,
      stereoExpand: app.stereoExpand,
      mono: core.mono,
      balance: core.balance,
      limiterEnabled: core.limiter,
    );
    return AudioInfoData(
      processing: chain,
      systemWide: app.systemWideActive,
      eqOnly: app.isEqMode,
      route: _routeLine(app),
      sourceKind: _sourceKind(item),
      playing: player.playing,
      sourcePath: subject is SongModel ? subject.data : null,
    );
  }

  String? _sourceKind(MediaItem? item) {
    if (item == null) return null;
    final id = item.id;
    if (id.startsWith('http')) return 'Stream';
    return 'File';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final data = _build(app);
    final player = app.handler.player;
    return AudioInfoView(
      data: data,
      infoSource:
          widget.infoSource ?? () => Channel.getAudioInfo(player.playerId),
    );
  }
}

/// The page body: polls [infoSource] while mounted.
class AudioInfoView extends StatefulWidget {
  const AudioInfoView({
    super.key,
    required this.data,
    required this.infoSource,
    this.pollInterval = const Duration(milliseconds: 250),
  });

  final AudioInfoData data;
  final AudioInfoSource infoSource;
  final Duration pollInterval;

  @override
  State<AudioInfoView> createState() => _AudioInfoViewState();
}

class _AudioInfoViewState extends State<AudioInfoView>
    with WidgetsBindingObserver {
  Timer? _timer;
  Map<String, dynamic>? _info;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  void _start() {
    _timer?.cancel();
    _poll();
    _timer = Timer.periodic(widget.pollInterval, (_) => _poll());
  }

  /// No polling while the app is in the background.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_timer == null) _start();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _poll() async {
    if (_busy) return;
    _busy = true;
    try {
      final info = await widget.infoSource();
      if (mounted) setState(() => _info = info);
    } catch (_) {
      // No engine yet: keep the last reading.
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final source = [
      if (d.sourceKind != null) InfoStage('kind', 'Type', d.sourceKind!),
      ...describeSource(_info, path: d.sourcePath),
    ];
    final reduction = d.playing
        ? (_info?['limiterReductionDb'] as num?)?.toDouble() ?? 0
        : 0.0;
    final processing = [
      for (final s in d.processing)
        if (s.id == 'limiter')
          InfoStage(
            s.id,
            s.title,
            reduction > 0.05
                ? 'reducing ${reduction.toStringAsFixed(1)} dB'
                : 'On',
          )
        else
          s,
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Audio Info')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (!d.eqOnly) ...[
            _Section('Source', source, empty: 'Nothing playing'),
          ],
          _Section('Processing', processing, empty: 'No effects active'),
          if (d.systemWide && Platform.isAndroid)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'The equalizer applies to all apps. Some stages run in the '
                'system and are not shown here.',
              ),
            ),
          _Section('Output', [InfoStage('route', 'Route', d.route)]),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.rows, {this.empty});

  final String title;
  final List<InfoStage> rows;
  final String? empty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
          child: Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        if (rows.isEmpty && empty != null)
          Text(empty!, style: theme.textTheme.bodyMedium),
        for (final r in rows)
          Padding(
            key: ValueKey('info-${r.id}'),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 4, child: Text(r.title)),
                Expanded(
                  flex: 6,
                  child: Text(r.value, textAlign: TextAlign.end),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
