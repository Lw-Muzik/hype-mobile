import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import 'advanced_settings_section.dart';
import 'audio_focus_settings_section.dart';
import 'audio_info_page.dart';
import 'audio_sub_page.dart';
import 'crossfade_settings_section.dart';
import 'dvc_settings_section.dart';
import 'effects_settings_page.dart';
import 'equalizer_settings_section.dart';
import 'global_eq_section.dart';
import 'output_profiles_page.dart';
import 'replay_gain_settings_section.dart';

/// What the user sees for a sub-page: on iOS the DVC page holds only the
/// headroom slider, so it is called that.
String audioSubPageLabel(AudioSubPage page) =>
    page == AudioSubPage.dvc && Platform.isIOS ? 'Headroom' : page.title;

/// The body of one Audio sub-page, built from the existing section widgets.
/// Pages that own a Scaffold (info, outputs, effects) are returned as-is;
/// [AudioSettingsPage] wraps the rest.
Widget buildAudioSubPage(
  BuildContext context,
  AppController controller,
  AudioSubPage page,
) {
  switch (page) {
    case AudioSubPage.info:
      return const AudioInfoPage();
    case AudioSubPage.crossfade:
      return CrossfadeSettingsSection(
        settings: controller.fadeSettings,
        onChanged: (value) => controller.fadeSettings = value,
      );
    case AudioSubPage.replayGain:
      return ReplayGainSettingsSection(
        settings: controller.replayGainSettings,
        onChanged: (v) => controller.replayGainSettings = v,
        disabledReason: controller.systemWideDisabledReason,
      );
    case AudioSubPage.audioFocus:
      return AudioFocusSettingsSection(
        settings: controller.audioFocusSettings,
        onChanged: (v) => controller.audioFocusSettings = v,
        isIos: Platform.isIOS,
        showHeader: false,
      );
    case AudioSubPage.equalizer:
      return Column(children: [
        if (controller.globalEqAvailable) ...[
          GlobalEqSection(controller: controller),
          const SizedBox(height: 12),
        ],
        EqualizerSettingsSection(
          settings: controller.eqSettings,
          onChanged: (value) => controller.eqSettings = value,
          onResetAutoEqSuggestions: () async {
            final messenger = ScaffoldMessenger.of(context);
            await controller.resetAutoEqSuggestions();
            messenger.showSnackBar(
              const SnackBar(content: Text('AutoEq suggestions reset')),
            );
          },
          onRestorePresets: controller.restoreEqPresets,
        ),
      ]);
    case AudioSubPage.dvc:
      return _DvcBody(controller: controller);
    case AudioSubPage.advanced:
      return AdvancedSettingsSection(
        settings: controller.advancedSettings,
        onChanged: (v) => controller.advancedSettings = v,
        isIos: Platform.isIOS,
        musicFxAvailable: controller.musicFxAvailable,
        onOpenMusicFx: () => controller.openMusicFx(),
        onRestoreEqPresets: controller.restoreEqPresets,
        onRestoreReverbPresets: controller.restoreReverbPresets,
        showHeader: false,
      );
    case AudioSubPage.outputs:
      return const OutputProfilesPage();
    case AudioSubPage.effects:
      return const EffectsSettingsPage();
  }
}

bool _ownsScaffold(AudioSubPage p) =>
    p == AudioSubPage.info ||
    p == AudioSubPage.outputs ||
    p == AudioSubPage.effects;

/// Direct volume control, locked while the equalizer applies system-wide.
class _DvcBody extends StatelessWidget {
  const _DvcBody({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final reason = controller.systemWideDisabledReason;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (reason != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(reason, style: Theme.of(context).textTheme.bodySmall),
          ),
        IgnorePointer(
          ignoring: controller.systemWideActive,
          child: Opacity(
            opacity: controller.systemWideActive ? 0.5 : 1.0,
            child: DvcSettingsSection(
              settings: controller.dvcSettings,
              onChanged: (v) => controller.dvcSettings = v,
              dvcEnabled: controller.dvcEnabled,
              onDvcEnabled: (enabled) {
                if (enabled && !controller.dvcEnabled) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("System volume will be set to maximum"),
                      duration: Duration(seconds: 3),
                    ),
                  );
                }
                controller.dvcEnabled = enabled;
              },
              dvcGainDb: controller.dvcGain,
              onDvcGainDb: (v) => controller.dvcGain = v,
              headroomDb: controller.dspCore.headroomDb,
              onHeadroomDb: (v) => controller.dspCore =
                  controller.dspCore.copyWith(headroomDb: v),
              isIos: Platform.isIOS,
              dvcRunning: controller.dvcRunning,
            ),
          ),
        ),
      ],
    );
  }
}

class _SubPageRoute extends StatelessWidget {
  const _SubPageRoute({required this.page});
  final AudioSubPage page;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final body = buildAudioSubPage(context, controller, page);
    if (_ownsScaffold(page)) return body;
    return Scaffold(
      appBar: AppBar(
        // On iOS the DVC page holds only the headroom slider.
        title: Text(audioSubPageLabel(page)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [body],
      ),
    );
  }
}

/// Settings → Audio: one tile per [AudioSubPage], in enum order. In
/// Equalizer-only mode only the pages that apply there are listed.
class AudioSettingsPage extends StatefulWidget {
  const AudioSettingsPage({super.key, this.open});

  /// Pushed on the first frame (a search result landing on a sub-page).
  final AudioSubPage? open;

  @override
  State<AudioSettingsPage> createState() => _AudioSettingsPageState();
}

class _AudioSettingsPageState extends State<AudioSettingsPage> {
  @override
  void initState() {
    super.initState();
    final open = widget.open;
    if (open != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _push(open);
      });
    }
  }

  void _push(AudioSubPage page) {
    final controller = context.read<AppController>();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: _SubPageRoute(page: page),
      ),
    ));
  }

  static const _icons = {
    AudioSubPage.info: Icons.info_outline,
    AudioSubPage.crossfade: Icons.compare_arrows,
    AudioSubPage.replayGain: Icons.graphic_eq,
    AudioSubPage.audioFocus: Icons.center_focus_strong_outlined,
    AudioSubPage.equalizer: Icons.equalizer,
    AudioSubPage.dvc: Icons.tune,
    AudioSubPage.advanced: Icons.settings_suggest_outlined,
    AudioSubPage.outputs: Icons.speaker_group_outlined,
    AudioSubPage.effects: Icons.auto_awesome_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final eqMode = context.watch<AppController>().isEqMode;
    final pages = [
      for (final p in AudioSubPage.values)
        if (!eqMode || p.inEqualizerOnlyMode) p,
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Audio')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          AudioSectionCard(children: [
            for (var i = 0; i < pages.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: Icon(_icons[pages[i]]),
                title: Text(audioSubPageLabel(pages[i])),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _push(pages[i]),
              ),
            ],
          ]),
        ],
      ),
    );
  }
}
