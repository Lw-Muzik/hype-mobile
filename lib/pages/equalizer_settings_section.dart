/// Settings → Equalizer.
///
/// How many bands the equalizer has and where they sit, the bass and treble
/// shelves, what the screen's value read-outs show, and the AutoEq headphone
/// suggestions. Defaults and ranges live in `lib/audio/eq/equalizer_settings.dart`.
///
/// Every label shown here is also a search entry in `kSettingsIndex`; the
/// widget test for this file checks that the two agree.
library;

import 'package:flutter/material.dart';

import '../audio/eq/eq_layout.dart';
import '../audio/eq/equalizer_settings.dart';

class EqualizerSettingsSection extends StatelessWidget {
  const EqualizerSettingsSection({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.onResetAutoEqSuggestions,
    required this.onRestorePresets,
  });

  final EqualizerSettings settings;
  final ValueChanged<EqualizerSettings> onChanged;
  final VoidCallback onResetAutoEqSuggestions;
  final VoidCallback onRestorePresets;

  /// The labels this page shows, for the settings search.
  static const labels = [
    'Number of bands',
    'Enable custom bands',
    'Custom number of bands',
    'First frequency',
    'Last frequency',
    'Bass frequency',
    'Bass Q',
    'Treble frequency',
    'Treble Q',
    'Equalizer values',
    'Tone values',
    'Auto save',
    'Smooth equalizer/tone gains',
    'Suggest AutoEq presets',
    'Reset disabled AutoEq suggestions',
    'Restore equalizer presets',
  ];

  void _set(EqualizerSettings value) => onChanged(value);

