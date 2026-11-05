/// Audio → Outputs.
///
/// A profile for each kind of output (speaker, wired headphones, Bluetooth,
/// USB audio, other) and for each Bluetooth or USB device Hype has seen: an EQ
/// preset applied when the output becomes active, and five switches. The
/// output in use is marked. A device follows its kind until it is given a
/// profile of its own. What the profiles do is in
/// `lib/audio/output/output_profiles.dart`.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../audio/eq/autoeq_suggest.dart' show normaliseDeviceName;
import '../audio/headset/output_kind.dart';
import '../audio/output/output_profiles.dart';
import '../controllers/app_controller.dart';

/// The labels of the switches, for the settings search.
const kOutputProfileLabels = [
  'EQ preset',
  'No Equ/Tone',
  'No Duck',
  'Ignore audio focus',
  'No DVC',
  'No headroom gain reduction',
];

class OutputProfilesPage extends StatelessWidget {
  const OutputProfilesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AppController>();
    return Scaffold(
      appBar: AppBar(title: const Text('Outputs')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: OutputProfilesView(
          profiles: c.outputProfiles,
          active: c.activeOutputRoute,
          presetNames: c.outputPresetNames,
          isAndroid: Theme.of(context).platform != TargetPlatform.iOS,
          onKind: c.setOutputKindProfile,
          onDevice: c.setOutputDeviceProfile,
          onForget: c.forgetOutputDevice,
        ),
      ),
    );
  }
}

class OutputProfilesView extends StatelessWidget {
  const OutputProfilesView({
    super.key,
    required this.profiles,
    required this.active,
    required this.presetNames,
    required this.isAndroid,
    required this.onKind,
    required this.onDevice,
    required this.onForget,
  });

  final OutputProfiles profiles;
  final ActiveRoute? active;
  final List<String> presetNames;
  final bool isAndroid;
  final void Function(AudioOutputKind kind, OutputProfile p) onKind;
  final void Function(String name, AudioOutputKind kind, OutputProfile? p)
  onDevice;
  final ValueChanged<String> onForget;

  static const _kinds = [
    AudioOutputKind.speaker,
    AudioOutputKind.wired,
    AudioOutputKind.bluetooth,
    AudioOutputKind.usb,
    AudioOutputKind.other,
  ];

  static String kindTitle(AudioOutputKind k) => switch (k) {
    AudioOutputKind.speaker => 'Speaker',
    AudioOutputKind.wired => 'Wired headphones',
    AudioOutputKind.bluetooth => 'Bluetooth',
    AudioOutputKind.usb => 'USB audio',
    AudioOutputKind.other => 'Other',
  };

  static IconData kindIcon(AudioOutputKind k) => switch (k) {
    AudioOutputKind.speaker => Icons.speaker_rounded,
    AudioOutputKind.wired => Icons.headphones_rounded,
    AudioOutputKind.bluetooth => Icons.bluetooth_audio_rounded,
    AudioOutputKind.usb => Icons.usb_rounded,
    AudioOutputKind.other => Icons.cast_rounded,
  };

