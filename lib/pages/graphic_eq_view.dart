import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/eq_models.dart';
import 'audio_fx.dart';
import '../themes/ember.dart';

/// The app's one accent, not a fifth colour invented for this screen.
///
/// This page used to carry four: a red tab indicator from the theme, a muted
/// gold for boost, a cyan for cut, and white knobs. None of them was the logo's.
const Color _kAccent = Ember.accent;

/// A cut is the same colour as a boost, dimmed — not a second hue.
///
/// Cyan against gold read as two unrelated controls rather than one control
/// pushed either side of flat.
const Color _kCut = Color(0xFFB08A2E);
const double _kMinGain = -15.0;
const double _kMaxGain = 15.0;

class GraphicEqView extends StatefulWidget {
  const GraphicEqView({super.key});

  @override
  State<GraphicEqView> createState() => _GraphicEqViewState();
}

class _GraphicEqViewState extends State<GraphicEqView> {
  int _activeBand = -1;
  int _curveDragBand = -1;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final mapping = controller.currentBandMapping;
    final displayGains = controller.displayBandGains;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeaderRow(controller),
          const SizedBox(height: 8),
          Expanded(
            child: FancyCard(
              isFancy: controller.isFancy,
              child: Column(
                children: [
                  _buildPreampRow(controller),
                  _buildLimiterRow(controller),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Container(
                      height: 0.5,
                      color: Colors.white.withValues(alpha: 0.06),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: _buildCurve(controller, displayGains, mapping),
                  ),
                  const SizedBox(height: 2),
                  Expanded(
                    flex: 4,
                    // Capped, then centred. Stretched to fill a tall phone the
                    // faders ran to ~450px against an 11px cap, which reads as
                    // a bar chart rather than something to grip.
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 300),
                        child: _buildBandSliders(
                            controller, displayGains, mapping),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          _buildPresetsRow(controller),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 1. Header: power, title, flatten, band count
  // ---------------------------------------------------------------------------

  Widget _buildHeaderRow(AppController controller) {
    return Row(
      children: [
        Text(
          "Graphic EQ",
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const Spacer(),
        // Flatten all bands to 0 dB
        SizedBox(
          width: 32,
          height: 32,
          child: IconButton(
            padding: EdgeInsets.zero,
            icon: Icon(
              Icons.restart_alt_rounded,
              size: 19,
              color: Colors.white.withValues(alpha: 0.35),
            ),
            tooltip: "Flatten bands",
            onPressed: () {
              final gains = controller.displayBandGains;
              for (int i = 0; i < gains.length; i++) {
                controller.setDisplayBandGain(i, 0.0);
              }
              controller.activePresetName = 'Flat';
            },
          ),
        ),
        const SizedBox(width: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(8),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: controller.eqBandCount,
              isDense: true,
              dropdownColor: const Color(0xFF1E1E2E),
              style: const TextStyle(color: Colors.white70, fontSize: 13),
              items: BandMapping.supportedCounts
                  .map(
                    (c) => DropdownMenuItem(value: c, child: Text('$c bands')),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) controller.eqBandCount = v;
              },
            ),
          ),
        ),
      ],
    );
  }

  /// Output limiter: the safety net that catches boosts clipping.
  Widget _buildLimiterRow(AppController controller) {
    return Row(
      children: [
        Icon(
          Icons.shield_outlined,
          size: 16,
          color: _kAccent.withValues(alpha: 0.7),
        ),
        const SizedBox(width: 6),
        Text(
          "Limiter",
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: Colors.white.withValues(alpha: 0.5),
          ),
        ),
        const Spacer(),
        SizedBox(
          height: 28,
          child: Switch(
            value: controller.limiterEnabled,
            activeTrackColor: _kAccent.withValues(alpha: 0.5),
            activeThumbColor: _kAccent,
            onChanged: (v) => controller.limiterEnabled = v,
          ),
        ),
      ],
    );
  }

  Widget _buildPreampRow(AppController controller) {
    return Row(
      children: [
        Icon(
          Icons.volume_up_rounded,
          size: 16,
          color: _kAccent.withValues(alpha: 0.7),
        ),
        const SizedBox(width: 6),
        Text(
          "Pre",
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: Colors.white.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              activeTrackColor: _kAccent,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
              thumbColor: _kAccent,
              overlayColor: _kAccent.withValues(alpha: 0.08),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: controller.preampGain,
              min: -24,
              max: 24,
              onChanged: (v) => controller.preampGain = v,
            ),
          ),
        ),
        SizedBox(
          width: 42,
          child: Text(
            '${controller.preampGain >= 0 ? "+" : ""}${controller.preampGain.toStringAsFixed(1)}',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: controller.preampGain.abs() > 0.05
                  ? _kAccent
                  : Colors.white.withValues(alpha: 0.35),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Curve (inside EQ surface — no card wrapper)
  // ---------------------------------------------------------------------------

  Widget _buildCurve(
    AppController controller,
    List<double> gains,
    BandMapping mapping,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;

        return GestureDetector(
          onPanStart: (details) {
            _curveDragBand = _findNearestBand(
              details.localPosition,
              gains,
              mapping.frequencies,
              width,
              height,
            );
            if (_curveDragBand >= 0) {
              _updateBandFromCurve(
                controller,
                _curveDragBand,
                details.localPosition,
                height,
              );
            }
          },
          onPanUpdate: (details) {
            if (_curveDragBand >= 0) {
              _updateBandFromCurve(
                controller,
                _curveDragBand,
                details.localPosition,
                height,
              );
            }
          },
          onPanEnd: (_) {
            _curveDragBand = -1;
            controller.commitGraphicGains();
          },
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _FrequencyCurvePainter(
                gains: gains,
                frequencies: mapping.frequencies,
                accent: _kAccent,
                activeBand: _curveDragBand,
              ),
              size: Size(width, height),
            ),
          ),
        );
      },
    );
  }

