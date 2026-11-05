# Audio Focus + Headset & Bluetooth Implementation Plan (plan 4 of 6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Audio Focus (§4) and Headset & Bluetooth (§8) as the spec describes them, on Android and iOS. One Dart policy decides what happens on interruptions, calls, ducking, becoming-noisy, device connects, app start and reopen, remote commands and headset buttons. iOS shows only the rows its column keeps.

**Architecture:**
- just_audio's own interruption handling and session activation are switched off on both players. Hype asks for focus itself, from its handler's play paths.
  - On Android it asks with *will pause when ducked*. Android then reports a duckable loss to Hype instead of ducking Hype itself, and Hype ducks to 25 % on the player volume.
  - audio_session's interruption, becoming-noisy and device-change streams feed pure policies.
- Remote commands (lock screen, notification, Bluetooth/AVRCP transport, CarPlay/Auto, iOS remote command center) reach a `CompositeAudioHandler` gate. The gate is registered with audio_service in front of `HypeAudioHandler`. Strict mode, the Bluetooth grace window and the repeat/shuffle filter therefore apply to everything that comes from outside, and never to Hype's own UI.
- On Android, audio_service is vendored into `packages/audio_service` with a ~20-line hook, as just_audio already is. The hook passes raw key events to Dart: code, down/up and device. A pure recogniser turns them into single, double, triple and long presses.
- Java stays thin. It forwards events, plays beeps and vibration, and enables a voice-search proxy activity for long presses.
- Every decision is a pure function or a small state machine with an explicit clock. The services that wire them take injected streams and are tested under `fake_async`.
- iOS needs no native change.

**Tech Stack:** Dart/Flutter; `audio_session` 0.2.4 (a direct dependency since plan 3 Task 9); `audio_service` 0.18.19 (vendored); Java (Android). No C++, no Swift.

**Spec:** `docs/superpowers/specs/2026-11-05-audio-settings-design.md`. This plan covers §4 Audio Focus, §8 Headset & Bluetooth, the Platform key, the anti-goals and "Equalizer-only app mode". §1, §6, §7 and §9 belong to plans 5–6. "Pause/resume on volume" is §7, so plan 3's `SystemVolumeObserver` and `outputVolume` KVO are **not** used here (see "For plans 5 and 6").

**This plan starts only after plans 2 and 3 have landed.**
- Files plans 2–3 also edit that this plan touches: `lib/controllers/app_controller.dart`, `lib/pages/Settings.dart`, `lib/Helpers/Channel.dart` and `android/app/src/main/kotlin/x/a/zix/MainActivity.java`. It also touches `lib/Helpers/audio_handler.dart` (plan 2) and `pubspec.yaml` (plan 3).
- Other files it touches: `lib/main.dart`, `lib/player/output_gain.dart` and `android/app/src/main/AndroidManifest.xml`.
- It does **not** touch `ios/Runner/AppDelegate.swift`, `ios/Runner/DSPManager.swift` or any other iOS native file.

## Current state (what exists vs. what the spec adds)

| Area | Android today | iOS today | Spec adds |
|---|---|---|---|
| Interruptions | just_audio's built-in handler on each player pauses on transient and permanent focus loss and resumes after a transient one. A duckable loss is ducked by Android itself, because the focus request has no will-pause-when-ducked. | Same handler: pause on interruption began, resume when it ends with should-resume. | Resume after call, Short / Pause in call / Resume on focus gain / Duck / Permanent switches (iOS: Resume after call only) |
| Focus request | just_audio calls `AudioSession.setActive(true)` (fallback `music()` config) on every `play()` | Same; `AppDelegate` also activates `.playback` at launch | Hype requests it itself |
| Calls | No detection beyond the focus loss | — | Call detection, Pause in call |
| Start/reopen | `_restoreSession` restores a paused queue; the first play loads it (`onBeforePlay`) | Same | Resume on start, Resume on reopen |
| Plug/connect | Nothing. `MainActivity.HeadphoneService` is never registered (dead). The activity's Bluetooth ACL intent-filter is dead, since broadcasts never reach activities. `BluetoothManager.java` is unused. | Nothing | Resume on wired, Resume on Bluetooth, Pause on USB DAC (Android) |
| Unplug | just_audio pauses on becoming-noisy | Same; audio_session maps any old-device-unavailable to becoming-noisy | Pause on headset disconnect switch |
| Buttons | audio_service maps every PLAY/PAUSE/PLAY_PAUSE/HEADSETHOOK key-down to `click(media)`, a **toggle**, so a Bluetooth "play" while playing pauses. NEXT/PREV skip. No multi or long press, no feedback. | MPRemoteCommandCenter: play / pause / toggle / next / previous | Respond to buttons, per-source press modes, Strict, Beep/Beep more/Vibrate, Disable default long press (Android); Strict (iOS) |
| Repeat/shuffle | Not advertised, so `BaseAudioHandler` no-ops | Same | Honoured unless Ignore repeat/shuffle |
| After connect | — | — | Ignore Bluetooth commands 0–20 s |

## Global Constraints

- No app builds (`flutter build`, Gradle, Xcode). Verify with:
  - `flutter analyze`: no new issues against the count recorded in Task 0.
  - `flutter test`: only `widget_test.dart` and `intro_splash_test.dart` may fail.
  - Java: type-check every new Hype Java file that imports only `android.*` and `java.*`. Write output to a scratch directory:
    `javac --release 11 -proc:none -cp /opt/homebrew/share/android-commandlinetools/platforms/android-36/android.jar -d "$SCRATCH/javac" <files>`
    Expect no errors. The vendored `AudioService.java`, `MainActivity.java` and the manifest are checked by inspection; they need androidx and Flutter jars.
- This plan touches no C++ and no Swift, so `native_tests`, `clang++ -fsyntax-only` and `swiftc -parse` do not apply. If a step ends up touching either, run plan 3's commands.
- No new `ios/Runner` files are planned. If one becomes necessary, register it in the Runner target and run `plutil -lint ios/Runner.xcodeproj/project.pbxproj`.
- Do not name the reference app anywhere in the repo: code, comments, tests, docs, commit messages.
- Both platforms unless a step says Android or iOS. Rows the spec marks "hidden" on iOS are not rendered on iOS and are left out of iOS settings search.
- Existing users: Hype had no equivalent settings, so every control starts at the spec default. The audible differences are listed in Decision 19.
- No commits until the owner confirms; leave all changes in the working tree.
- Java has no host test harness. Java only forwards key events, plays feedback and toggles a component; every decision is pure Dart.
- **Path casing (load-bearing).**
  - On disk the directories are `lib/helpers/` and `lib/global/`; the git index has `lib/Helpers/` and `lib/Global/`. Paths in this plan use the git casing.
  - Dart treats differently-cased URIs as different libraries, which gives two `HypeAudioHandler` types.
  - Import `audio_handler.dart` as `…/helpers/audio_handler.dart` (lower case), as `main.dart`, `app_controller.dart` and `global/index.dart` already do. In tests use `package:eq_app/helpers/audio_handler.dart`.
  - Import `Channel.dart` as `…/Helpers/Channel.dart`, as `app_controller.dart` and `audio_handler.dart` do.
  - New directories are lower case.

## Review Focus

1. **Hype never starts music the listener did not ask for.**
   - It does not resume:
     - after an interruption the listener had already paused before;
     - after the listener acted during the interruption;
     - on a plug, connect or reopen while Hype is waiting for focus (a call).
   - Devices present at launch are not connections.
   - Resume on start never fires headless (Hype Connect after reboot), in equalizer-only mode or without a queue.
   - Tests: Task 2 `paused_before_loss_never_resumes`, `listener_play_cancels_resume`; Task 3 `no_connect_resume_while_waiting_for_focus`; Task 6 `initial_devices_are_not_connections`, `start_waits_for_restore`, `no_lifecycle_no_resume`.
2. **The duck always comes back, without a jump.**
   - It goes to 25 % and back to full when the other sound ends.
   - It survives crossfade steps and listener-volume changes.
   - A duck interrupted by a pause leaves the resumed track at full level.
   - Tests: Task 5 `OutputGain` duck tests; Task 2 `ducked_then_transient_pauses_then_unducks`; Task 6 `unduck_waits_for_the_pause`.
