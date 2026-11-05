/// Settings → Headset & Bluetooth.
///
/// Fourteen controls: when to resume or pause as headphones come and go, how
/// headset buttons are read, and what feedback they give. Defaults and ranges
/// live in `lib/audio/headset/headset_settings.dart`.
///
/// Dimmed, not hidden: the two button modes, Beep, Beep more, Vibrate and
/// Disable default long press while Respond to buttons is off; Beep more while
/// Beep is off.
///
/// iOS has no headset key hook or feedback, so it shows only the six rows both
/// platforms keep. Every label is also a search entry in `kSettingsIndex`; the
/// widget test for this file checks that the two agree.
library;

import 'package:flutter/material.dart';

import '../audio/headset/headset_settings.dart';

class HeadsetSettingsSection extends StatelessWidget {
  const HeadsetSettingsSection({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.isIos,
  });

  final HeadsetSettings settings;
  final ValueChanged<HeadsetSettings> onChanged;
  final bool isIos;

  /// The labels this section shows, for the settings search.
  static const labels = [
    'Resume on wired headset',
    'Resume on Bluetooth',
    'Pause on headset disconnect',
    'Pause on USB DAC connection',
    'Respond to buttons',
    'Wired headset buttons',
    'Bluetooth buttons',
    'Strict resume/pause/stop',
    'Ignore Bluetooth commands',
    'Ignore repeat/shuffle',
    'Beep',
    'Beep more',
    'Vibrate',
    'Disable default long press',
  ];

  /// The rows iOS does not have (hidden there, and from its search).
  static const androidOnlyLabels = [
    'Pause on USB DAC connection',
    'Respond to buttons',
    'Wired headset buttons',
    'Bluetooth buttons',
    'Beep',
    'Beep more',
    'Vibrate',
    'Disable default long press',
  ];

  static const _longPressSubtitle =
      'Long press no longer starts voice search while Hype plays. '
      'When Android asks, choose Hype.';