  @override
  Widget build(BuildContext context) {
    final s = settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context, Icons.equalizer_rounded, 'Bands'),
        _card(context, [
          _ChoiceTile<int>(
            title: 'Number of bands',
            value: s.bandCount,
            values: kStandardBandCounts,
            labelOf: bandCountLabel,
            enabled: !s.customBands,
            onChanged: (v) => _set(s.copyWith(bandCount: v)),
          ),
          _divider,
          SwitchListTile.adaptive(
            value: s.customBands,
            title: const Text('Enable custom bands'),
            subtitle: const Text('Pick any count from 5 to 32'),
            onChanged: (v) => _set(s.copyWith(customBands: v)),
          ),
          _ValueSlider(
            title: 'Custom number of bands',
            value: s.customCount.toDouble(),
            min: 5,
            max: 32,
            step: 1,
            enabled: s.customBands,
            format: (v) => '${v.round()}',
            onChanged: (v) => _set(s.copyWith(customCount: v.round())),
          ),
          _divider,
          _ValueSlider(
            title: 'First frequency',
            value: s.firstHz,
            min: 5,
            max: 200,
            step: 1,
            enabled: s.usesFirstLast,
            format: (v) => '${v.round()} Hz',
            onChanged: (v) => _set(s.copyWith(firstHz: v)),
          ),
          _ValueSlider(
            title: 'Last frequency',
            value: s.lastHz / 1000,
            min: 14,
            max: 20,
            step: 0.5,
            enabled: s.usesFirstLast,
            format: (v) => '${v.toStringAsFixed(1)} kHz',
            onChanged: (v) => _set(s.copyWith(lastHz: v * 1000)),
          ),
        ]),
        const SizedBox(height: 20),
        _header(context, Icons.tune_rounded, 'Bass and treble'),
        _card(context, [
          _ValueSlider(
            title: 'Bass frequency',
            value: s.bassFreq,
            min: 20,
            max: 250,
            step: 10,
            format: (v) => '${v.round()} Hz',
            onChanged: (v) => _set(s.copyWith(bassFreq: v)),
          ),
          _ValueSlider(
            title: 'Bass Q',
            value: s.bassQ,
            min: 0.1,
            max: 2.0,
            step: 0.05,
            format: (v) => v.toStringAsFixed(2),
            onChanged: (v) => _set(s.copyWith(bassQ: v)),
          ),
          _divider,
          _ValueSlider(
            title: 'Treble frequency',
            value: s.trebleFreq / 1000,
            min: 5,
            max: 15,
            step: 1,
            format: (v) => '${v.round()} kHz',
            onChanged: (v) => _set(s.copyWith(trebleFreq: v * 1000)),
          ),
          _ValueSlider(
            title: 'Treble Q',
            value: s.trebleQ,
            min: 0.1,
            max: 2.0,
            step: 0.05,
            format: (v) => v.toStringAsFixed(2),
            onChanged: (v) => _set(s.copyWith(trebleQ: v)),
          ),
        ]),
        const SizedBox(height: 20),
        _header(context, Icons.visibility_rounded, 'Screen'),
        _card(context, [
          _ChoiceTile<EqValueLabels>(
            title: 'Equalizer values',
            value: s.eqValues,
            values: EqValueLabels.values,
            labelOf: (v) => v.label,
            onChanged: (v) => _set(s.copyWith(eqValues: v)),
          ),
          _divider,
          _ChoiceTile<EqValueLabels>(
            title: 'Tone values',
            value: s.toneValues,
            values: EqValueLabels.values,
            labelOf: (v) => v.label,
            onChanged: (v) => _set(s.copyWith(toneValues: v)),
          ),
          _divider,
          SwitchListTile.adaptive(
            value: s.autoSave,
            title: const Text('Auto save'),
            subtitle: const Text('Keep edits to the selected preset'),
            onChanged: (v) => _set(s.copyWith(autoSave: v)),
          ),
          _divider,
          SwitchListTile.adaptive(
            value: s.smoothGains,
            title: const Text('Smooth equalizer/tone gains'),
            subtitle: const Text('Glide between settings instead of jumping'),
            onChanged: (v) => _set(s.copyWith(smoothGains: v)),
          ),
        ]),
        const SizedBox(height: 20),
        _header(context, Icons.headphones_rounded, 'Headphones'),
        _card(context, [
          SwitchListTile.adaptive(
            value: s.suggestAutoEq,
            title: const Text('Suggest AutoEq presets'),
            subtitle: const Text(
              'Offer a matching preset when headphones connect',
            ),
            onChanged: (v) => _set(s.copyWith(suggestAutoEq: v)),
          ),
          _divider,
          ListTile(
            title: const Text('Reset disabled AutoEq suggestions'),
            subtitle: const Text('Ask again for devices you said no to'),
            trailing: const Icon(Icons.restart_alt_rounded, size: 20),
            onTap: onResetAutoEqSuggestions,
          ),
        ]),
        const SizedBox(height: 20),
        _header(context, Icons.library_music_rounded, 'Presets'),
        _card(context, [
          ListTile(
            title: const Text('Restore equalizer presets'),
            subtitle: const Text('Bring back the factory presets'),
            trailing: const Icon(Icons.settings_backup_restore_rounded,
                size: 20),
            onTap: () => _confirmRestore(context),
          ),
        ]),
      ],
    );
  }

  Future<void> _confirmRestore(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore factory presets?'),
        content: const Text(
          'Every built-in preset goes back to its original curve. '
          'Presets you made are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (ok == true) onRestorePresets();
  }

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

/// A setting chosen from a short list: shows the choice, opens the list.
/// Dimmed (not hidden) and inert while [enabled] is false.
class _ChoiceTile<T> extends StatelessWidget {
  const _ChoiceTile({
    required this.title,
    required this.value,
    required this.values,
    required this.labelOf,
    required this.onChanged,
    this.enabled = true,
  });

  final String title;
  final T value;
  final List<T> values;
  final String Function(T) labelOf;
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
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
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
                  RadioListTile<T>(value: v, title: Text(labelOf(v))),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
    if (picked != null && picked != value) onChanged(picked);
  }
}

/// A number on its setting's range and step.
///
/// Holds its own value while dragging and commits on release, so the engine
/// and the saved settings see one change, not one per frame. A step with no
/// drag around it (keyboard, accessibility) commits at once.
class _ValueSlider extends StatefulWidget {
  const _ValueSlider({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.format,
    required this.onChanged,
    this.enabled = true,
  });

  final String title;
  final double value;
  final double min;
  final double max;
  final double step;
  final bool enabled;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  @override
  State<_ValueSlider> createState() => _ValueSliderState();
}

class _ValueSliderState extends State<_ValueSlider> {
  double? _dragging;
  bool _active = false;

  @override
  void didUpdateWidget(_ValueSlider old) {
    super.didUpdateWidget(old);
    // Disabled mid-drag: onChangeEnd never comes, so end the drag here or the
    // next keyboard step after re-enabling would never commit.
    if (!widget.enabled) _active = false;
    if (_dragging != null &&
        (!widget.enabled || (old.value != widget.value && !_active))) {
      _dragging = null;
    }
  }

  /// Rounds to the step grid (and to 4 decimals, against float drift).
  double _snap(double v) {
    final n = ((v - widget.min) / widget.step).round();
    final r = widget.min + n * widget.step;
    return double.parse(r.clamp(widget.min, widget.max).toStringAsFixed(4));
  }

  void _commit(double v) {
    final committed = _snap(v);
    if (committed != widget.value) widget.onChanged(committed);
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
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
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
