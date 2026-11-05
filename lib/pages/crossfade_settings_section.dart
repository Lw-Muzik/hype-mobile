/// Settings → Crossfade & Gapless.
///
/// Ten controls — how tracks meet, how a skip, a pause and a seek sound — with
/// the defaults and ranges in `lib/player/fade_settings.dart`, laid out in the
/// same cards as the rest of Hype's settings.
///
/// Every label shown here is also a search entry in `kSettingsIndex`; the
/// widget test for this file checks that the two agree.
library;

import 'package:flutter/material.dart';

import '../player/fade_settings.dart';

class CrossfadeSettingsSection extends StatelessWidget {
  const CrossfadeSettingsSection({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final FadeSettings settings;
  final ValueChanged<FadeSettings> onChanged;

  /// The labels this page shows, for the settings search.
  static const labels = [
    'Auto-advance fading',
    'Manual track change fading',
    'Crossfade length',
    'Short crossfade length',
    'Fade play/pause/stop',
    'Play/pause/stop fade length',
    'Fade on seek',
    'Seek fade length',
    'Preload gapless tracks',
    'Silence between tracks',
  ];

  FadeSettings get _s => settings;
  void _set(FadeSettings value) => onChanged(value);

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context, Icons.compare_arrows_rounded, 'Crossfade'),
        _card(context, [
          _ChoiceTile<AutoAdvanceFading>(
            title: 'Auto-advance fading',
            value: s.autoAdvance,
            values: AutoAdvanceFading.values,
            labelOf: (v) => v.label,
            describe: _describeAuto,
            onChanged: (v) => _set(s.copyWith(autoAdvance: v)),
          ),
          _divider,
          _ChoiceTile<ManualChangeFading>(
            title: 'Manual track change fading',
            value: s.manualChange,
            values: ManualChangeFading.values,
            labelOf: (v) => v.label,
            describe: _describeManual,
            onChanged: (v) => _set(s.copyWith(manualChange: v)),
          ),
          _divider,
          _LengthSlider(
            title: 'Crossfade length',
            value: s.crossfadeMs,
            range: FadeRanges.crossfade,
            onChanged: (v) => _set(_s.copyWith(crossfadeMs: v)),
          ),
          _divider,
          _LengthSlider(
            title: 'Short crossfade length',
            value: s.shortCrossfadeMs,
            range: FadeRanges.shortCrossfade,
            onChanged: (v) => _set(_s.copyWith(shortCrossfadeMs: v)),
          ),
        ]),
        const SizedBox(height: 20),
        _header(context, Icons.graphic_eq_rounded, 'Fades'),
        _card(context, [
          SwitchListTile.adaptive(
            value: s.fadePlayPause,
            title: const Text('Fade play/pause/stop'),
            subtitle: const Text('Ease in and out instead of cutting'),
            onChanged: (v) => _set(s.copyWith(fadePlayPause: v)),
          ),
          _LengthSlider(
            title: 'Play/pause/stop fade length',
            value: s.playPauseFadeMs,
            range: FadeRanges.playPause,
            enabled: s.fadePlayPause,
            onChanged: (v) => _set(_s.copyWith(playPauseFadeMs: v)),
          ),
          _divider,
          SwitchListTile.adaptive(
            value: s.fadeSeek,
            title: const Text('Fade on seek'),
            subtitle: const Text(
              'Fade back in after jumping, so it never clicks',
            ),
            onChanged: (v) => _set(s.copyWith(fadeSeek: v)),
          ),
          _LengthSlider(
            title: 'Seek fade length',
            value: s.seekFadeMs,
            range: FadeRanges.seek,
            enabled: s.fadeSeek,
            onChanged: (v) => _set(_s.copyWith(seekFadeMs: v)),
          ),
        ]),
        const SizedBox(height: 20),
        _header(context, Icons.linear_scale_rounded, 'Gapless'),
        _card(context, [
          _LengthSlider(
            title: 'Preload gapless tracks',
            subtitle: 'Open the next track this early, so it starts on time',
            value: s.gaplessPreloadMs,
            range: FadeRanges.gaplessPreload,
            zeroLabel: 'Default',
            onChanged: (v) => _set(_s.copyWith(gaplessPreloadMs: v)),
          ),
          _divider,
          _LengthSlider(
            title: 'Silence between tracks',
            subtitle: 'A pause between tracks that are not crossfaded',
            value: s.silenceMs,
            range: FadeRanges.silence,
            zeroLabel: 'None',
            onChanged: (v) => _set(_s.copyWith(silenceMs: v)),
          ),
        ]),
      ],
    );
  }

  static String _describeAuto(AutoAdvanceFading v) => switch (v) {
    AutoAdvanceFading.none =>
      'Tracks run straight into each other, with no gap',
    AutoAdvanceFading.nonGapless =>
      'Crossfade, except between consecutive tracks of an album',
    AutoAdvanceFading.allSongs => 'Crossfade every time a track ends',
    AutoAdvanceFading.shuffledSongs => 'Crossfade only while shuffle is on',
  };

  static String _describeManual(ManualChangeFading v) => switch (v) {
    ManualChangeFading.none => 'Skipping cuts straight to the next track',
    ManualChangeFading.shortCrossfade =>
      'A quick blend, set by Short crossfade length',
    ManualChangeFading.crossfade => 'A full blend, set by Crossfade length',
  };

  static const _divider = Divider(height: 1, indent: 16, endIndent: 16);

  Widget _header(BuildContext context, IconData icon, String title) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: Theme.of(context).textTheme.labelLarge
                ?.copyWith(color: primary, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, List<Widget> children) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