  @override
  Widget build(BuildContext context) {
    final s = settings;
    final primary = Theme.of(context).colorScheme.primary;
    final buttons = s.respondToButtons;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(
            children: [
              Icon(Icons.headset_rounded, size: 20, color: primary),
              const SizedBox(width: 8),
              Text(
                'Headset & Bluetooth',
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: primary, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        Card(
          elevation: 0,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              _SwitchRow(
                title: labels[0],
                subtitle: 'Start playing when a wired headset is plugged in',
                value: s.resumeOnWired,
                onChanged: (v) => onChanged(s.copyWith(resumeOnWired: v)),
              ),
              _divider,
              _SwitchRow(
                title: labels[1],
                subtitle: 'Start playing when a Bluetooth device connects',
                value: s.resumeOnBluetooth,
                onChanged: (v) => onChanged(s.copyWith(resumeOnBluetooth: v)),
              ),
              _divider,
              _SwitchRow(
                title: labels[2],
                subtitle: 'Pause when headphones are unplugged or disconnect',
                value: s.pauseOnDisconnect,
                onChanged: (v) =>
                    onChanged(s.copyWith(pauseOnDisconnect: v)),
              ),
              if (!isIos) ...[
                _divider,
                _SwitchRow(
                  title: labels[3],
                  subtitle: 'Pause when a USB audio device is plugged in',
                  value: s.pauseOnUsbDac,
                  onChanged: (v) => onChanged(s.copyWith(pauseOnUsbDac: v)),
                ),
                _divider,
                _SwitchRow(
                  title: labels[4],
                  subtitle: 'Headset buttons control playback',
                  value: s.respondToButtons,
                  onChanged: (v) =>
                      onChanged(s.copyWith(respondToButtons: v)),
                ),
                _divider,
                _ChoiceTile(
                  title: labels[5],
                  value: s.wiredButtons,
                  enabled: buttons,
                  onChanged: (v) => onChanged(s.copyWith(wiredButtons: v)),
                ),
                _divider,
                _ChoiceTile(
                  title: labels[6],
                  value: s.bluetoothButtons,
                  enabled: buttons,
                  onChanged: (v) =>
                      onChanged(s.copyWith(bluetoothButtons: v)),
                ),
              ],
              _divider,
              _SwitchRow(
                title: labels[7],
                subtitle: 'Ignore play when already playing, '
                    'pause or stop when already paused',
                value: s.strictCommands,
                onChanged: (v) => onChanged(s.copyWith(strictCommands: v)),
              ),
              _divider,
              _SecondsSlider(
                title: labels[8],
                subtitle: 'Drop Bluetooth commands for a moment after a '
                    'device connects. 0 turns this off.',
                value: s.ignoreBluetoothCommandsS,
                onChanged: (v) =>
                    onChanged(s.copyWith(ignoreBluetoothCommandsS: v)),
              ),
              _divider,
              _SwitchRow(
                title: labels[9],
                subtitle: 'Leave repeat and shuffle alone when a remote '
                    'asks to change them',
                value: s.ignoreRepeatShuffle,
                onChanged: (v) =>
                    onChanged(s.copyWith(ignoreRepeatShuffle: v)),
              ),
              if (!isIos) ...[
                _divider,
                _SwitchRow(
                  title: labels[10],
                  subtitle: 'Beep when a button press is understood',
                  value: s.beep,
                  enabled: buttons,
                  onChanged: (v) => onChanged(s.copyWith(beep: v)),
                ),
                _divider,
                _SwitchRow(
                  title: labels[11],
                  subtitle: 'Also beep for a single press',
                  value: s.beepMore,
                  enabled: buttons && s.beep,
                  onChanged: (v) => onChanged(s.copyWith(beepMore: v)),
                ),
                _divider,
                _SwitchRow(
                  title: labels[12],
                  subtitle: 'Vibrate when a button press is understood',
                  value: s.vibrate,
                  enabled: buttons,
                  onChanged: (v) => onChanged(s.copyWith(vibrate: v)),
                ),
                _divider,
                _SwitchRow(
                  title: labels[13],
                  subtitle: _longPressSubtitle,
                  value: s.disableDefaultLongPress,
                  enabled: buttons,
                  onChanged: (v) =>
                      onChanged(s.copyWith(disableDefaultLongPress: v)),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  static const _divider = Divider(height: 1, indent: 16, endIndent: 16);
}

/// A switch row; a row that is `enabled: false` stays visible but dimmed.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      value: value,
      title: Text(title),
      subtitle: Text(subtitle),
      onChanged: enabled ? onChanged : null,
    );
  }
}

/// A button mode chosen from a short list: shows the choice, opens the list.
class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.title,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String title;
  final ButtonMode value;
  final ValueChanged<ButtonMode> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      enabled: enabled,
      title: Text(title),
      subtitle: Text(value.label),
      trailing: const Icon(Icons.unfold_more_rounded, size: 20),
      onTap: enabled ? () => _open(context) : null,
    );
  }

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<ButtonMode>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: RadioGroup<ButtonMode>(
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
              for (final v in ButtonMode.values)
                RadioListTile<ButtonMode>(value: v, title: Text(v.label)),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (picked != null && picked != value) onChanged(picked);
  }
}

/// Whole seconds, 0…[kIgnoreBluetoothCommandsMaxS], shown as `%d s`.
///
/// Holds its own value while dragging and commits on release, so the setting is
/// saved once per drag, not on every frame. A change with no drag around it
/// (keyboard arrow, accessibility step) commits at once.
class _SecondsSlider extends StatefulWidget {
  const _SecondsSlider({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_SecondsSlider> createState() => _SecondsSliderState();
}

class _SecondsSliderState extends State<_SecondsSlider> {
  double? _dragging;
  bool _active = false;

  @override
  void didUpdateWidget(_SecondsSlider old) {
    super.didUpdateWidget(old);
    // A new value arriving while nothing is dragged must not leave a stale
    // drag value on screen.
    if (_dragging != null && old.value != widget.value && !_active) {
      _dragging = null;
    }
  }

  void _commit(double v) {
    final committed = v.round();
    if (committed != widget.value) widget.onChanged(committed);
  }

  @override
  Widget build(BuildContext context) {
    final shown = (_dragging ?? widget.value.toDouble()).round();
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
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
              Text(
                '$shown s',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
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
            value: shown.toDouble(),
            min: 0,
            max: kIgnoreBluetoothCommandsMaxS.toDouble(),
            divisions: kIgnoreBluetoothCommandsMaxS,
            onChangeStart: (_) => _active = true,
            onChanged: (v) {
              if (_active) {
                setState(() => _dragging = v);
              } else {
                _commit(v);
              }
            },
            onChangeEnd: (v) {
              _active = false;
              setState(() => _dragging = null);
              _commit(v);
            },
          ),
        ],
      ),
    );
  }
}