3. **Calls.**
   - With Short on, a call pauses and *Resume after call*, not *Resume on focus gain*, decides the resume.
   - With Short off, *Pause in call* pauses for a call detected up to 1.5 s after the loss, and every other transient loss is ignored.
   - Tests: Task 2 call cases; Task 6 `late_call_detection_upgrades_the_hold`.
4. **Each button or remote command does exactly one thing.**
   - A Bluetooth "play" while playing is ignored (strict) or toggles (strict off).
   - Double press = next and triple = previous, with a 400 ms window.
   - Long press = next, only while playing.
   - Next/previous are never delayed.
   - Commands in the Bluetooth grace window are dropped; wired keys are not.
   - Notification buttons are never treated as headset presses.
   - Tests: Task 3 strict table and grace; Task 4 recogniser; Task 5 gate tests; Task 7 service tests.
5. **No blast in the ears from feedback.**
   - A beep sits 20 dB under the music, including when DVC holds the system volume at maximum.
   - Ignored commands give no feedback.
   - Tests: Task 4 `beepToneVolume`, `feedbackFor`; Task 7 `ignored_command_gives_no_feedback`.

## Decisions taken where the spec is open (owner may overrule)

1. **Android ducking is Hype's own.**
   - Hype asks for focus with will-pause-when-ducked, so Android reports a duckable loss instead of ducking Hype itself.
   - Hype's duck is a factor on the player volume: 0.25, gliding down over 100 ms and up over 500 ms.
   - Without this the system's ~20 % duck would stack under Hype's 25 %, and Duck volume off could never pause.
   - This is done with `setActive(true, androidWillPauseWhenDucked: true)` on a session configured with `music()` (will-pause unset). The request then carries the flag while audio_session still reports `duck`, not `pause`.
2. **Focus is requested by Hype's handler, not just_audio.** Both players get `handleInterruptions: false, handleAudioSessionActivation: false`. The handler calls `onActivateSession` at the start of `play()` and before the player starts in `startPlayback()`, the two paths every play goes through. If activation fails, nothing plays, as just_audio behaved before. Crossfades and gapless advances run while focus is already held, so they do not ask.
3. **Call detection on Android uses the audio mode.**
   - Ringtone, in call and in communication count as a call.
   - The mode is polled at 0, 500 and 1500 ms after a transient loss. Telecom requests focus before it sets the mode.
   - No phone-state permission is needed.
   - A loss that turns out to be a call is treated as a call when deciding whether to resume.
4. **Short audio focus change off:**
   - Transient and duckable losses are ignored entirely; Hype keeps playing at full level.
   - Pause in call still pauses a detected call.
   - While Short is on, Pause in call shows on and disabled; its stored value is kept for when Short goes off.
5. **Permanent audio focus change off:** Hype does not pause.
   - On Android ≤ 11 it keeps playing without focus.
   - Android 12+ fades out and mutes an app that keeps playing after losing focus to another media player. Hype therefore asks for focus back once, at once.
   - If it loses focus permanently again before its next pause, it keeps playing without asking again, so there is no focus tug-of-war.
   - Limitation: while Hype plays without focus, audio_session does not report becoming-noisy on Android, because its receiver exists only while focus is held.
6. **Resumes only undo Hype's own pauses.**
   - A pause the listener made before the interruption is never undone.
   - A play or pause by the listener during the interruption cancels the pending resume.
   - Resume on wired/Bluetooth and Resume on reopen never fire while Hype waits for focus to return.
7. **Fades on focus pauses.** iOS interruption pauses are immediate (no fade), because iOS has already silenced the audio. Android focus pauses use the normal pause fade.
8. **iOS, Pause on headset disconnect off.** AVPlayer stops itself when the old route goes away, so Hype restarts playback: pause without fade, then play, which fades in on the new route.
9. **"Start" and "reopen".**
   - Start is the first time Hype's UI is in the foreground in this process, once the saved session has been read.
   - Reopen is any later return to the foreground (`resumed` after `paused`/`hidden`), on both platforms. Android does not reliably say whether the launcher or Recents brought the app back.
   - A headless start (Hype Connect after reboot) is not a start.
10. **Resume on wired/Bluetooth.**
    - Fires when Hype is paused with a queue, not only when the unplug paused it, 500 ms after the device appears so the route has switched.
    - Devices connected when Hype starts are not connections.
    - Bluetooth means A2DP on Android (audio_session 0.2.4 reports LE Audio devices as `unknown`), and A2DP or LE on iOS. Wired means wired headset, wired headphones or analog line.
    - A USB DAC is any USB audio output; plugging one never triggers a resume.
    - Works while Hype runs. Android keeps the service alive while paused; on iOS, a long pause in the background suspends the app.
11. **Media keys on Android need the raw event.**
    - audio_service is vendored. Its notification buttons get the scan code `0x4859` so the hook passes them straight through.
    - A key from a real input device is wired. A virtual one (AVRCP, deviceId −1) is Bluetooth when a Bluetooth output is active, otherwise wired. A device name containing "avrcp" or "bluetooth" is Bluetooth.
    - Respond to buttons off swallows headset keys; notification and lock-screen controls keep working.
12. **Press timing.**
    - Multi-press window: 400 ms after each release. 2 presses = next, 3 or more = previous.
    - Long press: held ≥ 600 ms.
    - Next/previous/stop keys act at once on key-down in every mode.
    - In Long press mode a long press while not playing acts as a short press.
    - A press is timed by its arrival in Dart (package `clock`), not by Java timestamps; AVRCP events carry none.
13. **Long press of play/pause and headset-hook never reaches an app on Android.** The system starts voice search instead.
    - Hype therefore offers a disabled-by-default activity for `android.speech.action.VOICE_SEARCH_HANDS_FREE` and `android.speech.action.WEB_SEARCH`. It is enabled while Respond to buttons is on and either Disable default long press is on or a Long press mode is chosen.
    - A request from the system (referrer `android`, no `QUERY` extra) while Hype plays is taken as the long press: next in Long press mode, nothing otherwise.
    - Any other request is passed to the other voice-search app.
    - Android asks once which app to use; the row's subtitle says to pick Hype.
14. **Strict.** A redundant command is one that asks for the state Hype is already in: play while playing, pause or stop while paused or stopped.
    - Strict on: redundant commands are ignored.
    - Strict off: redundant commands toggle.
    - Commands that are not redundant do what they say; toggle always toggles.
    - Applies to Android keys and to remote/transport commands on both platforms.
15. **Ignore Bluetooth commands.**
    - Covers every remote/transport command, plus media keys classified as Bluetooth, within N s after a Bluetooth output appears.
    - Wired keys are never dropped. 0 = never.
    - Notification taps inside that window are also dropped: audio_service gives no way to tell them from other transport commands.
