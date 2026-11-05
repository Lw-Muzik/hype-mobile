import 'package:shared_preferences/shared_preferences.dart';

import '../../models/room_preset.dart';

/// How many steps Hype's volume keys (and direct volume control) have. The
/// gain range is 30 dB, so [levels] steps are `30 / levels` dB each.
enum VolumeLevels {
  systemDefault('System default', null),
  l30('30 steps', 30),
  l50('50 steps', 50),
  l75('75 steps', 75),
  l100('100 steps', 100);

  const VolumeLevels(this.label, this.levels);
  final String label;
  final int? levels;

  /// The direct volume control step in dB; System default keeps the 5 % step.
  double get dvcStepDb => levels == null ? 1.5 : 30.0 / levels!;
}

/// The Advanced Tweaks settings, saved in the preferences.
class AdvancedSettings {
  const AdvancedSettings({
    this.volumeLevels = VolumeLevels.systemDefault,
    this.volumePanel = false,
    this.pauseResumeOnVolume = false,
    this.musicFx = false,
    this.forceAudioOnFocusChange = false,
  });

  final VolumeLevels volumeLevels;
  final bool volumePanel;
  final bool pauseResumeOnVolume;
  final bool musicFx;
  final bool forceAudioOnFocusChange;

  static const _kLevels = 'advVolumeLevels';
  static const _kPanel = 'advVolumePanel';
  static const _kPauseResume = 'advPauseResumeOnVolume';
  static const _kMusicFx = 'advMusicFx';
  static const _kForceAudio = 'advForceAudioOnFocusChange';

  /// The legacy "Fine volume steps" switch (read once by the 100/30 migration; the row is gone).
  static const _kLegacyFineSteps = 'dvcFineSteps';

  AdvancedSettings copyWith({
    VolumeLevels? volumeLevels,
    bool? volumePanel,
    bool? pauseResumeOnVolume,
    bool? musicFx,
    bool? forceAudioOnFocusChange,
  }) => AdvancedSettings(
    volumeLevels: volumeLevels ?? this.volumeLevels,
    volumePanel: volumePanel ?? this.volumePanel,
    pauseResumeOnVolume: pauseResumeOnVolume ?? this.pauseResumeOnVolume,
    musicFx: musicFx ?? this.musicFx,
    forceAudioOnFocusChange:
        forceAudioOnFocusChange ?? this.forceAudioOnFocusChange,
  );

  static VolumeLevels _levelsFrom(SharedPreferences prefs) {
    final name = prefs.getString(_kLevels);
    if (name != null) {
      for (final v in VolumeLevels.values) {
        if (v.name == name) return v;
      }
      return VolumeLevels.systemDefault;
    }
    // Migration: fine (1 %) -> 100 levels, coarse (5 %) -> 30.
    final fine = prefs.getBool(_kLegacyFineSteps);
    if (fine == null) return VolumeLevels.systemDefault;
    return fine ? VolumeLevels.l100 : VolumeLevels.l30;
  }

  static AdvancedSettings load(SharedPreferences prefs) {
    const d = AdvancedSettings();
    return AdvancedSettings(
      volumeLevels: _levelsFrom(prefs),
      volumePanel: prefs.getBool(_kPanel) ?? d.volumePanel,
      pauseResumeOnVolume:
          prefs.getBool(_kPauseResume) ?? d.pauseResumeOnVolume,
      musicFx: prefs.getBool(_kMusicFx) ?? d.musicFx,
      forceAudioOnFocusChange:
          prefs.getBool(_kForceAudio) ?? d.forceAudioOnFocusChange,
    );
  }

  Future<void> save(SharedPreferences prefs) async {
    await prefs.setString(_kLevels, volumeLevels.name);
    await prefs.setBool(_kPanel, volumePanel);
    await prefs.setBool(_kPauseResume, pauseResumeOnVolume);
    await prefs.setBool(_kMusicFx, musicFx);
    await prefs.setBool(_kForceAudio, forceAudioOnFocusChange);
  }

  @override
  bool operator ==(Object other) =>
      other is AdvancedSettings &&
      other.volumeLevels == volumeLevels &&
      other.volumePanel == volumePanel &&
      other.pauseResumeOnVolume == pauseResumeOnVolume &&
      other.musicFx == musicFx &&
      other.forceAudioOnFocusChange == forceAudioOnFocusChange;

  @override
  int get hashCode => Object.hash(
    volumeLevels,
    volumePanel,
    pauseResumeOnVolume,
    musicFx,
    forceAudioOnFocusChange,
  );
}

/// What a change of the system volume asks Hype to do.
enum VolumeAction { pause, resume }

/// Pause at volume 0, resume when the volume is raised from 0 — but only music
/// that this very rule paused ([pausedByVolume]), and only while Hype's UI or
/// notification is visible. Everything else is left alone.
VolumeAction? volumeAction({
  required double previous,
  required double now,
  required bool playing,
  required bool pausedByVolume,
  required bool uiOrNotificationVisible,
}) {
  if (playing && now <= 0 && previous > 0) return VolumeAction.pause;
  if (!playing &&
      pausedByVolume &&
      previous <= 0 &&
      now > 0 &&
      uiOrNotificationVisible) {
    return VolumeAction.resume;
  }
  return null;
}

/// What to do 1.5 s after the audio focus came back.
enum ForceAudioStep { none, restart }

/// The playback position must move by at least this much in the wait for the
/// output to count as alive.
const kForceAudioMinAdvance = Duration(milliseconds: 200);

/// Restart the output once if Hype is meant to be playing but the position
/// has not advanced since the focus came back.
ForceAudioStep forceAudioDecision({
  required bool enabled,
  required bool meantToPlay,
  required Duration positionAtGain,
  required Duration positionNow,
  required int attempts,
}) {
  if (!enabled || !meantToPlay || attempts >= 1) return ForceAudioStep.none;
  final advanced = positionNow - positionAtGain >= kForceAudioMinAdvance;
  return advanced ? ForceAudioStep.none : ForceAudioStep.restart;
}

/// The factory default room preset ("Off"): what Restore reverb presets
/// returns the room settings to. Editing a preset renames the active one to
/// "Custom", so restoring "the active preset" would never bring anything back.
RoomPreset factoryRoomPreset() => RoomPreset.builtIn.first;
