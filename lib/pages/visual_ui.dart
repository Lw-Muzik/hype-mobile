import 'dart:io';

import '/exports/exports.dart';
import '../visualizers/spectrum_bars/presets.dart';
import '../visualizers/spectrum_bars/spectrum_bars_view.dart';
import '../visualizers/visualizer_styles.dart';
import '../visualizers/wave-visualizer.dart';
import '../controllers/app_controller.dart';
import '/helpers/audio_visualizer.dart';
import '/helpers/project_mcontroller.dart';
import '/helpers/visualizer_widget.dart';
import '/routes/routes.dart';
import '/widgets/body.dart';
import '../widgets/artwork_widget.dart';
import '/pages/settings.dart';

class VisualUI extends StatefulWidget {
  const VisualUI({super.key});

  @override
  State<VisualUI> createState() => _VisualUIState();
}

class _VisualUIState extends State<VisualUI>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _controller;
  bool _isPanelOpen = false;

  // projectM state
  final ProjectMController _projectM = ProjectMController();
  bool _projectMInitialized = false;
  // Guards the async init window: without these, backing out of the page
  // mid-init left the native GL render loop running with no owner (dispose
  // saw _projectMInitialized == false and skipped release), and a re-open
  // then double-inited the renderer.
  bool _projectMInitInFlight = false;
  bool _projectMDisposed = false;
  String _presetName = '';

  static Map<String, _VisualPreset> get _visualizers => {
    for (final v in visualizerStyles(isIos: Platform.isIOS))
      v.id: _VisualPreset(
        name: v.name,
        icon: v.icon,
        description: v.description,
      ),
  };

  static const _colorPalette = [
    (0xFFFFFFFF, Colors.white),
    (0xFFD4A825, Color(0xFFD4A825)),
    (0xFF2196F3, Colors.blue),
    (0xFF9C27B0, Colors.purple),
    (0xFF4CAF50, Colors.green),
    (0xFFE91E63, Colors.pink),
    (0xFFFF5722, Color(0xFFFF5722)),
    (0xFF00BCD4, Color(0xFF00BCD4)),
  ];

  bool _didInit = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    final ctrl = context.read<AppController>();
    Visualizers.setFrameRate(ctrl.visualizerFrameRate);
    Visualizers.setSmoothing(
      ctrl.visualizerReactivity,
      ctrl.visualizerReactivity * 0.7,
    );
    Visualizers.setGain(ctrl.visualizerBeatSensitivity);
    Visualizers.scaleVisualizer(true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause projectM's native GL render loop while backgrounded — it renders
    // into an off-screen surface otherwise and pins the GPU with the screen off.
    if (!_projectMInitialized) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        if (_projectM.isRunning) _projectM.stop();
        break;
      case AppLifecycleState.resumed:
        if (!_projectM.isRunning) _projectM.start();
        break;
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didInit) {
      _didInit = true;
      final ctrl = context.read<AppController>();
      if (ctrl.visualizerStyle == 'milkdrop') {
        _initProjectM();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Mark disposed FIRST so an in-flight _initProjectM releases the renderer
    // itself when its awaits complete (see the `abandoned` check there).
    _projectMDisposed = true;
    _stopProjectM();
    _controller.dispose();
    super.dispose();
  }

  // Quality tier → (max longest edge in px, mesh width, mesh height)
  static const _qualityTiers = [
    (480, 24, 18), // Low — battery saver, low-end devices
    (720, 32, 24), // Medium — balanced (default)
    (1080, 48, 36), // High — mid-to-high-end
    (0, 64, 48), // Ultra — full resolution, flagship GPUs
  ];

  Future<void> _initProjectM() async {
    if (_projectMInitialized || _projectMInitInFlight) return;
    _projectMInitInFlight = true;

    final ctrl = context.read<AppController>();
    final size = MediaQuery.of(context).size;
    final pixelRatio = MediaQuery.of(context).devicePixelRatio;
    // Use physical pixels for accurate GPU load sizing
    final fullW = (size.width * pixelRatio).toInt();
    final fullH = (size.height * pixelRatio).toInt();

    // Scale render resolution based on quality tier
    final tier = _qualityTiers[ctrl.milkdropQuality.clamp(0, 3)];
    final maxEdge = tier.$1;
    final meshW = tier.$2;
    final meshH = tier.$3;

    int w, h;
    if (maxEdge <= 0 || (fullW <= maxEdge && fullH <= maxEdge)) {
      // Ultra or already within budget
      w = fullW;
      h = fullH;
    } else {
      // Scale down so longest edge = maxEdge, preserve aspect ratio
      final longest = fullW > fullH ? fullW : fullH;
      final scale = maxEdge.toDouble() / longest.toDouble();
      w = (fullW * scale).toInt();
      h = (fullH * scale).toInt();
    }
    // Ensure minimum resolution
    w = w.clamp(64, fullW);
    h = h.clamp(64, fullH);

    final textureId = await _projectM.init(w, h);
    try {
      if (textureId != null) {
        await _projectM.setMeshSize(meshW, meshH);
        await _projectM.setFps(ctrl.milkdropFps);
        await _projectM.setBeatSensitivity(ctrl.milkdropBeatSensitivity);
        await _projectM.setPresetDuration(ctrl.milkdropPresetDuration);
        await _projectM.setPresetLocked(ctrl.milkdropPresetLocked);
        await _projectM.start();

        // Restore the last selected preset instead of using the default first one
        String name;
        final savedPreset = ctrl.milkdropPresetName;
        if (savedPreset.isNotEmpty) {
          final presets = await _projectM.listPresets();
          final idx = presets.indexOf(savedPreset);
          if (idx >= 0) {
            name = await _projectM.loadPresetByIndex(idx);
          } else {
            name = await _projectM.getCurrentPreset();
          }
        } else {
          name = await _projectM.getCurrentPreset();
        }

        // The page may have been disposed (or the style switched away) while
        // we were awaiting — if so, tear the renderer down NOW; nobody else
        // will, and the GL loop would otherwise run orphaned forever.
        final abandoned =
            !mounted || _projectMDisposed || ctrl.visualizerStyle != 'milkdrop';
        if (abandoned) {
          await _projectM.release();
          return;
        }

        setState(() {
          _projectMInitialized = true;
          _presetName = name;
        });
      }
    } finally {
      _projectMInitInFlight = false;
    }
  }

  void _setPreset(String name) {
    setState(() => _presetName = name);
    final ctrl = context.read<AppController>();
    ctrl.milkdropPresetName = name;
    // Lock the preset so auto-cycle / hard cuts don't override user selection
    if (!ctrl.milkdropPresetLocked) {
      ctrl.milkdropPresetLocked = true;
      _projectM.setPresetLocked(true);
    }
  }

  Future<void> _stopProjectM() async {
    if (!_projectMInitialized) return;
    await _projectM.release();
    _projectMInitialized = false;
  }

  void _onStyleChanged(String style) {
    final ctrl = context.read<AppController>();
    final wasMillkdrop = ctrl.visualizerStyle == 'milkdrop';
    ctrl.visualizerStyle = style;

    if (style == 'milkdrop' && !wasMillkdrop) {
      _initProjectM();
    } else if (style != 'milkdrop' && wasMillkdrop) {
      _stopProjectM();
    }
  }

  void _togglePanel() {
    setState(() => _isPanelOpen = !_isPanelOpen);
    if (_isPanelOpen) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Body(
      child: Consumer<AppController>(
        builder: (context, controller, child) {
          // See PlayerBody: starting the tap from build() meant a platform call
          // per notify. AppController drives it from the two surface toggles.
          final size = MediaQuery.of(context).size;
          final isMilkDrop = controller.visualizerStyle == 'milkdrop';

          return Scaffold(
            backgroundColor: controller.isFancy
                ? Colors.transparent
                : Theme.of(context).scaffoldBackgroundColor,
            body: Stack(
              fit: StackFit.expand,
              children: [
                // Visualizer canvas — tap to dismiss
                GestureDetector(
                  onTap: () {
                    if (_isPanelOpen) {
                      _togglePanel();
                    } else {
                      Routes.pop(context);
                    }
                  },
                  // Swipe left/right for preset switching in milkdrop mode
                  onHorizontalDragEnd: isMilkDrop
                      ? (details) async {
                          if (details.primaryVelocity == null) return;
                          String name;
                          if (details.primaryVelocity! < -200) {
                            name = await _projectM.nextPreset();
                          } else if (details.primaryVelocity! > 200) {
                            name = await _projectM.previousPreset();
                          } else {
                            return;
                          }
                          _setPreset(name);
                        }
                      : null,
                  behavior: HitTestBehavior.opaque,
                  child: mounted
                      ? isMilkDrop
                            ? _buildMilkDropVisualizer()
                            : _buildVisualizer(size.width, size.height)
                      : const SizedBox(),
                ),

                // Preset name overlay for MilkDrop
                if (isMilkDrop && _presetName.isNotEmpty)
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 16,
                    left: 16,
                    right: 16,
                    child: IgnorePointer(
                      child: Text(
                        _presetName,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          shadows: const [
                            Shadow(blurRadius: 8, color: Colors.black),
                          ],
                        ),
                      ),
                    ),
                  ),

                // Settings shortcut
                Positioned(
                  top: MediaQuery.of(context).padding.top + 12,
                  right: 12,
                  child: GestureDetector(
                    onTap: () => Navigator.of(
                      context,
                    ).push(MaterialPageRoute(builder: (_) => const Settings())),
                    child: Icon(
                      Icons.settings_rounded,
                      color: Colors.white.withValues(alpha: 0.35),
                      size: 20,
                    ),
                  ),
                ),

                // Bottom controls overlay
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _BottomOverlay(
                    controller: controller,
                    isPanelOpen: _isPanelOpen,
                    selectedVisual: controller.visualizerStyle,
                    visualColor: Color(controller.visualizerColor),
                    visualizers: _visualizers,
                    bottomPadding: bottomPadding,
                    onTogglePanel: _togglePanel,
                    onSelectVisual: _onStyleChanged,
                    onSelectColor: (color) =>
                        controller.visualizerColor = color.toARGB32(),
                    onClose: () => Routes.pop(context),
                    projectM: _projectM,
                    currentPreset: _presetName,
                    onPresetSelected: _setPreset,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildMilkDropVisualizer() {
    if (!_projectMInitialized || _projectM.textureId == null) {
      return const Center(
        child: CircularProgressIndicator(
          color: Color(0xFFD4A825),
          strokeWidth: 2,
        ),
      );
    }
    return Texture(textureId: _projectM.textureId!);
  }

  Widget _buildVisualizer(double width, double height) {
    final ctrl = context.read<AppController>();
    final style = ctrl.visualizerStyle;
    final color = Color(ctrl.visualizerColor);
    final reactivity = ctrl.visualizerReactivity;

    final spectrum = spectrumBarsVisualizer(style);
    if (spectrum != null) {
      // Has its own SpectrumFeed, so it stays outside VisualizerWidget.
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 500),
        transitionBuilder: (child, animation) =>
            FadeTransition(opacity: animation, child: child),
        child: spectrum,
      );
    }

    return VisualizerWidget(
      builder: (context, waveform, fft, x) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 500),
          transitionBuilder: (child, animation) {
            return FadeTransition(opacity: animation, child: child);
          },
          child: WaveVisualizer(
            key: ValueKey(style),
            color: color,
            width: width,
            height: height,
            audioData: waveform,
            fftData: fft,
            selector: style,
            reactivity: reactivity,
          ),
        );
      },
      id: 0,
    );
  }
}

class _VisualPreset {
  final String name;
  final IconData icon;
  final String description;
  const _VisualPreset({
    required this.name,
    required this.icon,
    required this.description,
  });
}

/// Bottom overlay: track info bar + expandable settings panel.
class _BottomOverlay extends StatelessWidget {
  final AppController controller;
  final bool isPanelOpen;
  final String selectedVisual;
  final Color visualColor;
  final Map<String, _VisualPreset> visualizers;
  final double bottomPadding;
  final VoidCallback onTogglePanel;
  final ValueChanged<String> onSelectVisual;
  final ValueChanged<Color> onSelectColor;
  final VoidCallback onClose;
  final ProjectMController projectM;
  final String currentPreset;
  final ValueChanged<String> onPresetSelected;

  const _BottomOverlay({
    required this.controller,
    required this.isPanelOpen,
    required this.selectedVisual,
    required this.visualColor,
    required this.visualizers,
    required this.bottomPadding,
    required this.onTogglePanel,
    required this.onSelectVisual,
    required this.onSelectColor,
    required this.onClose,
    required this.projectM,
    required this.currentPreset,
    required this.onPresetSelected,
  });

  @override
  Widget build(BuildContext context) {
    final song = controller.songs[controller.songId];

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: 0.7),
            Colors.black.withValues(alpha: 0.9),
          ],
          stops: const [0.0, 0.3, 1.0],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Expanded settings panel
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity),
            secondChild: _SettingsPanel(
              selectedVisual: selectedVisual,
              visualColor: visualColor,
              visualizers: visualizers,
              onSelectVisual: onSelectVisual,
              onSelectColor: onSelectColor,
              projectM: projectM,
              currentPreset: currentPreset,
              onPresetSelected: onPresetSelected,
            ),
            crossFadeState: isPanelOpen
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 250),
          ),

          // Track info + controls bar
          Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding + 12),
            child: Row(
              children: [
                // Close
                _CircleButton(
                  icon: Icons.keyboard_arrow_down_rounded,
                  onTap: onClose,
                ),
                const SizedBox(width: 12),
                // Cover art
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ArtworkWidget(
                    height: 40,
                    width: 40,
                    songId: song.id,
                    size: 200,
                    type: ArtworkType.AUDIO,
                    path: song.data,
                  ),
                ),
                const SizedBox(width: 10),
                // Track info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        song.artist ?? 'Unknown artist',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Settings toggle
                _CircleButton(
                  icon: isPanelOpen ? Icons.close_rounded : Icons.tune_rounded,
                  onTap: onTogglePanel,
                  accent: isPanelOpen,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Settings panel with visualizer selector + color picker + preset picker.
class _SettingsPanel extends StatelessWidget {
  final String selectedVisual;
  final Color visualColor;
  final Map<String, _VisualPreset> visualizers;
  final ValueChanged<String> onSelectVisual;
  final ValueChanged<Color> onSelectColor;
  final ProjectMController projectM;
  final String currentPreset;
  final ValueChanged<String> onPresetSelected;

  static const _accentColor = Color(0xFFD4A825);

  const _SettingsPanel({
    required this.selectedVisual,
    required this.visualColor,
    required this.visualizers,
    required this.onSelectVisual,
    required this.onSelectColor,
    required this.projectM,
    required this.currentPreset,
    required this.onPresetSelected,
  });

  @override
  Widget build(BuildContext context) {
    final isMilkDrop = selectedVisual == 'milkdrop';
    final fixedColors = isMilkDrop || isSpectrumBarsStyle(selectedVisual);

    final activeStyle = visualizers[selectedVisual];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Visualizer style — tap to open picker sheet
          GestureDetector(
            onTap: () => _openStylePicker(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: Row(
                children: [
                  Icon(
                    activeStyle?.icon ?? Icons.equalizer_rounded,
                    size: 18,
                    color: _accentColor.withValues(alpha: 0.8),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Style',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white.withValues(alpha: 0.45),
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          activeStyle?.name ?? 'Select',
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
          const SizedBox(height: 16),
          // Section: Color palette (hidden for milkdrop and the spectrum styles — their colors are fixed)
          if (!fixedColors) ...[
            const Text(
              'COLOR',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.0,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: _VisualUIState._colorPalette.map((pair) {
                final color = pair.$2;
                final isSelected = visualColor.toARGB32() == color.toARGB32();

                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: GestureDetector(
                    onTap: () => onSelectColor(color),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected ? Colors.white : Colors.transparent,
                          width: 2.5,
                        ),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: color.withValues(alpha: 0.4),
                                  blurRadius: 12,
                                  spreadRadius: 2,
                                ),
                              ]
                            : null,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
          ],
          // Section: Preset selector for MilkDrop
          if (isMilkDrop) ...[
            const Text(
              'PRESET',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.0,
              ),
            ),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => _openPresetPicker(context),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.12),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.blur_on_rounded,
                      color: currentPreset.isNotEmpty
                          ? _accentColor
                          : Colors.white38,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        currentPreset.isNotEmpty
                            ? currentPreset
                            : 'Select a preset...',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: currentPreset.isNotEmpty
                              ? Colors.white
                              : Colors.white38,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.search_rounded,
                      color: Colors.white38,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Prev / Next row
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () async {
                      final name = await projectM.previousPreset();
                      onPresetSelected(name);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.skip_previous_rounded,
                            color: Colors.white54,
                            size: 18,
                          ),
                          SizedBox(width: 4),
                          Text(
                            'Prev',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GestureDetector(
                    onTap: () async {
                      final name = await projectM.nextPreset();
                      onPresetSelected(name);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            'Next',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                          SizedBox(width: 4),
                          Icon(
                            Icons.skip_next_rounded,
                            color: Colors.white54,
                            size: 18,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }

  void _openStylePicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _StylePickerSheet(
        visualizers: visualizers,
        selected: selectedVisual,
        onSelected: onSelectVisual,
      ),
    );
  }

  void _openPresetPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PresetPickerSheet(
        projectM: projectM,
        currentPreset: currentPreset,
        onSelected: onPresetSelected,
      ),
    );
  }
}

/// Searchable bottom sheet for browsing and selecting MilkDrop presets.
class _PresetPickerSheet extends StatefulWidget {
  final ProjectMController projectM;
  final String currentPreset;
  final ValueChanged<String> onSelected;

  const _PresetPickerSheet({
    required this.projectM,
    required this.currentPreset,
    required this.onSelected,
  });

  @override
  State<_PresetPickerSheet> createState() => _PresetPickerSheetState();
}

class _PresetPickerSheetState extends State<_PresetPickerSheet> {
  static const _accentColor = Color(0xFFD4A825);

  List<String> _allPresets = [];
  List<String> _filtered = [];
  String _query = '';
  bool _loading = true;
  late String _activePreset;
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _activePreset = widget.currentPreset;
    _loadPresets();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadPresets() async {
    final presets = await widget.projectM.listPresets();
    if (mounted) {
      setState(() {
        _allPresets = presets;
        _filtered = presets;
        _loading = false;
      });
      // Scroll to current preset
      _scrollToActive();
    }
  }

  void _scrollToActive() {
    if (_activePreset.isEmpty) return;
    final idx = _filtered.indexOf(_activePreset);
    if (idx > 0 && _scrollController.hasClients) {
      // Each item is ~48px tall
      _scrollController.animateTo(
        (idx * 48.0).clamp(0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _onSearch(String query) {
    setState(() {
      _query = query;
      if (query.isEmpty) {
        _filtered = _allPresets;
      } else {
        final lower = query.toLowerCase();
        _filtered = _allPresets
            .where((p) => p.toLowerCase().contains(lower))
            .toList();
      }
    });
  }

  Future<void> _selectPreset(String name) async {
    final idx = _allPresets.indexOf(name);
    if (idx < 0) return;
    final loaded = await widget.projectM.loadPresetByIndex(idx);
    setState(() => _activePreset = loaded);
    widget.onSelected(loaded);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final screenHeight = MediaQuery.of(context).size.height;

    return Container(
      height: screenHeight * 0.65,
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
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
          // Title + count
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                const Icon(
                  Icons.blur_on_rounded,
                  color: _accentColor,
                  size: 20,
                ),
                const SizedBox(width: 8),
                const Text(
                  'MilkDrop Presets',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (!_loading)
                  Text(
                    '${_filtered.length} preset${_filtered.length == 1 ? '' : 's'}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          // Search field
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearch,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search presets...',
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.3),
                  fontSize: 14,
                ),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  color: Colors.white.withValues(alpha: 0.3),
                  size: 20,
                ),
                suffixIcon: _query.isNotEmpty
                    ? GestureDetector(
                        onTap: () {
                          _searchController.clear();
                          _onSearch('');
                        },
                        child: Icon(
                          Icons.close_rounded,
                          color: Colors.white.withValues(alpha: 0.3),
                          size: 18,
                        ),
                      )
                    : null,
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
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: _accentColor,
                      strokeWidth: 2,
                    ),
                  )
                : _filtered.isEmpty
                ? Center(
                    child: Text(
                      _query.isEmpty ? 'No presets available' : 'No matches',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: _filtered.length,
                    padding: EdgeInsets.only(bottom: bottomInset + 16),
                    itemBuilder: (context, index) {
                      final name = _filtered[index];
                      final isActive = name == _activePreset;

                      return InkWell(
                        onTap: () async {
                          await _selectPreset(name);
                          if (mounted) Navigator.pop(context);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          color: isActive
                              ? _accentColor.withValues(alpha: 0.1)
                              : null,
                          child: Row(
                            children: [
                              Icon(
                                isActive
                                    ? Icons.play_circle_filled_rounded
                                    : Icons.blur_on_rounded,
                                color: isActive
                                    ? _accentColor
                                    : Colors.white.withValues(alpha: 0.25),
                                size: 20,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isActive
                                        ? _accentColor
                                        : Colors.white.withValues(alpha: 0.8),
                                    fontSize: 13,
                                    fontWeight: isActive
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                              ),
                              if (isActive)
                                const Icon(
                                  Icons.check_rounded,
                                  color: _accentColor,
                                  size: 18,
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

/// Small circle button for the bottom bar.
/// Bottom sheet for picking a visualizer style.
class _StylePickerSheet extends StatelessWidget {
  final Map<String, _VisualPreset> visualizers;
  final String selected;
  final ValueChanged<String> onSelected;

  static const _accent = Color(0xFFD4A825);

  const _StylePickerSheet({
    required this.visualizers,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final entries = visualizers.entries.toList();

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.5,
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
                const Icon(Icons.equalizer_rounded, color: _accent, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'Visualizer Style',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '${entries.length} styles',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ),
          // List
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).padding.bottom + 16,
              ),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final key = entries[index].key;
                final preset = entries[index].value;
                final isActive = key == selected;

                return InkWell(
                  onTap: () {
                    onSelected(key);
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
                            preset.icon,
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
                                preset.description,
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

class _CircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool accent;

  const _CircleButton({
    required this.icon,
    required this.onTap,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accent
                ? const Color(0xFFD4A825).withValues(alpha: 0.2)
                : Colors.white.withValues(alpha: 0.1),
          ),
          child: Icon(
            icon,
            color: accent ? const Color(0xFFD4A825) : Colors.white70,
            size: 22,
          ),
        ),
      ),
    );
  }
}

/// The built-in spectrum bars view for [style], or null when [style] is a
/// radial/line style that goes through the wave visualizer.
@visibleForTesting
Widget? spectrumBarsVisualizer(String style) {
  if (!isSpectrumBarsStyle(style)) return null;
  final preset = spectrumBarsPresetById(style);
  if (preset == null) return null;
  return SpectrumBarsView(key: ValueKey(style), preset: preset);
}
