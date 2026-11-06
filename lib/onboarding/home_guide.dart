import 'dart:async';
import 'dart:io';

import 'package:eq_app/Themes/app_fonts.dart';
import 'package:eq_app/config/app_config.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The first guide tip's text. Store builds call the place "Discover" (see
/// [AppConfig.directBuild]); direct builds name the service.
String guideDiscoverMessage({required bool directBuild}) => directBuild
    ? 'Open YouTube Music from Places for trending charts, popular songs, and artists to explore and stream.'
    : 'Open Discover from Places for trending charts, popular songs, and artists to explore and stream.';

/// The second tip's text: it names Folders only where that place exists.
String guidePlacesMessage({
  required bool directBuild,
  required bool isAndroid,
}) {
  final youtube = directBuild ? 'YouTube Music' : 'Discover';
  final folders = isAndroid ? 'Folders, ' : '';
  return 'Places lists For You, Songs, Albums, Artists, Genres, $folders'
      'Playlists, $youtube, and Cloud. Swipe right or press back to go up a level.';
}

/// A one-time overlay guide shown on the home screen after onboarding.
/// Highlights key areas with a semi-transparent backdrop and floating tips.
class HomeGuide extends StatefulWidget {
  final Widget child;
  final VoidCallback? onComplete;

  /// True while the guide's scrim is up. The mini player (which sits above the
  /// pages) hides then, so it never covers the scrim's buttons.
  static final ValueNotifier<bool> visible = ValueNotifier<bool>(false);

  const HomeGuide({super.key, required this.child, this.onComplete});

  @override
  State<HomeGuide> createState() => _HomeGuideState();
}

class _HomeGuideState extends State<HomeGuide>
    with SingleTickerProviderStateMixin {
  bool _show = false;
  int _step = 0;
  late AnimationController _fadeController;
  late Animation<double> _fadeAnim;

  static List<_GuideTip> get _tips => [
    _GuideTip(
      title: 'Discover Music',
      message: guideDiscoverMessage(directBuild: AppConfig.directBuild),
      icon: Icons.explore_rounded,
      alignment: Alignment.center,
    ),
    _GuideTip(
      title: 'Browse Your Library',
      message: guidePlacesMessage(
        directBuild: AppConfig.directBuild,
        isAndroid: Platform.isAndroid,
      ),
      icon: Icons.swipe_rounded,
      alignment: Alignment.center,
    ),
    _GuideTip(
      title: 'Now Playing',
      message:
          'Tap any song to play. Music opens on the player; pull its artwork down, or tap the arrow, to see where the song came from. The mini player at the bottom brings it back.',
      icon: Icons.play_circle_rounded,
      alignment: Alignment.bottomCenter,
    ),
    _GuideTip(
      title: 'Player Features',
      message:
          'In the player: EQ, Lyrics, Visualizer, Queue, and Track ID. Swipe cards to change tracks.',
      icon: Icons.tune_rounded,
      alignment: Alignment.center,
    ),
    _GuideTip(
      title: 'Cloud & Streaming',
      message:
          'Connect Google Drive or Dropbox in Settings. Enable Data Saver to reduce cellular usage.',
      icon: Icons.cloud_rounded,
      alignment: Alignment.center,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeController, curve: Curves.easeOut);
    _checkShouldShow();
  }

  Future<void> _checkShouldShow() async {
    final prefs = await SharedPreferences.getInstance();
    final shown = prefs.getBool('home_guide_shown') ?? false;
    if (!shown && mounted) {
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      setState(() => _show = true);
      HomeGuide.visible.value = true;
      _fadeController.forward();
    } else {
      // Already shown — trigger coach marks immediately
      widget.onComplete?.call();
    }
  }

  void _next() {
    if (_step < _tips.length - 1) {
      _fadeController.reverse().then((_) {
        setState(() => _step++);
        _fadeController.forward();
      });
    } else {
      _dismiss();
    }
  }

  Future<void> _dismiss() async {
    await _fadeController.reverse();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('home_guide_shown', true);
    HomeGuide.visible.value = false;
    if (mounted) setState(() => _show = false);
    widget.onComplete?.call();
  }

  @override
  void dispose() {
    if (_show) {
      // Not while the tree is being torn down.
      scheduleMicrotask(() => HomeGuide.visible.value = false);
    }
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_show)
          FadeTransition(
            opacity: _fadeAnim,
            child: GestureDetector(
              onTap: _next,
              child: Container(
                color: Colors.black.withValues(alpha: 0.75),
                child: SafeArea(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Spacer(flex: 2),
                      _buildTip(_tips[_step]),
                      const Spacer(flex: 1),
                      // Progress + action
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          children: [
                            // Dots
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: List.generate(_tips.length, (i) {
                                return AnimatedContainer(
                                  duration: const Duration(milliseconds: 250),
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                  width: i == _step ? 24 : 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: i == _step
                                        ? const Color(0xFFD4A825)
                                        : Colors.white.withValues(alpha: 0.25),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                );
                              }),
                            ),
                            const SizedBox(height: 24),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                TextButton(
                                  onPressed: _dismiss,
                                  child: Text(
                                    'Skip',
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.5,
                                      ),
                                      fontSize: 15,
                                    ),
                                  ),
                                ),
                                FilledButton(
                                  onPressed: _next,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFFD4A825),
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 28,
                                      vertical: 12,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  child: Text(
                                    _step == _tips.length - 1
                                        ? 'Got It'
                                        : 'Next',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTip(_GuideTip tip) {
    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFD4A825).withValues(alpha: 0.15),
              ),
              child: Icon(tip.icon, size: 32, color: const Color(0xFFD4A825)),
            ),
            const SizedBox(height: 24),
            Text(
              tip.title,
              textAlign: TextAlign.center,
              style: AppFonts.displayStyle(
                fontSize: 24,
                color: Colors.white,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              tip.message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: Colors.white.withValues(alpha: 0.65),
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GuideTip {
  final String title;
  final String message;
  final IconData icon;
  final Alignment alignment;

  const _GuideTip({
    required this.title,
    required this.message,
    required this.icon,
    required this.alignment,
  });
}