  /// "Bass · No Duck": what a profile sets; null for the default.
  String? summary(OutputProfile p) {
    final parts = [
      if (p.eqPreset != null) presetLabel(p.eqPreset!),
      if (p.autoEq != null) 'AutoEq',
      if (p.noEqTone) 'No Equ/Tone',
      if (p.noDuck) 'No Duck',
      if (p.ignoreFocus) 'Ignore audio focus',
      if (p.noDvc && isAndroid) 'No DVC',
      if (p.noHeadroomReduction) 'No headroom reduction',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static String presetLabel(String name) =>
      name.startsWith('_device_') ? 'Saved curve' : name;

  @override
  Widget build(BuildContext context) {
    final devices = profiles.devices.entries.toList()
      ..sort(
        (a, b) =>
            a.value.name.toLowerCase().compareTo(b.value.name.toLowerCase()),
      );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Heading('Output types'),
        _CardColumn(
          children: [
            for (final k in _kinds)
              _OutputTile(
                key: ValueKey('kind-${k.name}'),
                title: kindTitle(k),
                icon: kindIcon(k),
                isActive:
                    active != null && active!.kind == k && !_deviceActive(),
                subtitle:
                    summary(profiles.kinds[k] ?? const OutputProfile()) ??
                    'Same as everywhere',
                profile: profiles.kinds[k] ?? const OutputProfile(),
                presetNames: presetNames,
                isAndroid: isAndroid,
                onChanged: (p) => onKind(k, p),
              ),
          ],
        ),
        if (devices.isNotEmpty) ...[
          const SizedBox(height: 16),
          const _Heading('Devices'),
          _CardColumn(
            children: [
              for (final e in devices)
                _OutputTile(
                  key: ValueKey('device-${e.key}'),
                  title: e.value.name,
                  icon: kindIcon(e.value.kind),
                  isActive:
                      active?.deviceName != null &&
                      normaliseDeviceName(active!.deviceName!) == e.key,
                  subtitle: e.value.profile == null
                      ? 'Same as ${kindTitle(e.value.kind)}'
                      : summary(e.value.profile!) ?? 'Own profile',
                  profile: e.value.profile ?? const OutputProfile(),
                  presetNames: presetNames,
                  isAndroid: isAndroid,
                  ownProfile: e.value.profile != null,
                  onOwnProfile: (on) => onDevice(
                    e.value.name,
                    e.value.kind,
                    on
                        ? (profiles.kinds[e.value.kind] ??
                              const OutputProfile())
                        : null,
                  ),
                  onChanged: (p) => onDevice(e.value.name, e.value.kind, p),
                  onForget: () => onForget(e.value.name),
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// A named device is the active output, so its kind row is not.
  bool _deviceActive() {
    final name = active?.deviceName;
    return name != null &&
        profiles.devices.containsKey(normaliseDeviceName(name));
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge
            ?.copyWith(color: primary, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _CardColumn extends StatelessWidget {
  const _CardColumn({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _OutputTile extends StatelessWidget {
  const _OutputTile({
    super.key,
    required this.title,
    required this.icon,
    required this.isActive,
    required this.subtitle,
    required this.profile,
    required this.presetNames,
    required this.isAndroid,
    required this.onChanged,
    this.ownProfile = true,
    this.onOwnProfile,
    this.onForget,
  });

  final String title;
  final IconData icon;
  final bool isActive;
  final String subtitle;
  final OutputProfile profile;
  final List<String> presetNames;
  final bool isAndroid;
  final bool ownProfile;
  final ValueChanged<bool>? onOwnProfile;
  final ValueChanged<OutputProfile> onChanged;
  final VoidCallback? onForget;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExpansionTile(
      shape: const Border(),
      collapsedShape: const Border(),
      leading: Icon(icon, color: isActive ? scheme.primary : null),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: isActive
          ? Chip(
              label: const Text('Active'),
              visualDensity: VisualDensity.compact,
              backgroundColor: scheme.primaryContainer,
              labelStyle: TextStyle(color: scheme.onPrimaryContainer),
              side: BorderSide.none,
            )
          : null,
      children: [
        if (onOwnProfile != null)
          SwitchListTile.adaptive(
            title: const Text('Own profile'),
            subtitle: const Text('Off: follows the output type'),
            value: ownProfile,
            onChanged: onOwnProfile,
          ),
        if (ownProfile) ...[
          ListTile(
            title: const Text('EQ preset'),
            subtitle: Text(
              profile.eqPreset == null
                  ? 'None (leave the curve alone)'
                  : OutputProfilesView.presetLabel(profile.eqPreset!),
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _pickPreset(context),
          ),
          _flag(
            'No Equ/Tone',
            'Bypass the equalizer and tone on this output',
            profile.noEqTone,
            (v) => onChanged(profile.copyWith(noEqTone: v)),
          ),
          _flag(
            'No Duck',
            'Pause instead of lowering the volume for a short sound',
            profile.noDuck,
            (v) => onChanged(profile.copyWith(noDuck: v)),
          ),
          _flag(
            'Ignore audio focus',
            'Keep playing when another app takes audio focus',
            profile.ignoreFocus,
            (v) => onChanged(profile.copyWith(ignoreFocus: v)),
          ),
          if (isAndroid)
            _flag(
              'No DVC',
              'Direct Volume Control stays off on this output',
              profile.noDvc,
              (v) => onChanged(profile.copyWith(noDvc: v)),
            ),
          _flag(
            'No headroom gain reduction',
            'Skip the headroom attenuation on this output',
            profile.noHeadroomReduction,
            (v) => onChanged(profile.copyWith(noHeadroomReduction: v)),
          ),
        ],
        if (onForget != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onForget,
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('Forget this device'),
            ),
          ),
      ],
    );
  }

  Widget _flag(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) => SwitchListTile.adaptive(
    title: Text(title),
    subtitle: Text(subtitle),
    value: value,
    onChanged: onChanged,
  );

  Future<void> _pickPreset(BuildContext context) async {
    final current = profile.eqPreset;
    final legacy = current != null && current.startsWith('_device_');
    final picked = await showModalBottomSheet<_Pick>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              _presetRow(ctx, 'None', current == null, const _Pick(null)),
              if (legacy) _presetRow(ctx, 'Saved curve', true, _Pick(current)),
              for (final n in presetNames)
                _presetRow(ctx, n, n == current, _Pick(n)),
            ],
          ),
        ),
      ),
    );
    if (picked != null) onChanged(profile.copyWith(eqPreset: picked.name));
  }

  Widget _presetRow(
    BuildContext ctx,
    String label,
    bool selected,
    _Pick pick,
  ) => ListTile(
    title: Text(label),
    trailing: selected ? const Icon(Icons.check_rounded) : null,
    onTap: () => Navigator.pop(ctx, pick),
  );
}

/// A chosen preset; [name] null is "None". Wrapped so a dismissed sheet (null)
/// can be told from choosing None.
class _Pick {
  const _Pick(this.name);
  final String? name;
}