  int _findNearestBand(
    Offset pos,
    List<double> gains,
    List<double> frequencies,
    double width,
    double height,
  ) {
    const padLeft = 32.0;
    const padRight = 8.0;
    final plotW = width - padLeft - padRight;

    double bestDist = 40.0;
    int bestBand = -1;

    for (int i = 0; i < gains.length; i++) {
      final x =
          padLeft +
          _FrequencyCurvePainter._logNormalize(frequencies[i]) * plotW;
      final dist = (pos.dx - x).abs();
      if (dist < bestDist) {
        bestDist = dist;
        bestBand = i;
      }
    }
    return bestBand;
  }

  void _updateBandFromCurve(
    AppController controller,
    int band,
    Offset pos,
    double height,
  ) {
    const padTop = 12.0;
    const padBottom = 20.0;
    final plotH = height - padTop - padBottom;
    final normY = ((pos.dy - padTop) / plotH).clamp(0.0, 1.0);
    final gain = _kMaxGain - normY * (_kMaxGain - _kMinGain);
    final rounded = (gain * 10).roundToDouble() / 10;
    // Real-time audio only — persisted once on pan-end (same pattern as the
    // band sliders); the debounced safety net in the controller covers any
    // path that never reaches pan-end.
    controller.setDisplayBandGain(
      band,
      rounded.clamp(_kMinGain, _kMaxGain),
      persist: false,
    );
    controller.activePresetName = 'Custom';
    setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Band sliders (inside EQ surface — no card wrapper)
  // ---------------------------------------------------------------------------

  Widget _buildBandSliders(
    AppController controller,
    List<double> displayGains,
    BandMapping mapping,
  ) {
    final bandCount = mapping.displayCount;
    final frequencies = mapping.frequencies;

    bool showLabel(int i) {
      if (bandCount <= 10) return true;
      if (bandCount <= 16) return i % 2 == 0 || i == bandCount - 1;
      return i % 4 == 0 || i == bandCount - 1;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;

        if (bandCount <= 10) {
          final bandWidth = availableWidth / bandCount;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(bandCount, (i) {
              return _BandSlider(
                frequency: frequencies[i],
                gain: displayGains[i],
                width: bandWidth,
                isActive: _activeBand == i,
                showLabel: showLabel(i),
                onChanged: (value) {
                  // Real-time audio only; persist once on drag-end (below).
                  controller.setDisplayBandGain(i, value, persist: false);
                },
                onDragStart: () {
                  controller.activePresetName = 'Custom';
                  setState(() => _activeBand = i);
                },
                onDragEnd: () {
                  controller.commitGraphicGains();
                  setState(() => _activeBand = -1);
                },
              );
            }),
          );
        }

        const fixedBandWidth = 38.0;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(bandCount, (i) {
              return _BandSlider(
                frequency: frequencies[i],
                gain: displayGains[i],
                width: fixedBandWidth,
                isActive: _activeBand == i,
                showLabel: showLabel(i),
                onChanged: (value) {
                  // Real-time audio only; persist once on drag-end (below).
                  controller.setDisplayBandGain(i, value, persist: false);
                },
                onDragStart: () {
                  controller.activePresetName = 'Custom';
                  setState(() => _activeBand = i);
                },
                onDragEnd: () {
                  controller.commitGraphicGains();
                  setState(() => _activeBand = -1);
                },
              );
            }),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 3. Preset button + bottom sheet
  // ---------------------------------------------------------------------------

  Widget _buildPresetsRow(AppController controller) {
    return GestureDetector(
      onTap: () => _openPresetSheet(context, controller),
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
              Icons.tune_rounded,
              size: 18,
              color: _kAccent.withValues(alpha: 0.8),
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
                    controller.activePresetName.isEmpty
                        ? 'Custom'
                        : controller.activePresetName,
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
    );
  }

  void _openPresetSheet(BuildContext context, AppController controller) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PresetBottomSheet(
        controller: controller,
        onSave: () => _showSaveDialog(context, controller),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Save dialog
  // ---------------------------------------------------------------------------

  void _showSaveDialog(BuildContext context, AppController controller) {
    final nameController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Save Preset"),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: "Preset name",
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _kAccent),
            onPressed: () {
              final name = nameController.text.trim();
              if (name.isNotEmpty) {
                controller.savePreset(name);
                controller.activePresetName = name;
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Preset "$name" saved'),
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(milliseconds: 1800),
                    backgroundColor: _kAccent,
                  ),
                );
              }
            },
            child: const Text("Save"),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Preset Bottom Sheet
// =============================================================================

class _PresetBottomSheet extends StatefulWidget {
  final AppController controller;
  final VoidCallback onSave;

  const _PresetBottomSheet({required this.controller, required this.onSave});

  @override
  State<_PresetBottomSheet> createState() => _PresetBottomSheetState();
}

class _PresetBottomSheetState extends State<_PresetBottomSheet> {
  String _query = '';
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final builtIn = BuiltInPresets.names;
    final saved = widget.controller.savedPresets.keys
        .where((k) => !k.startsWith('_device_'))
        .toList();
    final all = [...builtIn, ...saved];
    final filtered = _query.isEmpty
        ? all
        : all
              .where((n) => n.toLowerCase().contains(_query.toLowerCase()))
              .toList();
    final active = widget.controller.activePresetName;
    final screenH = MediaQuery.of(context).size.height;

    return Container(
      constraints: BoxConstraints(maxHeight: screenH * 0.6),
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
          // Title row
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
            child: Row(
              children: [
                const Icon(Icons.tune_rounded, color: _kAccent, size: 20),
                const SizedBox(width: 8),
                const Text(
                  "EQ Presets",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                // Save button
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    widget.onSave();
                  },
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text("Save Current"),
                  style: TextButton.styleFrom(
                    foregroundColor: _kAccent,
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          // Search
          if (all.length > 8)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _searchController,
                onChanged: (v) => setState(() => _query = v),
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search presets...',
                  hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                  ),
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    size: 20,
                    color: Colors.white.withValues(alpha: 0.3),
                  ),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.08),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          // Preset list
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).padding.bottom + 16,
              ),
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final name = filtered[index];
                final isActive = name == active;
                final isUser = saved.contains(name);
                return _PresetTile(
                  name: name,
                  isActive: isActive,
                  isUser: isUser,
                  onTap: () {
                    if (isUser) {
                      widget.controller.loadPreset(name);
                    } else {
                      widget.controller.applyBuiltInPreset(name);
                    }
                    Navigator.pop(context);
                  },
                  onDelete: isUser
                      ? () {
                          widget.controller.deletePreset(name);
                          setState(() {});
                        }
                      : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PresetTile extends StatelessWidget {
  final String name;
  final bool isActive;
  final bool isUser;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _PresetTile({
    required this.name,
    required this.isActive,
    required this.isUser,
    required this.onTap,
    this.onDelete,
  });

  IconData get _icon {
    final lower = name.toLowerCase();
    if (lower.contains('bass')) return Icons.speaker_rounded;
    if (lower.contains('rock')) return Icons.whatshot_rounded;
    if (lower.contains('pop')) return Icons.stars_rounded;
    if (lower.contains('jazz')) return Icons.piano_rounded;
    if (lower.contains('classical')) return Icons.music_note_rounded;
    if (lower.contains('vocal') || lower.contains('voice'))
      return Icons.mic_rounded;
    if (lower.contains('dance') || lower.contains('edm'))
      return Icons.nightlife_rounded;
    if (lower.contains('flat')) return Icons.horizontal_rule_rounded;
    if (lower.contains('treble')) return Icons.graphic_eq_rounded;
    if (lower.contains('loudness')) return Icons.volume_up_rounded;
    if (isUser) return Icons.person_rounded;
    return Icons.equalizer_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: isActive ? _kAccent.withValues(alpha: 0.1) : null,
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: isActive
                    ? _kAccent.withValues(alpha: 0.2)
                    : Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                _icon,
                size: 18,
                color: isActive
                    ? _kAccent
                    : Colors.white.withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      color: isActive
                          ? _kAccent
                          : Colors.white.withValues(alpha: 0.85),
                      fontSize: 14,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (isUser)
                    Text(
                      "Custom preset",
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.35),
                      ),
                    ),
                ],
              ),
            ),
            if (isActive)
              const Icon(Icons.check_rounded, color: _kAccent, size: 20),
            if (onDelete != null && !isActive)
              GestureDetector(
                onTap: onDelete,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.delete_outline_rounded,
                    size: 18,
                    color: Colors.white.withValues(alpha: 0.25),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Band Slider
// =============================================================================

/// A fader that grows out of 0 dB.
///
/// The old one was a Material [Slider] in a `RotatedBox`, fed `(gain - min) /
/// (max - min)`. That maps −15 dB to an empty bar and 0 dB to a half-full one,
/// so the fill measured *distance from the floor* — a volume level. A band at
/// flat looked half-boosted, a deep cut looked like "almost nothing" rather
/// than "pulled well down", and there was no mark on the track saying where
/// flat was.
///
/// Gain is signed, so the fill starts at the centre and runs up for a boost or
/// down for a cut, against a rule drawn at 0. Flat now reads as flat: no fill
/// at all, just the rule.
class _BandSlider extends StatefulWidget {
  final double frequency;
  final double gain;
  final double width;
  final bool isActive;
  final bool showLabel;
  final ValueChanged<double> onChanged;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;

  const _BandSlider({
    required this.frequency,
    required this.gain,
    required this.width,
    required this.isActive,
    required this.showLabel,
    required this.onChanged,
    required this.onDragStart,
    required this.onDragEnd,
  });

  @override
  State<_BandSlider> createState() => _BandSliderState();
}

class _BandSliderState extends State<_BandSlider> {
  /// Height of the last laid-out track, so a tap can be turned into a gain.
  double _trackHeight = 0;

  /// Whether the last reported gain was above flat, so the detent fires once
  /// per crossing instead of on every pixel of a drag that sits near zero.
  bool? _wasPositive;

  String get _freqLabel {
    final f = widget.frequency;
    if (f >= 1000) {
      final k = f / 1000;
      return k == k.roundToDouble()
          ? '${k.round()}k'
          : '${k.toStringAsFixed(1)}k';
    }
    return f >= 100 ? '${f.round()}' : f.toStringAsFixed(1);
  }

  /// Turns a y inside the track into a gain, centre-out.
  double _gainAt(double localY) {
    if (_trackHeight <= 0) return widget.gain;
    final half = _trackHeight / 2;
    final raw = (half - localY) / half * _kMaxGain;
    final rounded = (raw * 10).roundToDouble() / 10;
    return rounded.clamp(_kMinGain, _kMaxGain);
  }

  void _report(double gain) {
    // A detent at flat: the one value a person is most often trying to hit,
    // and the hardest to land on by dragging.
    final positive = gain > 0;
    if (_wasPositive != null && positive != _wasPositive && gain.abs() < 1.5) {
      HapticFeedback.selectionClick();
    }
    _wasPositive = positive;
    widget.onChanged(gain);
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.isActive;
    final boost = widget.gain > 0;
    final fillColor = boost ? _kAccent : _kCut;

    return SizedBox(
      width: widget.width,
      child: Column(
        children: [
          // Reserved whether or not it is showing, so nothing below it moves
          // when a drag starts.
          SizedBox(
            height: 16,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              opacity: active ? 1 : 0,
              child: FittedBox(
                child: Text(
                  '${widget.gain > 0 ? '+' : ''}${widget.gain.toStringAsFixed(1)}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: widget.gain == 0 ? Ember.textSecondary : fillColor,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                _trackHeight = constraints.maxHeight;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // The whole column is the target, not a 12px-wide rail.
                  onVerticalDragStart: (d) {
                    _wasPositive = widget.gain > 0;
                    widget.onDragStart();
                    _report(_gainAt(d.localPosition.dy));
                  },
                  onVerticalDragUpdate: (d) =>
                      _report(_gainAt(d.localPosition.dy)),
                  onVerticalDragEnd: (_) {
                    _wasPositive = null;
                    widget.onDragEnd();
                  },
                  onTapDown: (d) {
                    widget.onDragStart();
                    _report(_gainAt(d.localPosition.dy));
                  },
                  onTapUp: (_) => widget.onDragEnd(),
                  onTapCancel: widget.onDragEnd,
                  // Flat is a destination, so give it a gesture of its own
                  // rather than making someone drag for it.
                  onDoubleTap: () {
                    HapticFeedback.mediumImpact();
                    widget.onDragStart();
                    widget.onChanged(0);
                    widget.onDragEnd();
                  },
                  child: CustomPaint(
                    size: Size(widget.width, constraints.maxHeight),
                    painter: _FaderPainter(
                      gain: widget.gain,
                      fill: fillColor,
                      active: active,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 14,
            child: widget.showLabel
                ? FittedBox(
                    child: Text(
                      _freqLabel,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                        color: active ? _kAccent : Ember.textTertiary,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// Rail, the rule at flat, the signed fill, and the cap.
class _FaderPainter extends CustomPainter {
  final double gain;
  final Color fill;
  final bool active;

  const _FaderPainter({
    required this.gain,
    required this.fill,
    required this.active,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final centre = size.height / 2;
    final half = size.height / 2;
    const railW = 5.0;

    // Rail.
    final railRect = RRect.fromLTRBR(
      cx - railW / 2,
      0,
      cx + railW / 2,
      size.height,
      const Radius.circular(railW / 2),
    );
    canvas.drawRRect(
      railRect,
      Paint()..color = Colors.white.withValues(alpha: 0.07),
    );

    // The rule at flat. Wider than the rail so it reads as a datum the fills
    // are measured from rather than as part of the track.
    canvas.drawLine(
      Offset(cx - 9, centre),
      Offset(cx + 9, centre),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.20)
        ..strokeWidth = 1,
    );

    final y = centre - (gain / _kMaxGain) * half;

    // Signed fill, centre-out.
    if (gain.abs() > 0.05) {
      canvas.drawRRect(
        RRect.fromLTRBR(
          cx - railW / 2,
          math.min(centre, y),
          cx + railW / 2,
          math.max(centre, y),
          const Radius.circular(railW / 2),
        ),
        Paint()..color = fill.withValues(alpha: active ? 1.0 : 0.85),
      );
    }

    // Cap. A wide flat bar, the way a fader cap sits across its slot — a round
    // knob reads as a dot floating on the line.
    final capW = math.min(size.width - 10, 26.0);
    final capH = active ? 13.0 : 11.0;
    final capRect = RRect.fromLTRBR(
      cx - capW / 2,
      y - capH / 2,
      cx + capW / 2,
      y + capH / 2,
      const Radius.circular(3.5),
    );
    if (active) {
      canvas.drawRRect(
        RRect.fromLTRBR(
          cx - capW / 2 - 3,
          y - capH / 2 - 3,
          cx + capW / 2 + 3,
          y + capH / 2 + 3,
          const Radius.circular(6.5),
        ),
        Paint()
          ..color = fill.withValues(alpha: 0.28)
          ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 6),
      );
    }
    canvas.drawRRect(
      capRect,
      Paint()..color = gain.abs() > 0.05 ? fill : const Color(0xFF6E6E76),
    );
    // A notch, so the cap has a readable centre line at a glance.
    canvas.drawLine(
      Offset(cx - capW / 4, y),
      Offset(cx + capW / 4, y),
      Paint()
        ..color = Ember.ground.withValues(alpha: 0.55)
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_FaderPainter old) =>
      old.gain != gain || old.fill != fill || old.active != active;
}

// =============================================================================
// Frequency Response Curve Painter
// =============================================================================

class _FrequencyCurvePainter extends CustomPainter {
  final List<double> gains;
  final List<double> frequencies;
  final Color accent;
  final int activeBand;

  _FrequencyCurvePainter({
    required this.gains,
    required this.frequencies,
    required this.accent,
    this.activeBand = -1,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (gains.isEmpty || gains.length != frequencies.length) return;

    const double padLeft = 32;
    const double padRight = 8;
    const double padTop = 12;
    const double padBottom = 20;

    final plotW = size.width - padLeft - padRight;
    final plotH = size.height - padTop - padBottom;

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(padLeft, padTop, plotW, plotH));

    _drawGrid(canvas, size, padLeft, padRight, padTop, padBottom, plotW, plotH);

    final points = <Offset>[];
    for (int i = 0; i < gains.length; i++) {
      final x = padLeft + _logNormalize(frequencies[i]) * plotW;
      final y =
          padTop +
          plotH * (1.0 - (gains[i] - _kMinGain) / (_kMaxGain - _kMinGain));
      points.add(Offset(x, y));
    }

    final curvePath = _catmullRomPath(points);

    // The fill is bounded by the 0 dB line, not the floor of the plot.
    //
    // Closing it to the floor shaded everything between the curve and −15 dB,
    // so a modest boost painted three quarters of the chart and the picture
    // said "lots of everything" rather than "this much above flat". Bounded at
    // zero, the shaded area *is* the deviation — and a cut fills upward to the
    // same line without any extra code, because the path closes either way.
    final zeroY = padTop + plotH / 2;
    final fillPath = Path.from(curvePath)
      ..lineTo(points.last.dx, zeroY)
      ..lineTo(points.first.dx, zeroY)
      ..close();

    // Densest at the extremes and almost gone at the line, so the gradient
    // reinforces the same reading from both directions.
    final fillPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(size.width / 2, padTop),
        Offset(size.width / 2, padTop + plotH),
        [
          accent.withValues(alpha: 0.30),
          accent.withValues(alpha: 0.03),
          accent.withValues(alpha: 0.03),
          accent.withValues(alpha: 0.30),
        ],
        const [0.0, 0.47, 0.53, 1.0],
      );
    canvas.drawPath(fillPath, fillPaint);

    // Curve stroke
    final curvePaint = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    canvas.drawPath(curvePath, curvePaint);

    // Control dots
    for (int i = 0; i < points.length; i++) {
      final pt = points[i];
      final g = gains[i];
      final isActive = i == activeBand;
      final glowIntensity = (g.abs() / _kMaxGain).clamp(0.0, 1.0);

      if (glowIntensity > 0.05) {
        final glowColor = g > 0 ? accent : _kCut;
        canvas.drawCircle(
          pt,
          4 + glowIntensity * 4,
          Paint()..color = glowColor.withValues(alpha: 0.25 * glowIntensity),
        );
      }

      canvas.drawCircle(
        pt,
        isActive ? 4.0 : 2.5,
        Paint()..color = isActive ? accent : accent.withValues(alpha: 0.8),
      );
    }

    canvas.restore();

    _drawAxisLabels(
      canvas,
      size,
      padLeft,
      padRight,
      padTop,
      padBottom,
      plotW,
      plotH,
    );
  }

  static double _logNormalize(double freq) {
    const logMin = 1.3010299957; // log10(20)
    const logMax = 4.3010299957; // log10(20000)
    return (math.log(freq) / math.ln10 - logMin) / (logMax - logMin);
  }

  void _drawGrid(
    Canvas canvas,
    Size size,
    double padLeft,
    double padRight,
    double padTop,
    double padBottom,
    double plotW,
    double plotH,
  ) {
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 0.5;

    for (final dB in [-15.0, -10.0, -5.0, 0.0, 5.0, 10.0, 15.0]) {
      final y =
          padTop + plotH * (1.0 - (dB - _kMinGain) / (_kMaxGain - _kMinGain));
      _drawDashedLine(
        canvas,
        Offset(padLeft, y),
        Offset(padLeft + plotW, y),
        dB == 0
            ? (Paint()
                ..color = Colors.white.withValues(alpha: 0.2)
                ..strokeWidth = 1.0)
            : gridPaint,
        dashWidth: dB == 0 ? plotW : 4,
        gapWidth: dB == 0 ? 0 : 4,
      );
    }

    const freqGridLines = [100.0, 1000.0, 10000.0];
    for (final f in freqGridLines) {
      final x = padLeft + _logNormalize(f) * plotW;
      _drawDashedLine(
        canvas,
        Offset(x, padTop),
        Offset(x, padTop + plotH),
        gridPaint,
        dashWidth: 4,
        gapWidth: 4,
      );
    }
  }

  void _drawDashedLine(
    Canvas canvas,
    Offset start,
    Offset end,
    Paint paint, {
    double dashWidth = 4,
    double gapWidth = 3,
  }) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    final ux = dx / len;
    final uy = dy / len;

    double d = 0;
    while (d < len) {
      final segEnd = math.min(d + dashWidth, len);
      canvas.drawLine(
        Offset(start.dx + ux * d, start.dy + uy * d),
        Offset(start.dx + ux * segEnd, start.dy + uy * segEnd),
        paint,
      );
      d += dashWidth + gapWidth;
    }
  }

  void _drawAxisLabels(
    Canvas canvas,
    Size size,
    double padLeft,
    double padRight,
    double padTop,
    double padBottom,
    double plotW,
    double plotH,
  ) {
    final labelStyle = ui.TextStyle(
      color: Colors.white.withValues(alpha: 0.4),
      fontSize: 9,
    );

    for (final dB in [-15.0, -10.0, -5.0, 0.0, 5.0, 10.0, 15.0]) {
      final y =
          padTop + plotH * (1.0 - (dB - _kMinGain) / (_kMaxGain - _kMinGain));
      final builder =
          ui.ParagraphBuilder(
              ui.ParagraphStyle(textAlign: TextAlign.right, maxLines: 1),
            )
            ..pushStyle(labelStyle)
            ..addText(dB >= 0 ? '+${dB.round()}' : '${dB.round()}');
      final paragraph = builder.build()
        ..layout(const ui.ParagraphConstraints(width: 26));
      canvas.drawParagraph(paragraph, Offset(2, y - paragraph.height / 2));
    }

    final freqLabels = <double, String>{
      100.0: '100',
      1000.0: '1k',
      10000.0: '10k',
    };
    for (final entry in freqLabels.entries) {
      final x = padLeft + _logNormalize(entry.key) * plotW;
      final builder =
          ui.ParagraphBuilder(
              ui.ParagraphStyle(textAlign: TextAlign.center, maxLines: 1),
            )
            ..pushStyle(labelStyle)
            ..addText(entry.value);
      final paragraph = builder.build()
        ..layout(const ui.ParagraphConstraints(width: 30));
      canvas.drawParagraph(paragraph, Offset(x - 15, padTop + plotH + 4));
    }
  }

  Path _catmullRomPath(List<Offset> points) {
    final path = Path();
    if (points.length < 2) return path;

    path.moveTo(points[0].dx, points[0].dy);

    for (int i = 0; i < points.length - 1; i++) {
      final p0 = i > 0 ? points[i - 1] : points[i];
      final p1 = points[i];
      final p2 = points[i + 1];
      final p3 = i + 2 < points.length ? points[i + 2] : points[i + 1];

      const segments = 10;
      for (int s = 1; s <= segments; s++) {
        final t = s / segments;
        final tt = t * t;
        final ttt = tt * t;

        final x =
            0.5 *
            ((2 * p1.dx) +
                (-p0.dx + p2.dx) * t +
                (2 * p0.dx - 5 * p1.dx + 4 * p2.dx - p3.dx) * tt +
                (-p0.dx + 3 * p1.dx - 3 * p2.dx + p3.dx) * ttt);
        final y =
            0.5 *
            ((2 * p1.dy) +
                (-p0.dy + p2.dy) * t +
                (2 * p0.dy - 5 * p1.dy + 4 * p2.dy - p3.dy) * tt +
                (-p0.dy + 3 * p1.dy - 3 * p2.dy + p3.dy) * ttt);

        path.lineTo(x, y);
      }
    }

    return path;
  }

  @override
  bool shouldRepaint(covariant _FrequencyCurvePainter oldDelegate) {
    if (activeBand != oldDelegate.activeBand) return true;
    if (gains.length != oldDelegate.gains.length) return true;
    if (frequencies.length != oldDelegate.frequencies.length) return true;
    for (int i = 0; i < gains.length; i++) {
      if (gains[i] != oldDelegate.gains[i]) return true;
    }
    for (int i = 0; i < frequencies.length; i++) {
      if (frequencies[i] != oldDelegate.frequencies[i]) return true;
    }
    return accent != oldDelegate.accent;
  }
}
