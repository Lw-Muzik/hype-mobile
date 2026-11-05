import 'dart:ui';

import 'package:eq_app/Helpers/Channel.dart';
import 'package:eq_app/extensions/index.dart';
import 'package:eq_app/widgets/horizontal_slider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';

class AudioFx extends StatefulWidget {
  const AudioFx({super.key});

  @override
  State<AudioFx> createState() => _AudioFxState();
}

class _AudioFxState extends State<AudioFx> {
  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, controller, child) {
        return SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SettingsHeader(title: "AUDIOFX TUNE"),
                const SizedBox.square(dimension: 20),
                FancyCard(
                  isFancy: controller.isFancy,
                  child: Column(
                    children: [
                      const SizedBox.square(dimension: 20),
                      buildSlider(
                        "Preamp",
                        controller.preampGain,
                        -24,
                        24,
                        (x) => controller.preampGain = x,
                      ),
                    ],
                  ),
                ),
                const SizedBox.square(dimension: 20),
                FancyCard(
                  isFancy: controller.isFancy,
                  child: ListTile(
                    title: const Text("Restore to default"),
                    leading: const Icon(Icons.restore),
                    trailing: const Icon(Icons.open_in_new),
                    onTap: () {
                      controller.resetToDefaults();
                      Channel.showNativeMessage("Restored to defaults");
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget buildSlider(
    String title,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return HorizontalSlider(
      title: title,
      value: value,
      min: min,
      max: max,
      onChanged: onChanged,
      dB: value.dps,
    );
  }
}

// Reusable settings header widget for titles.
class SettingsHeader extends StatelessWidget {
  final String title;
  const SettingsHeader({required this.title, Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 50,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(),
          ],
        ),
      ),
    );
  }
}

// Fancy card with blur and elevation based on controller.isFancy.
class FancyCard extends StatelessWidget {
  final Widget child;
  final bool isFancy;
  const FancyCard({required this.child, required this.isFancy, super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: isFancy ? Colors.transparent : Theme.of(context).cardColor,
      elevation: isFancy ? 0 : 2,
      clipBehavior: Clip.hardEdge,
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: isFancy ? 20 : 0,
          sigmaY: isFancy ? 20 : 0,
        ),
        child: Padding(padding: const EdgeInsets.all(8.0), child: child),
      ),
    );
  }
}

extension on AppController {
  void resetToDefaults() {
    preampGain = 0.0;
    bassGain = 0.0;
    trebleGain = 0.0;
    bassFreq = 80.0;
    trebleFreq = 10000.0;
    bassQ = 0.707;
    trebleQ = 0.707;
    toneEnabled = false;
    limiterEnabled = true;
  }
}
