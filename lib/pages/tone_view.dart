import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '/controllers/app_controller.dart';
import '/audio/eq/eq_labels.dart';
import '/extensions/build_context_extension.dart';
import '/widgets/tone_knob.dart';
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

class ToneView extends StatelessWidget {
  const ToneView({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, controller, _) {
        // The knobs take the whole page: nothing below them, so the page never
        // scrolls and a drag on a knob is never taken for a scroll. Balance,
        // mono and tempo live on the Space page.
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeaderRow(context, controller),
              const SizedBox(height: 8),
              Expanded(
                child: FancyCard(
                  isFancy: controller.isFancy,
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: controller.toneEnabled ? 1.0 : 0.4,
                      duration: const Duration(milliseconds: 250),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final knobSize = context.isMobile
                              ? (constraints.maxWidth / 2 - 8).clamp(0.0, 220.0)
                              : 350.0;
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              ToneKnob(
                                label: "BASS",
                                value: controller.bassGain,
                                max: 22.5,
                                valueText: toneValueLabel(
                                  controller.bassGain,
                                  bass: true,
                                  mode: controller.eqSettings.toneValues,
                                ),
                                activeColor: _kAccent,
                                size: knobSize,
                                onChanged: controller.toneEnabled
                                    ? (v) => controller.bassGain = v
                                    : (_) {},
                              ),
                              ToneKnob(
                                label: "TREBLE",
                                value: controller.trebleGain,
                                valueText: toneValueLabel(
                                  controller.trebleGain,
                                  bass: false,
                                  mode: controller.eqSettings.toneValues,
                                ),
                                activeColor: _kCut,
                                size: knobSize,
                                onChanged: controller.toneEnabled
                                    ? (v) => controller.trebleGain = v
                                    : (_) {},
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _buildInfoRow(controller),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeaderRow(BuildContext context, AppController controller) {
    return Row(
      children: [
        Icon(
          Icons.tune_rounded,
          size: 18,
          color: controller.toneEnabled
              ? _kAccent
              : Colors.white.withValues(alpha: 0.25),
        ),
        const SizedBox(width: 8),
        Text(
          "Tone Controls",
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const Spacer(),
        SizedBox(
          height: 28,
          child: Switch(
            value: controller.toneEnabled,
            activeTrackColor: _kAccent.withValues(alpha: 0.5),
            activeThumbColor: _kAccent,
            onChanged: (v) => controller.toneEnabled = v,
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(AppController controller) {
    final e = controller.eqSettings;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _infoLabel(
          "${e.bassFreq.round()} Hz · Q ${e.bassQ.toStringAsFixed(2)}",
        ),
        _infoLabel(
          "${(e.trebleFreq / 1000).toStringAsFixed(1)} kHz · Q ${e.trebleQ.toStringAsFixed(2)}",
        ),
      ],
    );
  }

  Widget _infoLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        color: Colors.white.withValues(alpha: 0.35),
        fontWeight: FontWeight.w500,
      ),
    );
  }
}
