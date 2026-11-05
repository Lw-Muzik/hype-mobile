# Audio DSP Core Implementation Plan (plan 1 of 6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every player its own DSP engine on both platforms and add the core output stages — input gain (preamp + headroom + per-player track gain), software master volume (DVC), mono, balance and the rebuilt limiter — so DVC no longer leaves a crossfading player at full system volume.

**Architecture:** The C++ `RoomDSPEngine` (two identical copies) gains the new stages in the approved chain order. Android already runs one engine per ExoPlayer; it learns each player's just_audio id. iOS moves from one shared engine to one per player tap, with `DSPManager` replaying every setting onto engines created later. Dart owns the settings and decides what each engine gets.

**Tech Stack:** C++17 (NDK 28.2 / Xcode), Java (Android), Swift + Objective-C (iOS), Dart/Flutter, the just_audio fork in `packages/just_audio`.

**Spec:** `docs/superpowers/specs/2026-11-05-audio-settings-design.md` (sections 6, 10, decision 4, chain order). Later plans: 2 Replay Gain · 3 Equalizer · 4 Audio focus + Headset & Bluetooth · 5 DVC settings, Advanced Tweaks, per-output · 6 Settings layout + Audio Info.

## Global Constraints

- No app builds (`flutter build`, Gradle, Xcode). Verification is `flutter analyze`, `flutter test`, host C++ tests (`native_tests/*/run.sh`), `clang++ -fsyntax-only` and `swiftc -parse`.
- Do not name the reference app anywhere in the repo: code, comments, tests, docs, commit messages, branch names.
- Every header shared by `android/app/src/main/cpp` and `ios/HypeDSP/src` stays byte-identical; the host test scripts `cmp` them.
- Both platforms unless a step says Android or iOS.
- Existing users keep their sound where Hype had an equivalent setting; new settings start at the spec defaults.
- Work on branch `feat/crossfade-and-fades`; push after each commit (owner's standing rule; no `Co-Authored-By` lines).
- NDK for syntax checks: `/opt/homebrew/share/android-commandlinetools/ndk/28.2.13676358` (`--target=aarch64-linux-android24 --sysroot=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/sysroot`).

## Review Focus

1. DVC on, skip during playback: the incoming crossfade player must already be at the DVC level — never a burst at full volume (Task 3: cached master volume applied in `onFlush` before the first buffer).
2. Changing master volume, balance or preamp while music plays must not click (Task 1 test: per-sample gain step bounded).
3. Balance fully left/right silences the other side exactly; a mono source stays centred at any balance short of ±1 (Task 1 tests).
4. A sustained boost (preamp +24 dB into a full-scale sine) never exceeds ±1.0 at the output, and the limiter recovers to unity ~341 ms after the overload ends (Task 1 tests).
5. iOS: the engine created for the second player after settings were changed carries every current setting (Task 2 replay test).

---

### Task 1: Engine stages (C++, both copies)

**Files:**
- Create: `android/app/src/main/cpp/output_stages.h` (+ identical `ios/HypeDSP/src/output_stages.h`) — `GainStage`, `MonoStage`, `BalanceStage`.
- Modify: `limiter.h` (both copies) — rebuild `OutputLimiter`.
- Modify: `room_dsp_engine.h/.cpp` (both platforms) — new setters, chain order, auto-gain removed.
- Test: `native_tests/dsp_core/dsp_core_test.cpp`, `native_tests/dsp_core/run.sh` (shape of `native_tests/stereo/run.sh`: `cmp` every shared header, then compile and run).

**Interfaces — produces, on `RoomDSPEngine` (both platforms):**
- `void setPreampGain(float dB)` — clamp ±24; no auto-gain.
- `void setHeadroomDb(float dB)` — clamp −10…0.
- `void setTrackGainDb(float dB)` — clamp −30…+24; per engine (= per player).
- `void setMasterVolumeDb(float dB)` — clamp −30…0; −30 is silence (gain exactly 0).
- `void setMono(bool)`, `void setBalance(float b)` — b clamped −1…1.
- `void setLimiterEnabled(bool)` — existing name kept; `float limiterGain() const` — current limiter gain (for Audio Info later).

- [ ] **Step 1: Write failing host tests** in `dsp_core_test.cpp` (the `CHECK` framework of `native_tests/stereo/stereo_expander_test.cpp`):
  - `gain_stage_glides_without_clicks`: settled at 0 dB, `setDb(-30)`; over full-scale DC input the largest step between consecutive outputs ≤ `1.0f/256 + 1e-6f`; after 1024 frames the gain equals `powf(10, -30/20.f)`.
  - `master_volume_floor_is_silence`: settled `setDb(-30, /*muteAtFloor=*/true)` outputs exactly 0.
  - `balance_full_left_silences_right`: `set(-1)` → L unchanged, R == 0.
  - `balance_half_attenuates_opposite_by_24db`: `set(0.5f)` → R unchanged, L == input × `powf(10, -24/20.f)` (±1e-5).
  - `mono_averages`: L 0.6, R 0.2 → both 0.4.
  - `limiter_never_exceeds_ceiling`: preamp +24 dB into a 1 kHz full-scale sine, 1 s at 48 kHz, through the engine → every |output| ≤ 1.0.
  - `limiter_recovers_in_341ms`: after the overload stops, the gain reaches 1.0 within `ceil(48000 × 0.3414) + 4` frames and not before `48000 × 0.33`.
  - `limiter_slopes_scale_with_rate`: the same recovery at 96 kHz takes the same time (twice the frames).
  - `chain_order`: balance −1 with stereo expand 1.0 on L 0, R 0.5 → output R == 0 (balance runs after expand).

- [ ] **Step 2: Run `native_tests/dsp_core/run.sh`** — expect a compile failure (types missing).

- [ ] **Step 3: Implement `output_stages.h`.** `GainStage`: atomic target; per-sample linear glide at a fixed slope of 1/256 of full scale; `setDb(float dB, bool muteAtFloor = false)`; `bool active() const` (target ≠ 1 or still gliding); `process(float* l, float* r, int n)`. `MonoStage`: `L = R = (L+R)/2` when on. `BalanceStage`: b < 0 attenuates R by `48·|b|` dB, b > 0 attenuates L, exactly 0 at |b| = 1, gliding like `GainStage`.

- [ ] **Step 4: Rebuild `OutputLimiter`.** No look-ahead, ceiling 1.0. Per frame: `peak = max(|L|,|R|)`; if `peak > ceiling` then `target = min(target, ceiling/peak)`, else `target = min(1, target + rel)`; the applied gain moves toward the target, down by `att`, up by `rel`, never past it; samples are multiplied when gain ≠ 1. `att = 2^-8 × 48000/fs`, `rel = 2^-14 × 48000/fs`, recomputed when the sample rate is set. Keep `setEnabled/isEnabled`; add `float gain() const`. Remove setters nothing calls (grep first).

- [ ] **Step 5: Wire the engine** (both platforms):
  - Input gain = `trackGainDb + preampDb + headroomDb` through one `GainStage`, run whenever it is active (not only when EQ is on). Delete `recomputeAutoGain()` and its calls; EQ/tone setters no longer touch the preamp.
  - Order: stems → input gain → speaker EQ → EQ → tone → MBC → crossfeed → surround → reverb → master volume (`GainStage`, mute at floor) → stereo expand → mono → balance → limiter → final clamp.
  - `doLimiter = limiter_.isEnabled()` on both (Android's `anyUpstreamBoost()` gate goes).
  - Update the chain comments in both headers.

- [ ] **Step 6: Verify.** `native_tests/dsp_core/run.sh` and `native_tests/stereo/run.sh` pass with headers identical; `clang++ -std=c++17 -fsyntax-only` on both engine `.cpp` files (Android against the NDK sysroot) shows no errors.

- [ ] **Step 7: Commit** `feat(dsp): input gain, master volume, mono, balance and a rebuilt limiter`; push.

---

### Task 2: One engine per player, addressable by player id

**Files:**
- Modify: `packages/just_audio/lib/just_audio.dart` — `String get playerId => _id;`.
- Modify: `packages/just_audio/android/src/main/java/com/ryanheise/just_audio/AudioPlayer.java` (~line 894) — reflectively call `createPlayerInstance(String)` with the player's id.
- Modify: `android/app/src/main/kotlin/x/a/zix/RoomEffectsProcessor.java` — `createPlayerInstance(String playerId)` (the no-arg form delegates with `""`); a `ConcurrentHashMap<String, RoomEffectsProcessor>`; cached global values for every new setter, replayed in `onFlush` like the existing caches; `static void setTrackGainDb(String playerId, float dB)` (cached per id, replayed).
- Modify: `android/app/src/main/cpp/jni_bridge.cpp` — `nativeSetHeadroomDb`, `nativeSetTrackGainDb`, `nativeSetMasterVolumeDb`, `nativeSetMono`, `nativeSetBalance`.
- Modify: `packages/just_audio/darwin/just_audio/Sources/just_audio/AudioPlayer.m` (`addItemObservers:`) — call `installTapOnPlayerItem:forPlayer:` with `_playerId`.
- Modify: `ios/Runner/HypeAudioTap.h/.m` — one engine handle per player id, created on first use through a factory block set by `DSPManager` (replaces `setDspHandle`); a player's tap reuses its engine for every item; `latestPcmFloat` unchanged.
- Create: `ios/Runner/DSPReplayLog.swift` — pure Swift: `record(key: String, apply: @escaping (UnsafeMutableRawPointer) -> Void)` (same key replaces in place), `replay(onto:)`.
- Modify: `ios/Runner/DSPManager.swift` — every setter applies to all engines and records itself (key = setter name + band index); `func makeEngine() -> UnsafeMutableRawPointer` creates and replays; `func setTrackGainDb(_ dB: Float, playerId: String)` targets one engine and is not recorded globally.
- Modify: `ios/HypeDSP/src/dsp_bridge.cpp` + both `dsp_bridge.h` — `dsp_set_headroom_db`, `dsp_set_track_gain_db`, `dsp_set_master_volume_db`, `dsp_set_mono`, `dsp_set_balance`.
- Modify: `MainActivity.java`, `ios/Runner/AppDelegate.swift`, `lib/helpers/Channel.dart` — methods `dspSetHeadroomDb {value}`, `dspSetTrackGainDb {playerId, value}`, `dspSetMasterVolumeDb {value}`, `dspSetMono {enabled}`, `dspSetBalance {value}`.
- Test: `native_tests/ios_replay/replay_test.swift` + `run.sh` (`swiftc ios/Runner/DSPReplayLog.swift replay_test.swift -o …` then run).

**Interfaces:**
- Consumes: Task 1 setters.
- Produces: `AudioPlayer.playerId`; `Channel.dspSetHeadroomDb(double)`, `Channel.dspSetTrackGainDb(String playerId, double dB)`, `Channel.dspSetMasterVolumeDb(double)`, `Channel.dspSetMono(bool)`, `Channel.dspSetBalance(double)`.

- [ ] **Step 1: Failing replay test:** record `preamp=3`, `eqBand(4)=2`, `eqBand(4)=5`, `mono=true`; replaying onto a fresh fake engine applies exactly `preamp=3, eqBand(4)=5, mono=true`, in first-recorded order.
- [ ] **Step 2: Run `native_tests/ios_replay/run.sh`** — expect a compile failure.
- [ ] **Step 3: Implement `DSPReplayLog.swift`**; rerun — expect pass.
- [ ] **Step 4: Implement the plumbing above** on both platforms.
- [ ] **Step 5: Verify.** `flutter analyze lib packages/just_audio/lib` (no new issues); NDK `-fsyntax-only` on `jni_bridge.cpp`; `swiftc -parse` on every touched Swift file; all `native_tests/*/run.sh`.
- [ ] **Step 6: Commit** `feat(dsp): one engine per player on both platforms`; push.

---

### Task 3: The DVC level becomes the engine's master volume (Android)

**Files:**
- Modify: `android/app/src/main/kotlin/x/a/zix/DvcController.java` — keep holding the system media volume at maximum while DVC is on and forwarding volume keys; drop the low-gain system-volume reduction and every `LoudnessControl` call.
- Modify: `RoomEffectsProcessor.java` — `static void broadcastMasterVolumeDb(float dB)`, cached and applied in `onFlush` before the first buffer (Review Focus 1).
- Delete: `android/app/src/main/kotlin/x/a/zix/LoudnessControl.java` once `grep -rn LoudnessControl android/` shows no caller.
- Create: `lib/audio/dsp_core.dart` — `double masterVolumeFor({required bool dvcEnabled, required double dvcGainDb})`.
- Modify: `lib/controllers/app_controller.dart` — the `dvcGain`/`dvcEnabled` setters push `Channel.dspSetMasterVolumeDb(masterVolumeFor(...))`; `_bindAudioSessionId` stops re-applying DVC; `lib/helpers/Channel.dart` loses the LoudnessEnhancer-only methods once unused.
- Test: `test/audio/dvc_routing_test.dart`.

**Interfaces:**
- Consumes: `Channel.dspSetMasterVolumeDb` (Task 2).
- Produces: `masterVolumeFor` — `dvcGainDb` clamped −30…0 when enabled, else 0.

- [ ] **Step 1: Failing test:** `masterVolumeFor(dvcEnabled: true, dvcGainDb: -12)` == −12; `(true, -45)` == −30; `(false, -12)` == 0.
- [ ] **Step 2: Run** `flutter test test/audio/dvc_routing_test.dart` — expect FAIL (undefined).
- [ ] **Step 3: Implement** `masterVolumeFor` and the Java/Dart routing.
- [ ] **Step 4: Verify** — the test passes; `flutter analyze` no new issues; NDK `-fsyntax-only` unaffected.
- [ ] **Step 5: Commit** `fix(dvc): apply the DVC level inside each player's engine`; push.

---

### Task 4: Core settings in Dart (headroom, balance, mono, limiter, preamp, tempo)

**Files:**
- Modify: `lib/audio/dsp_core.dart` — immutable `DspCoreSettings` with `copyWith`, `static DspCoreSettings load(SharedPreferences prefs, {required bool isIos})`, `Future<void> save(SharedPreferences)`; `double headroomFor({required bool dvcActive, required double headroomDb})`.
- Modify: `lib/controllers/app_controller.dart` — holds `DspCoreSettings`; `set dspCore(DspCoreSettings)` saves and pushes changed values through `Channel`; the existing apply-all-DSP path pushes all of them (also on iOS engine re-init). Headroom is pushed as `headroomFor(dvcActive: Platform.isAndroid && dvcEnabled, …)` and re-pushed when DVC toggles. The existing `limiterEnabled` getter/setter (pref `limiterEnabled`, default true) becomes a view of `dspCore.limiter`.
- Modify: `lib/helpers/audio_handler.dart` — `Future<void> setTempo(double speed)` sets both players (so an incoming crossfade player matches) and survives swaps.
- Test: `test/audio/dsp_core_settings_test.dart`.

**Interfaces — produces:** `DspCoreSettings { double headroomDb; double balance; bool mono; bool limiter; double preampDb; bool tempoOn; double tempo; }`; prefs keys `dspHeadroomDb`, `dspBalance`, `dspMono`, `limiterEnabled` (existing), `dspPreampDb`, `dspTempoOn`, `dspTempo`.

- [ ] **Step 1: Failing tests:**
  - empty prefs → headroom −6.0 (`isIos: false`) / 0.0 (`isIos: true`); balance 0; mono false; limiter true; preamp 0; tempoOn false; tempo 1.0.
  - migration: `limiterEnabled: false` → `limiter: false`; Hype's existing preamp pref (find its key in `app_controller.dart`) carries over, clamped to ±24.
  - clamps/snaps: headroom −12 → −10, +1 → 0, 0.5 dB steps; balance ±1.5 → ±1; tempo 0.4 → 0.5, 3.5 → 3.0; balance within ±0.02 → 0; tempo within ±0.02 of 1.0 → 1.0.
  - `headroomFor(dvcActive: true, headroomDb: -6)` == 0; `(false, -6)` == −6.
  - `save` → `load` round-trips.
- [ ] **Step 2: Run** `flutter test test/audio/dsp_core_settings_test.dart` — expect FAIL.
- [ ] **Step 3: Implement** the model, controller wiring and `setTempo`.
- [ ] **Step 4: Verify** — tests pass; `flutter analyze` no new issues.
- [ ] **Step 5: Commit** `feat(dsp): headroom, balance, mono, limiter, preamp and tempo settings`; push.

---

### Task 5: Controls on the equalizer pages

**Files:**
- Create: `lib/pages/volume_controls.dart` — `VolumeControls({required DspCoreSettings settings, required ValueChanged<DspCoreSettings> onChanged, required double stereoExpand, required ValueChanged<double> onStereoExpand})`: Balance slider (−1…1, centre snap, labels L / R, value `%.2f`), Mono switch, Tempo switch + slider (0.50–3.00×, centre snap 1.00×, `−`/`+` stepping 0.05, disabled at the ends, value `%.2fx`), Reset (confirm dialog; resets balance, stereo expand, tempo, mono).
- Modify: `lib/pages/tone_view.dart` — mount `VolumeControls` under a "VOLUME" header in the page's card style.
- Modify: `lib/pages/eq_view.dart` — Limiter switch; preamp slider range ±24 dB.
- Modify: `lib/pages/Settings.dart` — "No DVC – preamp reduction" slider (−10.0…0 dB, 0.5 dB steps, `%.1f dB`) in the Audio Enhancement section until plan 6 moves it, disabled with "Not used while direct volume control is on" when DVC is active; `SettingsEntry` rows for Balance, Mono, Tempo, Limiter and No DVC – preamp reduction.
- Test: `test/pages/volume_controls_test.dart`.

**Interfaces — consumes:** `DspCoreSettings`, `AppController.dspCore`, `AppController.stereoExpand`.

- [ ] **Step 1: Failing widget tests:** "Balance", "Mono", "Tempo", "Reset" shown; `+` at 1.00× reports 1.05; `+` disabled at 3.00×; Reset, once confirmed, reports balance 0, mono false, tempo off at 1.0 and stereo expand 0.
- [ ] **Step 2: Run** `flutter test test/pages/volume_controls_test.dart` — expect FAIL.
- [ ] **Step 3: Implement** `VolumeControls` and the page changes.
- [ ] **Step 4: Verify** — `flutter test` shows only the two pre-existing failures (`widget_test.dart`, `intro_splash_test.dart`); `flutter analyze` no new issues.
- [ ] **Step 5: Commit** `feat(eq): balance, mono, tempo, limiter and headroom controls`; push.
