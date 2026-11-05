import 'package:flutter/material.dart';

import '../audio/dsp_core.dart';
import '../themes/ember.dart';

/// Balance, mono and tempo, plus one reset for them.
///
/// Stateless: the caller owns [settings] and [stereoExpand] and gets every
/// change back through [onChanged] / [onStereoExpand]. Stereo Expand's own
/// slider lives on the Space page; it appears here only because Reset clears
/// it too.
///
/// A non-null [disabledReason] (system-wide equalizer mode) greys out Balance
/// and Mono, which the platform equalizer cannot carry, and shows the reason;
/// Tempo and Reset keep working.
class VolumeControls extends StatelessWidget {
  const VolumeControls({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.stereoExpand,
    required this.onStereoExpand,
    this.disabledReason,
  });

  final DspCoreSettings settings;
  final ValueChanged<DspCoreSettings> onChanged;
  final double stereoExpand;
  final ValueChanged<double> onStereoExpand;
  final String? disabledReason;

  static const double _tempoMin = 0.5;
  static const double _tempoMax = 3.0;
  static const double _tempoStep = 0.05;

  static const Color _accent = Ember.accent;

  @override
  Widget build(BuildContext context) {
    final s = settings;
    final reason = disabledReason;
    final locked = reason != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (locked)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Text(
              reason,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
          ),
        _sliderRow(
          context,
          label: 'Balance',
          value: s.balance,
          min: -1,
          max: 1,
          display: s.balance.toStringAsFixed(2),
          onChanged: locked ? null : (v) => onChanged(s.copyWith(balance: v)),
          ends: const ('L', 'R'),
        ),
        SwitchListTile.adaptive(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          title: const Text('Mono'),
          subtitle: const Text('Left and right mixed into one'),
          value: s.mono,
          onChanged: locked ? null : (v) => onChanged(s.copyWith(mono: v)),
        ),
        SwitchListTile.adaptive(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          title: const Text('Tempo'),
          subtitle: const Text('Playback speed, pitch kept'),
          value: s.tempoOn,
          onChanged: (v) => onChanged(s.copyWith(tempoOn: v)),
        ),
        _tempoRow(context),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => _confirmReset(context),
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            label: const Text('Reset'),
          ),
        ),
      ],
    );
  }

  Widget _tempoRow(BuildContext context) {
    final s = settings;
    final t = s.tempo;
    // Moving the speed engages it: a speed that changes nothing is a control
    // with no effect.
    void setTempo(double v) =>
        onChanged(s.copyWith(tempoOn: true, tempo: v));
    final enabled = s.tempoOn;
    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.remove),
            tooltip: 'Slower',
            onPressed: t <= _tempoMin + 1e-9
                ? null
                : () => setTempo(
                    _round((t - _tempoStep).clamp(_tempoMin, _tempoMax))),
          ),
          Expanded(
            child: _slider(
              context,
              value: t,
              min: _tempoMin,
              max: _tempoMax,
              onChanged: setTempo,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Faster',
            onPressed: t >= _tempoMax - 1e-9
                ? null
                : () => setTempo(
                    _round((t + _tempoStep).clamp(_tempoMin, _tempoMax))),
          ),
          SizedBox(
            width: 52,
            child: Text(
              '${t.toStringAsFixed(2)}x',
              textAlign: TextAlign.right,
              style: _valueStyle(context, active: (t - 1.0).abs() > 0.005),
            ),
          ),
        ],
      ),
    );
  }

  static double _round(double v) => (v * 100).round() / 100;

  Widget _sliderRow(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    required String display,
    required ValueChanged<double>? onChanged,
    required (String, String) ends,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: Theme.of(context).textTheme.bodyLarge),
              const Spacer(),
              Text(display, style: _valueStyle(context, active: value != 0)),
            ],
          ),
          Row(
            children: [
              Text(ends.$1, style: _endStyle),
              Expanded(
                child: _slider(
                  context,
                  value: value,
                  min: min,
                  max: max,
                  onChanged: onChanged,
                ),
              ),
              Text(ends.$2, style: _endStyle),
            ],
          ),
        ],
      ),
    );
  }

  Widget _slider(
    BuildContext context, {
    required double value,
    required double min,
    required double max,
    required ValueChanged<double>? onChanged,
  }) {
    return SliderTheme(
      data: SliderThemeData(
        trackHeight: 3,
        activeTrackColor: _accent,
        inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
        thumbColor: _accent,
        overlayColor: _accent.withValues(alpha: 0.08),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
      child: Slider(
        value: value.clamp(min, max).toDouble(),
        min: min,
        max: max,
        onChanged: onChanged,
      ),
    );
  }

  static TextStyle get _endStyle => TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: Colors.white.withValues(alpha: 0.4),
  );

  TextStyle _valueStyle(BuildContext context, {required bool active}) =>
      TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: active ? _accent : Colors.white.withValues(alpha: 0.4),
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  Future<void> _confirmReset(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset volume controls?'),
        content: const Text(
          'Balance, stereo expand, tempo and mono go back to their defaults.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    onChanged(
      settings.copyWith(balance: 0, mono: false, tempoOn: false, tempo: 1.0),
    );
    onStereoExpand(0);
  }
}
