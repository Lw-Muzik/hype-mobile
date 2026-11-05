/// Settings → Advanced tweaks.
///
/// Seven rows: how many steps the volume keys have, Hype's own volume panel,
/// pausing at volume 0, the system audio effects panel (MusicFX), forcing audio
/// back after a focus change, and two restore actions. Defaults live in
/// `lib/audio/advanced/advanced_settings.dart`.
///
/// iOS has no volume key hook, volume panel, MusicFX or focus tug of war, so it
/// shows only the three rows both platforms keep. Every label is also a search
/// entry in `kSettingsIndex`.
library;

import 'package:flutter/material.dart';

import '../audio/advanced/advanced_settings.dart';

class AdvancedSettingsSection extends StatelessWidget {
  const AdvancedSettingsSection({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.isIos,
    required this.musicFxAvailable,
    required this.onOpenMusicFx,
    required this.onRestoreEqPresets,
    required this.onRestoreReverbPresets,
    this.showHeader = true,
  });

  /// False when hosted in a sub-page whose AppBar already carries the title.
  final bool showHeader;

  final AdvancedSettings settings;
  final ValueChanged<AdvancedSettings> onChanged;
  final bool isIos;

  /// Whether an app on this phone answers the audio effects panel intent.
  final bool musicFxAvailable;
  final VoidCallback onOpenMusicFx;
  final VoidCallback onRestoreEqPresets;
  final VoidCallback onRestoreReverbPresets;

  /// The labels this section shows, for the settings search.
  static const labels = [
    'Volume levels',
    'Volume panel',
    'Pause/resume on volume',
    'MusicFX',
    'Force audio on audio focus change',
    'Restore equalizer presets',
    'Restore reverb presets',
  ];

  /// The rows iOS does not have (hidden there, and from its search).
  static const androidOnlyLabels = [
    'Volume levels',
    'Volume panel',
    'MusicFX',
    'Force audio on audio focus change',
  ];

  static const _divider = Divider(height: 1, indent: 16, endIndent: 16);

  @override
  Widget build(BuildContext context) {
    final s = settings;
    final primary = Theme.of(context).colorScheme.primary;
    final rows = <Widget>[
      if (!isIos)
        ListTile(
          title: Text(labels[0]),
          subtitle: Text(s.volumeLevels.label),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _chooseLevels(context),
        ),
      if (!isIos)
        SwitchListTile.adaptive(
          value: s.volumePanel,
          title: Text(labels[1]),
          subtitle: const Text(
            "Show Hype's own volume bar when you change "
            'the volume in the app',
          ),
          onChanged: (v) => onChanged(s.copyWith(volumePanel: v)),
        ),
      SwitchListTile.adaptive(
        value: s.pauseResumeOnVolume,
        title: Text(labels[2]),
        subtitle: const Text(
          'Pause at volume 0, resume when you raise it '
          'while Hype is showing',
        ),
        onChanged: (v) => onChanged(s.copyWith(pauseResumeOnVolume: v)),
      ),
      if (!isIos)
        SwitchListTile.adaptive(
          value: s.musicFx,
          title: Text(labels[3]),
          subtitle: Text(
            musicFxAvailable
                ? 'Show a button that opens the system audio effects panel'
                : 'No audio effects panel on this phone',
          ),
          onChanged: musicFxAvailable
              ? (v) => onChanged(s.copyWith(musicFx: v))
              : null,
        ),
      if (!isIos && s.musicFx && musicFxAvailable)
        ListTile(
          title: const Text('Open MusicFX'),
          trailing: const Icon(Icons.open_in_new_rounded, size: 20),
          onTap: onOpenMusicFx,
        ),
      if (!isIos)
        SwitchListTile.adaptive(
          value: s.forceAudioOnFocusChange,
          title: Text(labels[4]),
          subtitle: const Text(
            'Restart the sound if it stays silent after '
            'a notification or call',
          ),
          onChanged: (v) => onChanged(s.copyWith(forceAudioOnFocusChange: v)),
        ),
      ListTile(
        title: Text(labels[5]),
        subtitle: const Text('Bring back the factory presets'),
        trailing: const Icon(Icons.settings_backup_restore_rounded, size: 20),
        onTap: () => _confirm(
          context,
          title: 'Restore factory presets?',
          body:
              'Every built-in equalizer preset goes back to its original '
              'curve. Presets you made are kept.',
          onConfirm: onRestoreEqPresets,
        ),
      ),
      ListTile(
        title: Text(labels[6]),
        subtitle: const Text("Bring back Hype's room presets"),
        trailing: const Icon(Icons.settings_backup_restore_rounded, size: 20),
        onTap: () => _confirm(
          context,
          title: 'Restore room presets?',
          body:
              "The room and reverb settings go back to Hype's original "
              'preset (Off).',
          onConfirm: onRestoreReverbPresets,
        ),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeader)
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(
            children: [
              Icon(Icons.tune_rounded, size: 20, color: primary),
              const SizedBox(width: 8),
              Text(
                'Advanced tweaks',
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: primary, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) _divider,
                rows[i],
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _chooseLevels(BuildContext context) async {
    final picked = await showDialog<VolumeLevels>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Volume levels'),
        children: [
          for (final v in VolumeLevels.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, v),
              child: Text(v.label),
            ),
        ],
      ),
    );
    if (picked != null) onChanged(settings.copyWith(volumeLevels: picked));
  }

  Future<void> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required VoidCallback onConfirm,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
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
    if (ok == true) onConfirm();
  }
}
