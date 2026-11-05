/// Settings → Playback → Audio Focus.
///
/// Eight switches for what Hype does when another sound takes the audio
/// (a call, a notification, another player) and when it may start by itself.
/// Defaults live in `lib/audio/focus/audio_focus_settings.dart`.
///
/// Dependants stay visible but dimmed: Resume on reopen needs Resume on start;
/// Resume on focus gain and Duck volume need Short audio focus change; Pause in
/// call shows on, and locked, while Short is on (a short change already covers
/// calls).
///
/// iOS has no per-app focus rules beyond the first three rows, so it shows only
/// those. Every label is also a search entry in `kSettingsIndex`; the widget
/// test for this file checks that the two agree.
library;

import 'package:flutter/material.dart';

import '../audio/focus/audio_focus_settings.dart';

class AudioFocusSettingsSection extends StatelessWidget {
  const AudioFocusSettingsSection({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.isIos,
    this.showHeader = true,
  });

  /// False when hosted in a sub-page whose AppBar already carries the title.
  final bool showHeader;

  final AudioFocusSettings settings;
  final ValueChanged<AudioFocusSettings> onChanged;
  final bool isIos;

  /// The labels this section shows, for the settings search.
  static const labels = [
    'Resume after call',
    'Resume on start',
    'Resume on reopen',
    'Short audio focus change / calls',
    'Pause in call',
    'Resume on focus gain',
    'Duck volume',
    'Permanent audio focus change',
  ];

  /// The rows iOS does not have (hidden there, and from its search).
  static const androidOnlyLabels = [
    'Short audio focus change / calls',
    'Pause in call',
    'Resume on focus gain',
    'Duck volume',
    'Permanent audio focus change',
  ];

  @override
  Widget build(BuildContext context) {
    final s = settings;
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeader)
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(
            children: [
              Icon(Icons.hearing_rounded, size: 20, color: primary),
              const SizedBox(width: 8),
              Text(
                'Audio Focus',
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
                subtitle: 'Carry on by itself once a call ends',
                value: s.resumeAfterCall,
                onChanged: (v) => onChanged(s.copyWith(resumeAfterCall: v)),
              ),
              _divider,
              _SwitchRow(
                title: labels[1],
                subtitle: 'Start playing when Hype opens, if it has a queue',
                value: s.resumeOnStart,
                onChanged: (v) => onChanged(s.copyWith(resumeOnStart: v)),
              ),
              _divider,
              _SwitchRow(
                title: labels[2],
                subtitle: 'Start playing when you come back to Hype',
                value: s.resumeOnReopen,
                enabled: s.resumeOnStart,
                onChanged: (v) => onChanged(s.copyWith(resumeOnReopen: v)),
              ),
              if (!isIos) ...[
                _divider,
                _SwitchRow(
                  title: labels[3],
                  subtitle:
                      'Pause for a call or a short sound, then carry on',
                  value: s.shortFocusChange,
                  onChanged: (v) =>
                      onChanged(s.copyWith(shortFocusChange: v)),
                ),
                _divider,
                _SwitchRow(
                  title: labels[4],
                  subtitle: s.shortFocusChange
                      ? 'Already on while Short audio focus change is on'
                      : 'Pause when a call starts',
                  value: s.effectivePauseInCall,
                  enabled: !s.shortFocusChange,
                  onChanged: (v) => onChanged(s.copyWith(pauseInCall: v)),
                ),
                _divider,
                _SwitchRow(
                  title: labels[5],
                  subtitle: 'Carry on when the short sound ends',
                  value: s.resumeOnFocusGain,
                  enabled: s.shortFocusChange,
                  onChanged: (v) =>
                      onChanged(s.copyWith(resumeOnFocusGain: v)),
                ),
                _divider,
                _SwitchRow(
                  title: labels[6],
                  subtitle: 'Turn down instead of pausing for brief sounds',
                  value: s.duckVolume,
                  enabled: s.shortFocusChange,
                  onChanged: (v) => onChanged(s.copyWith(duckVolume: v)),
                ),
                _divider,
                _SwitchRow(
                  title: labels[7],
                  subtitle: 'Pause when another app takes over for good',
                  value: s.permanentFocusChange,
                  onChanged: (v) =>
                      onChanged(s.copyWith(permanentFocusChange: v)),
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
