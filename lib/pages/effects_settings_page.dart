import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import 'dynamics_view.dart';
import 'global_eq_section.dart';
import 'space_view.dart';
import 'speaker_eq_view.dart';
import 'volume_controls.dart';

/// Settings → Audio → Effects: the Space, Dynamics and Speaker Correction
/// pages, plus the former Tone & Effects content (tone, limiter, balance,
/// mono, tempo).
class EffectsSettingsPage extends StatelessWidget {
  const EffectsSettingsPage({super.key});

  Widget _entry(BuildContext context, IconData icon, String title,
      String subtitle, Widget Function() page) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: page(),
        ),
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    return Scaffold(
      appBar: AppBar(title: const Text('Effects')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          AudioSectionCard(children: [
            _entry(context, Icons.surround_sound_outlined, 'Space',
                'Reverb, widening and spatial effects', () => const SpaceView()),
            const Divider(height: 1, indent: 16, endIndent: 16),
            _entry(context, Icons.compress, 'Dynamics',
                'Compressor and multiband control', () => const DynamicsView()),
            const Divider(height: 1, indent: 16, endIndent: 16),
            _entry(context, Icons.speaker_outlined, 'Speaker Correction',
                'Tune the response to your speaker',
                () => const SpeakerEqView()),
          ]),
          const SizedBox(height: 12),
          const AudioSectionHeader(Icons.tune, "Tone Controls"),
          AudioSectionCard(children: [
            SwitchListTile.adaptive(
              value: controller.toneEnabled,
              title: const Text("Tone controls"),
              subtitle: Text(
                controller.toneEnabled ? "Bass & treble active" : "Disabled",
              ),
              onChanged: (enabled) => controller.toneEnabled = enabled,
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            SwitchListTile.adaptive(
              value: controller.limiterEnabled,
              title: const Text("Limiter"),
              subtitle: const Text("Prevents distortion from EQ boosts"),
              onChanged: (enabled) => controller.limiterEnabled = enabled,
            ),
          ]),
          const SizedBox(height: 12),
          const AudioSectionHeader(Icons.volume_up, "Volume"),
          AudioSectionCard(children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: VolumeControls(
                settings: controller.dspCore,
                onChanged: (v) => controller.dspCore = v,
                stereoExpand: controller.stereoExpand,
                onStereoExpand: (v) => controller.stereoExpand = v,
                disabledReason: controller.systemWideDisabledReason,
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
