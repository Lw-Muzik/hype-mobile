/// Settings → Direct Volume Control.
///
/// Four rows on Android: the enable switch, "No DVC for Bluetooth absolute
/// volume", "No DVC – preamp reduction" and the DVC volume. iOS has no DVC and
/// shows only the preamp reduction. Every label is also a search entry in
/// `kSettingsIndex`.
///
/// Both sliders hold their value while dragging and commit on release or on a
/// keyboard / accessibility step, so the engine is touched once, not per frame.
library;

import 'package:flutter/material.dart';

import '../audio/dvc/dvc_settings.dart';

class DvcSettingsSection extends StatelessWidget {
  const DvcSettingsSection({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.dvcEnabled,
    required this.onDvcEnabled,
    required this.dvcGainDb,
    required this.onDvcGainDb,
    required this.headroomDb,
    required this.onHeadroomDb,
    required this.isIos,
    this.dvcRunning,
  });

  final DvcSettings settings;
  final ValueChanged<DvcSettings> onChanged;
  final bool dvcEnabled;
  final ValueChanged<bool> onDvcEnabled;

  /// The DVC level, -30..0 dB (shown as 0..100 %).
  final double dvcGainDb;
  final ValueChanged<double> onDvcGainDb;

  /// "No DVC – preamp reduction", -10..0 dB.
  final double headroomDb;
  final ValueChanged<double> onHeadroomDb;
  final bool isIos;

  /// Whether DVC is actually running now (it can be suspended by system-wide
  /// mode or a Bluetooth route); the preamp reduction applies when it is not.
  /// Defaults to [dvcEnabled].
  final bool? dvcRunning;

  /// The labels this section shows, for the settings search.
  static const labels = [
    'Enable direct volume control',
    'No DVC for Bluetooth absolute volume',
    'No DVC – preamp reduction',
    'Volume',
  ];

  /// The rows iOS does not have.
  static const androidOnlyLabels = [
    'Enable direct volume control',
    'No DVC for Bluetooth absolute volume',
    'Volume',
  ];

  @override
  Widget build(BuildContext context) {
    final running = dvcRunning ?? dvcEnabled;
    const divider = Divider(height: 1, indent: 16, endIndent: 16);
    final preamp = Opacity(
      opacity: running ? 0.5 : 1.0,
      child: _CommitSlider(
        title: labels[2],
        subtitle: running
            ? 'Not used while direct volume control is on'
            : 'Lowers the level before effects so boosts do not clip',
        value: headroomDb,
        min: -10,
        max: 0,
        step: 0.5,
        format: (v) => '${v.toStringAsFixed(1)} dB',
        enabled: !running,
        onCommit: onHeadroomDb,
      ),
    );
    if (isIos) return preamp;
    final percent = ((dvcGainDb + 30) / 30 * 100).clamp(0.0, 100.0);
    return Column(
      children: [
        SwitchListTile(
          title: Text(labels[0]),
          subtitle: const Text(
            'The volume buttons set the app\'s own level; the phone stays at full',
          ),
          value: dvcEnabled,
          onChanged: onDvcEnabled,
        ),
        divider,
        SwitchListTile(
          title: Text(labels[1]),
          subtitle: const Text(
            'Bluetooth headsets with absolute volume keep their own level',
          ),
          value: settings.noDvcForBluetoothAbsoluteVolume,
          onChanged: (v) =>
              onChanged(settings.copyWith(noDvcForBluetoothAbsoluteVolume: v)),
        ),
        divider,
        preamp,
        divider,
        _CommitSlider(
          title: labels[3],
          subtitle: 'The level direct volume control plays at',
          value: percent,
          min: 0,
          max: 100,
          step: 1,
          format: (v) => '${v.round()} %',
          enabled: dvcEnabled,
          onCommit: (p) => onDvcGainDb(p / 100 * 30 - 30),
        ),
      ],
    );
  }
}

/// A stepped slider that holds its value while dragging and commits once, on
/// release or for a step with no drag around it (keyboard, accessibility).
class _CommitSlider extends StatefulWidget {
  const _CommitSlider({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.format,
    required this.onCommit,
    this.enabled = true,
  });

  final String title;
  final String subtitle;
  final double value;
  final double min;
  final double max;
  final double step;
  final String Function(double) format;
  final ValueChanged<double> onCommit;
  final bool enabled;

  @override
  State<_CommitSlider> createState() => _CommitSliderState();
}

class _CommitSliderState extends State<_CommitSlider> {
  double? _dragging;
  bool _active = false;

  @override
  void didUpdateWidget(_CommitSlider old) {
    super.didUpdateWidget(old);
    if (!widget.enabled) _active = false;
    if (_dragging != null &&
        (!widget.enabled || (old.value != widget.value && !_active))) {
      _dragging = null;
    }
  }

  double _snap(double v) =>
      ((v / widget.step).round() * widget.step).clamp(widget.min, widget.max);

  void _commit(double v) {
    final c = _snap(v);
    if ((c - widget.value).abs() > 1e-9) widget.onCommit(c);
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
                widget.format(shown),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: widget.enabled
                      ? Theme.of(context).colorScheme.primary
                      : muted,
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
            value: shown.clamp(widget.min, widget.max),
            min: widget.min,
            max: widget.max,
            divisions: ((widget.max - widget.min) / widget.step).round(),
            onChangeStart: widget.enabled ? (_) => _active = true : null,
            onChanged: widget.enabled
                ? (v) {
                    if (_active) {
                      setState(() => _dragging = _snap(v));
                    } else {
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