16. **Ignore repeat/shuffle off means remote repeat/shuffle now work.** Hype advertises `setRepeatMode`/`setShuffleMode` and publishes its modes. Remote group/all both map to repeat-all and shuffle-on. With it on, the controls stay visible but the commands are dropped.
17. **Feedback.**
    - Beep: next 2 beeps, previous 3, long press 1. Beep more adds 1 beep for single-press commands.
    - Vibrate: one 40 ms pulse per command. Ignored commands get none.
    - ToneGenerator volume: 60 (−20 dB re the stream) with DVC off; `60 + 2·dvcGainDb` with DVC in effect (plan 3's `dvcInEffect`), clamped 0…100.
18. **Settings placement until plan 6.** The Audio Focus section sits on the Playback page. Headset & Bluetooth gets its own category now, its final place. Android-only rows are hidden on iOS, including from search (`SettingsEntry.android`).
19. **Behaviour changes for existing users** (no prior setting existed, so the spec defaults apply):
    - A single headset press now waits 400 ms (double/triple is the default).
    - A Bluetooth "play" while playing no longer pauses (Strict).
    - Next and previous from buttons beep.
    - The duck is 25 %, Hype's own, instead of the system's ~20 %.
    - Remote repeat/shuffle now act.
20. **Dead code removed.** `MainActivity.HeadphoneService` is never registered and only shows a toast, so it is removed with its `new HeadphoneService()`.

---

### Task 0: Baseline

**Files:** none, unless the check in Step 2 fails.

- [ ] **Step 1:** Record the `flutter analyze` issue count as this plan's baseline (after plans 2 and 3), and confirm `flutter test` fails only `widget_test.dart` and `intro_splash_test.dart`.
- [ ] **Step 2:** Confirm `pubspec.yaml` lists `audio_session: ^0.2.4` (plan 3 Task 9). If it does not, add it and run `flutter pub get`.
- [ ] **Step 3:** Record `grep -n "AudioPlayer(" lib/Helpers/audio_handler.dart`. There should be two players, neither passing `handleInterruptions`.

---

### Task 1: Settings models (pure Dart)

**Files:**
- Create `lib/audio/focus/audio_focus_settings.dart` and `lib/audio/headset/headset_settings.dart`.
- Test: `test/audio/audio_focus_settings_test.dart`, `test/audio/headset_settings_test.dart`.

**Interfaces — produces:**
- `class AudioFocusSettings`: immutable, with a `const` constructor and every default below, plus `copyWith`, `==`, `hashCode`, `static AudioFocusSettings load(SharedPreferences)` and `Future<void> save(SharedPreferences)`.
  - `bool get effectivePauseInCall => shortFocusChange || pauseInCall`.

| Field | Default | Pref key |
|---|---|---|
| `resumeAfterCall` | true | `afResumeAfterCall` |
| `resumeOnStart` | false | `afResumeOnStart` |
| `resumeOnReopen` | false | `afResumeOnReopen` |
| `shortFocusChange` | true | `afShortFocusChange` |
| `pauseInCall` | true | `afPauseInCall` |
| `resumeOnFocusGain` | true | `afResumeOnFocusGain` |
| `duckVolume` | true | `afDuckVolume` |
| `permanentFocusChange` | true | `afPermanentFocusChange` |

- `enum ButtonMode { singlePress('Single press'), multiPress('Double/triple press for next/prev'), longPressNext('Long press for next (when playing)') }` with `final String label`.
- `const kIgnoreBluetoothCommandsMaxS = 20;`
- `class HeadsetSettings`: same shape as `AudioFocusSettings`.
  - `copyWith` and `load` normalise `ignoreBluetoothCommandsS`: round to whole seconds, clamp 0…20.
  - Enums are stored by name; an unknown name gives the default.

| Field | Default | Pref key |
|---|---|---|
| `resumeOnWired` | false | `hsResumeOnWired` |
| `resumeOnBluetooth` | false | `hsResumeOnBluetooth` |
| `pauseOnDisconnect` | true | `hsPauseOnDisconnect` |
| `pauseOnUsbDac` | true | `hsPauseOnUsbDac` |
| `respondToButtons` | true | `hsRespondToButtons` |
| `wiredButtons` | `multiPress` | `hsWiredButtons` |
| `bluetoothButtons` | `multiPress` | `hsBluetoothButtons` |
| `strictCommands` | true | `hsStrictCommands` |
| `ignoreBluetoothCommandsS` | 1 | `hsIgnoreBtCommandsS` |
| `ignoreRepeatShuffle` | false | `hsIgnoreRepeatShuffle` |
| `beep` | true | `hsBeep` |
| `beepMore` | false | `hsBeepMore` |
| `vibrate` | false | `hsVibrate` |
| `disableDefaultLongPress` | false | `hsDisableLongPress` |

- [ ] **Step 1: Failing tests.**
  - Empty prefs give every default in both tables.
  - `save` → `load` round-trips with every field flipped from its default.
  - `effectivePauseInCall`:
    - (short on, pause-in-call off) → true.
    - (off, off) → false.
    - (off, on) → true.
    - With short on and pause-in-call off, `load(save())` keeps `pauseInCall` false.
  - `ignoreBluetoothCommandsS`: −3 → 0, 25 → 20, 7 → 7, both through `copyWith` and through a stored value.
  - `hsWiredButtons: 'bogus'` → `multiPress`.
  - The three `ButtonMode.label`s equal the strings above exactly.
- [ ] **Step 2:** Run both tests — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run — PASS; `flutter analyze` shows no new issues.

---

### Task 2: Audio focus policy (pure Dart)

**Files:**
- Create `lib/audio/focus/focus_policy.dart`.
- Test: `test/audio/focus_policy_test.dart`.

**Interfaces — consumes:** `AudioFocusSettings` (Task 1); `AudioInterruptionEvent`, `AudioInterruptionType` and `AndroidAudioHardwareMode` from `audio_session`; `AppLifecycleState`.

**Interfaces — produces:**
- `const kDuckLevel = 0.25; const kDuckDownMs = 100; const kDuckUpMs = 500;`
- `enum FocusLossKind { transient, canDuck, permanent }`
- `sealed class FocusEvent` with these subclasses:
  - `FocusLost(FocusLossKind kind)`, `CallDetected()`, `FocusGained()`: Android.
  - `InterruptionBegan()`, `InterruptionEnded({required bool shouldResume})`: iOS.
  - `ListenerPlayed()`, `PlaybackPaused()`: both.
- `enum FocusHold { none, ducked, pausedByFocus, pausedByCall }`
- `enum FocusAction { pause, resume, duck, unduck, reacquireFocus }`
  - `unduck` means "back to full level": it glides while playing and is instant while paused.
- `class FocusState`, `const FocusState({hold = none, lossActive = false, reclaimed = false, givenUp = false})`, with:
  - `bool get waitingForFocus` (`pausedByFocus` or `pausedByCall`);
  - `bool get needsFocusRequest => !givenUp`;
  - `copyWith` and `==`.
- `class FocusStep { final FocusState state; final List<FocusAction> actions; }`
- `FocusStep focusStep(FocusState s, FocusEvent e, AudioFocusSettings settings, {required bool playing, bool systemMutesLosers = false, bool noDuck = false, bool ignoreFocus = false})`.
  - `noDuck` and `ignoreFocus` are plan 5's per-output flags; this plan always passes false.
  - `ignoreFocus` silences Android events only.
- `FocusEvent focusEventFromInterruption(AudioInterruptionEvent e, {required bool isIos})`.
- `bool isCallMode(AndroidAudioHardwareMode m)`.
- `enum LifecycleResume { start, reopen }`
- `class ForegroundTracker { LifecycleResume? onState(AppLifecycleState s); }`
- `bool shouldResumeOnLifecycle(LifecycleResume when, AudioFocusSettings s, {required bool playing, required bool hasSession, required bool waitingForFocus})`.

- [ ] **Step 1: Failing tests.** Defaults and `playing: true` unless stated; Android events unless marked iOS. Use `isA<…>().having(…)` for events.
  - `transient_pauses_gain_resumes`: `FocusLost(transient)` → `[pause]`, hold `pausedByFocus`, `lossActive` true. Then `FocusGained` → `[resume]`, hold `none`.
  - `call_uses_resume_after_call`:
    - Transient, then `CallDetected` → `[]`, hold `pausedByCall`.
    - `FocusGained` with `resumeAfterCall` false → `[]`; with it true → `[resume]`.
    - With `resumeOnFocusGain` false but the loss a call → `[resume]`.
  - `focus_gain_switch`: transient with `resumeOnFocusGain` false, then gain → `[]`.
  - `duck_and_unduck`: `FocusLost(canDuck)` → `[duck]`, hold `ducked`. Gain → `[unduck]`, hold `none`.
  - `duck_off_pauses`: `duckVolume` false → canDuck gives `[pause]`, then gain → `[resume]`. The same with `noDuck: true`.
  - `ducked_then_transient_pauses_then_unducks`: canDuck, then transient → `[pause, unduck]`, hold `pausedByFocus`.
  - `short_off`:
    - Transient → `[]` with `lossActive` true.
    - `CallDetected` → `[pause]`, hold `pausedByCall`. Gain → `[resume]`.
    - With `pauseInCall` false, `CallDetected` → `[]`.
    - canDuck → `[]`.
  - `permanent`:
    - → `[pause]`, hold `none`, `lossActive` false; a later gain → `[]`.
    - While ducked → `[pause, unduck]`.
    - Transient then permanent (not playing) → hold `none`, so a gain → `[]`.
  - `permanent_off`:
    - `permanentFocusChange` false, `systemMutesLosers` false → `[]`.
    - With `systemMutesLosers` true:
      - The first loss → `[reacquireFocus]`, `reclaimed` true.
      - A second loss → `[]` and `needsFocusRequest` false.
      - `PlaybackPaused` → `needsFocusRequest` true, `reclaimed` false.
    - While ducked (no muting) → `[unduck]`.
  - `paused_before_loss_never_resumes`: `playing: false`, transient → `[]`; gain → `[]`.
  - `listener_play_cancels_resume`: transient, then `ListenerPlayed` → hold `none`; gain → `[]`.
  - `stale_call_poll`: `CallDetected` with `lossActive` false → `[]`.
  - `ignore_focus`: `ignoreFocus: true` → every Android event gives `[]`.
  - iOS:
    - `InterruptionBegan` → `[pause]`, hold `pausedByCall`.
    - `InterruptionEnded(shouldResume: true)` → `[resume]`; `(false)` → `[]`.
    - With `resumeAfterCall` false, `(true)` → `[]`.
    - Began with `playing: false` → `[]`, then ended(true) → `[]`.
  - `waitingForFocus`: true for `pausedByFocus` and `pausedByCall`; false for `ducked` and `none`.
  - `focusEventFromInterruption`:
    - Android: (begin, pause) → `FocusLost(transient)`; (begin, duck) → `canDuck`; (begin, unknown) → `permanent`; (end, pause) and (end, duck) → `FocusGained`.
    - iOS: (begin, unknown) → `InterruptionBegan`; (end, pause) → `InterruptionEnded(true)`; (end, unknown) → `InterruptionEnded(false)`.
  - `isCallMode`: ringtone, inCall and inCommunication → true; normal, invalid and current → false.
  - `ForegroundTracker`:
    - `resumed` → `start`.
    - Then `inactive`, `resumed` → null, null.
    - `paused`, `resumed` → null, `reopen`.
    - `hidden`, `resumed` → null, `reopen`.
    - A fresh tracker given `inactive` → null, then `resumed` → `start`.
  - `shouldResumeOnLifecycle`:
    - start with `resumeOnStart` → true; start without it → false.
    - reopen with `resumeOnReopen` only → false; with both → true.
    - `playing`, `!hasSession` or `waitingForFocus` → false.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run — PASS; analyze clean.

---

### Task 3: Remote commands and device policy (pure Dart)

**Files:**
- Create `lib/player/remote_commands.dart`, `lib/audio/headset/output_kind.dart` and `lib/audio/headset/headset_policy.dart`.
- Test: `test/player/remote_commands_test.dart`, `test/audio/headset_policy_test.dart`.

**Interfaces — consumes:** `HeadsetSettings` (Task 1); `AudioServiceRepeatMode` and `AudioServiceShuffleMode` (audio_service); `LoopMode` (just_audio); `AudioDevice`, `AudioDeviceType` and `AudioDevicesChangedEvent` (audio_session).

**Interfaces — produces:**
- `remote_commands.dart`:
  - `enum RemoteCommand { play, pause, toggle, stop, next, previous }`
  - `RemoteCommand? resolveRemoteCommand(RemoteCommand c, {required bool playing, required bool strict, required bool inBluetoothGrace})`: returns what to do, or null to ignore.
  - `bool inBluetoothGrace({required int nowMs, required int? bluetoothConnectedAtMs, required int graceSeconds})`: `now − at < grace·1000`. False when grace is 0 or the timestamp is null.
  - `LoopMode loopModeFromRemote(AudioServiceRepeatMode)`, `AudioServiceRepeatMode remoteRepeatModeOf(LoopMode)`, `bool shuffleFromRemote(AudioServiceShuffleMode)`.
- `output_kind.dart`:
  - `enum AudioOutputKind { speaker, wired, bluetooth, usb, other }`
  - `AudioOutputKind outputKindOf(AudioDeviceType t)`
  - `Set<AudioOutputKind> newlyConnectedOutputs(AudioDevicesChangedEvent e, Set<String> knownOutputIds)`: counts outputs only and updates `knownOutputIds` (adds the added, removes the removed).
- `headset_policy.dart`:
  - `enum HeadsetAction { pause, resume, restartPlayback, startBluetoothGrace }`
  - `List<HeadsetAction> onOutputsConnected(Set<AudioOutputKind> kinds, HeadsetSettings s, {required bool playing, required bool canResume, required bool waitingForFocus, required bool isIos})`
  - `List<HeadsetAction> onBecomingNoisy(HeadsetSettings s, {required bool playing, required bool isIos})`

- [ ] **Step 1: Failing tests.**
  - `resolveRemoteCommand` (grace false):

| c | playing | strict | → |
|---|---|---|---|
| play | true | true | null |
| play | true | false | pause |
| play | false | any | play |
| pause | false | true | null |
| pause | false | false | play |
| pause | true | any | pause |
| stop | false | true | null |
| stop | false | false | play |
| stop | true | any | stop |
| toggle | true / false | any | pause / play |
| next, previous | any | any | itself |

  - With `inBluetoothGrace: true`, every command → null.
  - `inBluetoothGrace`:
    - (10500, 10000, 1) → true.
    - (11000, 10000, 1) → false.
    - (10500, 10000, 0) → false.
    - (10500, null, 1) → false.
  - Repeat/shuffle mapping:
    - `loopModeFromRemote`: none → off, one → one, all → all, group → all.
    - `remoteRepeatModeOf` inverts off/one/all.
    - `shuffleFromRemote`: none → false, all → true, group → true.
  - `outputKindOf`:
    - wiredHeadset, wiredHeadphones, lineAnalog → wired.
    - bluetoothA2dp, bluetoothLe → bluetooth; bluetoothSco → other.
    - usbAudio → usb.
    - builtInSpeaker, builtInEarpiece, builtInSpeakerSafe → speaker.
    - airPlay, carAudio, hdmi, unknown → other.
  - `newlyConnectedOutputs` with known `{'1', '2'}`:
    - Added = {#2 A2DP output, #3 wiredHeadset output, #4 headsetMic input-only} → `{wired}`, known `{'1', '2', '3'}`.
    - #3 removed then re-added → `{wired}` again.
    - The initial burst {#1, #2} → `{}`.
  - `onOutputsConnected`:
    - `{bluetooth}` with defaults, paused → `[startBluetoothGrace]`.
    - With `resumeOnBluetooth`, paused, `canResume` → `[startBluetoothGrace, resume]`.
    - The same but playing, or `canResume` false, or `waitingForFocus` (`no_connect_resume_while_waiting_for_focus`) → `[startBluetoothGrace]`.
    - `{wired}` with `resumeOnWired`, paused → `[resume]`.
    - `{usb}`, playing, Android → `[pause]`; paused → `[]`.
    - `{usb}` on iOS → `[]`.
    - `{usb, wired}` paused with `resumeOnWired` → `[]`.
  - `onBecomingNoisy`:
    - Playing → `[pause]`; paused → `[]`.
    - `pauseOnDisconnect` off on Android → `[]`.
    - Off on iOS while playing → `[restartPlayback]`.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run — PASS; analyze clean.

---

### Task 4: Button presses and feedback (pure Dart)

**Files:**
- Create `lib/audio/headset/button_presses.dart`.
- Test: `test/audio/button_presses_test.dart`.

**Interfaces — consumes:** `HeadsetSettings` and `ButtonMode` (Task 1); `RemoteCommand` (Task 3).

**Interfaces — produces:**
- `abstract final class MediaKey { static const headsetHook = 79, playPause = 85, stop = 86, next = 87, previous = 88, play = 126, pause = 127; static const handled = {79, 85, 86, 87, 88, 126, 127}; }`
- `enum ButtonSource { wired, bluetooth }`
- `class ButtonEvent { const ButtonEvent({required int keyCode, required bool down, required int atMs, required ButtonSource source, bool longPress = false}); }`. `longPress` marks a long press the system turned into a voice-search request.
- `class RecognizedPress { const RecognizedPress(RemoteCommand command, {required int presses, bool long = false, required ButtonSource source}); == }`
- `const kMultiPressWindowMs = 400; const kLongPressMs = 600;`
- `class PressRecognizer`:
  - `List<RecognizedPress> onEvent(ButtonEvent e, {required ButtonMode mode, required bool playing})`: first settles an expired pending sequence.
  - `List<RecognizedPress> onDeadline(int nowMs, {required bool playing})`.
  - `int? get deadlineMs`.
- `ButtonSource classifyButtonSource({required int deviceId, String? deviceName, required bool bluetoothOutput})`.
- `ButtonEvent? buttonEventFromPlatform(Map<Object?, Object?> m, {required int atMs})`.
  - Keys: `keyCode`, `down`, `repeat`, `deviceId`, `deviceName`, `btOutput`; or `longPress`, `btOutput`.
  - Returns null for an unhandled key, `repeat > 0`, or malformed input.
- `bool voiceProxyEnabled(HeadsetSettings s)`: `respondToButtons && (disableDefaultLongPress || wiredButtons == longPressNext || bluetoothButtons == longPressNext)`.
- `class ButtonFeedback { const ButtonFeedback({int beeps = 0, bool vibrate = false}); bool get isNone; == }`
- `ButtonFeedback feedbackFor(RecognizedPress p, HeadsetSettings s)`.
- `int beepToneVolume({required bool dvcInEffect, required double dvcGainDb})`.

- [ ] **Step 1: Failing tests.** Times in ms; `playing: true` unless stated.
  - Multi-press:
    - Hook down 0, up 80 → `[]`; `deadlineMs` == 480; `onDeadline(479)` → `[]`; `onDeadline(480)` → `[toggle ×1]`.
    - A second press (down 250, up 330) → deadline 730 → `[next ×2]`.
    - A third press (down 500, up 560) → `[previous ×3]`; 4 presses → `previous`.
    - PLAY alone → `[play]`; PAUSE alone → `[pause]`.
    - Down 0, up 80, then down 500 without `onDeadline` → `onEvent` returns `[toggle ×1]` and starts a new sequence.
    - Voice-key resend (down 1000 and up 1000) → one press.
  - Single press: hook down → `[]`, up → `[toggle]` at once; `deadlineMs` null.
  - Long press mode:
    - Down 0 → deadline 600. Up 200 → `[toggle]`.
    - Held: `onDeadline(600)` → `[next, long]`, then up 900 → `[]`.
    - Held while not playing: `onDeadline(600, playing: false)` → `[]`, then up 900 → `[toggle]`.
  - `ButtonEvent(longPress: true)`:
    - Long mode while playing → `[next, long]`.
    - Multi mode → `[]`.
    - Not playing → `[]`.
  - NEXT down → `[next]` and its up → `[]`, in all three modes; STOP down → `[stop]`.
  - `classifyButtonSource`:
    - (7, 'h2w headset', false) → wired.
    - (−1, null, true) → bluetooth; (−1, null, false) → wired.
    - (5, 'AVRCP', false) → bluetooth; (3, 'Bluetooth HID', false) → bluetooth.
  - `buttonEventFromPlatform`:
    - `{keyCode: 79, down: true, repeat: 0, deviceId: 4, deviceName: 'h2w headset', btOutput: false}` → hook down, wired, atMs.
    - `repeat: 1` → null; `keyCode: 24` → null; `{keyCode: 'x'}` → null.
    - `{longPress: true, btOutput: true}` → a long press from bluetooth.
  - `voiceProxyEnabled`:
    - Defaults → false.
    - `disableDefaultLongPress` → true; `wiredButtons: longPressNext` → true.
    - The same with `respondToButtons` false → false.
  - `feedbackFor` (defaults: beep on, beep more off, vibrate off):
    - next ×2 → 2 beeps; previous ×3 → 3; previous ×4 → 3.
    - Long → 1; toggle ×1 → 0, or 1 with `beepMore`.
    - `beep` off, with `beepMore` on → 0.
    - `vibrate` on → vibrate true.
  - `beepToneVolume`:
    - (false, any) → 60.
    - (true, 0) → 60; (true, −10) → 40; (true, −25) → 10; (true, −30) → 0.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run — PASS; analyze clean.

---

### Task 5: Player side — duck, own focus request, remote-command gate

**Files:**
- Create `lib/audio/focus/playback_target.dart` and `lib/player/remote_command_gate.dart`.
- Modify `lib/player/output_gain.dart`.
- Modify `lib/Helpers/audio_handler.dart`:
  - Both players get `handleInterruptions: false, handleAudioSessionActivation: false`.
  - Activation, duck, `pause({fade})`, `restartPlayback`, and repeat/shuffle publication.
- Modify `lib/main.dart`: build `final handler = HypeAudioHandler();`, then `AudioService.init<RemoteCommandGate>(builder: () => RemoteCommandGate(handler), …)`. Pass `remote:` to `AppController`.
- Modify `lib/player/video/video_fullscreen.dart`: the two direct `player.play()`/`pause()` calls go through `controller.handler.play()`/`pause()`, so they ask for focus.
- Test: `test/player/output_gain_test.dart` (extend), `test/player/remote_command_gate_test.dart`, `test/player/remote_state_test.dart`.

**Interfaces — consumes:** `kDuckDownMs` and `kDuckUpMs` (Task 2); `RemoteCommand`, `resolveRemoteCommand`, `inBluetoothGrace` and the mapping functions (Task 3); `HeadsetSettings` (Task 1); `runRamp` and `FadeCancellation` (existing).

**Interfaces — produces:**
- `OutputGain<P>`:
  - `double get duck`
  - `void setDuck(double gain, Iterable<P> players)`
  - `volumeOf` = track × mix × fade × listener × duck.
- `abstract interface class PlaybackTarget { bool get playing; Stream<bool> get playingStream; Future<void> play(); Future<void> pause({bool fade = true}); Future<void> setDuck(double level); Future<void> restartPlayback(); }`
- `HypeAudioHandler implements PlaybackTarget`:
  - `bool get playing => playbackState.value.playing` (false while a pause fades out); `playingStream` is distinct.
  - `Future<bool> Function()? onActivateSession`: awaited in `play()` after `onBeforePlay` and before any state change; in `startPlayback()` the player starts only once it returns true. Null means true, for tests.
  - `Future<void> pause({bool fade = true})`: `fade: false` pauses immediately.
  - `Future<void> setDuck(double level)`:
    - Clamped 0…1.
    - Glides on both players: down over `kDuckDownMs`, up over `kDuckUpMs`.
    - A new call cancels the glide in progress.
    - Instant while not playing.
  - `double get duckLevel`.
  - `Future<void> restartPlayback()`: `pause(fade: false)`, then `play()`.
  - `set shuffleEnabled(bool)`: republishes the playback state.
  - `_transformEvent` adds `repeatMode: remoteRepeatModeOf(_loopMode)` and `shuffleMode`, and puts `MediaAction.setRepeatMode` and `MediaAction.setShuffleMode` in `systemActions`. `setLoopMode` republishes.
- `class RemoteCommandGate extends CompositeAudioHandler`:
  - `RemoteCommandGate(BaseAudioHandler inner, {int Function()? nowMs})`; `nowMs` defaults to `clock.now().millisecondsSinceEpoch`.
  - `HeadsetSettings settings`, `int? bluetoothConnectedAtMs`, `ValueChanged<LoopMode>? onRemoteRepeat`, `ValueChanged<bool>? onRemoteShuffle`.
  - `Future<bool> execute(RemoteCommand c, {required bool bluetooth})`: resolves with `playing = playbackState.value.playing`, `strict = settings.strictCommands`, and grace applying only when `bluetooth`. Returns whether it acted.
  - Overrides `play`, `pause`, `stop`, `click`, `skipToNext`, `skipToPrevious`, `setRepeatMode` and `setShuffleMode`. All are treated as `bluetooth: true`, since the source is unknown.
  - Each override calls `super.<sameMethod>()` itself when the command resolves to itself, so `must_call_super` stays quiet. Otherwise it dispatches to the resolved super method.
  - `setRepeatMode`/`setShuffleMode` call super and then the callbacks, unless `ignoreRepeatShuffle` is on.

- [ ] **Step 1: Failing tests.**
  - `OutputGain`:
    - `setTrack('a', 1)`, then `setDuck(0.25, ['a', 'b'])` → applied a == 0.25 and b == 0.25.
    - `setMix('a', 0.5)` → 0.125.
    - `setListener(0.5, ['a', 'b'])` → a 0.0625.
    - `setTrack('a', 1)` again keeps the duck.
    - `setDuck(1.0, …)` → a 0.25 (mix 0.5 × listener 0.5).
  - Gate: the fake inner extends `BaseAudioHandler`, records calls, and is seeded with `PlaybackState(playing: …)`.
    - Strict, playing: `play()` → `[]`; `pause()` → `['pause']`.
    - Strict off, playing: `play()` → `['pause']`.
    - Paused, strict off: `pause()` → `['play']`; `stop()` → `['play']`.
    - Paused, strict: `stop()` → `[]`.
    - `click()`: playing → `['pause']`, paused → `['play']`; `click(MediaButton.next)` → `['next']`.
    - Grace (now 10000, connected 9500, 1 s):
      - `skipToNext()` → `[]`.
      - `execute(next, bluetooth: false)` → true and `['next']`.
      - `execute(next, bluetooth: true)` → false.
      - At now 10500, `skipToNext()` → `['next']`.
    - `setRepeatMode(group)` → `onRemoteRepeat` receives `[LoopMode.all]`; with `ignoreRepeatShuffle` → nothing.
    - `setShuffleMode(all)` → `[true]`.
  - Remote state: `HypeAudioHandler()`, `shuffleEnabled = true`, `bindPlaybackEvents(Stream.value(PlaybackEvent()))` →
    - `playbackState.value.shuffleMode == AudioServiceShuffleMode.all`;
    - `repeatMode == none`;
    - `systemActions` contains `setRepeatMode` and `setShuffleMode`.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3:** Implement and wire `main.dart`. `grep -n "handleInterruptions: false" lib/Helpers/audio_handler.dart` should match 2 lines.
- [ ] **Step 4:** `flutter test` shows only the known failures; `flutter analyze` shows no new issues (in particular no `must_call_super`).

---

### Task 6: Focus and headset services, controller wiring

**Files:**
- Create `lib/services/audio_focus_service.dart` and `lib/services/headset_service.dart`.
- Modify `lib/controllers/app_controller.dart`.
- Test: `test/audio/audio_focus_service_test.dart`, `test/audio/headset_service_test.dart` (`fake_async`; a `FakeTarget implements PlaybackTarget` that records calls, with a `pause` that completes after 50 ms).

**Interfaces — consumes:** Tasks 1–5; `AudioSession.instance` (`configure`, `setActive`, `interruptionEventStream`, `becomingNoisyEventStream`, `devicesChangedEventStream`, `getDevices`); `AndroidAudioManager().getMode()`; `DeviceInfoPlugin().androidInfo.version.sdkInt`.

**Interfaces — produces:**
- `const kResumeOnConnectDelay = Duration(milliseconds: 500); const kCallModePolls = [Duration.zero, Duration(milliseconds: 500), Duration(milliseconds: 1500)];`
- `class AudioFocusService`:
  - Constructor: `AudioFocusService({required PlaybackTarget target, required AudioFocusSettings Function() settings, required bool Function() hasSession, required bool isIos, required Stream<AudioInterruptionEvent> interruptions, required Future<bool> Function() requestFocus, Future<AndroidAudioHardwareMode> Function()? audioMode, Stream<LifecycleResume>? lifecycle, bool systemMutesLosers = false})`.
  - `static Future<AudioFocusService> forPlatform({required PlaybackTarget target, required AudioFocusSettings Function() settings, required bool Function() hasSession})`:
    - Configures `AudioSessionConfiguration.music()`.
    - `requestFocus`: Android `setActive(true, androidWillPauseWhenDucked: true)`; iOS `setActive(true)`.
    - Lifecycle comes from a `WidgetsBindingObserver` feeding `ForegroundTracker`, seeded with `WidgetsBinding.instance.lifecycleState`.
    - `systemMutesLosers` = Android SDK ≥ 31.
  - `void start()`: subscribes and sets `handler.onActivateSession = activate`.
  - `Future<bool> activate()`: true without a request while `!state.needsFocusRequest`.
  - `bool get waitingForFocus`.
  - `void sessionRestored()`: a `start` that arrived earlier is evaluated now.
  - `void dispose()`.
  - Behaviour:
    - Actions run in order, each awaited.
    - `pause` is `target.pause(fade: !isIos)`.
    - `unduck` after a pause runs once the pause has completed.
    - Plays and pauses the service did not cause become `ListenerPlayed` and `PlaybackPaused`.
- `class HeadsetService`:
  - Constructor: `HeadsetService({required PlaybackTarget target, required void Function(int nowMs) onBluetoothConnected, required HeadsetSettings Function() settings, required bool Function() canResume, required bool Function() waitingForFocus, required bool isIos, required Stream<AudioDevicesChangedEvent> devicesChanged, required Stream<void> becomingNoisy, required Future<Set<AudioDevice>> Function() currentDevices, int Function()? nowMs})`.
  - `static HeadsetService forPlatform(…)`, `Future<void> start()`, `void dispose()`.
  - The output-id baseline comes from `currentDevices` (outputs only) before the subscriptions act.
  - A resume runs after `kResumeOnConnectDelay`, and only if Hype is still paused and not waiting for focus.
- `AppController`:
  - `AppController(this._prefs, this._handler, {RemoteCommandGate? remote})`.
  - `AudioFocusSettings get/set audioFocusSettings` and `HeadsetSettings get/set headsetSettings`. The setters save, notify, and set `_remote?.settings`.
  - `bool get canResumePlayback => !isEqMode && songs.isNotEmpty`.
  - `_restoreSession` calls `_audioFocus?.sessionRestored()` on every return path.
  - `_remote?.onRemoteRepeat = setLoopMode`, `onRemoteShuffle = setShuffled`.
  - `handler.shuffleEnabled` follows `_isShuffled` on load and in `setShuffled`.
  - `onBluetoothConnected` sets `_remote?.bluetoothConnectedAtMs`.
  - The services are started (unawaited) in the constructor after the handler callbacks are wired.

- [ ] **Step 1: Failing tests (fake_async).**
  - Focus service, Android:
    - `transient_pauses_and_gain_resumes`: `(begin, pause)` → `['pause(fade: true)']`. After `playingStream` false, `(end, pause)` → `'play'`.
    - `late_call_detection_upgrades_the_hold`: `audioMode` returns normal at 0 ms and `inCall` at 500 ms. With `resumeAfterCall` false, a gain at 2 s → no `'play'`.
    - `short_off_pause_in_call`: Short off, `inCall` at 0 → `'pause'`; gain → `'play'`.
    - `unduck_waits_for_the_pause`: `(begin, duck)`, then `(begin, pause)` → `['duck(0.25)', 'pause', 'paused', 'duck(1.0)']`, in that order.
    - `listener_play_cancels`: after a transient pause, `playingStream` true (not caused by the service), then a gain → no `'play'`.
    - `no_tug_of_war`: Permanent off, `systemMutesLosers` true, playing. Two `(begin, unknown)` → `requestFocus` called once; `activate()` → true without another request. After `playingStream` false, `activate()` requests again.
  - Focus service, iOS: `(begin, unknown)` → `'pause(fade: false)'`; `(end, pause)` → `'play'`; `(end, unknown)` → nothing.
  - Lifecycle:
    - `start_waits_for_restore`: `resumeOnStart` on, lifecycle emits `start` → no play; `sessionRestored()` → `'play'`.
    - `reopen` with both switches → `'play'`; with `hasSession` false → nothing.
    - `no_lifecycle_no_resume`: no lifecycle events, `sessionRestored()` → nothing.
  - Headset service:
    - `initial_devices_are_not_connections`: `currentDevices` = {A2DP #5}; an added {#5} → no grace call, no play.
    - Connect, then resume:
      - With `resumeOnBluetooth`, paused, an added {A2DP #9 output} → `onBluetoothConnected` called at once.
      - No `'play'` at 499 ms; `'play'` at 500 ms.
      - Playing at 200 ms → no `'play'`.
    - `becomingNoisy` while playing → `'pause'`.
    - Android, playing, added {usbAudio #3} → `'pause'`.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3:** Implement the services and the controller wiring.
- [ ] **Step 4:** `flutter test` shows only the known failures; analyze clean.

---

### Task 7: Android media buttons — raw keys to Dart, feedback

**Files:**
- Vendor audio_service 0.18.19.
  - Copy `pubspec.yaml`, `LICENSE`, `README.md`, `CHANGELOG.md`, `analysis_options.yaml`, `lib/`, `android/` and `darwin/` from `~/.pub-cache/hosted/pub.dev/audio_service-0.18.19` into `packages/audio_service`. Do not copy `example/` or `test/`.
  - Add `audio_service: path: packages/audio_service` under `dependency_overrides` in `pubspec.yaml`.
  - Run `flutter pub get` at the root and in `packages/audio_service`.
- Modify `packages/audio_service/android/src/main/java/com/ryanheise/audioservice/AudioService.java`; add a header comment naming the Hype change.
- Create `android/app/src/main/kotlin/x/a/zix/MediaButtonBridge.java` and `ButtonFeedbackPlayer.java`. Both import only `android.*` and `java.*`; no androidx and no Flutter.
- Modify `MainActivity.java` and `AndroidManifest.xml` (`<uses-permission android:name="android.permission.VIBRATE"/>`).
- Modify `lib/Helpers/Channel.dart`.
- Create `lib/services/media_button_service.dart`.
- Modify `app_controller.dart`: start the service on Android only; the `headsetSettings` setter pushes policy.
- Test: `test/audio/media_button_service_test.dart` (`fake_async`).

**Interfaces — consumes:** Task 4 (recogniser, parser, `feedbackFor`, `beepToneVolume`, `voiceProxyEnabled`); Task 5 `RemoteCommandGate.execute`; plan 3 `dvcInEffect(isAndroid:, dvcEnabled:, systemWide:)` and `AppController.systemWideActive`. If plan 3 Task 11 has not landed, use `dvcEnabled` directly.

**Interfaces — produces:**
- Vendored `AudioService`:
  - `public interface MediaButtonInterceptor { boolean onMediaButton(KeyEvent event); }`
  - `public static void setMediaButtonInterceptor(MediaButtonInterceptor i)`
  - `public static final int NOTIFICATION_SCAN_CODE = 0x4859;`
  - `buildMediaButtonPendingIntent` stamps its `KeyEvent` with `new KeyEvent(0, 0, ACTION_DOWN, keyCode, 0, 0, KeyCharacterMap.VIRTUAL_KEYBOARD, NOTIFICATION_SCAN_CODE)`.
  - `MediaSessionCallback.onMediaButtonEvent` consults the interceptor first, for events that do not carry that scan code and are not `KEYCODE_BYPASS_PLAY`/`PAUSE`. It returns true when the interceptor consumes the event.
  - Nothing else changes: `diff -r` against the pub cache shows only these hunks.
- `MediaButtonBridge`:
  - `interface Sink { void send(Map<String, Object> event); }`
  - `static void setSink(Sink s)`
  - `static boolean onMediaButton(Context c, KeyEvent e)`:
    - Keys outside {79, 85, 86, 87, 88, 126, 127} → false.
    - `!respond` → true (swallowed).
    - No sink → false (audio_service's own handling).
    - Otherwise it sends `{keyCode, down, repeat, deviceId, deviceName, btOutput}` and returns true. `btOutput` = `AudioOutputDetector` reports "bluetooth".
  - `static void setPolicy(Context c, boolean respond, boolean playing, boolean longPressProxy)`.
  - `static boolean isPlaying()`.
- `ButtonFeedbackPlayer.play(Context c, int beeps, int toneVolume, boolean vibrate)`:
  - Beeps: `ToneGenerator(STREAM_MUSIC, toneVolume)`, `TONE_PROP_BEEP` for 60 ms, spaced 120 ms, released afterwards.
  - Vibration: one 40 ms pulse (`VibrationEffect` on API 26+, `VibratorManager` on API 31+).
- `MainActivity`:
  - EventChannel `eq_app/media_buttons`: `setSink` on listen, wrapping the `EventSink` with a post to the main looper; null on cancel.
  - `AudioService.setMediaButtonInterceptor(e -> MediaButtonBridge.onMediaButton(getApplicationContext(), e))` in `configureFlutterEngine`.
  - Method cases `setButtonPolicy {respond, playing, longPressProxy}` and `buttonFeedback {beeps, toneVolume, vibrate}`.
  - Removes `HeadphoneService` (Decision 20).
- `Channel`:
  - `static Stream<Map<Object?, Object?>> get mediaButtonEvents`
  - `static Future<void> setButtonPolicy({required bool respond, required bool playing, required bool longPressProxy})`
  - `static Future<void> buttonFeedback({required int beeps, required int toneVolume, required bool vibrate})`
- `class MediaButtonService`:
  - Constructor: `MediaButtonService({required Stream<Map<Object?, Object?>> events, required Future<bool> Function(RemoteCommand c, {required bool bluetooth}) execute, required HeadsetSettings Function() settings, required bool Function() playing, required Stream<bool> playingStream, required Future<void> Function(ButtonFeedback f, int toneVolume) feedback, required int Function() toneVolume, required Future<void> Function({required bool respond, required bool playing, required bool longPressProxy}) pushPolicy})`.
  - `void start()`, `void dispose()`, `Future<void> pushPolicy()`.
  - It times presses with `clock`, keeps one deadline `Timer`, and sends feedback only when `execute` returned true.

- [ ] **Step 1: Failing tests (fake_async, fake execute/feedback/pushPolicy).**
  - Hook down/up (wired, multi):
    - No `execute` at 399 ms.
    - At 400 ms → `execute(toggle, bluetooth: false)`.
    - No feedback with defaults.
  - Two presses → `execute(next)`, then `feedback(beeps: 2)`.
  - `ignored_command_gives_no_feedback`: `execute` returns false → no feedback.
  - A Bluetooth PLAY down/up → `execute(play, bluetooth: true)`.
  - `respondToButtons` false → nothing executed.
  - `playingStream` true → `pushPolicy(respond: true, playing: true, longPressProxy: false)`.
  - `wiredButtons: longPressNext` → `longPressProxy: true`.
  - Long press in Long press mode while playing → `execute(next)` at 600 ms; the later up executes nothing.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3:** Implement the Dart side, then the Java side.
- [ ] **Step 4: Verify.**
  - The tests pass; `flutter test` shows only the known failures.
  - `flutter analyze` shows no new issues. If vendoring added any, add `packages/audio_service/**` to `analyzer: exclude:` in the root `analysis_options.yaml` and re-check.
  - `pubspec.lock` shows `path: "packages/audio_service"`.
  - `javac` (Global Constraints) on `AudioOutputDetector.java`, `MediaButtonBridge.java` and `ButtonFeedbackPlayer.java` → no errors.
  - `grep -c HeadphoneService MainActivity.java` == 0.

---

### Task 8: Android long press — voice-search proxy

**Files:**
- Create `android/app/src/main/kotlin/x/a/zix/VoiceSearchProxyActivity.java` (`android.*` only).
- Modify `MediaButtonBridge.java` and `AndroidManifest.xml`.

**Interfaces — consumes:** Task 7 `setPolicy(…, longPressProxy)`. Its Dart side already sends `voiceProxyEnabled(settings)`.

**Interfaces — produces:**
- Manifest:
  - `<activity android:name=".VoiceSearchProxyActivity" android:enabled="false" android:exported="true" android:excludeFromRecents="true" android:noHistory="true" android:taskAffinity="" android:theme="@android:style/Theme.Translucent.NoTitleBar">`.
  - Two intent filters, both with category DEFAULT: `android.speech.action.VOICE_SEARCH_HANDS_FREE` and `android.speech.action.WEB_SEARCH`.
- `MediaButtonBridge.setPolicy` enables or disables the component (`setComponentEnabledSetting`, `DONT_KILL_APP`) when `longPressProxy` changes.
- `static void onVoiceLongPress(Context c)` sends `{longPress: true, btOutput}`.
- `VoiceSearchProxyActivity.onCreate`:
  - It treats the request as the long press when the referrer host is `android`, there is no `SearchManager.QUERY` extra, and `MediaButtonBridge.isPlaying()`. It then calls `onVoiceLongPress`.
  - Otherwise it forwards a copy of the intent:
    - To the single other handler (`queryIntentActivities`, `MATCH_DEFAULT_ONLY`, own package excluded).
    - To a chooser with `EXTRA_EXCLUDE_COMPONENTS` = itself when there are several.
    - Nowhere when there are none.
  - It always calls `finish()`.

- [ ] **Step 1:** Implement.
- [ ] **Step 2: Verify.**
  - `javac` on `VoiceSearchProxyActivity.java` and `MediaButtonBridge.java` with `AudioOutputDetector.java` → no errors.
  - `grep -c "VoiceSearchProxyActivity" AndroidManifest.xml` == 1, and the activity is `android:enabled="false"`.
  - By inspection: no path can start Hype's own proxy again.

---

### Task 9: Settings — Audio Focus section and Headset & Bluetooth category

**Files:**
- Create `lib/pages/audio_focus_settings_section.dart` and `lib/pages/headset_settings_section.dart`, styled like `crossfade_settings_section.dart`: cards, `SwitchListTile.adaptive`, a bottom-sheet chooser for the button modes, and a slider.
- Modify `lib/pages/Settings.dart`:
  - `SettingsCategory.headset('Headset & Bluetooth', Icons.headset_rounded, 'Resume on connect, pause on disconnect, headset buttons', _SettingsGroup.playback)`, after `crossfade`; the `_buildCategory` switch handles it.
  - The playback summary becomes `'Replay gain, audio focus, autoplay'`.
  - `_buildPlaybackSection` adds the Audio Focus section under the existing card.
  - `SettingsEntry.android(...)` and `bool availableOn({required bool isAndroid})`; search filters by it.
  - Index entries for every label.
- Test: `test/pages/audio_focus_settings_section_test.dart`, `test/pages/headset_settings_section_test.dart`.

**Interfaces — consumes:** Task 1 models; `AppController.audioFocusSettings` and `headsetSettings` (Task 6).

**Interfaces — produces:**
- `AudioFocusSettingsSection({required AudioFocusSettings settings, required ValueChanged<AudioFocusSettings> onChanged, required bool isIos})`.
  - `static const labels`: Resume after call, Resume on start, Resume on reopen, Short audio focus change / calls, Pause in call, Resume on focus gain, Duck volume, Permanent audio focus change.
  - `androidOnlyLabels` = the last five.
- `HeadsetSettingsSection({required HeadsetSettings settings, required ValueChanged<HeadsetSettings> onChanged, required bool isIos})`.
  - `static const labels`: Resume on wired headset, Resume on Bluetooth, Pause on headset disconnect, Pause on USB DAC connection, Respond to buttons, Wired headset buttons, Bluetooth buttons, Strict resume/pause/stop, Ignore Bluetooth commands, Ignore repeat/shuffle, Beep, Beep more, Vibrate, Disable default long press.
  - `androidOnlyLabels` = Pause on USB DAC connection, Respond to buttons, Wired headset buttons, Bluetooth buttons, Beep, Beep more, Vibrate, Disable default long press.
- Dimmed rows (not hidden):
  - Resume on reopen while Resume on start is off.
  - Resume on focus gain and Duck volume while Short is off.
  - Pause in call shows on, disabled, while Short is on.
  - The two button modes, Beep, Beep more, Vibrate and Disable default long press while Respond to buttons is off.
  - Beep more while Beep is off.
- Ignore Bluetooth commands: a slider over 0–20 s with 20 divisions, shown `'%d s'`.
- Disable default long press subtitle: "Long press no longer starts voice search while Hype plays. When Android asks, choose Hype."

- [ ] **Step 1: Failing widget tests.**
  - The Android focus section shows all 8 labels; with `isIos: true`, exactly Resume after call, Resume on start and Resume on reopen render, and the other 5 find nothing.
  - Pause in call:
    - With Short on, its switch value is true and `onChanged` is null.
    - With Short off and `pauseInCall` false, tapping it reports `pauseInCall` true.
  - With Short off, Resume on focus gain and Duck volume have `onChanged` null. With Resume on start off, Resume on reopen has `onChanged` null.
  - The Android headset section shows all 14 labels; iOS shows exactly the 6 Both rows.
  - Wired headset buttons → "Single press" reports `wiredButtons: singlePress`.
  - The slider has min 0, max 20 and divisions 20, and the label reads "1 s".
  - With Respond to buttons off, the button-mode tiles, Beep, Beep more, Vibrate and Disable default long press are disabled. With Beep off, Beep more is disabled.
  - Index checks:
    - Every label has a `kSettingsIndex` entry: focus labels under `playback`, headset labels under `headset`.
    - Exactly the `androidOnlyLabels` entries are `androidOnly`, and `availableOn(isAndroid: false)` is false for them.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3:** Implement and mount. Pass `isIos: Platform.isIOS`.
- [ ] **Step 4: Verify.**
  - `flutter test` shows only the two known failures; `flutter analyze` shows no new issues against the Task 0 baseline.
  - In equalizer-only mode neither the Playback nor the Headset category is listed (`_visibleCategories`, unchanged).
  - A case-insensitive grep for the reference app's name over every changed file returns nothing.

**Sequencing:** Task 1 first. Tasks 2, 3 and 4 are independent pure Dart and can run in parallel. Then Task 5, Task 6, Task 7 and Task 8, in that order. Task 9 needs only Task 1 and can run beside Tasks 2–8.

---

### For plans 5 and 6 (produced here, not built)

- **Per-output profiles (plan 5):**
  - `AudioOutputKind { speaker, wired, bluetooth, usb, other }` and `outputKindOf(AudioDeviceType)` are the output kinds §9 names. Plan 3's `OutputKind { bluetooth, usb, other }` in `autoeq_suggest.dart` can be folded into it.
  - `focusStep(…, noDuck:, ignoreFocus:)` already takes the per-output No Duck and Ignore audio focus flags; plan 5 passes the active output's values through `AudioFocusService`.
  - `HeadsetService`'s known-output set is the starting point for route detection.
- **Advanced Tweaks (plan 5):**
  - "Force audio on audio focus change" belongs in `AudioFocusService`, next to `activate()`/`requestFocus`, the one place focus is requested.
  - "Pause/resume on volume" uses plan 3's volume observers. It should act through `PlaybackTarget` and check `AudioFocusService.waitingForFocus`, so it never resumes into a call.
- **Settings layout (plan 6):**
  - Move `AudioFocusSettingsSection` from the Playback page into Audio → Audio Focus.
  - `SettingsCategory.headset` is already the Headset & Bluetooth category.
  - Use `SettingsEntry.android` for the DVC and Advanced Tweaks Android-only rows.
  - Equalizer-only mode already hides both pages.

### Critical Files for Implementation
- /Users/bruno/me/COTE/hype/lib/Helpers/audio_handler.dart (on disk `lib/helpers/audio_handler.dart`)
- /Users/bruno/me/COTE/hype/lib/controllers/app_controller.dart
- /Users/bruno/me/COTE/hype/lib/audio/focus/focus_policy.dart (new) and /Users/bruno/me/COTE/hype/lib/audio/headset/button_presses.dart (new)
- /Users/bruno/me/COTE/hype/packages/audio_service/android/src/main/java/com/ryanheise/audioservice/AudioService.java (vendored from ~/.pub-cache/hosted/pub.dev/audio_service-0.18.19)
- /Users/bruno/me/COTE/hype/android/app/src/main/kotlin/x/a/zix/MainActivity.java (plus the new MediaButtonBridge.java and VoiceSearchProxyActivity.java, and AndroidManifest.xml)