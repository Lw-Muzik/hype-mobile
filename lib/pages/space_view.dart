import '../models/stereo_expand.dart';
import '/controllers/app_controller.dart';

import 'package:eq_app/models/room_preset.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'audio_fx.dart';
import 'volume_controls.dart';

class SpaceView extends StatefulWidget {
  const SpaceView({super.key});

  @override
  State<SpaceView> createState() => _SpaceViewState();
}

class _SpaceViewState extends State<SpaceView> {
  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        // =============== 3D SURROUND ===============
        // A port of the desktop stage: six virtual speakers rendered
        // binaurally, not a widening effect. See surround3d.h for why every
        // constant matches desktop's.
        const SettingsHeader(title: "3D SURROUND"),
        const SizedBox(height: 8),
        FancyCard(
          isFancy: controller.isFancy,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile.adaptive(
                title: const Text("3D Surround"),
                subtitle: Text(
                  controller.surround3dEnabled
                      ? "Virtual speaker ring — headphones"
                      : "Disabled",
                ),
                value: controller.surround3dEnabled,
                onChanged: (v) => controller.surround3dEnabled = v,
              ),
              if (controller.surround3dEnabled) ...[
                _SurroundRing(controller: controller),
                _buildReverbSlider(
                  context,
                  label: "Intensity",
                  leftLabel: "Subtle",
                  rightLabel: "Full",
                  value: controller.surround3dIntensity,
                  min: 0.0,
                  max: 1.0,
                  displayValue:
                      "${(controller.surround3dIntensity * 100).round()}%",
                  onChanged: (v) => controller.surround3dIntensity = v,
                ),
                _buildReverbSlider(
                  context,
                  label: "Subwoofer",
                  leftLabel: "Off",
                  rightLabel: "Deep",
                  value: controller.surround3dSubwoofer,
                  min: 0.0,
                  max: 1.0,
                  displayValue:
                      "${(controller.surround3dSubwoofer * 100).round()}%",
                  onChanged: (v) => controller.surround3dSubwoofer = v,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    "Best on headphones. Turning a side speaker off folds its "
                    "highs back into the front, so the image changes without "
                    "losing treble.",
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),

        // =============== ROOM REVERB ===============
        const SettingsHeader(title: "ROOM REVERB"),
        const SizedBox(height: 8),
        FancyCard(
          isFancy: controller.isFancy,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile.adaptive(
                title: const Text("Room Reverb"),
                subtitle: Text(
                  controller.reverbEnabled
                      ? controller.activeRoomPresetName
                      : "Disabled",
                ),
                value: controller.reverbEnabled,
                onChanged: (v) => controller.reverbEnabled = v,
              ),
              if (controller.reverbEnabled) ...[
                const SizedBox(height: 8),
                _buildPresetChips(controller, theme),
                const Divider(height: 24),
                _buildReverbSlider(
                  context,
                  label: "Room Size",
                  leftLabel: "Tiny",
                  rightLabel: "Cathedral",
                  value: controller.dspRoomSize,
                  min: 0.0,
                  max: 1.0,
                  displayValue:
                      "${(controller.dspRoomSize * 100).toStringAsFixed(0)}%",
                  onChanged: (v) {
                    controller.dspRoomSize = v;
                    _markCustomPreset(controller);
                  },
                ),
                _buildReverbSlider(
                  context,
                  label: "Decay",
                  leftLabel: "Short",
                  rightLabel: "Long",
                  value: controller.dspDecay,
                  min: 0.0,
                  max: 1.0,
                  displayValue:
                      "${(controller.dspDecay * 100).toStringAsFixed(0)}%",
                  onChanged: (v) {
                    controller.dspDecay = v;
                    _markCustomPreset(controller);
                  },
                ),
                _buildReverbSlider(
                  context,
                  label: "Damping",
                  leftLabel: "Bright",
                  rightLabel: "Dark",
                  value: controller.dspDamping,
                  min: 0.0,
                  max: 1.0,
                  displayValue:
                      "${(controller.dspDamping * 100).toStringAsFixed(0)}%",
                  onChanged: (v) {
                    controller.dspDamping = v;
                    _markCustomPreset(controller);
                  },
                ),
                _buildReverbSlider(
                  context,
                  label: "Pre-Delay",
                  leftLabel: "0 ms",
                  rightLabel: "200 ms",
                  value: controller.dspPreDelay,
                  min: 0.0,
                  max: 200.0,
                  displayValue:
                      "${controller.dspPreDelay.toStringAsFixed(0)} ms",
                  onChanged: (v) {
                    controller.dspPreDelay = v;
                    _markCustomPreset(controller);
                  },
                ),
                _buildReverbSlider(
                  context,
                  label: "Diffusion",
                  leftLabel: "Sparse",
                  rightLabel: "Dense",
                  value: controller.dspDiffusion,
                  min: 0.0,
                  max: 1.0,
                  displayValue:
                      "${(controller.dspDiffusion * 100).toStringAsFixed(0)}%",
                  onChanged: (v) {
                    controller.dspDiffusion = v;
                    _markCustomPreset(controller);
                  },
                ),
                _buildReverbSlider(
                  context,
                  label: "Wet/Dry",
                  leftLabel: "Dry",
                  rightLabel: "Wet",
                  value: controller.dspWetDry,
                  min: 0.0,
                  max: 1.0,
                  displayValue:
                      "${(controller.dspWetDry * 100).toStringAsFixed(0)}%",
                  onChanged: (v) {
                    controller.dspWetDry = v;
                    _markCustomPreset(controller);
                  },
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),

        // =============== STEREO ENHANCEMENT ===============
        const SettingsHeader(title: "STEREO ENHANCEMENT"),
        const SizedBox(height: 8),
        FancyCard(
          isFancy: controller.isFancy,
          child: Column(
            children: [
              // One control, as the effect has one setting: 0 is off, and
              // anything above it widens. No switch to forget about.
              ListTile(
                title: const Text("Stereo Expand"),
                subtitle: Text(
                  controller.systemWideDisabledReason ??
                      "Widens the stereo image",
                ),
                trailing: Text(
                  controller.stereoExpandEnabled
                      ? StereoExpand.label(controller.stereoExpand)
                      : "Off",
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: controller.stereoExpandEnabled
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Text(
                      "Off",
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.5,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        value: controller.stereoExpand,
                        min: StereoExpand.min,
                        max: StereoExpand.max,
                        divisions: StereoExpand.divisions,
                        label: StereoExpand.label(controller.stereoExpand),
                        // The platform equalizer cannot carry it: held off
                        // (the stored amount is kept) while system-wide.
                        onChanged: controller.systemWideActive
                            ? null
                            : (v) {
                                final crossfeedWasOn = controller.crossfeedEnabled;
                                controller.stereoExpand = v;
                                if (v > 0 && crossfeedWasOn) {
                                  _showMutualExclusiveToast("Crossfeed disabled");
                                }
                              },
                      ),
                    ),
                    Text(
                      "100%",
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: _StereoFieldIndicator(
                  // The indicator's 0.5 is an untouched stereo image; the
                  // expander only ever widens from there.
                  width: 0.5 + controller.stereoExpand * 0.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // =============== VOLUME ===============
        // Balance, mono and tempo. They sat under the tone knobs, which made
        // that page scroll on a phone and a knob drag read as a scroll.
        const SettingsHeader(title: "VOLUME"),
        const SizedBox(height: 8),
        FancyCard(
          isFancy: controller.isFancy,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: VolumeControls(
              settings: controller.dspCore,
              onChanged: (v) => controller.dspCore = v,
              stereoExpand: controller.stereoExpand,
              onStereoExpand: (v) => controller.stereoExpand = v,
              disabledReason: controller.systemWideDisabledReason,
            ),
          ),
        ),
        const SizedBox(height: 16),

        // =============== CROSSFEED ===============
        const SettingsHeader(title: "CROSSFEED"),
        const SizedBox(height: 8),
        FancyCard(
          isFancy: controller.isFancy,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile.adaptive(
                title: const Text("Crossfeed"),
                subtitle: Text(
                  controller.crossfeedEnabled
                      ? _crossfeedLabel(controller.crossfeedFeed)
                      : "Disabled",
                ),
                value: controller.crossfeedEnabled,
                onChanged: (v) {
                  final expandWasOn = controller.stereoExpandEnabled;
                  controller.crossfeedEnabled = v;
                  if (v && expandWasOn) {
                    _showMutualExclusiveToast("Stereo Expand set to off");
                  }
                },
              ),
              if (controller.crossfeedEnabled) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _CrossfeedPresetChip(
                        label: "Light",
                        cutoff: 700,
                        feed: 4.5,
                        currentFeed: controller.crossfeedFeed,
                        onTap: () {
                          controller.crossfeedCutoff = 700;
                          controller.crossfeedFeed = 4.5;
                        },
                      ),
                      _CrossfeedPresetChip(
                        label: "Normal",
                        cutoff: 700,
                        feed: 6.0,
                        currentFeed: controller.crossfeedFeed,
                        onTap: () {
                          controller.crossfeedCutoff = 700;
                          controller.crossfeedFeed = 6.0;
                        },
                      ),
                      _CrossfeedPresetChip(
                        label: "Strong",
                        cutoff: 650,
                        feed: 9.5,
                        currentFeed: controller.crossfeedFeed,
                        onTap: () {
                          controller.crossfeedCutoff = 650;
                          controller.crossfeedFeed = 9.5;
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                _buildReverbSlider(
                  context,
                  label: "Feed Level",
                  leftLabel: "Subtle",
                  rightLabel: "Strong",
                  value: controller.crossfeedFeed,
                  min: 1.0,
                  max: 15.0,
                  displayValue:
                      "${controller.crossfeedFeed.toStringAsFixed(1)} dB",
                  onChanged: (v) => controller.crossfeedFeed = v,
                ),
                _buildReverbSlider(
                  context,
                  label: "Cutoff",
                  leftLabel: "100 Hz",
                  rightLabel: "2000 Hz",
                  value: controller.crossfeedCutoff,
                  min: 100.0,
                  max: 2000.0,
                  displayValue:
                      "${controller.crossfeedCutoff.toStringAsFixed(0)} Hz",
                  onChanged: (v) => controller.crossfeedCutoff = v,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    "Crossfeed blends a filtered portion of each stereo channel into the other, "
                    "reducing the exaggerated separation heard in headphones for a more "
                    "natural, speaker-like presentation.",
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildPresetChips(AppController controller, ThemeData theme) {
    final accent = theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: GestureDetector(
        onTap: () => _openRoomPresetSheet(context, controller),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: Row(
            children: [
              Icon(
                Icons.spatial_audio_rounded,
                size: 18,
                color: accent.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Preset",
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      controller.activeRoomPresetName.isEmpty
                          ? 'Custom'
                          : controller.activeRoomPresetName,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 22,
                color: Colors.white.withValues(alpha: 0.4),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openRoomPresetSheet(BuildContext context, AppController controller) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _RoomPresetBottomSheet(controller: controller),
    );
  }

  Widget _buildReverbSlider(
    BuildContext context, {
    required String label,
    required String leftLabel,
    required String rightLabel,
    required double value,
    required double min,
    required double max,
    required String displayValue,
    required ValueChanged<double> onChanged,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: theme.textTheme.bodyMedium),
              Text(
                displayValue,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          Row(
            children: [
              Text(
                leftLabel,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  fontSize: 11,
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 7,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                  ),
                  child: Slider(
                    value: value.clamp(min, max),
                    min: min,
                    max: max,
                    onChanged: onChanged,
                  ),
                ),
              ),
              Text(
                rightLabel,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _markCustomPreset(AppController controller) {
    final presets = RoomPreset.builtIn;
    for (final p in presets) {
      if ((p.roomSize - controller.dspRoomSize).abs() < 0.01 &&
          (p.decay - controller.dspDecay).abs() < 0.01 &&
          (p.damping - controller.dspDamping).abs() < 0.01 &&
          (p.preDelay - controller.dspPreDelay).abs() < 0.5 &&
          (p.diffusion - controller.dspDiffusion).abs() < 0.01 &&
          (p.wetDry - controller.dspWetDry).abs() < 0.01) {
        controller.activeRoomPresetName = p.name;
        return;
      }
    }
    controller.activeRoomPresetName = 'Custom';
  }

  String _crossfeedLabel(double feedDb) {
    if (feedDb < 3.0) return "Very Light";
    if (feedDb < 5.5) return "Light";
    if (feedDb < 8.0) return "Normal";
    return "Strong";
  }

  void _showMutualExclusiveToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

// =============================================================================
// Room Preset Bottom Sheet
// =============================================================================

class _RoomPresetBottomSheet extends StatelessWidget {
  final AppController controller;
  const _RoomPresetBottomSheet({required this.controller});

  static const _accent = Color(0xFFD4A825);

  IconData _iconForPreset(String name) {
    final lower = name.toLowerCase();
    if (lower == 'off') return Icons.volume_off_rounded;
    if (lower.contains('small')) return Icons.weekend_rounded;
    if (lower.contains('medium')) return Icons.living_rounded;
    if (lower.contains('large')) return Icons.home_rounded;
    if (lower.contains('hall')) return Icons.account_balance_rounded;
    if (lower.contains('cathedral')) return Icons.church_rounded;
    if (lower.contains('plate')) return Icons.rectangle_rounded;
    if (lower.contains('studio')) return Icons.headphones_rounded;
    if (lower.contains('chamber')) return Icons.door_sliding_rounded;
    if (lower.contains('arena')) return Icons.stadium_rounded;
    if (lower.contains('concert')) return Icons.theater_comedy_rounded;
    return Icons.spatial_audio_rounded;
  }

  String _description(RoomPreset p) {
    if (p.name == 'Off') return 'No reverb';
    final sizeLabel = p.roomSize < 0.3
        ? 'Tight'
        : p.roomSize < 0.6
        ? 'Medium'
        : 'Spacious';
    final decayLabel = p.decay < 0.3
        ? 'short decay'
        : p.decay < 0.6
        ? 'moderate decay'
        : 'long decay';
    return '$sizeLabel, $decayLabel, ${(p.wetDry * 100).round()}% wet';
  }

  @override
  Widget build(BuildContext context) {
    final presets = RoomPreset.builtIn;
    final active = controller.activeRoomPresetName;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.55,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Title
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: [
                const Icon(
                  Icons.spatial_audio_rounded,
                  color: _accent,
                  size: 20,
                ),
                const SizedBox(width: 8),
                const Text(
                  "Room Presets",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  "${presets.length} presets",
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ),
          // Preset list
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).padding.bottom + 16,
              ),
              itemCount: presets.length,
              itemBuilder: (context, index) {
                final preset = presets[index];
                final isActive = preset.name == active;
                return InkWell(
                  onTap: () {
                    controller.applyRoomPreset(preset);
                    Navigator.pop(context);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    color: isActive ? _accent.withValues(alpha: 0.1) : null,
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: isActive
                                ? _accent.withValues(alpha: 0.2)
                                : Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            _iconForPreset(preset.name),
                            size: 18,
                            color: isActive
                                ? _accent
                                : Colors.white.withValues(alpha: 0.4),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                preset.name,
                                style: TextStyle(
                                  color: isActive
                                      ? _accent
                                      : Colors.white.withValues(alpha: 0.85),
                                  fontSize: 14,
                                  fontWeight: isActive
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                              Text(
                                _description(preset),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.white.withValues(alpha: 0.35),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (isActive)
                          const Icon(
                            Icons.check_rounded,
                            color: _accent,
                            size: 20,
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Visual indicator showing the stereo field width.
class _StereoFieldIndicator extends StatelessWidget {
  final double width; // 0.0 to 1.0

  const _StereoFieldIndicator({required this.width});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 32,
      child: CustomPaint(
        size: const Size(double.infinity, 32),
        painter: _StereoFieldPainter(
          width: width,
          color: theme.colorScheme.primary,
          bgColor: theme.colorScheme.surfaceContainerHighest,
        ),
      ),
    );
  }
}

class _StereoFieldPainter extends CustomPainter {
  final double width;
  final Color color;
  final Color bgColor;

  _StereoFieldPainter({
    required this.width,
    required this.color,
    required this.bgColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()
      ..color = bgColor
      ..style = PaintingStyle.fill;
    final fgPaint = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..style = PaintingStyle.fill;

    final centerX = size.width / 2;
    final centerY = size.height / 2;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, centerY - 4, size.width, 8),
        const Radius.circular(4),
      ),
      bgPaint,
    );

    final spread = (size.width / 2) * width.clamp(0.0, 1.0);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(centerX - spread, centerY - 6, spread * 2, 12),
        const Radius.circular(6),
      ),
      fgPaint,
    );

    final textStyle = TextStyle(
      color: color,
      fontSize: 10,
      fontWeight: FontWeight.bold,
    );
    final lPainter = TextPainter(
      text: TextSpan(text: 'L', style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final rPainter = TextPainter(
      text: TextSpan(text: 'R', style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();

    lPainter.paint(canvas, Offset(4, centerY - lPainter.height / 2));
    rPainter.paint(
      canvas,
      Offset(size.width - rPainter.width - 4, centerY - rPainter.height / 2),
    );
  }

  @override
  bool shouldRepaint(_StereoFieldPainter old) =>
      old.width != width || old.color != color;
}

/// Crossfeed intensity preset chip (BS2B standard presets).
class _CrossfeedPresetChip extends StatelessWidget {
  final String label;
  final double cutoff;
  final double feed;
  final double currentFeed;
  final VoidCallback onTap;

  const _CrossfeedPresetChip({
    required this.label,
    required this.cutoff,
    required this.feed,
    required this.currentFeed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSelected = (currentFeed - feed).abs() < 0.3;
    return ActionChip(
      label: Text(label),
      onPressed: onTap,
      backgroundColor: isSelected
          ? theme.colorScheme.primary
          : theme.colorScheme.surfaceContainerLow,
      labelStyle: TextStyle(
        color: isSelected
            ? theme.colorScheme.onPrimary
            : theme.colorScheme.onSurface,
        fontSize: 13,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    );
  }
}

/// The speaker ring, laid out the way they sit around the listener.
///
/// The desktop panel draws this as an SVG radial diagram in a modal. On a phone
/// a modal for six toggles is a detour, so the same six sit in the card at
/// their real angles — front pair at the top, sides at the edges, surrounds at
/// the bottom — which is the part of the desktop diagram that carries meaning.
class _SurroundRing extends StatelessWidget {
  final AppController controller;

  const _SurroundRing({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _SpeakerChip(
                label: 'Front L',
                on: controller.s3dFrontL,
                onTap: () => controller.setSurroundSpeaker(
                  'frontL',
                  !controller.s3dFrontL,
                ),
              ),
              const SizedBox(width: 10),
              _SpeakerChip(
                label: 'Front R',
                on: controller.s3dFrontR,
                onTap: () => controller.setSurroundSpeaker(
                  'frontR',
                  !controller.s3dFrontR,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _SpeakerChip(
                label: 'Side L',
                on: controller.s3dSideL,
                onTap: () => controller.setSurroundSpeaker(
                  'sideL',
                  !controller.s3dSideL,
                ),
              ),
              Icon(
                Icons.person_rounded,
                size: 20,
                color: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: 0.35),
              ),
              _SpeakerChip(
                label: 'Side R',
                on: controller.s3dSideR,
                onTap: () => controller.setSurroundSpeaker(
                  'sideR',
                  !controller.s3dSideR,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _SpeakerChip(
                label: 'Rear L',
                on: controller.s3dSurroundL,
                onTap: () => controller.setSurroundSpeaker(
                  'surroundL',
                  !controller.s3dSurroundL,
                ),
              ),
              const SizedBox(width: 10),
              _SpeakerChip(
                label: 'Rear R',
                on: controller.s3dSurroundR,
                onTap: () => controller.setSurroundSpeaker(
                  'surroundR',
                  !controller.s3dSurroundR,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SpeakerChip extends StatelessWidget {
  final String label;
  final bool on;
  final VoidCallback onTap;

  const _SpeakerChip({
    required this.label,
    required this.on,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: on ? accent.withValues(alpha: 0.18) : Colors.transparent,
          border: Border.all(
            color: on
                ? accent.withValues(alpha: 0.7)
                : theme.colorScheme.onSurface.withValues(alpha: 0.2),
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              on ? Icons.volume_up_rounded : Icons.volume_off_rounded,
              size: 15,
              color: on
                  ? accent
                  : theme.colorScheme.onSurface.withValues(alpha: 0.45),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: on
                    ? accent
                    : theme.colorScheme.onSurface.withValues(alpha: 0.55),
                fontWeight: on ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
