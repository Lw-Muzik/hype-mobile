# DVC settings, Advanced Tweaks and Per-output Implementation Plan (plan 5 of 6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Spec §6 (the remaining Direct Volume Control settings), §7 Advanced Tweaks and §9 Per output, on Android and iOS, plus the items earlier plans parked for plan 5.

**Architecture:** Three independent lanes, each with its own pure-Dart settings model and decision functions (unit-tested), thin native glue, and its own settings section widget. The controller mounts the sections into Settings.dart at the end (plan 6 later moves them under an Audio category).

**Spec:** `docs/superpowers/specs/2026-11-05-audio-settings-design.md` §6, §7, §9 (authority; follow each row's Platform column exactly).

## Global Constraints

- No app builds. Verify with `flutter analyze` (no new issues vs 135), `flutter test` (only `test/widget_test.dart` and `test/widgets/intro_splash_test.dart` may fail), `native_tests/*/run.sh` if native engine code changes, `javac` standalone Java against `/opt/homebrew/share/android-commandlinetools/platforms/android-37.0/android.jar` where possible, `swiftc -parse`, `plutil -lint` (new ios/Runner Swift files must be registered in the Runner target).
- Never name the reference app anywhere in the repo.
- Android + iOS; iOS behaviour exactly as the spec's Platform column.
- Existing users keep their behaviour where Hype had an equivalent setting; new settings start at spec defaults. "Fine volume steps": fine (1 %) → 100 levels, coarse (5 %) → 30.
- Any gain change in the engine is click-free (ramps/two-chain, as in plans 1–3); never take a lock on the iOS render thread.
- Package `eq_app`; repo casing `lib/Helpers/`, `lib/Global/` (imports must match neighbours).
- No commits until the owner confirms. Each lane touches only its own files; shared files (`lib/controllers/app_controller.dart`, `android/.../MainActivity.java`, `lib/Helpers/Channel.dart`, `ios/Runner/AppDelegate.swift`) — re-read immediately before each edit, keep edits to the lane's paths. Do NOT edit `lib/pages/Settings.dart` (the controller mounts sections).

## Review Focus

1. DVC never ends up forcing the system volume to max on a Bluetooth route with absolute volume (or unknown): switching speaker → Bluetooth while DVC is on releases DVC in the safe order (system volume restored first) and back again (Task 1).
2. Pause/resume on volume never resumes music the listener did not start, and never acts while Hype's UI and notification are both hidden (Task 2).
3. A per-output EQ preset applies once per route change, never fights the listener's edit on the same output, and never writes into another output's preset (Task 3).
4. Per-output No Duck / Ignore audio focus / No DVC / No headroom reduction take effect on the route change itself, click-free, and revert when the route changes back (Task 3).
5. Existing users: DVC value, DVC volume, fine/coarse volume steps, link-devices device presets and AutoEq dismissals all carry over (Tasks 1–3).

---

### Task 1: Direct Volume Control settings (Android; headroom Both) + parked DVC fix

**Files:** Create `lib/audio/dvc/dvc_settings.dart`, `lib/pages/dvc_settings_section.dart`, tests `test/audio/dvc_settings_test.dart`, `test/pages/dvc_settings_section_test.dart`. Modify `lib/controllers/app_controller.dart` (DVC paths only), `android/app/src/main/kotlin/x/a/zix/DvcController.java`, `AudioOutputDetector.java`, `MainActivity.java` (channel case), `lib/Helpers/Channel.dart`.

- `DvcSettings { bool noDvcForBluetoothAbsoluteVolume (default true); }` load/save/copyWith/== (pref `dvcNoBtAbsolute`). The existing `dvcEnabled`, DVC volume and "No DVC – preamp reduction" (plan 1 headroom) stay where they are stored today; the section shows all four spec rows.
- Pure `bool dvcAllowedOnRoute({required bool isAndroid, required bool dvcEnabled, required bool onBluetooth, required bool? btAbsoluteVolumeOff, required bool noDvcForBtAbsolute, required bool systemWide})` — on Bluetooth with the setting on, DVC is allowed only when absolute volume is known to be OFF (`btAbsoluteVolumeOff == true`); unknown (null) or on → not allowed. Feed it into the existing `dvcInEffect`/`dvcRunning` path so a route change runs the existing safe `dvcToggleSteps` (disable: restore system volume first) without changing the stored `dvcEnabled`.
- Android: `AudioOutputDetector`/`DvcController` report `btAbsoluteVolumeOff` = `Settings.Global "bluetooth_disable_absolute_volume" == 1` (else false/unknown → null when unreadable); route changes already reach Dart via the existing device/route events — re-evaluate on each.
- Parked fix (plan 3/4 ledgers): after a headless start (Hype Connect after reboot) DVC never comes up natively once the activity attaches — on the first activity attach / lifecycle resumed, re-run the DVC startup path if `dvcRunning` should be true.
- Section `DvcSettingsSection` (Android shows 4 rows; iOS shows only "No DVC – preamp reduction"): Enable direct volume control, No DVC for Bluetooth absolute volume, No DVC – preamp reduction (−10.0…0, 0.5 dB, `%.1f dB`, reuse the reviewed commit-on-release/keyboard slider pattern), Volume (the DVC level). `static const labels`, `androidOnlyLabels`.
- [ ] Tests first: `dvcAllowedOnRoute` table (speaker allowed; BT + setting on + abs unknown → false; BT + abs off → true; BT + setting off → true; system-wide → false); settings round-trip + defaults; section labels/iOS rows/slider commit. Then implement; analyze + full test.

### Task 2: Advanced Tweaks

**Files:** Create `lib/audio/advanced/advanced_settings.dart`, `lib/services/volume_feed.dart`, `lib/widgets/volume_panel_overlay.dart`, `lib/pages/advanced_settings_section.dart`, tests under `test/audio/` and `test/pages/`. Modify `lib/controllers/app_controller.dart` (advanced paths only), `android/.../SystemVolumeObserver.java` (add a Dart event feed), `MainActivity.java` (MusicFX + volume levels cases), `ios/Runner/SystemVolume.swift` / `DSPManager.swift` / `AppDelegate.swift` (Dart volume feed), `lib/Helpers/Channel.dart`, the reverb presets code (find Hype's room/reverb presets).

- `AdvancedSettings { VolumeLevels volumeLevels (systemDefault|l30|l50|l75|l100, default systemDefault; legacy "Fine volume steps" fine → l100, coarse → l30 — find its pref key in Settings.dart ~808 / app_controller); bool volumePanel=false; bool pauseResumeOnVolume=false; bool musicFx=false; bool forceAudioOnFocusChange=false; }` load/save/migration.
- Volume levels (Android): Hype's volume keys / DVC steps use the chosen number of levels (map to the existing DVC step / fine-step code paths).
- Volume panel (Android): Hype's own overlay shown when the volume is changed in the app (volume keys while Hype is foreground); auto-hides after 1.5 s.
- Pause/resume on volume (Both): a Dart-facing volume feed (`VolumeFeed` stream of 0…1 from Android SystemVolumeObserver and iOS outputVolume KVO — the observers today push only to native engines). Pure `VolumeAction? volumeAction({required double previous, required double now, required bool playing, required bool pausedByVolume, required bool uiOrNotificationVisible})`: playing and now == 0 → pause (mark pausedByVolume); paused-by-volume and now > 0 and visible → resume; nothing else. A listener pause/play clears the mark.
- MusicFX (Android): when on, show a button (in the EQ page header and the section) that opens `AudioEffect.ACTION_DISPLAY_AUDIO_EFFECT_CONTROL_PANEL` with Hype's session id; hidden when no handler resolves.
- Force audio on audio focus change (Android): after a transient focus loss + gain, if Hype is meant to be playing but the position hasn't advanced for 1.5 s, re-request focus and restart output (seek in place + play); one retry. Pure decision + thin wiring in the AudioFocusService path (re-read lib/services/audio_focus_service.dart first).
- Restore equalizer presets (exists: `AppController.restoreEqPresets()`) and Restore reverb presets (new: restore Hype's built-in room/reverb presets, keep user ones) as actions with confirmation.
- Section `AdvancedSettingsSection` with all 7 rows (Android-only rows hidden on iOS: Volume levels, Volume panel, MusicFX, Force audio).
- [ ] Tests first for the model/migration, `volumeAction` table, force-audio decision, section rows; then implement; analyze + full test.

### Task 3: Per output

**Files:** Create `lib/audio/output/output_profiles.dart`, `lib/services/output_profile_service.dart`, `lib/pages/output_profiles_page.dart`, tests. Modify `lib/controllers/app_controller.dart` (output-profile paths only), `lib/audio/headset/output_kind.dart` (fold AutoEq's `OutputKind` into `AudioOutputKind`; update lib/audio/eq/autoeq_suggest.dart + lib/services/autoeq_suggestions.dart to use it), `lib/audio/eq/eq_presets.dart` only if the device-preset migration needs it.

- `OutputProfile { String? eqPreset; bool noEqTone; bool noDuck; bool ignoreFocus; bool noDvc /*Android*/; bool noHeadroomReduction; }` keyed by output kind (speaker, wired, bluetooth, usb, other) and optionally by a named Bluetooth/USB device (normalised name, as AutoEq does). `OutputProfiles` load/save (pref `outputProfilesV1` JSON); migration: the legacy link-devices `_device_<type>` hidden EQ presets / `detectAndApplyDevicePreset` become the matching kind's `eqPreset`; AutoEq applied profiles bind to the named device.
- Pure `OutputProfile resolveProfile(OutputProfiles p, {required AudioOutputKind kind, String? deviceName})` (named device beats kind beats default).
- `OutputProfileService`: on every active-route change (reuse HeadsetService's device events / AudioOutputDetector on Android, route change on iOS), resolve the profile and apply: EQ preset (once per route change, via `applyEqPreset`; skipped if the listener edited the curve on this route since it was applied), noEqTone (EQ + tone bypass through the existing faded enable paths), noDuck (AudioFocusService pauses instead of ducking), ignoreFocus (AudioFocusService ignores losses), noDvc (feeds Task 1's `dvcAllowedOnRoute`-style gate — coordinate via a simple `bool perOutputNoDvc` input on AppController), noHeadroomReduction (headroom 0 on this output, click-free via the existing headroom setter).
- `OutputProfilesPage` ("Outputs"): list of kinds + known named devices, each editable; the active output highlighted.
- [ ] Tests first: resolveProfile precedence, migration of legacy device presets, apply-once-per-route + listener-edit guard, revert on route back; page rows; then implement; analyze + full test.

### Task 4 (controller): mount sections

Mount `DvcSettingsSection` and `AdvancedSettingsSection` and an "Outputs" entry in Settings.dart (sound group), `SettingsEntry` rows for every label (Android-only flags), search hides Android-only rows on iOS; cross-index test.
