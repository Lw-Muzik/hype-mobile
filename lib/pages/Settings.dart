import 'dart:io';
import 'dart:typed_data';

import '/Helpers/audio_visualizer.dart';
import '/Helpers/channel.dart';
import '/routes/routes.dart';
import '/controllers/app_controller.dart';
import '/widgets/body.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wiredash/wiredash.dart';

import '../config/app_config.dart';
import '../models/eq_models.dart';
import '../onboarding/coach_marks.dart';
import '../onboarding/interactions_guide.dart';
import '../services/streaming_data_guard.dart';
import '../services/share_service.dart';
import '../services/connect/hype_connect.dart';
import 'hype_connect_page.dart';
import 'stream_server.dart';

import '/widgets/bottom_player.dart';
import '../services/radio/radio_queue.dart';
import '../services/ytmusic/yt_download_repair.dart';
import '/controllers/library_controller.dart';
import 'package:just_audio/just_audio.dart' show UriAudioSource;
import '../themes/ember.dart';

/// One group of settings, and the sections it gathers.
///
/// # Why an index and not one scroll
///
/// This page carried fifteen sections in a single list — App Mode through
/// About — and finding one meant scrolling past the fourteen that were not it.
/// Grouping into a handful of categories, each opening a focused page, is what
/// every piece of guidance on settings converges on, and a search field is what
/// makes the grouping bearable when the user does not know which group a thing
/// is in.
enum SettingsCategory {
  // ── Playback ──
  appMode('App Mode', Icons.swap_horiz_rounded,
      'Full player, or equalizer only', _SettingsGroup.playback),
  playback('Playback', Icons.play_circle_outline_rounded,
      'Gapless, crossfade, replay gain, autoplay', _SettingsGroup.playback),
  streaming('Streaming', Icons.wifi_rounded,
      'Data saver and cellular limits', _SettingsGroup.playback),

  // ── Sound ──
  equalizer('Equalizer', Icons.equalizer_rounded,
      'Bands, presets, global EQ', _SettingsGroup.sound),
  tone('Tone & Effects', Icons.tune_rounded,
      'Bass, treble, enhancement', _SettingsGroup.sound),

  // ── Look ──
  appearance('Appearance', Icons.palette_outlined,
      'Theme, blur, artwork background', _SettingsGroup.look),
  visualizer('Visualizers', Icons.graphic_eq_rounded,
      'Spectrum, visual style, MilkDrop', _SettingsGroup.look),

  // ── System ──
  library('Library', Icons.library_music_outlined,
      'Scanning, artwork, identifying tracks', _SettingsGroup.system),
  devices('Cloud & Devices', Icons.devices_rounded,
      'Drives, phone link, cast to desktop', _SettingsGroup.system),
  about('About & Support', Icons.info_outline_rounded,
      'App info, guides, report a bug', _SettingsGroup.system);

  const SettingsCategory(this.title, this.icon, this.summary, this.group);

  final String title;
  final IconData icon;
  final String summary;
  final _SettingsGroup group;
}

/// The headings the index is divided under.
///
/// Ten rows in one undivided list is the same crowding problem one level up.
/// Four headings give the eye somewhere to land.
enum _SettingsGroup {
  playback('PLAYBACK'),
  sound('SOUND'),
  look('LOOK'),
  system('SYSTEM');

  const _SettingsGroup(this.label);
  final String label;
}

/// One searchable setting: what it is called, and where it lives.
///
/// Written out rather than derived from the widget tree because the tree is
/// built lazily per category — nothing can be searched that has not been built,
/// and the whole point is to find a setting without knowing where it is.
class SettingsEntry {
  const SettingsEntry(this.label, this.category, [this.keywords = '']);
  final String label;
  final SettingsCategory category;

  /// Extra words someone might reach for. "loudness" finds Replay Gain.
  final String keywords;

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return false;
    return label.toLowerCase().contains(q) ||
        keywords.toLowerCase().contains(q) ||
        category.title.toLowerCase().contains(q);
  }
}

const kSettingsIndex = <SettingsEntry>[
  SettingsEntry('App mode', SettingsCategory.appMode, 'player equalizer only'),
  SettingsEntry('Gapless playback', SettingsCategory.playback, 'seamless'),
  SettingsEntry('Crossfade', SettingsCategory.playback, 'fade overlap'),
  SettingsEntry('Autoplay', SettingsCategory.playback, 'radio station endless'),
  SettingsEntry('Data Saver', SettingsCategory.streaming, 'quality data network'),
  SettingsEntry('Stream on Cellular', SettingsCategory.streaming, 'mobile wifi'),
  SettingsEntry('Cellular Data Limit', SettingsCategory.streaming, 'cap mb quota'),
  SettingsEntry('Equalizer', SettingsCategory.equalizer, 'eq bands preset'),
  SettingsEntry('Global equalizer', SettingsCategory.equalizer, 'system wide other apps'),
  SettingsEntry('Replay gain', SettingsCategory.playback, 'loudness volume normalise'),
  SettingsEntry('Bass', SettingsCategory.tone, 'low end boost'),
  SettingsEntry('Treble', SettingsCategory.tone, 'high end'),
  SettingsEntry('Audio enhancement', SettingsCategory.tone, 'effects reverb virtualizer'),
  SettingsEntry('Theme', SettingsCategory.appearance, 'dark light fancy colour'),
  SettingsEntry('Blur', SettingsCategory.appearance, 'background artwork'),
  SettingsEntry('Visualizer', SettingsCategory.visualizer, 'spectrum waveform bars'),
  SettingsEntry('Visual style', SettingsCategory.visualizer, 'frame rate'),
  SettingsEntry('MilkDrop', SettingsCategory.visualizer, 'presets'),
  SettingsEntry('Rescan library', SettingsCategory.library, 'refresh songs missing'),
  SettingsEntry('Identify unknown tracks', SettingsCategory.library,
      'fingerprint tags artwork'),
  if (AppConfig.directBuild)
    SettingsEntry('Fix YouTube downloads', SettingsCategory.library,
        'repair tags cover artwork lyrics album artist metadata'),
  SettingsEntry('Cloud storage', SettingsCategory.devices, 'google drive dropbox'),
  SettingsEntry('Phone link', SettingsCategory.devices, 'upload transfer'),
  SettingsEntry('Stream to desktop', SettingsCategory.devices, 'cast'),
  SettingsEntry('Hype Connect', SettingsCategory.devices,
      'remote control browser web link devices qr code play from computer'),
  SettingsEntry('About Hype Music', SettingsCategory.about, 'version build info'),
  SettingsEntry('Interactions Guide', SettingsCategory.about, 'gestures shortcuts tips'),
  SettingsEntry('Reset Guides', SettingsCategory.about,
      'walkthrough onboarding coach marks show again tour'),
  SettingsEntry('Report a bug', SettingsCategory.about, 'feedback send issue'),
];

