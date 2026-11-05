import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../Helpers/Channel.dart';
import '../controllers/app_controller.dart';

/// Section header + rounded card, shared by the Audio sub-pages.
class AudioSectionHeader extends StatelessWidget {
  const AudioSectionHeader(this.icon, this.title, {super.key});
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Row(children: [
        Icon(icon, size: 20, color: scheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
        ),
      ]),
    );
  }
}

class AudioSectionCard extends StatelessWidget {
  const AudioSectionCard({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        child: Column(children: children),
      );
}

/// The "Global Equalizer" card (system-wide EQ switch, confirmation dialog,
/// battery prompt, apps currently playing). Moved from Settings.dart.
class GlobalEqSection extends StatelessWidget {
  const GlobalEqSection({super.key, required this.controller});
  final AppController controller;

  void _showBatteryOptimizationPrompt(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Disable Battery Optimization"),
        content: const Text(
          "To prevent Android from stopping Hype in the background, "
          "please allow unrestricted battery usage.\n\n"
          "This keeps your EQ and music playing without interruption.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Later"),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Channel.requestDisableBatteryOptimization();
            },
            child: const Text("Allow"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AudioSectionHeader(Icons.public, "Global Equalizer"),
        AudioSectionCard(children: [
          SwitchListTile.adaptive(
            value: controller.globalEqEnabled,
            title: const Text("System-wide EQ"),
            subtitle: Text(
              controller.globalEqEnabled
                  ? "Active — EQ applied to all apps"
                  : "Off",
            ),
            onChanged: (enabled) {
              if (!enabled) {
                controller.globalEqEnabled = false;
                return;
              }
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text("Enable Global EQ?"),
                  content: const Text(
                    "Your EQ, tone, and limiter settings will be applied to audio from other apps (Spotify, YouTube Music, etc.).\n\n"
                    "A persistent notification will appear while active.",
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text("Cancel"),
                    ),
                    FilledButton(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        controller.globalEqEnabled = true;
                        // Prompt for battery optimization if not already disabled.
                        final isDisabled =
                            await Channel.isBatteryOptimizationDisabled();
                        if (!isDisabled && context.mounted) {
                          _showBatteryOptimizationPrompt(context);
                        }
                      },
                      child: const Text("Enable"),
                    ),
                  ],
                ),
              );
            },
          ),
          if (controller.globalEqEnabled) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 16, color: dim),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "EQ, tone, and limiter changes sync to other apps in real-time. "
                      "Parametric EQ, MBC, reverb, and stereo effects are not applied globally.",
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: dim),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            _PlayingAppsRow(controller: controller),
          ],
        ]),
      ],
    );
  }
}

class _PlayingAppsRow extends StatelessWidget {
  const _PlayingAppsRow({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final apps = controller.playingApps;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
          child: Row(children: [
            Icon(Icons.apps, size: 16, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text("Apps currently playing",
                  style: Theme.of(context).textTheme.bodyMedium),
            ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              tooltip: "Refresh",
              visualDensity: VisualDensity.compact,
              onPressed: () => controller.refreshPlayingApps(),
            ),
          ]),
        ),
        if (apps.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              "None detected",
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.5),
                  ),
            ),
          )
        else
          ...apps.map((app) => _AppIconTile(
                packageName: app['package'] ?? '',
                appName: app['name'] ?? app['package'] ?? '',
              )),
        const SizedBox(height: 4),
      ],
    );
  }
}

class _AppIconTile extends StatefulWidget {
  const _AppIconTile({required this.packageName, required this.appName});
  final String packageName;
  final String appName;

  @override
  State<_AppIconTile> createState() => _AppIconTileState();
}

class _AppIconTileState extends State<_AppIconTile> {
  Uint8List? _iconBytes;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadIcon();
  }

  Future<void> _loadIcon() async {
    final bytes = await Channel.getAppIcon(widget.packageName);
    if (mounted) {
      setState(() {
        _iconBytes = bytes;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(children: [
        SizedBox(
          width: 36,
          height: 36,
          child: _loaded
              ? (_iconBytes != null
                  ? Image.memory(_iconBytes!, fit: BoxFit.contain)
                  : Icon(Icons.music_note, size: 24, color: scheme.primary))
              : const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.appName,
                  style: Theme.of(context).textTheme.bodyMedium),
              Text(
                widget.packageName,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.4),
                    ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ]),
    );
  }
}
