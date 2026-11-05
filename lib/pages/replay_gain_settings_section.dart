/// Settings → Playback → Replay Gain.
///
/// Four controls: whether (and how) tags are applied, which tag set drives it,
/// and two preamps. Source and the preamps stay visible but dimmed while the
/// mode is off. Every label here is also a search entry in `kSettingsIndex`;
/// the widget test for this file checks that the two agree.
///
/// A non-null `disabledReason` (system-wide equalizer mode, where the platform
/// equalizer cannot carry track gain) disables every control and shows the
/// reason; the stored settings are untouched.
library;

import 'package:flutter/material.dart';

import '../audio/replay_gain/replay_gain.dart';

class ReplayGainSettingsSection extends StatelessWidget {
  const ReplayGainSettingsSection({
    super.key,
    required this.settings,
    required this.onChanged,
    this.disabledReason,
  });

  final ReplayGainSettings settings;
  final ValueChanged<ReplayGainSettings> onChanged;
  final String? disabledReason;

  /// The labels this section shows, for the settings search.
  static const labels = [
    'Replay Gain',
    'Source',
    'RG preamp',
    'Preamp for songs without RG info',
  ];

  @override
  Widget build(BuildContext context) {
    final s = settings;
    final reason = disabledReason;
    final locked = reason != null;
    final active = s.mode != ReplayGainMode.off && !locked;
    return Column(
      children: [
        if (locked)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                reason,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface
                      .withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
        _ChoiceTile<ReplayGainMode>(
          title: labels[0],
          value: s.mode,
          values: ReplayGainMode.values,
          labelOf: (v) => v.label,
          describe: _describeMode,
          enabled: !locked,
          onChanged: (v) => onChanged(s.copyWith(mode: v)),
        ),
        _divider,
        _ChoiceTile<ReplayGainSource>(
          title: labels[1],
          value: s.source,
          values: ReplayGainSource.values,
          labelOf: (v) => v.label,
          describe: _describeSource,
          enabled: active,
          onChanged: (v) => onChanged(s.copyWith(source: v)),
        ),
        _divider,
        _DbSlider(
          title: labels[2],
          subtitle: 'Added to the gain from the file\'s tags',
          value: s.preampDb,
          enabled: active,
          onChanged: (v) => onChanged(s.copyWith(preampDb: v)),
        ),
        _divider,
        _DbSlider(
          title: labels[3],
          subtitle: 'Used when a file has no Replay Gain tags',
          value: s.untaggedPreampDb,
          enabled: active,
          onChanged: (v) => onChanged(s.copyWith(untaggedPreampDb: v)),
        ),
      ],
    );
  }

  static String _describeMode(ReplayGainMode v) => switch (v) {
    ReplayGainMode.off => 'Songs play at their own volume',
    ReplayGainMode.apply => 'Even out volume using the file\'s tags',
    ReplayGainMode.applyPreventClipping =>
      'Even out volume, but never louder than the peak allows',
  };

  static String _describeSource(ReplayGainSource v) => switch (v) {
    ReplayGainSource.album =>
      'Keep an album\'s loudness balance between its tracks',
    ReplayGainSource.track => 'Level every track on its own',
  };

  static const _divider = Divider(height: 1, indent: 16, endIndent: 16);
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
    this.enabled = true,
  });

  final String title;
  final T value;
  final List<T> values;
  final String Function(T) labelOf;
  final String Function(T) describe;
  final ValueChanged<T> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      enabled: enabled,
      title: Text(title),
      subtitle: Text(labelOf(value)),
      trailing: const Icon(Icons.unfold_more_rounded, size: 20),
      onTap: enabled ? () => _open(context) : null,
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

/// A gain in dB, −16.0…+16.0 in 0.1 steps, shown as `%.1f dB`.
///
/// Holds its own value while dragging and commits on release, so playback
/// re-applies the gain once, not on every frame of a drag. Values within
/// 0.25 dB of the centre snap to exactly 0.
class _DbSlider extends StatefulWidget {
  const _DbSlider({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String title;
  final String subtitle;
  final double value;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  State<_DbSlider> createState() => _DbSliderState();
}

class _DbSliderState extends State<_DbSlider> {
  double? _dragging;

  @override
  void didUpdateWidget(_DbSlider old) {
    super.didUpdateWidget(old);
    // Disabled mid-drag: onChangeEnd never comes, so end the drag here or the
    // next keyboard step after re-enabling would never commit.
    if (!widget.enabled) _active = false;
    // A disabled slider, or a new value arriving while nothing is being
    // dragged, must not leave a stale drag value on screen.
    if (_dragging != null &&
        (!widget.enabled || (old.value != widget.value && !_active))) {
      _dragging = null;
    }
  }

  bool _active = false;

  void _commit(double v) {
    final committed = _snap(v);
    if (committed != widget.value) widget.onChanged(committed);
  }

  /// Rounds to 0.1 and pulls values near the centre onto 0. A single 0.1 step
  /// from the current value (keyboard, accessibility) is never pulled, or the
  /// preamp could not be nudged off 0.
  double _snap(double v) {
    final r = (v * 10).round() / 10;
    final oneStep = (r - widget.value).abs() < 0.15;
    return r.abs() < 0.25 && !oneStep ? 0.0 : r;
  }

  @override
  Widget build(BuildContext context) {
    final shown = _dragging ?? widget.value;
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
                '${shown.toStringAsFixed(1)} dB',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: widget.enabled
                      ? Theme.of(context).colorScheme.primary
                      : muted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              widget.subtitle,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: muted),
            ),
          ),
          Slider.adaptive(
            value: shown.clamp(kReplayGainPreampMinDb, kReplayGainPreampMaxDb),
            min: kReplayGainPreampMinDb,
            max: kReplayGainPreampMaxDb,
            divisions: 320,
            onChangeStart: widget.enabled
                ? (_) => _active = true
                : null,
            onChanged: widget.enabled
                ? (v) {
                    if (_active) {
                      setState(() => _dragging = _snap(v));
                    } else {
                      // A change with no drag around it: commit now.
                      _commit(v);
                    }
                  }
                : null,
            onChangeEnd: widget.enabled
                ? (v) {
                    _active = false;
                    setState(() => _dragging = null);
                    _commit(v);
                  }
                : null,
          ),
        ],
      ),
    );
  }
}