/// Formats a length the way it reads best: milliseconds under a second,
/// seconds with one decimal above.
String formatFadeMs(int ms) {
  if (ms < 1000) return '$ms ms';
  // 5000 → "5 s", 5100 → "5.1 s", 5050 → "5.05 s".
  final seconds = (ms / 1000)
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'\.?0+$'), '');
  return '$seconds s';
}

/// A setting chosen from a short list: shows the choice, opens the list.
class _ChoiceTile<T> extends StatelessWidget {
  const _ChoiceTile({
    required this.title,
    required this.value,
    required this.values,
    required this.labelOf,
    required this.describe,
    required this.onChanged,
  });

  final String title;
  final T value;
  final List<T> values;
  final String Function(T) labelOf;
  final String Function(T) describe;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      subtitle: Text(labelOf(value)),
      trailing: const Icon(Icons.unfold_more_rounded, size: 20),
      onTap: () => _open(context),
    );
  }

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: RadioGroup<T>(
          groupValue: value,
          onChanged: (v) => Navigator.of(context).pop(v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              for (final v in values)
                RadioListTile<T>(
                  value: v,
                  title: Text(labelOf(v)),
                  subtitle: Text(describe(v)),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (picked != null && picked != value) onChanged(picked);
  }
}

/// A length in milliseconds, on its setting's range and step.
///
/// Holds its own value while dragging and commits on release: a commit can
/// move playback to the other way of loading tracks (silence between tracks
/// does), which must happen once, not on every frame of a drag.
class _LengthSlider extends StatefulWidget {
  const _LengthSlider({
    required this.title,
    required this.value,
    required this.range,
    required this.onChanged,
    this.subtitle,
    this.enabled = true,
    this.zeroLabel,
  });

  final String title;
  final String? subtitle;
  final int value;
  final FadeRange range;
  final bool enabled;

  /// What a value of zero reads as, where zero means something other than a
  /// length.
  final String? zeroLabel;
  final ValueChanged<int> onChanged;

  @override
  State<_LengthSlider> createState() => _LengthSliderState();
}

class _LengthSliderState extends State<_LengthSlider> {
  int? _dragging;

  @override
  Widget build(BuildContext context) {
    final range = widget.range;
    final shown = _dragging ?? widget.value;
    final label = shown == 0 && widget.zeroLabel != null
        ? widget.zeroLabel!
        : formatFadeMs(shown);
    final muted = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.5);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: Theme.of(context).textTheme.bodyLarge
                      ?.copyWith(color: widget.enabled ? null : muted),
                ),
              ),
              Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: widget.enabled
                      ? Theme.of(context).colorScheme.primary
                      : muted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (widget.subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                widget.subtitle!,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: muted),
              ),
            ),
          Slider.adaptive(
            value: shown.toDouble(),
            min: range.min.toDouble(),
            max: range.max.toDouble(),
            divisions: (range.max - range.min) ~/ range.step,
            onChanged: widget.enabled
                ? (v) => setState(() => _dragging = range.clamp(v.round()))
                : null,
            onChangeEnd: widget.enabled
                ? (v) {
                    final committed = range.clamp(v.round());
                    setState(() => _dragging = null);
                    if (committed != widget.value) widget.onChanged(committed);
                  }
                : null,
          ),
        ],
      ),
    );
  }
}