class Settings extends StatefulWidget {
  /// Null shows the index; a category shows just that category's sections.
  ///
  /// The same State either way, so every section builder below is reached
  /// unchanged — none of the wiring inside them moves.
  const Settings({super.key, this.category});

  final SettingsCategory? category;

  @override
  State<Settings> createState() => _SettingsState();
}

class _SettingsState extends State<Settings> {
  bool _scanning = false;
  int _scanCurrent = 0;
  int _scanTotal = 0;
  String _scanSongName = '';
  int? _scanResult;

  // Fixing YouTube downloads that predate tagging.
  bool _repairing = false;
  int _repairDone = 0;
  int _repairTotal = 0;
  String _repairName = '';
  YtRepairReport? _repairReport;

  @override
  void initState() {
    super.initState();
    // The Autoplay switch below reads a field that starts at its default, so
    // without this it shows "on" to a user who turned it off in an earlier
    // session and never opened Discover this run.
    RadioQueue.instance.loadPreference().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, controller, child) {
        return StreamBuilder(
          // The handler off the controller, not out of a second provider.
          // `context.read<HypeAudioHandler>()` threw "Provider not found" here
          // and took the whole page with it — Flutter renders a grey
          // ErrorWidget in release, so Settings was a blank grey screen rather
          // than anything that looked like a crash. The controller already
          // holds the handler, so the lookup was redundant as well as broken.
          stream: controller.handler.player.playingStream,
          builder: (context, service) {
            return Body(
              child: Scaffold(
                backgroundColor: controller.isFancy
                    ? Colors.transparent
                    : Theme.of(context).scaffoldBackgroundColor,
                appBar: AppBar(
                  forceMaterialTransparency: controller.isFancy,
                  title: Text(widget.category?.title ?? "Settings"),
                ),
                body: widget.category == null
                    ? _buildIndex(controller)
                    : _buildCategory(controller, widget.category!),
                bottomNavigationBar:
                    !controller.isEqMode && controller.hasMiniPlayer
                    ? BottomPlayer(controller: controller)
                    : null,
              ),
            );
          },
        );
      },
    );
  }

  // -- Index --

  String _query = '';

  /// The categories worth showing, given the app's current mode.
  ///
  /// EQ-only mode hides most of the app, so it hides most of the settings too —
  /// offering a Library page to someone running the equalizer alone is offering
  /// a page that will be empty when they arrive.
  List<SettingsCategory> _visibleCategories(AppController controller) {
    if (controller.isEqMode) {
      return const [
        SettingsCategory.appMode,
        SettingsCategory.equalizer,
        SettingsCategory.tone,
        SettingsCategory.about,
      ];
    }
    return [
      for (final category in SettingsCategory.values)
        // Nothing to show on a device without a system-wide equalizer.
        if (category != SettingsCategory.appMode || Platform.isAndroid)
          category,
    ];
  }

  Widget _buildIndex(AppController controller) {
    final searching = _query.trim().isNotEmpty;
    final visible = _visibleCategories(controller);
    if (searching) {
      // Only what this mode can actually reach. Equalizer-only mode hides most
      // of the categories, and a search result that opens a page the mode does
      // not otherwise offer is a dead end dressed up as an answer.
      final reachable = visible.toSet();
      final matches = [
        for (final entry in kSettingsIndex)
          if (reachable.contains(entry.category) && entry.matches(_query))
            entry,
      ];
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _buildSearchField(),
          const SizedBox(height: 8),
          if (matches.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text('Nothing matches that',
                    style: TextStyle(color: Ember.textTertiary)),
              ),
            )
          else
            ...matches.map(_buildSearchResult),
        ],
      );
    }

    final children = <Widget>[_buildSearchField(), const SizedBox(height: 20)];
    for (final group in _SettingsGroup.values) {
      final inGroup = [
        for (final category in visible)
          if (category.group == group) category,
      ];
      if (inGroup.isEmpty) continue;
      children
        ..add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Text(group.label, style: Ember.shelfTitle(context)),
        ))
        ..addAll(inGroup.map(_buildCategoryRow))
        ..add(const SizedBox(height: 22));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: children,
    );
  }

  Widget _buildSearchField() {
    return TextField(
      onChanged: (value) => setState(() => _query = value),
      style: const TextStyle(color: Ember.textPrimary, fontSize: 15),
      decoration: InputDecoration(
        hintText: 'Search settings',
        hintStyle: TextStyle(color: Ember.textTertiary, fontSize: 15),
        prefixIcon: Icon(Icons.search_rounded, color: Ember.textTertiary),
        filled: true,
        fillColor: Ember.surface,
        contentPadding: const EdgeInsets.symmetric(vertical: 4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Ember.radiusTile),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  /// A hit names the setting AND the group it is in — finding it is only half
  /// the job, the other half is knowing where it lived so it can be found again.
  Widget _buildSearchResult(SettingsEntry entry) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: Icon(entry.category.icon, color: Ember.accent, size: 22),
      title: Text(entry.label,
          style: const TextStyle(
              color: Ember.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w500)),
      subtitle: Text(entry.category.title,
          style: TextStyle(color: Ember.textTertiary, fontSize: 12)),
      trailing:
          Icon(Icons.chevron_right_rounded, color: Ember.textTertiary, size: 20),
      onTap: () => _openCategory(entry.category),
    );
  }

  Widget _buildCategoryRow(SettingsCategory category) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Ember.surface,
        borderRadius: BorderRadius.circular(Ember.radiusTile),
        child: InkWell(
          borderRadius: BorderRadius.circular(Ember.radiusTile),
          onTap: () => _openCategory(category),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                // A tinted plate rather than a bare glyph: at this size an icon
                // alone reads as decoration, and the row is the tap target.
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: Ember.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(Ember.radiusControl),
                  ),
                  child: Icon(category.icon, color: Ember.accent, size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(category.title,
                          style: const TextStyle(
                              color: Ember.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(category.summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Ember.textTertiary, fontSize: 12)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    color: Ember.textTertiary, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openCategory(SettingsCategory category) {
    Routes.scaleTo(Settings(category: category), context);
  }

  /// One category's page. The section builders are reached exactly as they were
  /// — nothing inside them moves, which is the point: the wiring in fifteen
  /// hundred lines of controls is the part worth not touching.
  Widget _buildCategory(AppController controller, SettingsCategory category) {
    final body = switch (category) {
      SettingsCategory.appMode => _buildAppModeSection(controller),
      SettingsCategory.playback => _buildPlaybackSection(controller),
      SettingsCategory.streaming => _buildStreamingSection(),
      SettingsCategory.equalizer => Column(children: [
          if (controller.globalEqAvailable) ...[
            _buildGlobalEqSection(controller),
            const SizedBox(height: 12),
          ],
          _buildEqualizerSection(controller),
        ]),
      SettingsCategory.tone => Column(children: [
          if (!controller.isEqMode) ...[
            _buildAudioEnhancementSection(controller),
            const SizedBox(height: 12),
          ],
          _buildToneSection(controller),
        ]),
      SettingsCategory.appearance => _buildAppearanceSection(controller),
      SettingsCategory.visualizer => _buildVisualizerSection(controller),
      SettingsCategory.library => _buildLibrarySection(),
      SettingsCategory.devices => Column(children: [
          _buildCloudStorageSection(controller),
          const SizedBox(height: 12),
          _buildPhoneLinkSection(),
          const SizedBox(height: 12),
          _buildHypeConnectSection(),
        ]),
      SettingsCategory.about => _buildAboutSection(context),
    };

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        // The summary from the index, repeated as a lede. Arriving on a page
        // whose title you tapped a second ago and being told what it is for
        // costs one line and settles "am I in the right place".
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
          child: Text(category.summary,
              style: TextStyle(color: Ember.textTertiary, fontSize: 13)),
        ),
        body,
      ],
    );
  }

  // -- Section builder helpers --

  Widget _buildSectionHeader(IconData icon, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionCard(List<Widget> children) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }

  // -- App Mode Section --

  Widget _buildAppModeSection(AppController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(Icons.swap_horiz, "App Mode"),
        _buildSectionCard([
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: SegmentedButton<AppMode>(
              segments: const [
                ButtonSegment<AppMode>(
                  value: AppMode.musicPlayer,
                  label: Text('Music Player'),
                  icon: Icon(Icons.headphones_rounded),
                ),
                ButtonSegment<AppMode>(
                  value: AppMode.equalizer,
                  label: Text('Equalizer'),
                  icon: Icon(Icons.equalizer_rounded),
                ),
              ],
              selected: {controller.appMode},
              onSelectionChanged: (values) {
                controller.appMode = values.first;
              },
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.15),
                selectedForegroundColor: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Text(
              'Switch between full music player and EQ-only mode',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
        ]),
      ],
    );
  }

  // -- Playback Section --

  Widget _buildPlaybackSection(AppController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(Icons.headphones, "Playback"),
        _buildSectionCard([
          SwitchListTile.adaptive(
            value: controller.gaplessPlayback,
            title: const Text("Gapless playback"),
            subtitle: Text(controller.gaplessPlayback ? "Enabled" : "Disabled"),
            onChanged: (enabled) => controller.gaplessPlayback = enabled,
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            title: const Text("Crossfade"),
            subtitle: Text(
              controller.crossfadeDuration == 0
                  ? "Off"
                  : "${controller.crossfadeDuration}s",
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text("0s"),
                Expanded(
                  child: Slider.adaptive(
                    value: controller.crossfadeDuration.toDouble(),
                    min: 0,
                    max: 30,
                    divisions: 30,
                    label: "${controller.crossfadeDuration}s",
                    onChanged: (value) =>
                        controller.crossfadeDuration = value.toInt(),
                  ),
                ),
                const Text("30s"),
              ],
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          SwitchListTile.adaptive(
            value: controller.replayGain,
            title: const Text("Replay gain"),
            subtitle: const Text("Volume normalization via ID3 tags"),
            onChanged: (enabled) => controller.replayGain = enabled,
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          // Gates every radio request Discover would otherwise make — with this
          // off, no related-track fetching happens at all.
          SwitchListTile.adaptive(
            value: RadioQueue.instance.enabled,
            title: const Text("Autoplay"),
            subtitle: const Text(
              "Keep playing related tracks when a Discover queue ends",
            ),
            onChanged: (enabled) async {
              await RadioQueue.instance.setEnabled(enabled);
              if (mounted) setState(() {});
            },
          ),
        ]),
      ],
    );
  }

  // -- Audio Enhancement Section --

  Widget _buildAudioEnhancementSection(AppController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(Icons.tune, "Audio Enhancement"),
        _buildSectionCard([
          SwitchListTile.adaptive(
            value: controller.dvcEnabled,
            title: const Text("Direct volume control"),
            subtitle: const Text(
              "Bypasses system volume for higher fidelity audio output",
            ),
            onChanged: (enabled) {
              if (enabled && !controller.dvcEnabled) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("System volume will be set to maximum"),
                    duration: Duration(seconds: 3),
                  ),
                );
              }
              controller.dvcEnabled = enabled;
            },
          ),
          if (controller.dvcEnabled) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              title: const Text("DVC Volume"),
              subtitle: Text(
                "${((controller.dvcGain + 30) / 30 * 100).round()}%",
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Text("0%"),
                  Expanded(
                    child: Slider.adaptive(
                      value: controller.dvcGain,
                      min: -30,
                      max: 0,
                      divisions: 20,
                      label:
                          "${((controller.dvcGain + 30) / 30 * 100).round()}%",
                      onChanged: (value) => controller.dvcGain = value,
                    ),
                  ),
                  const Text("100%"),
                ],
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "System volume set to MAX. Use hardware buttons or this slider to control volume.",
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            SwitchListTile.adaptive(
              value: controller.dvcFineSteps,
              title: const Text("Fine volume steps"),
              subtitle: const Text("1% steps instead of 5% (hardware buttons)"),
              onChanged: (value) => controller.dvcFineSteps = value,
            ),
          ],
        ]),
      ],
    );
  }

  // -- Global EQ Section --

  Widget _buildGlobalEqSection(AppController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(Icons.public, "Global Equalizer"),
        _buildSectionCard([
          SwitchListTile.adaptive(
            value: controller.globalEqEnabled,
            title: const Text("System-wide EQ"),
            subtitle: Text(
              controller.globalEqEnabled
                  ? "Active — EQ applied to all apps"
                  : "Off",
            ),
            onChanged: (enabled) {
              if (enabled) {
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
                          // Prompt for battery optimization if not already disabled
                          final isDisabled =
                              await Channel.isBatteryOptimizationDisabled();
                          if (!isDisabled && mounted) {
                            _showBatteryOptimizationPrompt();
                          }
                        },
                        child: const Text("Enable"),
                      ),
                    ],
                  ),
                );
              } else {
                controller.globalEqEnabled = false;
              }
            },
          ),
          if (controller.globalEqEnabled) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "EQ, tone, and limiter changes sync to other apps in real-time. "
                      "Parametric EQ, MBC, reverb, and stereo effects are not applied globally.",
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            _buildPlayingAppsRow(controller),
          ],
        ]),
      ],
    );
  }

  void _showBatteryOptimizationPrompt() {
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

  Widget _buildPlayingAppsRow(AppController controller) {
    final apps = controller.playingApps;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
          child: Row(
            children: [
              Icon(
                Icons.apps,
                size: 16,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "Apps currently playing",
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: "Refresh",
                visualDensity: VisualDensity.compact,
                onPressed: () => controller.refreshPlayingApps(),
              ),
            ],
          ),
        ),
        if (apps.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              "None detected",
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          )
        else
          ...apps.map(
            (app) => _AppIconTile(
              packageName: app['package'] ?? '',
              appName: app['name'] ?? app['package'] ?? '',
            ),
          ),
        const SizedBox(height: 4),
      ],
    );
  }

  // -- Equalizer Section --

  Widget _buildEqualizerSection(AppController controller) {
    final bandCount = controller.eqBandCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(Icons.equalizer, "Equalizer"),
        _buildSectionCard([
          ListTile(
            title: const Text("Band count"),
            subtitle: Text("$bandCount bands"),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SegmentedButton<int>(
              segments: BandMapping.supportedCounts
                  .map((c) => ButtonSegment<int>(value: c, label: Text('$c')))
                  .toList(),
              selected: {bandCount},
              onSelectionChanged: (values) {
                controller.eqBandCount = values.first;
              },
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.15),
                selectedForegroundColor: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ]),
      ],
    );
  }

  // -- Tone Settings Section --

  Widget _buildToneSection(AppController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(Icons.tune, "Tone Controls"),
        _buildSectionCard([
          SwitchListTile.adaptive(
            value: controller.toneEnabled,
            title: const Text("Tone controls"),
            subtitle: Text(
              controller.toneEnabled ? "Bass & treble active" : "Disabled",
            ),
            onChanged: (enabled) => controller.toneEnabled = enabled,
          ),
          if (controller.toneEnabled) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            // Bass settings
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 12),
              child: Text(
                "Bass",
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            ListTile(
              dense: true,
              title: const Text("Frequency"),
              subtitle: Text("${controller.bassFreq.round()} Hz"),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Slider.adaptive(
                value: controller.bassFreq,
                min: 20,
                max: 250,
                divisions: 23,
                onChanged: (v) => controller.bassFreq = v,
              ),
            ),
            ListTile(
              dense: true,
              title: const Text("Q Factor"),
              subtitle: Text(controller.bassQ.toStringAsFixed(2)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Slider.adaptive(
                value: controller.bassQ,
                min: 0.1,
                max: 2.0,
                divisions: 19,
                onChanged: (v) => controller.bassQ = v,
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            // Treble settings
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 12),
              child: Text(
                "Treble",
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            ListTile(
              dense: true,
              title: const Text("Frequency"),
              subtitle: Text("${controller.trebleFreq.round()} Hz"),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Slider.adaptive(
                value: controller.trebleFreq,
                min: 5000,
                max: 15000,
                divisions: 10,
                onChanged: (v) => controller.trebleFreq = v,
              ),
            ),
            ListTile(
              dense: true,
              title: const Text("Q Factor"),
              subtitle: Text(controller.trebleQ.toStringAsFixed(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Slider.adaptive(
                value: controller.trebleQ,
                min: 0.1,
                max: 2.0,
                divisions: 19,
                onChanged: (v) => controller.trebleQ = v,
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            // Output limiter
            SwitchListTile.adaptive(
              value: controller.limiterEnabled,
              title: const Text("Output limiter"),
              subtitle: const Text("Prevents distortion from EQ boosts"),
              onChanged: (enabled) => controller.limiterEnabled = enabled,
            ),
          ],
        ]),
      ],
    );
  }

  // -- Appearance Section --

  Widget _buildAppearanceSection(AppController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(Icons.palette, "Appearance"),
        _buildSectionCard([
          SwitchListTile.adaptive(
            value: controller.isFancy,
            title: const Text("Fancy theme"),
            subtitle: Text(
              controller.isFancy ? "Fancy enabled" : "Fancy disabled",
            ),
            onChanged: (enabled) => controller.isFancy = enabled,
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            title: const Text("Player blur"),
            subtitle: Text(
              "${((controller.blur / 500) * 100).toStringAsFixed(0)}%",
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Slider.adaptive(
              value: controller.blur,
              min: 0,
              max: 500,
              onChanged: (value) => controller.blur = value,
            ),
          ),
        ]),
      ],
    );
  }

  // -- Visualizer Section --

  static Map<String, (String, IconData)> get _visualizerStyles => {
    'radial': ('Radial', Icons.flare_rounded),
    'bars': ('Spectrum', Icons.bar_chart_rounded),
    'mirror_bars': ('Mirror', Icons.align_vertical_center_rounded),
    'line': ('Waveform', Icons.show_chart_rounded),
    'terrain': ('Terrain', Icons.terrain_rounded),
    'dots': ('Matrix', Icons.grid_on_rounded),
    'silk': ('Silk', Icons.animation_rounded),
    'lissajous': ('Lissajous', Icons.all_inclusive_rounded),
    'windmill': ('Windmill', Icons.rotate_right_rounded),
    if (!Platform.isIOS) 'milkdrop': ('MilkDrop', Icons.blur_on_rounded),
  };

  static const _visualizerColors = [
    (0xFFFFFFFF, 'White'),
    (0xFFD4A825, 'Gold'),
    (0xFF2196F3, 'Blue'),
    (0xFF9C27B0, 'Purple'),
    (0xFF4CAF50, 'Green'),
    (0xFFE91E63, 'Pink'),
    (0xFFFF5722, 'Orange'),
    (0xFF00BCD4, 'Cyan'),
  ];

  Widget _buildVisualizerSection(AppController controller) {
    final accent = Theme.of(context).colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(Icons.graphic_eq, "Visualizer"),
        // No master "Enable visualizer" switch: these two rows ARE the switch.
        // Turning either on starts the native capture, turning both off stops
        // it. A third control could only disagree with them.
        _buildSectionCard([
          SwitchListTile.adaptive(
            value: controller.playerVisual,
            title: const Text("Bottom player visualizer"),
            subtitle: Text(controller.playerVisual ? "Enabled" : "Disabled"),
            onChanged: (enabled) => controller.playerVisual = enabled,
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          SwitchListTile.adaptive(
            value: controller.isVisualInBackground,
            title: const Text("Background visualizer"),
            subtitle: Text(
              controller.isVisualInBackground ? "Enabled" : "Disabled",
            ),
            onChanged: (enabled) => controller.isVisualInBackground = enabled,
          ),
        ]),

        const SizedBox(height: 12),
        _buildSectionHeader(Icons.auto_awesome, "Visual Style"),
        _buildSectionCard([
          // Style selector
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              "Style",
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _visualizerStyles.entries.map((entry) {
                final isSelected = controller.visualizerStyle == entry.key;
                return ChoiceChip(
                  avatar: Icon(
                    entry.value.$2,
                    size: 16,
                    color: isSelected ? accent : null,
                  ),
                  label: Text(entry.value.$1),
                  selected: isSelected,
                  onSelected: (_) => controller.visualizerStyle = entry.key,
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, indent: 16, endIndent: 16),

          // Color picker
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              "Color",
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: _visualizerColors.map((pair) {
                final colorVal = pair.$1;
                final isSelected = controller.visualizerColor == colorVal;
                return Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: GestureDetector(
                    onTap: () => controller.visualizerColor = colorVal,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Color(colorVal),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected ? accent : Colors.transparent,
                          width: 2.5,
                        ),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: Color(colorVal).withValues(alpha: 0.4),
                                  blurRadius: 8,
                                  spreadRadius: 1,
                                ),
                              ]
                            : null,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, indent: 16, endIndent: 16),

          // Frame rate slider
          ListTile(
            title: const Text("Frame rate"),
            subtitle: Text("${controller.visualizerFrameRate} fps"),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text("15"),
                Expanded(
                  child: Slider.adaptive(
                    value: controller.visualizerFrameRate.toDouble(),
                    min: 15,
                    max: 60,
                    divisions: 9,
                    label: "${controller.visualizerFrameRate} fps",
                    onChanged: (v) {
                      controller.visualizerFrameRate = v.toInt();
                      Visualizers.setFrameRate(v.toInt());
                    },
                  ),
                ),
                const Text("60"),
              ],
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),

          // Reactivity slider
          ListTile(
            title: const Text("Reactivity"),
            subtitle: Text(_reactivityLabel(controller.visualizerReactivity)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text("Smooth"),
                Expanded(
                  child: Slider.adaptive(
                    value: controller.visualizerReactivity,
                    min: 0.05,
                    max: 0.35,
                    divisions: 6,
                    onChanged: (v) {
                      controller.visualizerReactivity = v;
                      // Sync to C++ FFT smoothing: attack = reactivity, decay = reactivity * 0.7
                      Visualizers.setSmoothing(v, v * 0.7);
                    },
                  ),
                ),
                const Text("Snappy"),
              ],
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),

          // Beat sensitivity slider
          ListTile(
            title: const Text("Beat sensitivity"),
            subtitle: Text(
              _beatSensitivityLabel(controller.visualizerBeatSensitivity),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                const Text("Subtle"),
                Expanded(
                  child: Slider.adaptive(
                    value: controller.visualizerBeatSensitivity,
                    min: 0.5,
                    max: 3.0,
                    divisions: 10,
                    onChanged: (v) {
                      controller.visualizerBeatSensitivity = v;
                      Visualizers.setGain(v);
                    },
                  ),
                ),
                const Text("Intense"),
              ],
            ),
          ),
        ]),

        // MilkDrop settings (Android only, shown when milkdrop style is active)
        if (!Platform.isIOS && controller.visualizerStyle == 'milkdrop') ...[
          const SizedBox(height: 12),
          _buildSectionHeader(Icons.blur_on_rounded, "MilkDrop"),
          _buildSectionCard([
            ListTile(
              title: const Text("Render quality"),
              subtitle: Text(_milkdropQualityLabel(controller.milkdropQuality)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text("Low")),
                  ButtonSegment(value: 1, label: Text("Med")),
                  ButtonSegment(value: 2, label: Text("High")),
                  ButtonSegment(value: 3, label: Text("Ultra")),
                ],
                selected: {controller.milkdropQuality},
                onSelectionChanged: (s) {
                  controller.milkdropQuality = s.first;
                },
                showSelectedIcon: false,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                "Restart visualizer for changes to take effect",
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              title: const Text("Render FPS"),
              subtitle: Text("${controller.milkdropFps} fps"),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Text("15"),
                  Expanded(
                    child: Slider.adaptive(
                      value: controller.milkdropFps.toDouble(),
                      min: 15,
                      max: 60,
                      divisions: 9,
                      label: "${controller.milkdropFps} fps",
                      onChanged: (v) {
                        controller.milkdropFps = v.toInt();
                      },
                    ),
                  ),
                  const Text("60"),
                ],
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              title: const Text("Beat sensitivity"),
              subtitle: Text(
                _beatSensitivityLabel(controller.milkdropBeatSensitivity),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Text("Low"),
                  Expanded(
                    child: Slider.adaptive(
                      value: controller.milkdropBeatSensitivity,
                      min: 0.2,
                      max: 3.0,
                      divisions: 14,
                      onChanged: (v) {
                        controller.milkdropBeatSensitivity = v;
                      },
                    ),
                  ),
                  const Text("High"),
                ],
              ),
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              title: const Text("Preset auto-cycle"),
              subtitle: Text(
                controller.milkdropPresetDuration > 0
                    ? "${controller.milkdropPresetDuration.toInt()}s"
                    : "Manual only",
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  const Text("Off"),
                  Expanded(
                    child: Slider.adaptive(
                      value: controller.milkdropPresetDuration,
                      min: 0,
                      max: 120,
                      divisions: 12,
                      onChanged: (v) {
                        controller.milkdropPresetDuration = v;
                      },
                    ),
                  ),
                  const Text("120s"),
                ],
              ),
            ),
          ]),
        ],
      ],
    );
  }

  String _milkdropQualityLabel(int quality) {
    const labels = [
      "Low (480p)",
      "Medium (720p)",
      "High (1080p)",
      "Ultra (native)",
    ];
    return labels[quality.clamp(0, 3)];
  }

  String _beatSensitivityLabel(double value) {
    if (value <= 0.7) return "Subtle";
    if (value <= 1.1) return "Normal";
    if (value <= 1.7) return "Energetic";
    if (value <= 2.3) return "Punchy";
    return "Intense";
  }

  String _reactivityLabel(double value) {
    if (value <= 0.08) return "Very smooth";
    if (value <= 0.12) return "Smooth";
    if (value <= 0.18) return "Balanced";
    if (value <= 0.25) return "Responsive";
    return "Snappy";
  }

  // -- Streaming Section --

  Widget _buildStreamingSection() {
    final guard = StreamingDataGuard.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(Icons.wifi_rounded, "Streaming"),
        _buildSectionCard([
          SwitchListTile(
            secondary: const Icon(Icons.data_saver_on_rounded),
            title: const Text("Data Saver"),
            subtitle: const Text(
              "Skip background caching on cellular — only buffer what you listen to",
            ),
            value: guard.dataSaver,
            onChanged: (v) {
              setState(() => guard.dataSaver = v);
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          SwitchListTile(
            secondary: const Icon(Icons.cell_tower_rounded),
            title: const Text("Stream on Cellular"),
            subtitle: const Text("Allow streaming when not on WiFi"),
            value: guard.streamOnCellular,
            onChanged: (v) {
              setState(() => guard.streamOnCellular = v);
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: const Icon(Icons.speed_rounded),
            title: const Text("Cellular Data Limit"),
            subtitle: Text(
              guard.cellularLimitMB > 0
                  ? "${guard.cellularLimitMB} MB per session"
                  : "Unlimited",
            ),
            trailing: DropdownButton<int>(
              value: guard.cellularLimitMB,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 0, child: Text("Unlimited")),
                DropdownMenuItem(value: 50, child: Text("50 MB")),
                DropdownMenuItem(value: 100, child: Text("100 MB")),
                DropdownMenuItem(value: 200, child: Text("200 MB")),
                DropdownMenuItem(value: 500, child: Text("500 MB")),
              ],
              onChanged: (v) {
                if (v != null) setState(() => guard.cellularLimitMB = v);
              },
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          SwitchListTile(
            secondary: const Icon(Icons.download_rounded),
            title: const Text("Prefetch Next Track"),
            subtitle: Text(
              guard.prefetchOnlyOnWifi
                  ? "Pre-downloads next song on WiFi only"
                  : "Full file on WiFi, first 30s on cellular",
            ),
            value: guard.prefetchNextTrack,
            onChanged: (v) {
              setState(() => guard.prefetchNextTrack = v);
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          SwitchListTile(
            secondary: const Icon(Icons.wifi_lock_rounded),
            title: const Text("Prefetch on WiFi Only"),
            subtitle: const Text("Only prefetch when connected to WiFi"),
            value: guard.prefetchOnlyOnWifi,
            onChanged: (v) {
              setState(() => guard.prefetchOnlyOnWifi = v);
            },
          ),
          if (guard.cellularBytesUsed > 0 || guard.totalCellularBytes > 0) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
              leading: const Icon(Icons.bar_chart_rounded),
              title: const Text("Cellular Data Used"),
              subtitle: Text(
                "Session: ${guard.cellularUsageFormatted} · Total: ${guard.totalCellularFormatted}",
              ),
            ),
          ],
        ]),
      ],
    );
  }

  // -- Cloud Storage Section --

  Widget _buildCloudStorageSection(AppController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(Icons.cloud_rounded, "Cloud Storage"),
        _buildSectionCard([
          ListTile(
            leading: const Icon(Icons.cloud_rounded),
            title: const Text("Google Drive"),
            subtitle: Text(
              controller.isGoogleConnected ? "Connected" : "Not connected",
            ),
            trailing: FilledButton.tonal(
              onPressed: () async {
                if (controller.isGoogleConnected) {
                  await controller.disconnectGoogle();
                } else {
                  await controller.connectGoogle();
                }
              },
              child: Text(
                controller.isGoogleConnected ? "Disconnect" : "Connect",
              ),
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: const Icon(Icons.cloud_circle_rounded),
            title: const Text("Dropbox"),
            subtitle: Text(
              controller.isDropboxConnected ? "Connected" : "Not connected",
            ),
            trailing: FilledButton.tonal(
              onPressed: () async {
                if (controller.isDropboxConnected) {
                  await controller.disconnectDropbox();
                } else {
                  await controller.connectDropbox();
                }
              },
              child: Text(
                controller.isDropboxConnected ? "Disconnect" : "Connect",
              ),
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            leading: const Icon(Icons.storage_rounded),
            title: const Text("Audio cache"),
            subtitle: Text(controller.cloudCache.currentSizeFormatted),
            trailing: TextButton(
              onPressed: () async {
                await controller.cloudCache.clearCache();
                setState(() {});
              },
              child: const Text("Clear"),
            ),
          ),
        ]),
      ],
    );
  }

  // -- Phone Link Section --

  Widget _buildPhoneLinkSection() {
    final server = ShareService.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(Icons.cast_rounded, "Stream to Desktop"),
        _buildSectionCard([
          ListTile(
            leading: const Icon(Icons.cast_rounded),
            title: const Text("Stream to desktop"),
            subtitle: Text(
              server.running
                  ? "Sharing — open the Phone tab on your computer"
                  : "Play this phone's music on the HypeMuzik desktop app",
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Routes.routeTo(const StreamServerPage(), context),
          ),
        ]),
      ],
    );
  }

  // -- Hype Connect --

  Widget _buildHypeConnectSection() {
    final connect = HypeConnect.instanceOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(Icons.cast_connected_rounded, "Hype Connect"),
        _buildSectionCard([
          ListenableBuilder(
            listenable: connect ?? const AlwaysStoppedAnimation(0),
            builder: (context, _) => ListTile(
              leading: const Icon(Icons.cast_connected_rounded),
              title: const Text("Hype Connect"),
              subtitle: Text(
                connect == null
                    ? "Play music here from the web or your computer"
                    : connect.enabled
                        ? "On — link browsers and computers, see linked devices"
                        : "Off — play music here from the web or your computer",
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: connect == null
                  ? null
                  : () => Routes.routeTo(const HypeConnectPage(), context),
            ),
          ),
        ]),
      ],
    );
  }

  // -- Library Section --

  Widget _buildLibrarySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(Icons.library_music, "Library"),
        _buildSectionCard([
          ListTile(
            title: const Text("Rescan library"),
            subtitle: const Text(
              "Tap to rescan assets in case of missing files",
            ),
            trailing: const Icon(Icons.refresh),
            onTap: () => Navigator.pushNamed(context, Routes.loader),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          if (_scanning) ...[
            ListTile(
              leading: const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator.adaptive(strokeWidth: 2),
              ),
              title: Text("Identifying $_scanCurrent of $_scanTotal"),
              subtitle: Text(
                _scanSongName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: LinearProgressIndicator(
                value: _scanTotal > 0 ? _scanCurrent / _scanTotal : 0,
              ),
            ),
          ] else if (_scanResult != null) ...[
            ListTile(
              leading: Icon(
                Icons.check_circle,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text("Identified $_scanResult tracks"),
              subtitle: const Text("Tap to scan again"),
              onTap: () {
                setState(() => _scanResult = null);
                _startBatchScan();
              },
            ),
          ] else ...[
            ListTile(
              title: const Text("Identify unknown tracks"),
              subtitle: const Text(
                "Fingerprint and tag songs with missing metadata",
              ),
              trailing: const Icon(Icons.fingerprint),
              onTap: _startBatchScan,
            ),
          ],
          if (AppConfig.directBuild) ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            ..._buildRepairTiles(),
          ],
        ]),
      ],
    );
  }

  Future<void> _startBatchScan() async {
    final controller = context.read<AppController>();
    final songs = await controller.audioQuery.querySongs();
    if (songs.isEmpty) return;

    setState(() {
      _scanning = true;
      _scanCurrent = 0;
      _scanTotal = 0;
      _scanSongName = '';
      _scanResult = null;
    });

    final identified = await controller.fingerprintService.batchIdentify(
      songs,
      onProgress: (current, total, name) {
        if (mounted) {
          setState(() {
            _scanCurrent = current;
            _scanTotal = total;
            _scanSongName = name;
          });
        }
      },
    );

    if (mounted) {
      setState(() {
        _scanning = false;
        _scanResult = identified;
      });
    }
  }

  /// "Fix YouTube downloads": idle, working (with which song), or what it did.
  List<Widget> _buildRepairTiles() {
    if (_repairing) {
      return [
        ListTile(
          leading: const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator.adaptive(strokeWidth: 2),
          ),
          title: Text(
            _repairTotal == 0
                ? "Looking for downloads…"
                : "Fixing ${_repairDone + 1 > _repairTotal ? _repairTotal : _repairDone + 1} of $_repairTotal",
          ),
          subtitle: Text(
            _repairName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: LinearProgressIndicator(
            value: _repairTotal > 0 ? _repairDone / _repairTotal : null,
          ),
        ),
      ];
    }
    final report = _repairReport;
    if (report != null) {
      final done = report.fixed;
      final notes = [
        if (report.fromFileName > 0)
          "${report.fromFileName} named from their file names",
        if (report.failed > 0) "${report.failed} couldn't be fixed",
        if (report.skipped > 0) "${report.skipped} skipped while playing",
      ];
      return [
        ListTile(
          leading: Icon(
            Icons.check_circle,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: Text(
            done == 0 && notes.isEmpty
                ? "No downloads need fixing"
                : "Fixed $done download${done == 1 ? '' : 's'}",
          ),
          subtitle: Text(
            notes.isEmpty ? "Tap to check again" : "${notes.join(' · ')}. Tap to try again",
          ),
          onTap: () {
            setState(() => _repairReport = null);
            _startRepair();
          },
        ),
      ];
    }
    return [
      ListTile(
        title: const Text("Fix YouTube downloads"),
        subtitle: const Text(
          "Add song info, covers and lyrics to downloads that have none",
        ),
        trailing: const Icon(Icons.auto_fix_high),
        onTap: _startRepair,
      ),
    ];
  }

  Future<void> _startRepair() async {
    final controller = context.read<AppController>();
    final library = context.read<LibraryController>();
    setState(() {
      _repairing = true;
      _repairDone = 0;
      _repairTotal = 0;
      _repairName = '';
      _repairReport = null;
    });
    var report = const YtRepairReport();
    try {
      final songs = await library.repo.allSongs();
      final candidates = await YtDownloadRepair.findCandidates([
        for (final s in songs) (path: s.data, durationMs: s.duration),
      ]);
      if (candidates.isNotEmpty) {
        // The song playing now is left alone: rewriting a file under the
        // player would cut it off.
        final source = controller.handler.player.sequenceState.currentSource;
        final playing = source is UriAudioSource && source.uri.scheme == 'file'
            ? source.uri.toFilePath()
            : null;
        report = await YtDownloadRepair().run(
          candidates,
          playingPath: playing,
          onProgress: (done, total, name) {
            if (!mounted) return;
            setState(() {
              _repairDone = done;
              _repairTotal = total;
              _repairName = name;
            });
          },
        );
        if (report.fixed > 0) await library.rescan();
      }
    } catch (e) {
      debugPrint('Fix YouTube downloads: $e');
    }
    if (mounted) {
      setState(() {
        _repairing = false;
        _repairReport = report;
      });
    }
  }

  // -- About & Support Section --

  Widget _buildAboutSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(Icons.info_outline, "About & Support"),
        _buildSectionCard([
          ListTile(
            title: const Text("About Hype Music"),
            subtitle: const Text("All you need to know about Hype Music"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showAboutAppDialog(context),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            title: const Text("Interactions Guide"),
            subtitle: const Text("Gestures, shortcuts & tips"),
            trailing: const Icon(Icons.touch_app_rounded),
            onTap: () => Routes.routeTo(const InteractionsGuide(), context),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            title: const Text("Reset Guides"),
            subtitle: const Text("Show onboarding & tips again"),
            trailing: const Icon(Icons.restart_alt_rounded),
            onTap: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('onboarding_complete');
              await prefs.remove('home_guide_shown');
              await prefs.remove('interactions_guide_shown');
              await CoachMarkController.resetAll();
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(
                    const SnackBar(
                      content: Text('Guides will show on next launch'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
              }
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            title: const Text("Report a bug"),
            trailing: const Icon(Icons.bug_report_rounded),
            onTap: () => Wiredash.of(context).show(inheritMaterialTheme: true),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ListTile(
            title: const Text("Exit"),
            trailing: const Icon(Icons.exit_to_app),
            onTap: () => _showExitConfirmationDialog(),
          ),
        ]),
      ],
    );
  }

  // -- Dialogs --

  void _showAboutAppDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("About Hype Music"),
          content: const Text(
            "Hype Music is your ultimate music app, bringing you the best tunes, personalized playlists, and immersive audio experiences. "
            "Discover new songs, follow your favorite artists, and enjoy seamless music streaming with high-quality sound and a user-friendly interface. "
            "Join the hype and elevate your music journey with Hype Music!",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Close"),
            ),
          ],
        );
      },
    );
  }

  void _showExitConfirmationDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Exit Hype Music"),
          content: const Text("Are you sure you want to exit?"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            TextButton(onPressed: () => exit(0), child: const Text("Exit")),
          ],
        );
      },
    );
  }
}

class _AppIconTile extends StatefulWidget {
  final String packageName;
  final String appName;

  const _AppIconTile({required this.packageName, required this.appName});

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
    if (mounted)
      setState(() {
        _iconBytes = bytes;
        _loaded = true;
      });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: _loaded
                ? (_iconBytes != null
                      ? Image.memory(_iconBytes!, fit: BoxFit.contain)
                      : Icon(
                          Icons.music_note,
                          size: 24,
                          color: Theme.of(context).colorScheme.primary,
                        ))
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
                Text(
                  widget.appName,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                Text(
                  widget.packageName,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
