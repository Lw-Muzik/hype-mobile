import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../Routes/routes.dart';
import '../controllers/app_controller.dart';
import '../controllers/library_controller.dart';
import '../onboarding/mode_chooser.dart';
import '../onboarding/onboarding_screen.dart';
import '../widgets/intro_splash.dart';

class AssetLoader extends StatefulWidget {
  const AssetLoader({super.key});

  @override
  State<AssetLoader> createState() => _AssetLoaderState();
}

class _AssetLoaderState extends State<AssetLoader> {
  static const Color _bg = Color(0xFF0A0A0A);
  static const Color _accent = Color(0xFFF5F5F5);

  bool _isNavigating = false;
  final ValueNotifier<bool> _ready = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _loadAssets();
  }

  void _goHome() {
    if (!mounted || _isNavigating) return;
    _isNavigating = true;
    Navigator.pushNamedAndRemoveUntil(context, Routes.home, (route) => false);
  }

  Future<void> _loadAssets() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Check if onboarding is needed (first launch)
      final onboardingDone = prefs.getBool('onboarding_complete') ?? false;
      if (!onboardingDone && mounted) {
        _isNavigating = true;
        // iOS: always music mode, skip mode chooser
        if (!Platform.isAndroid) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (ctx) => OnboardingScreen(
                mode: AppMode.musicPlayer,
                onComplete: () {
                  Navigator.of(ctx)
                      .pushNamedAndRemoveUntil(Routes.loader, (route) => false);
                },
              ),
            ),
          );
        } else {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (ctx) => ModeChooser(
                onComplete: (AppMode mode) {
                  final controller = Provider.of<AppController>(
                    ctx,
                    listen: false,
                  );
                  controller.appMode = mode;

                  Navigator.of(ctx).pushReplacement(
                    MaterialPageRoute(
                      builder: (ctx2) => OnboardingScreen(
                        mode: mode,
                        onComplete: () {
                          Navigator.of(ctx2).pushNamedAndRemoveUntil(
                            Routes.loader,
                            (route) => false,
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          );
        }
        return;
      }

      // Only load music library in music player mode
      final appMode = AppMode.values[prefs.getInt("appMode") ?? 0];
      if (appMode == AppMode.musicPlayer && mounted) {
        // Home renders instantly from the library database; the scanner diffs
        // MediaStore in the background and streams new songs into the live
        // lists. No blocking full re-import, no per-launch artwork extraction.
        final library = Provider.of<LibraryController>(context, listen: false);
        final app = Provider.of<AppController>(context, listen: false);
        unawaited(
          library.start().then((_) {
            return library.importLegacyPlayCounts(app.playCounts);
          }),
        );
      }

      // The intro owns the minimum duration; flag readiness and let it hand over.
      _ready.value = true;
    } catch (e) {
      debugPrint('Error loading assets: $e');
      _showErrorDialog();
    }
  }

  void _showErrorDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Loading Error', style: TextStyle(color: _accent)),
        content: const Text(
          'Failed to load assets. Please try again.',
          style: TextStyle(color: _accent),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _loadAssets();
            },
            child: const Text('Retry', style: TextStyle(color: _accent)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _ready.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: IntroSplash(ready: _ready, onDone: _goHome),
    );
  }
}
