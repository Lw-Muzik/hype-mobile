import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import '../controllers/app_controller.dart';
import '/helpers/channel.dart';
import '/extensions/index.dart';

class EqualizerControls extends StatefulWidget {
  const EqualizerControls({super.key});

  @override
  State<EqualizerControls> createState() => _EqualizerControlsState();
}

class _EqualizerControlsState extends State<EqualizerControls> {
  List<int>? bandFrequencies;
  List<int>? bandLevels;

  @override
  void initState() {
    super.initState();
    _loadBandData();
  }

  Future<void> _loadBandData() async {
    final frequencies = await Channel.getBandFreq();
    final levels = await Future.wait(
      List.generate(frequencies.length, (i) => Channel.getBandLevel(i)),
    );

    setState(() {
      bandFrequencies = frequencies;
      bandLevels = levels;
    });
  }

  @override
  Widget build(BuildContext context) {
    final appController = context.watch<AppController>();

    if (bandFrequencies == null || bandLevels == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Padding(
      padding: const EdgeInsets.all(10.0),
      child: Row(
        children: List.generate(bandFrequencies!.length, (i) {
          return Expanded(
            child: Column(
              children: [
                Text("${bandLevels![i]} dB"),
                VerticalSlider(
                  min: -15,
                  max: 15,
                  value: bandLevels![i].toDouble(),
                  onChanged: (value) {
                    setState(() {
                      appController.bandValues[i] = value.toInt();
                      bandLevels![i] = value.toInt();
                    });
                    Channel.setBandLevel(i, value.toInt());
                  },
                ),
                Text(bandFrequencies![i].formatBandFrequency),
              ],
            ),
          );
        }),
      ),
    );
  }
}

class VerticalSlider extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;

  const VerticalSlider({
    Key? key,
    required this.value,
    this.min = 0.0,
    this.max = 1.0,
    this.onChanged,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return RotatedBox(
      quarterTurns: 3,
      child: SliderTheme(
        data: const SliderThemeData(
          trackHeight: 3,
          thumbShape: RoundSliderThumbShape(enabledThumbRadius: 16),
          tickMarkShape: RoundSliderTickMarkShape(tickMarkRadius: 2),
        ),
        child: Slider(value: value, min: min, max: max, onChanged: onChanged),
      ),
    );
  }
}

class ControlButtons extends StatelessWidget {
  const ControlButtons({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StreamBuilder<PlayerState>(
          stream: controller.handler.player.playerStateStream,
          builder: (context, snapshot) {
            final playerState = snapshot.data;
            final processingState = playerState?.processingState;
            final playing = playerState?.playing;

            if (processingState == ProcessingState.loading ||
                processingState == ProcessingState.buffering) {
              return const CircularProgressIndicator();
            } else if (playing != true) {
              return _buildControlButton(
                icon: Icons.play_arrow,
                onPressed: controller.handler.play,
              );
            } else if (processingState != ProcessingState.completed) {
              return _buildControlButton(
                icon: Icons.pause,
                onPressed: controller.handler.pause,
              );
            } else {
              return IconButton(
                icon: const Icon(Icons.replay),
                iconSize: 64.0,
                onPressed: () => controller.handler.seek(Duration.zero),
              );
            }
          },
        ),
      ],
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return MaterialButton(
      onPressed: onPressed,
      color: Colors.white,
      textColor: const Color(0xFF0B1220),
      padding: const EdgeInsets.all(16),
      shape: const CircleBorder(),
      elevation: 0.0,
      child: Icon(icon, size: 32),
    );
  }
}
