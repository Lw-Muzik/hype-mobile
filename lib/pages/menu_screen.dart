import 'package:eq_app/Themes/app_fonts.dart';

import 'dart:io';

import '/exports/exports.dart';

import '../Routes/routes.dart';
import '../controllers/app_controller.dart';
import '../controllers/drawer_controller.dart';

import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library/library_pages.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/places/places_page.dart';

import 'equalizer.dart';
import 'Settings.dart';
import '../player/lyrics_view.dart';
import 'visual_ui.dart';

class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key});

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  void _navigate(Widget page) {
    context.read<DrawerProvider>().closeDrawer();
    Routes.routeTo(page, context, animate: true);
  }

  /// Lands on Places, then opens Cloud from there (rather than stacking it on
  /// whatever trail the library is showing).
  Future<void> _openCloud() async {
    final library = AppNav.host?.library;
    if (library != null && library.path.isNotEmpty) {
      await library.showPath(const []);
    }
    if (!mounted) return;
    await AppNav.openPage(
      context,
      buildPlaceScaffold(PlaceId.cloud),
      key: LibraryPageKey.place(PlaceId.cloud.name),
    );
  }

  void _closeAndRun(VoidCallback action) {
    context.read<DrawerProvider>().closeDrawer();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final cs = Theme.of(context).colorScheme;

    return Consumer<AppController>(
      builder: (context, controller, _) {
        final isEq = controller.isEqMode;

        return Scaffold(
          backgroundColor: Colors.black,
          body: Padding(
            padding: EdgeInsets.only(top: topPad, bottom: bottomPad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 24),
                // ── Brand header ──
                _BrandHeader(colorScheme: cs),
                const SizedBox(height: 12),
                // ── Mode Switcher ──
                if (Platform.isAndroid)
                  _ModeSwitcher(
                    mode: controller.appMode,
                    onChanged: (mode) => controller.appMode = mode,
                  ),
                const SizedBox(height: 16),
                // ── Navigation items ──
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Primary section
                        _SectionLabel(isEq ? 'EQUALIZER' : 'PLAYER'),
                        const SizedBox(height: 4),
                        _MenuItem(
                          icon: Icons.equalizer_rounded,
                          label: 'Equalizer',
                          subtitle: 'Graphic & Parametric EQ',
                          onTap: () => _navigate(const Equalizer()),
                        ),
                        if (!isEq) ...[
                          _MenuItem(
                            icon: Icons.lyrics_rounded,
                            label: 'Lyrics',
                            subtitle: 'View & edit song lyrics',
                            onTap: () {
                              context.read<DrawerProvider>().closeDrawer();
                              Navigator.of(context).push(
                                PageRouteBuilder(
                                  opaque: false,
                                  pageBuilder: (_, __, ___) =>
                                      const LyricsView(),
                                  transitionsBuilder: (_, anim, __, child) {
                                    return SlideTransition(
                                      position:
                                          Tween<Offset>(
                                            begin: const Offset(0, 1),
                                            end: Offset.zero,
                                          ).animate(
                                            CurvedAnimation(
                                              parent: anim,
                                              curve: Curves.easeOutCubic,
                                            ),
                                          ),
                                      child: child,
                                    );
                                  },
                                  transitionDuration: const Duration(
                                    milliseconds: 350,
                                  ),
                                ),
                              );
                            },
                          ),
                          _MenuItem(
                            icon: Icons.graphic_eq_rounded,
                            label: 'Visualizer',
                            subtitle: 'Audio visual effects',
                            onTap: () => _navigate(const VisualUI()),
                          ),
                        ],

                        if (!isEq) ...[
                          const SizedBox(height: 20),
                          _SectionLabel('LIBRARY'),
                          const SizedBox(height: 4),
                          _MenuItem(
                            icon: Icons.cloud_rounded,
                            label: 'Cloud Music',
                            subtitle: 'Google Drive & Dropbox',
                            onTap: () => _closeAndRun(_openCloud),
                          ),
                          _MenuItem(
                            icon: Icons.refresh_rounded,
                            label: 'Rescan Library',
                            subtitle: 'Reload local music files',
                            onTap: () => _closeAndRun(
                              () => Navigator.pushNamed(context, Routes.loader),
                            ),
                          ),
                        ],

                        const SizedBox(height: 20),
                        _SectionLabel('APP'),
                        const SizedBox(height: 4),
                        _MenuItem(
                          icon: Icons.settings_rounded,
                          label: 'Settings',
                          subtitle: isEq
                              ? 'Audio, appearance & more'
                              : 'Playback, theme & more',
                          onTap: () => _navigate(const Settings()),
                        ),
                        _MenuItem(
                          icon: Icons.bug_report_rounded,
                          label: 'Report a Bug',
                          subtitle: 'Send feedback',
                          onTap: () => _closeAndRun(
                            () =>
                                Wiredash.of(context)
                                    .show(inheritMaterialTheme: true),
                          ),
                        ),
                        _MenuItem(
                          icon: Icons.info_outline_rounded,
                          label: 'About',
                          subtitle: isEq
                              ? 'Hype EQ v1.1.2'
                              : 'Hype Muzik v1.1.2',
                          onTap: () => _showAbout(context),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
                // ── Footer ──
                _Footer(onExit: () => _showExitDialog(context)),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showAbout(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          backgroundColor: cs.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset('assets/icon.png', width: 36, height: 36),
              ),
              const SizedBox(width: 12),
              const Text('Hype Muzik'),
            ],
          ),
          content: const Text(
            'Your ultimate audio player with professional-grade EQ, '
            'cloud streaming, synced lyrics, and immersive visualizations.\n\n'
            'Version 1.1.2',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                showLicensePage(
                  context: context,
                  applicationName: 'Hype Muzik',
                  applicationVersion: '1.1.2',
                );
              },
              child: const Text('Licenses'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  void _showExitDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          backgroundColor: cs.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text('Exit Hype Muzik'),
          content: const Text('Are you sure you want to exit?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => exit(0),
              style: FilledButton.styleFrom(
                backgroundColor: cs.error,
                foregroundColor: cs.onError,
              ),
              child: const Text('Exit'),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Brand Header
// ─────────────────────────────────────────────────────────────────────────────

class _BrandHeader extends StatelessWidget {
  final ColorScheme colorScheme;
  const _BrandHeader({required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          // App icon with subtle glow
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: colorScheme.primary.withValues(alpha: 0.3),
                  blurRadius: 20,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.asset('assets/icon.png', fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hype Muzik',
                  style: AppFonts.displayStyle(
                    color: Colors.white,
                    fontSize: 22,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Premium Audio Experience',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section Label
// ─────────────────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 4, bottom: 2),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.25),
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.4,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Menu Item
// ─────────────────────────────────────────────────────────────────────────────

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  const _MenuItem({
    required this.icon,
    required this.label,
    this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        splashColor: Colors.white.withValues(alpha: 0.06),
        highlightColor: Colors.white.withValues(alpha: 0.03),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: Colors.white70, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 1),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.35),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: Colors.white.withValues(alpha: 0.15),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mode Switcher
// ─────────────────────────────────────────────────────────────────────────────

class _ModeSwitcher extends StatelessWidget {
  final AppMode mode;
  final ValueChanged<AppMode> onChanged;
  const _ModeSwitcher({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            _buildSegment(
              label: 'Music Player',
              icon: Icons.headphones_rounded,
              selected: mode == AppMode.musicPlayer,
              onTap: () => onChanged(AppMode.musicPlayer),
            ),
            _buildSegment(
              label: 'Equalizer',
              icon: Icons.equalizer_rounded,
              selected: mode == AppMode.equalizer,
              onTap: () => onChanged(AppMode.equalizer),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSegment({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? Colors.white.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.35),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.35),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Footer
// ─────────────────────────────────────────────────────────────────────────────

class _Footer extends StatelessWidget {
  final VoidCallback onExit;
  const _Footer({required this.onExit});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'v1.1.2',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.2),
                fontSize: 12,
              ),
            ),
          ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onExit,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.power_settings_new_rounded,
                      color: Colors.white.withValues(alpha: 0.3),
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Exit',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.3),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
