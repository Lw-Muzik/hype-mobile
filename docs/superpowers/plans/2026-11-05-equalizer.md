# Equalizer Implementation Plan (plan 3 of 6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fixed 32-band grid and its grouped views with N real graphic-EQ bands at chosen centres (5 · 10 ISO · 12 · 15 ISO · 16 · 24 · 31 ISO · 32, or 5–32 custom). Presets store per-band frequency and gain. Every existing curve and preset is migrated by log-frequency interpolation. Add Auto save, Restore equalizer presets, Smooth equalizer/tone gains, the tone ranges and value labels, AutoEq suggestions, and the Settings → Equalizer page. Make Android system-wide mode carry N bands, preamp, headroom, smoothed tone and the limiter, and show the controls it cannot carry as disabled with a reason.

**Architecture:** A new shared C++ `GraphicEQ` (one biquad per band, at any centres, with Q taken from the band spacing) replaces the `ParametricEQ` the engine used as its graphic EQ. Dart owns the layout and pushes centres before gains, so a new engine never plays with the wrong layout. Android caches it and replays it in `onFlush`; iOS records it in the replay log. Smooth gains are worked out **inside each engine** from what the engine already knows: preamp, master volume and headroom, plus a system-volume value that native code pushes (an Android `ContentObserver`, iOS KVO on `outputVolume`). Volume keys therefore act at once, without a round trip to Dart. The DynamicsProcessing path uses the same C++ formula through one static JNI call. Band layouts, migration, presets, Auto save, labels and AutoEq matching are pure Dart and unit-tested.

**Tech Stack:** C++17 (NDK 28.2 / Xcode), Java (Android), Swift (iOS), Dart/Flutter, `audio_session` 0.2.4 (already locked; becomes a direct dependency).

**Spec:** `docs/superpowers/specs/2026-11-05-audio-settings-design.md` — §5 Equalizer, "Smooth equalizer/tone gains — the rule", the Android system-wide EQ mode paragraph, Equalizer-only app mode. Plan 1 ledger: `.superpowers/sdd/2026-11-05-audio-dsp-core/progress.md` (parked for plan 3: the two `tone_controls.h` copies differ; the speaker preamp applies twice in system-wide mode; the chain comment in Android `room_dsp_engine.h` is stale). **This plan starts only after plan 2 has landed.** Both edit `app_controller.dart`, `Settings.dart`, `Channel.dart`, `MainActivity.java`, `AppDelegate.swift` and `DSPManager.swift`, and Task 11 extends plan 2's `ReplayGainSettingsSection`.

## Global Constraints

- No app builds (`flutter build`, Gradle, Xcode). Verify with:
  - `flutter analyze`: no new issues against the count recorded before Task 0.
  - `flutter test`: only `widget_test.dart` and `intro_splash_test.dart` may fail.
  - `native_tests/*/run.sh`.
  - `clang++ -std=c++17 -fsyntax-only` on both engine `.cpp` files and `jni_bridge.cpp`. For Android, use the NDK sysroot: `/opt/homebrew/share/android-commandlinetools/ndk/28.2.13676358`, `--target=aarch64-linux-android24 --sysroot=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/sysroot`.
  - `swiftc -parse` on every Swift file you touch.
  - `plutil -lint ios/Runner.xcodeproj/project.pbxproj`.
- Do not name the reference app anywhere in the repo: code, comments, tests, docs, commit messages.
- Every header shared by `android/app/src/main/cpp` and `ios/HypeDSP/src` stays byte-identical. `native_tests/eq/run.sh` and `native_tests/dsp_core/run.sh` `cmp` all of these: `graphic_eq.h`, `smooth_gains.h`, `tone_controls.h`, `biquad.h`, `parametric_eq.h`, `output_stages.h`, `limiter.h`, `stereo_expander.h`. Both `dsp_bridge.h` copies (`ios/HypeDSP/include`, `ios/HypeDSP/src`) stay identical.
- Every new Swift file in `ios/Runner` is registered in the Runner target of `ios/Runner.xcodeproj/project.pbxproj` (see Task 0).
- Both platforms unless a step says Android or iOS.
- Existing users keep their sound and their sliders where Hype had an equivalent setting. Settings that did not exist before start at the spec defaults.
- No commits until the owner confirms; leave all changes in the working tree.
- Java has no host test harness (no Android jars). Keep Java logic thin and put the maths in C++ or Dart, where it can be tested.

## Review Focus

1. **The update keeps the sound and the sliders.** A legacy 10-band user sees the same 10 slider values on 10 (ISO), within 0.05 dB. 20 bands become 24. An unsaved "Custom" curve becomes a user preset. Built-ins and user presets survive. Tests: Task 3 (`nearestStandardBandCount`, interpolation) and Task 4 (migration).
2. **No click and no wrong-gain burst when the layout changes or a preset is applied during playback,** on either platform. Layout always goes before gains: Task 5 push-order test, Task 2 replay test. Coefficient fades and band draining: Task 1 click tests.
3. **Smooth gains follow the volume, not just edits.** At full scale a +12 dB band plays at +10 dB. Lowering the system volume by 10 dB brings it back to +12 dB without touching the EQ, on Android (stream dB) and iOS (`outputVolume`). The curve never inverts. Tests: Task 6 engine tests, floor test; Task 7 iOS mapping test.
4. **Auto save.**
   - On: edits land in the selected preset (built-ins too) and survive a restart.
   - Off: the preset is untouched and shown as unsaved, and the curve still survives a restart.
   - Restore equalizer presets brings built-ins back and leaves user presets alone.
   - Tests: Task 4 state tests, Task 5 sheet test.
5. **System-wide mode.** Other apps get the N bands, preamp, headroom, smoothed tone and limiter. Hype's own playback is never EQ'd, toned or preamped twice. Turning system-wide on with DVC enabled never leaves other apps at forced full volume. Disabled controls say why. Tests: Task 11 engine neutral test, `systemWideDvcSteps` test, `VolumeControls` reason test.

## Decisions taken where the spec is open (owner may overrule)

1. **First/Last frequency apply to every non-ISO layout** (5, 12, 16, 24, 32 and custom), not only to custom bands. This is my reading of "the other counts and custom bands are spaced logarithmically between first and last". ISO layouts ignore them.
2. **Tone X range is 0…1.** Hype's tone is boost-only: Dart clamps both shelves to 0–15 dB; the engines clamp at 15/15 (Android) and 25/20 (iOS). Stored tone gains stay in dB at the fixed (off) scale, so X = bass dB / 22.5 and treble dB / 15. Bass therefore extends to 0–22.5 dB and treble stays 0–15 dB. Existing values carry over unchanged in dB, so they sound identical with smoothing off or away from full scale. Both engine copies clamp to these ranges.
3. **Smooth scales are floored at 0 dB.** Taken literally, the rule inverts the curve once T > +15 dB (EQ) or T > +20 dB (bass), which only a preamp above +15 dB can reach. I read "nothing is clamped" as "gains are scaled, not clipped".
4. **T counts the user preamp only while it is applied** (EQ or speaker EQ on, and not in system-wide mode). The speaker-profile preamp and replay gain do not count. Master volume is the engine's DVC level plus a pushed system-volume dB, and that system value is 0 while DVC is active.
5. **Smooth gains default to on for existing installs too.** It is a new setting, per the anti-goal's second clause. It is audible only within about 3 dB (EQ/treble) or 8 dB (bass) of full scale. Plan 1's boost-seeded headroom already keeps most boosted users below that.
6. **Smoothing covers the graphic EQ and tone only.** The parametric EQ and speaker EQ (Hype extras) are not smoothed.
7. **Value labels show the set value** (fixed-scale dB, or X as %), not the gain smoothing is applying at that moment.
8. **Legacy curves are migrated from what the user saw.** A stored 32-value curve that is constant inside every group of a legacy grouping (5/10/16/20, coarsest first) becomes that grouping's display points. Any other curve keeps its 32 points. Interpolating the raw staircase would shift a 10-band user's four lowest sliders by one band.
9. **Existing installs keep what they had.** An existing install without a stored `eqBandCount` was on 32 bands and stays on 32; new installs get 10. If tone frequency/Q prefs are missing on an existing install, they get the values those users actually heard (80 Hz / 0.707, 10 kHz / 0.707). New installs get the spec defaults (90 / 0.80, 10000 / 0.60).
10. **Built-ins can be edited (by Auto save) and deleted.**
    - Restore puts every factory built-in back, at factory curves, in factory order at the top; user presets follow untouched. If the selected preset is a built-in, its factory curve is applied.
    - A user preset whose name collides with another (a built-in, or a migrated "Custom") gets " (2)", " (3)", …
    - Flatten always zeroes the curve, selects Flat and stores a flat curve into Flat (re-created if it was deleted).
11. **With Auto save off, the unsaved curve still persists across restarts** and is shown as `Name *`. It is not thrown away. Deleting the selected preset leaves the curve playing, unsaved, with no name.
12. **EQ screen band dropdown:** it lists the 8 standard counts, plus "Custom (N)" while custom bands are on. Picking a standard count turns custom bands off.
13. **AutoEq suggestions.**
    - Applying a suggestion applies the profile globally, like the Speaker Correction page does; plan 5's per-output profiles will bind it to the device.
    - Not offered while system-wide mode is on: DynamicsProcessing cannot carry a parametric speaker EQ.
    - Matching (verified against `assets/autoeq.json`): normalise names; exact name or model (name without brand) first; else the shortest profile containing the device name; else the longest model of at least 5 characters contained in the device name.
14. **System-wide mode, inside Hype's own engine:**
    - The graphic EQ, tone, user preamp and headroom run neutral, because DynamicsProcessing applies them to the whole mix, Hype included.
    - Track gain, balance, mono and stereo expand also run neutral (their controls are disabled).
    - Master volume is **not** neutralised in the engine. DVC is suspended by Dart in the safe order (system volume restored first) and resumes when system-wide goes off; the stored DVC setting is not changed.
15. **DynamicsProcessing details:**
    - Limiter: threshold 0 dBFS, attack 5.3 ms, release 341 ms, ratio 20, post-gain 0.
    - Band edges: geometric midpoints between centres; the last band edge is 20 000 Hz (controller ruling after Task 2 review).
    - A band-count change rebuilds the instance (its config is fixed at creation), which may cause a brief dropout for other apps.
16. **Found while planning (plan 1 leftover):** `ios/Runner/DSPReplayLog.swift` is not in the Runner target (0 matches in `project.pbxproj`), so an iOS build would fail to find `DSPReplayLog` and `PlayerValueBook`. Task 0 fixes it.

---

### Task 0: Register DSPReplayLog.swift in the Runner target (iOS)

**Files:** Modify `ios/Runner.xcodeproj/project.pbxproj`.

- [ ] **Step 1:** Add a `PBXFileReference` (`path = DSPReplayLog.swift; sourceTree = "<group>"`). Add a `PBXBuildFile` "DSPReplayLog.swift in Sources", a child entry in the Runner group (next to `DSPManager.swift`), and an entry in the Runner target's `PBXSourcesBuildPhase` (`97C146EA1CF9000F007C117D`). Use fresh 24-hex IDs; grep the file first so they do not collide.
- [ ] **Step 2: Verify:**
  - `plutil -lint` reports OK.
  - `grep -c "DSPReplayLog.swift" project.pbxproj` == 4.
  - `grep -c "DSPReplayLog.swift in Sources" project.pbxproj` == 2.
  - Record the `flutter analyze` issue count as this plan's baseline.

---

### Task 1: Engine — N-band graphic EQ at any centres (C++, both copies)

**Files:**
- Create `android/app/src/main/cpp/graphic_eq.h` and an identical `ios/HypeDSP/src/graphic_eq.h`.
- Modify `biquad.h` (both copies): add `bool fading() const` and `void clearState()` (zeroes the delay states only).
- Modify `parametric_eq.h` (both copies): remove `initGraphic` and `getPeakGain` once grep shows no caller; keep `ISO_FREQUENCIES` as the legacy grid.
- Modify `room_dsp_engine.h/.cpp` (both platforms): `graphicEq_` becomes a `GraphicEQ`; new setters; fix the stale chain comment.
- Test: create `native_tests/eq/eq_test.cpp` and `native_tests/eq/run.sh`, shaped like `native_tests/dsp_core/run.sh` (`cmp` every shared header listed in Global Constraints, then compile against the iOS engine and run). Add `graphic_eq.h` to `dsp_core/run.sh`'s `cmp` list.

**Interfaces — produces:**
- `graphic_eq.h`: `constexpr int kMaxGraphicBands = 32;` and `class GraphicEQ` with:
  - `void init(float sampleRate)`: keeps the layout and gains, clears state and sets coefficients immediately.
  - `void setLayout(const float* centresHz, int count)`: count clamped 1…32. Gains are kept by index below the new count; later indices become 0.
  - `void setBandGain(int band, float nominalDb)`: nominal gain, clamped ±15.
  - `void setAllGains(const float* nominalDb, int count)`.
  - `void setGainScale(float factor)`: effective gain = nominal × factor. Used by Task 6; default 1.
  - Accessors: `int bandCount() const`, `float centreHz(int) const`, `float q(int) const`, `float effectiveGainDb(int) const`.
  - `void process(float* l, float* r, int n)`.
  - `static float bandQ(const float* centresHz, int count, int band)`: N = octave distance to the neighbours (mean of left and right; one side at the edges); Q = √(2^N) / (2^N − 1).
- `GraphicEQ` behaviour:
  - A band whose |effective| < 0.05 dB, or whose centre ≥ 0.45 × sample rate, is inactive.
  - A band leaving the active set keeps being processed through its 96-sample coefficient fade plus 2 samples to flush its state; then `clearState()` runs and the band is skipped (bit-exact).
  - The default layout is the legacy 32 grid (`ISO_FREQUENCIES`), so nothing changes until Dart sends a layout.
- `RoomDSPEngine`:
  - New: `void setGraphicLayout(const float* centresHz, int count)`, `int graphicBandCount() const`, `float graphicCentreHz(int) const`, `float graphicEffectiveGainDb(int) const`.
  - `setGraphicBandGain` and `setGraphicAllBands` keep their signatures; the gains are nominal dB.
  - `init` and `reset` keep the layout.

- [ ] **Step 1: Write failing host tests** (`CHECK` framework from `native_tests/stereo/stereo_expander_test.cpp`, 48 kHz unless stated):
  - `graphic_q_from_spacing`: `bandQ` on {250, 500, 1000, 2000, 4000}, band 2 → 1.41421 ± 1e-4; band 0 → 1.41421 ± 1e-4. On 1000·2^(k/3), k = 0…4, band 1 → 4.3185 ± 1e-3.
  - `graphic_layout_keeps_gains_by_index`: octave layout 31.25·2^k (k = 0…9) with gains 1…10, then `setLayout` with 15 centres → `bandCount()` == 15; `effectiveGainDb(0…9)` == 1…10; `effectiveGainDb(10…14)` == 0.
  - `graphic_band_boosts_its_centre`: octave layout, band 5 (1000 Hz) at +12 dB.
    - 1 kHz sine, amplitude 0.1: settle 4800 frames, then the peak over the next 4800 frames is 12.0 ± 0.3 dB.
    - 125 Hz sine: 0 ± 0.5 dB.
  - `graphic_flat_is_bit_exact`: all gains 0 → output `memcmp`-equal to input.
  - `graphic_band_off_drains_then_bit_exact`: settled +12 dB on a 1 kHz sine, then `setBandGain(5, 0)`.
    - Across the change, the largest |y[n] − y[n−1]| ≤ 1.1 × the steady-state largest step before the change.
    - After 256 more frames, the output is bit-exact.
  - `graphic_layout_change_without_click`: same sine; switch to 15 ISO centres with the 1000 Hz band (index 8) at +12 dB → largest step ≤ 1.1 × the steady-state largest step.
  - `graphic_gain_clamped`: `setBandGain(0, 20)` → `effectiveGainDb(0)` == 15; −20 → −15.
  - `graphic_band_near_nyquist_bypassed`: `init(32000)`, a layout ending at 20000 Hz with only that band at +12 dB → output bit-exact.
  - `engine_default_layout_is_legacy_32`: a fresh engine → `graphicBandCount()` == 32, `graphicCentreHz(30)` == 18000.
  - `engine_layout_survives_init`: `setGraphicLayout(15 ISO)`, then `init(44100, 2)` → count 15 and `graphicCentreHz(8)` == 1000.
- [ ] **Step 2:** Run `native_tests/eq/run.sh` — expect a compile failure.
- [ ] **Step 3:** Implement `graphic_eq.h`, the `biquad.h` additions and the engine wiring (both copies).
- [ ] **Step 4: Verify.** All `native_tests/*/run.sh` pass with headers identical; NDK and iOS `-fsyntax-only` pass on both engine `.cpp` files.

---

### Task 2: Layout plumbing, replay, and DynamicsProcessing with N bands

**Files:**
- Modify `android/app/src/main/cpp/jni_bridge.cpp`.
- Modify `RoomEffectsProcessor.java`, `GlobalEqSessionManager.java`, `MainActivity.java`.
- Modify both `dsp_bridge.h`, `ios/HypeDSP/src/dsp_bridge.cpp`, `ios/Runner/DSPReplayLog.swift`, `ios/Runner/DSPManager.swift`, `ios/Runner/AppDelegate.swift`.
- Modify `lib/helpers/Channel.dart`.
- Test: `native_tests/ios_replay/replay_test.swift`.

**Interfaces — consumes:** Task 1 `setGraphicLayout`.

**Interfaces — produces:**
- JNI: `private native void nativeSetGraphicLayout(long handle, float[] centresHz, float[] gainsDb)` (`gainsDb` may be null). Layout and gains always travel in one call (controller ruling after Task 1 review: two calls let a block play old gains at new centres).
- `RoomEffectsProcessor`:
  - `static void broadcastGraphicLayout(float[] centresHz, float[] cutoffsHz, float[] gainsDb)` (also updates the cached gains).
  - Caches `cachedGraphicCount` (default 32), `cachedGraphicCentres[32]` (default the legacy grid) and `cachedGraphicCutoffs[32]` (default = the legacy centres, which is today's DynamicsProcessing behaviour).
  - `applyCachedParams` replays the layout together with the cached gains in one call (a fresh engine after `onReset`/`nativeCreate` otherwise falls back to the 32 layout).
  - Package-private accessors: `getCachedGraphicCount()`, `getCachedGraphicCentres()`, `getCachedGraphicCutoffs()`.
  - Calls `syncGlobalEq()`.
- `GlobalEqSessionManager`:
  - `preEqBandCount` = cached count.
  - `syncAllSessions()` releases and re-attaches the global instance when the count differs from the live instance's.
  - Band i uses `setCutoffFrequency(cutoffs[i])` with gain `graphicGains[i]`.
  - Tone offsets compare against `centres[i]`.
- iOS:
  - `void dsp_set_graphic_layout(void* handle, const float* centresHz, const float* gainsDb, int count)` (`gainsDb` may be NULL).
  - `DSPReplayLog.record(key:superseding:apply:)` drops every key starting with one of the given prefixes, then records.
  - `DSPManager.setGraphicLayout(_ centres: [Float], gains: [Float])` records `"setGraphicLayout"`, superseding `["setGraphicBandGain.", "setGraphicAllBands"]`.
- Channel method `setGraphicLayout {freqs: List<double>, cutoffs: List<double>, gains: List<double>}` on both platforms; iOS ignores `cutoffs`.
- Dart: `Channel.setGraphicLayout(List<double> centresHz, List<double> cutoffsHz, List<double> gainsDb)`.

- [ ] **Step 1: Failing replay test** `layout_supersedes_gains`: record `setGraphicAllBands(A)`, `setGraphicBandGain.3(x)`, then `record("setGraphicLayout", superseding: [...])(L)`, then `setGraphicAllBands(B)`. Replaying onto a fresh fake applies exactly `[layout L (with its gains), allBands B]`, in that order.
- [ ] **Step 2:** Run `native_tests/ios_replay/run.sh` — expect a compile failure.
- [ ] **Step 3:** Implement on both platforms.
- [ ] **Step 4: Verify.** The replay test passes; NDK `-fsyntax-only` on `jni_bridge.cpp`; `swiftc -parse` on the touched Swift files; `flutter analyze`.

---

### Task 3: Equalizer settings model, band layouts and interpolation (pure Dart)

**Files:**
- Create `lib/audio/eq/eq_layout.dart`, `lib/audio/eq/equalizer_settings.dart`, `lib/audio/eq/legacy_eq.dart` (legacy 5/10/16/20 groupings and display frequencies, copied from `BandMapping` for migration only).
- Modify `lib/audio/dsp_core.dart`: expose `bool isExistingInstall(SharedPreferences)` from the existing `_legacyKeys` list; `DspCoreSettings.load` uses it.
- Test: `test/audio/eq_layout_test.dart`, `test/audio/equalizer_settings_test.dart`.

**Interfaces — produces:**
- `eq_layout.dart`:
  - Constants:
    - `const kStandardBandCounts = [5, 10, 12, 15, 16, 24, 31, 32]`
    - `const kIsoBandCounts = {10, 15, 31}`
    - `kIso10 = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]`
    - `kIso15 = [25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000, 16000]`
    - `kIso31` = the 31 1/3-octave centres, 20…20000.
    - `kLegacyIso32` = the old 32 grid (includes 18000).
  - `List<double> logSpacedCentres(int count, double firstHz, double lastHz)`: f_i = first·(last/first)^(i/(n−1)).
  - `List<double> bandCentres(EqualizerSettings s)`.
  - `List<double> platformBandCutoffs(List<double> centres)`: geometric midpoints; the last is 20000 (controller ruling: legacy known-good maximum).
  - `double curveGainAt(List<double> hz, List<double> db, double f)`: linear in log2 f, holds the end values outside the range.
  - `List<double> interpolateCurve(List<double> fromHz, List<double> fromDb, List<double> toHz)`.
  - `int nearestStandardBandCount(int count)`: listed counts are kept; 20 → 24; any other count → the nearest listed one, ties going to the larger.
  - `String bandCountLabel(int count)`: ISO counts read e.g. "10 (ISO)".
- `equalizer_settings.dart`:
  - `enum EqValueLabels { hidden, db, percent }`, with labels "Hidden", "dB", "%".
  - Immutable `class EqualizerSettings` with `copyWith`, `==`, `static EqualizerSettings load(SharedPreferences)` and `Future<void> save(SharedPreferences)`. Every value is normalised in `load` and `copyWith`:

| Field | Type, range | Default | Pref key |
|---|---|---|---|
| `bandCount` | listed counts | 10 new · 32 existing | `eqBandCount` (reused; normalised by `nearestStandardBandCount`) |
| `customBands` | bool | false | `eqCustomBands` |
| `customCount` | int 5…32 | 10 | `eqCustomCount` |
| `firstHz` | 5…200, whole Hz | 20 | `eqFirstHz` |
| `lastHz` | 14000…20000, 500 steps | 16000 | `eqLastHz` |
| `bassFreq` | 20…250 | 90 new · 80 existing | `bassFreq` (reused) |
| `bassQ` | 0.10…2.00 | 0.80 new · 0.707 existing | `bassQ` (reused) |
| `trebleFreq` | 5000…15000 | 10000 | `trebleFreq` (reused) |
| `trebleQ` | 0.10…2.00 | 0.60 new · 0.707 existing | `trebleQ` (reused) |
| `eqValues` | `EqValueLabels` | `db` | `eqValueLabels` |
| `toneValues` | `EqValueLabels` | `percent` | `toneValueLabels` |
| `autoSave` | bool | true | `eqAutoSave` |
| `smoothGains` | bool | true | `eqSmoothGains` |
| `suggestAutoEq` | bool | true | `eqSuggestAutoEq` |

  - `bool get usesFirstLast => customBands || !kIsoBandCounts.contains(bandCount)`.
  - `static double normBassGainDb(double v)` clamps 0…22.5; `normTrebleGainDb` clamps 0…15 (used from Task 6).

- [ ] **Step 1: Failing tests.**
  - Layouts:
    - Default settings → `bandCentres` == `kIso10`.
    - `bandCount` 31 → `kIso31` (length 31, first 20, last 20000).
    - `logSpacedCentres(5, 20, 16000)` → [20, 106.37, 565.69, 3008.47, 16000] ± 0.01.
    - `bandCount` 24 → first 20, last 16000, length 24.
    - Custom on, count 7, 30–18000 → `logSpacedCentres(7, 30, 18000)`.
    - `platformBandCutoffs([1000, 2000, 4000])` → [1414.21, 2828.43, 20000] ± 0.01.
  - Interpolation:
    - From [100, 1000] / [0, 10] onto [316.228] → 5.0 ± 1e-6.
    - Onto [50] → 0; onto [2000] → 10.
    - Onto the source frequencies → the source gains exactly.
  - Counts: `nearestStandardBandCount` 20 → 24; 32 → 32; 5 → 5; 7 → 5; 11 → 12.
  - Settings:
    - Empty prefs → every default above.
    - Prefs with any legacy key (e.g. `isShuffled`) but no `eqBandCount` → 32, bass 80 / 0.707, treble Q 0.707.
    - `eqBandCount: 20` → 24.
    - Clamps: firstHz 3 → 5, 250 → 200, 37.6 → 38; lastHz 13000 → 14000, 21000 → 20000, 16200 → 16000; customCount 4 → 5, 40 → 32; bassFreq 500 → 250; bassQ 3 → 2.0; trebleFreq 1000 → 5000.
    - `save` → `load` round-trips.
    - `usesFirstLast`: 10 → false, 12 → true, custom → true.
- [ ] **Step 2:** Run `flutter test test/audio/eq_layout_test.dart test/audio/equalizer_settings_test.dart` — expect FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run — PASS; `flutter analyze` shows no new issues; `dsp_core_settings_test.dart` still passes.

---

### Task 4: Presets with per-band frequency and gain, migration, Auto save, Restore (pure Dart)

**Files:**
- Create `lib/audio/eq/eq_presets.dart`. The factory table moves here from `BuiltInPresets`, unchanged, as 32 points on `kLegacyIso32`.
- Test: `test/audio/eq_presets_test.dart`.

**Interfaces — consumes:** Task 3 (`interpolateCurve`, `kLegacyIso32`, legacy groupings, `isExistingInstall`).

**Interfaces — produces:**
- `class EqCurve { final List<double> hz, db; EqCurve onto(List<double> centres); bool sameAs(EqCurve o, {double tol = 0.05}); toJson/fromJson; }`
- `EqCurve legacyCurve(List<double> native32)`: the display points of the coarsest legacy grouping (5, 10, 16, 20) in which every group holds one value; otherwise the 32 points on `kLegacyIso32`.
- `class EqPreset { final String name; final EqCurve curve; final double? preampDb; final List<ParametricPoint> parametric; final bool builtIn; final String? deviceType; }` — `preampDb` null means the preset does not set the preamp (built-ins).
- `List<EqPreset> factoryPresets()`.
- `String uniqueName(String base, Iterable<String> taken)`.
- Immutable `class EqState { final List<EqPreset> presets; final String selected; final bool dirty; final EqCurve live; }` with:
  - Queries: `List<String> get visibleNames` (excludes `_device_*`), `bool isBuiltIn(String)`, `EqPreset? preset(String)`.
  - `EqState withLayout(List<double> centres)`: re-interpolates from the selected preset when not dirty, otherwise from `live`. It never writes a preset.
  - `EqState withBandGain(int band, double db, {required bool autoSave})`: auto save writes `live` into the selected preset and leaves dirty false; otherwise dirty becomes true.
  - `EqState withPreamp(double db, {required bool autoSave})`: writes only into a selected preset whose `preampDb` is not null.
  - `EqState applyPreset(String name)`: `live` = the preset's curve on the current centres; dirty false.
  - `EqState saveAs(String name, {double? preampDb})`, `EqState save({double? preampDb})`.
  - `EqState delete(String name)`, `EqState restoreFactory()`, `EqState flatten()`.
  - `EqState withDeviceCurve(EqCurve c)`: `live` = c on the current centres; dirty true; presets untouched (keeps the legacy link-devices path working until plan 5).
  - `static EqState load(SharedPreferences, {required List<double> centres})` (includes migration) and `Future<void> save(SharedPreferences)`.
  - Prefs: `eqPresetsV2` (JSON list, in order), `activePresetName` (reused), `eqPresetDirty`, `eqCurve`. The legacy `graphicBandGains` and `eqPresets` are read once, never written again, and left in place.

- [ ] **Step 1: Failing tests.**
  - New install → presets == the factory list in order; selected "Flat"; `live` = zeros on the given centres; dirty false.
  - Legacy 10-band staircase built from display values [1…10] with `activePresetName: 'Custom'`:
    - User preset "Custom" is created, its curve `hz` == [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000] and `db` == [1…10]; it is selected.
    - `live` on `kIso10` → band 1 == 2.0, band 9 == 10.0, band 0 within 0.03 of 1.0.
  - Legacy `eqPresets {"Mine": {graphicGains: Rock factory values, preamp: 2}}` → user preset Mine with 32 points and `preampDb` 2.
  - A user preset named "Rock" → renamed "Rock (2)"; the built-in Rock is kept.
  - `activePresetName: 'Rock'` with a curve equal to factory Rock → selected Rock and no Custom preset. The same with a curve that differs by 1 dB in one band → Custom created and selected.
  - Auto save on, `withBandGain(3, 4.5)` on Rock → `preset('Rock').curve.db[3]` == 4.5; dirty false.
  - Auto save off → Rock unchanged and dirty true; then `save()` → Rock updated and dirty false.
  - Round trip: `applyPreset('Rock')` on `kIso10`, then `withLayout(kLegacyIso32)` → gains == the factory Rock values exactly (interpolated from the preset, not from `live`).
  - `restoreFactory()`:
    - An edited Rock goes back to factory and a deleted Jazz comes back, in factory order.
    - User presets are untouched.
    - With Rock selected, `live` == factory Rock on the current centres.
  - `delete(selected)` → selected '' and dirty true.
  - `flatten()` after Flat was edited → `live` all 0, selected Flat, Flat's curve all 0.
  - `uniqueName('Custom', {'Custom', 'Custom (2)'})` == 'Custom (3)'.
  - `save` → `load` round-trips, including dirty and the unsaved `live`.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run — PASS; analyze clean.

---

### Task 5: Controller and EQ screen on N real bands

**Files:**
- Create `lib/audio/eq/eq_sync.dart` and `lib/pages/eq_preset_sheet.dart` (the preset sheet lifted out of `graphic_eq_view.dart`, with explicit parameters).
- Modify:
  - `lib/controllers/app_controller.dart`.
  - `lib/pages/graphic_eq_view.dart`: centres and gains from the controller; the dropdown per Decision 12; Flatten → `flattenEq`.
  - `lib/pages/parametric_eq_view.dart`: `_copyFromGraphic` uses `eqCentres[band]`.
  - `lib/pages/Settings.dart`: the band-count `SegmentedButton` becomes a temporary read-out; Task 10 replaces it.
  - `lib/models/eq_models.dart`: delete `BandMapping`, `BuiltInPresets` and the v1 `EqPreset` once grep shows no user; keep `ParametricPoint`.
- Delete `lib/widgets/eq_presets.dart`; it is dead code, referenced only from the commented-out `eq_view.dart`.
- Test: `test/audio/eq_sync_test.dart`, `test/pages/eq_preset_sheet_test.dart`.

**Interfaces — consumes:** Tasks 2–4.

**Interfaces — produces:**
- `eq_sync.dart`: `enum EqPushKind { layout, allGains, bandGain }`; `class EqPush { EqPushKind kind; int? band; List<double>? values; List<double>? cutoffs; List<double>? gains; }` (a layout push carries `values` = centres and `gains`); `List<EqPush> eqPushes(EqState before, EqState after)`.
- `AppController`:
  - Settings: `EqualizerSettings get eqSettings` and `set eqSettings(EqualizerSettings)`. The setter saves; on a layout change it runs `withLayout` and the resulting pushes; on tone frequency/Q changes it calls `Channel.dspSetBass*` / `Channel.dspSetTreble*`.
  - State: `EqState get eq`, `List<double> get eqCentres`, `List<double> get eqGains`, `bool get eqPresetDirty`; `String get activePresetName` becomes read-only (= `eq.selected`, still forwarded to `Channel.updateGlobalEqPreset`).
  - Edits: `void setEqBandGain(int band, double db, {bool persist = true})`, `void commitEqGains()`.
  - Presets: `void flattenEq()`, `void applyEqPreset(String name)` (sets the preamp when `preampDb` is not null), `void saveEqPresetAs(String name)`, `void saveEqPreset()`, `void deleteEqPreset(String name)`, `void restoreEqPresets()`.
  - Persistence: drags pass `persist: false`, write on drag end, with a 1 s debounce safety net (today's pattern).
  - Loading: `_loadSettings` loads `DspCoreSettings` first (it reads the legacy curve for headroom), then `EqualizerSettings`, then `EqState`.
  - Right after that first load, the controller saves `EqualizerSettings` and calls `EqState.saveTo(prefs)` (controller ruling: `detectAndApplyDevicePreset` writes the legacy key `lastOutputDevice` on every launch, so without saving, a fresh install would read as "existing" from its second launch; saving also lands the migration once). `EqState` persistence is `saveTo(prefs)` — `save({preampDb})` is the preset action.
  - `_applyAllDspParams` sends `setGraphicLayout` with the gains (one call).
  - Removed: `eqBandCount` setter, `currentBandMapping`, `displayBandGains`, `setDisplayBandGain`, `setGraphicBandGain`, `setGraphicAllBands`, `applyBuiltInPreset`, `savePreset`, `loadPreset`, `deletePreset`, `savedPresets`, `graphicBandGains`.
- `EqPresetSheet({required List<String> names, required Set<String> builtIns, required String selected, required bool dirty, required bool autoSave, required ValueChanged<String> onApply, required ValueChanged<String> onDelete, required ValueChanged<bool> onAutoSave, required VoidCallback onSave, required VoidCallback onSaveAs})`.

- [ ] **Step 1: Failing tests.**
  - `eqPushes`:
    - Layout 10 → 15 centres → `[layout(15 centres, platformBandCutoffs, 15 gains)]` — one push, gains included.
    - Editing band 3 → `[bandGain(3, 4.5)]`.
    - A preset applied on the same layout → `[allGains]`.
    - No change → `[]`.
  - Sheet:
    - Built-in and user names are shown.
    - With dirty true, the selected tile reads "Rock *" and a "Save" button appears.
    - "Save" is absent while `autoSave` is true.
    - Toggling "Auto save" reports false.
    - Delete on the built-in "Jazz" calls `onDelete('Jazz')`.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3:** Implement the helper, the sheet and the controller and view rewiring; `grep -rn "BandMapping\|BuiltInPresets\|displayBandGains" lib` returns nothing.
- [ ] **Step 4: Verify.** `flutter test` shows only the two known failures; `flutter analyze` shows no new issues.

---

### Task 6: Smooth equalizer/tone gains — engine stage, tone range, setting

**Files:**
- Create `smooth_gains.h` (both copies).
- Modify `tone_controls.h` (both copies, made byte-identical), `room_dsp_engine.h/.cpp` (both), `jni_bridge.cpp`, `RoomEffectsProcessor.java`, `MainActivity.java`, both `dsp_bridge.h`, `dsp_bridge.cpp`, `DSPManager.swift`, `AppDelegate.swift`, `Channel.dart`, `app_controller.dart` (bass setter clamp via `normBassGainDb`; push `smoothGains`), `tone_view.dart` (bass knob `max: 22.5`).
- Test: `native_tests/eq/eq_test.cpp`; `test/audio/equalizer_settings_test.dart`.

**Interfaces — produces:**
- `smooth_gains.h`:
  - `struct SmoothScales { float eqDb; float bassDb; };`
  - `constexpr float kEqScaleOffDb = 15.f, kBassScaleOffDb = 22.5f;`
  - `inline SmoothScales smoothGainScales(float levelDb, bool on)`:
    - Off → (15, 22.5).
    - On → eq = T > −3 ? 12.5 − T·(100/120) : 15; bass = T > −8 ? 15 − 0.75·T : 22.5.
    - Each result is floored at 0.
- `ToneControls`:
  - `void setGainScale(float bassFactor, float trebleFactor)`.
  - Clamps: bass gain 0…22.5, treble gain 0…15, bass freq 20–250, Q 0.1–2, treble freq 5000–15000.
  - `float effectiveBassGainDb() const`, `float effectiveTrebleGainDb() const`.
- `RoomDSPEngine`:
  - `void setSmoothGains(bool on)` (default off until Dart pushes).
  - `void setSystemVolumeDb(float dB)` (clamp −96…0; default 0).
  - `float smoothLevelDb() const`: T = (preamp if applied) + masterVolumeDb + systemVolumeDb + headroomDb.
  - `SmoothScales smoothScales() const`.
  - The private `updateSmoothScales()` runs from the preamp, headroom, master volume, system volume, smooth, EQ-enabled and speaker-EQ setters. It sets the graphic factor to eqDb/15 and the tone factors to bassDb/22.5 and eqDb/15. It never runs per block.
- JNI: `nativeSetSmoothGains(long, boolean)`, `nativeSetSystemVolumeDb(long, float)`, `static native float[] nativeSmoothScales(float levelDb, boolean on)`.
- Java: `broadcastSmoothGains(boolean)` (cache default false) and `broadcastSystemVolumeDb(float)` (cache default 0), both replayed in `applyCachedParams` and both calling `syncGlobalEq()`.
- iOS: `dsp_set_smooth_gains(void*, bool)`, `dsp_set_system_volume_db(void*, float)`; `DSPManager.setSmoothGains(_:)` and `DSPManager.setSystemVolumeDb(_:)`, both recorded.
- Channel `dspSetSmoothGains {enabled}`; Dart `Channel.dspSetSmoothGains(bool)`.

- [ ] **Step 1: Failing tests.**
  - `smooth_scales_follow_the_rule`:
    - Off → (15, 22.5) for T ∈ {−40, 0, 6}.
    - On:

| T (dB) | eqDb | bassDb |
|---|---|---|
| 0 | 12.5 | 15 |
| −2.9 | 14.9167 | 17.175 |
| −3 | 15 | 17.25 |
| −7.9 | 15 | 20.925 |
| −8 | 15 | 22.5 |
| +6 | 7.5 | 10.5 |
| +24 | 0 | 0 |

    - All values ± 1e-3.
  - `engine_scales_band_with_volume`:
    - 10-octave layout, band 5 at +12, smooth on, EQ on, preamp/master/headroom/system 0 → `graphicEffectiveGainDb(5)` == 10.0 ± 1e-4, with no `process()` call in between.
    - `setSystemVolumeDb(-10)` → 12.0.
    - Smooth off at T = 0 → 12.0.
    - The 1 kHz sine measurement at T = 0 → 10.0 ± 0.3 dB.
  - `t_counts_preamp_only_while_applied`: preamp +6, headroom −6, EQ on → T == 0. EQ off with speaker EQ off → T == −6.
  - `t_counts_master_volume`: master −2 → eqDb 14.1667 ± 1e-3.
  - `tone_bass_range`: `setBassGain(30)` → nominal 22.5; at T = 0 with smooth on → `effectiveBassGainDb` == 15.0.
  - `scale_change_without_click`: steady 1 kHz sine through +12 dB, change the system volume from −10 to 0 → largest step ≤ 1.1 × the steady largest step.
  - Dart: `normBassGainDb(30)` == 22.5, `normBassGainDb(-1)` == 0, `normTrebleGainDb(20)` == 15.
- [ ] **Step 2:** Run `native_tests/eq/run.sh` and the Dart test — expect FAIL.
- [ ] **Step 3:** Implement the engine, bridges and Dart pushes (on change and in the apply-all path).
- [ ] **Step 4: Verify.** All native tests pass with headers identical (`tone_controls.h` now `cmp`-equal); syntax checks pass; `flutter analyze` clean.

---

### Task 7: The volume source on each platform

**Files:**
- Create `android/app/src/main/kotlin/x/a/zix/SystemVolumeObserver.java` and `ios/Runner/SystemVolume.swift` (registered in `project.pbxproj` as in Task 0).
- Modify `MainActivity.java` (start it in `configureFlutterEngine`), `GlobalEqService.java` (start in `onCreate`), `DvcController.java` (`enable`/`disable` call `SystemVolumeObserver.refresh()`), `DSPManager.swift` (start KVO in `initialize`), `native_tests/ios_replay/run.sh` (also compile `SystemVolume.swift`).
- Test: `native_tests/ios_replay/replay_test.swift`.

**Interfaces — consumes:** `RoomEffectsProcessor.broadcastSystemVolumeDb`, `DSPManager.setSystemVolumeDb` (Task 6).

**Interfaces — produces:**
- Android `SystemVolumeObserver`:
  - `static void start(Context)` is idempotent and uses the application context. It registers a `ContentObserver` on `Settings.System.CONTENT_URI` (descendants) and an `AudioDeviceCallback`.
  - `static void refresh()`.
  - `static float currentMusicDb(AudioManager am)`:
    - 0 while `DvcController.isActive()`.
    - Index 0 → −96.
    - API ≥ 28 → `getStreamVolumeDb(STREAM_MUSIC, index, deviceType)`. `deviceType` comes from `AudioOutputDetector`: bluetooth → `TYPE_BLUETOOTH_A2DP`, wired_headphone → `TYPE_WIRED_HEADPHONES`, usb_audio → `TYPE_USB_HEADSET`, otherwise `TYPE_BUILTIN_SPEAKER`.
    - On an exception, or below API 28 → 20·log10(index/max).
    - The result is clamped to −96…0.
  - It pushes only changes larger than 0.01 dB.
- iOS: `enum SystemVolume { static func db(fromOutputVolume v: Float) -> Float }` returns 20·log10 v floored at −96 (v ≤ 0 → −96). `DSPManager` observes `AVAudioSession.sharedInstance()` `\.outputVolume` with `[.initial, .new]` and calls `setSystemVolumeDb`.
- For plan 5: these observers are the volume source "Pause/resume on volume" will reuse.

- [ ] **Step 1: Failing test** `system_volume_db`: 1.0 → 0.0; 0.5 → −6.0206 ± 1e-3; 0.0 → −96; 1e-6 → −96.
- [ ] **Step 2:** Run `native_tests/ios_replay/run.sh` — FAIL.
- [ ] **Step 3:** Implement both observers.
- [ ] **Step 4: Verify.** The test passes; `swiftc -parse` passes; `plutil -lint` OK; `grep -c "SystemVolume.swift in Sources"` == 2.

---

### Task 8: Value labels on the EQ and Tone screens

**Files:**
- Create `lib/audio/eq/eq_labels.dart`.
- Modify `lib/pages/graphic_eq_view.dart` (`_BandSlider` takes `String? valueLabel`), `lib/widgets/tone_knob.dart` (`String? valueText`; null hides it), `lib/pages/tone_view.dart` (labels and the info row from `eqSettings`).
- Test: `test/audio/eq_labels_test.dart`.

**Interfaces — produces:** `String? eqValueLabel(double db, EqValueLabels mode)`; `String? toneValueLabel(double db, {required bool bass, required EqValueLabels mode})`. Percent is X × 100, with X = db/15 (EQ, treble) or db/22.5 (bass).

- [ ] **Step 1: Failing tests.**
  - `eqValueLabel`: (6, db) == '+6.0'; (−4.5, db) == '-4.5'; (0, db) == '0.0'; (6, percent) == '+40%'; (−15, percent) == '-100%'; (0, percent) == '0%'; (6, hidden) == null.
  - `toneValueLabel`: (9, bass: true, percent) == '40%'; (9, bass: false, percent) == '60%'; (9, bass: true, db) == '9.0 dB'; (0, bass: true, db) == '0.0 dB'; hidden → null.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3:** Implement and wire.
- [ ] **Step 4:** `flutter test` shows only the known failures; analyze clean.

---

### Task 9: Suggest AutoEq presets

**Files:**
- Modify `pubspec.yaml`: add `audio_session: ^0.2.4` as a direct dependency (matching the lock), then run `flutter pub get`.
- Create `lib/audio/eq/autoeq_suggest.dart` and `lib/services/autoeq_suggestions.dart`.
- Modify `app_controller.dart`: start and dispose the service; add `resetAutoEqSuggestions()`.
- Test: `test/audio/autoeq_suggest_test.dart`.

**Interfaces — consumes:** `SpeakerProfile`, `AppController.applySpeakerProfile`, `eqSettings.suggestAutoEq`, `systemWideActive` (stub `false` until Task 11), `ConnectUiHost.navigatorKey`.

**Interfaces — produces:**
- `autoeq_suggest.dart`:
  - `enum OutputKind { bluetooth, usb, other }`; `class OutputDeviceEvent { final String name; final OutputKind kind; }`.
  - `String normaliseDeviceName(String)`: lower case, parenthesised text removed, only `[a-z0-9]` kept.
  - `SpeakerProfile? matchAutoEqProfile(String deviceName, List<SpeakerProfile> profiles)`, following Decision 13; names shorter than 4 characters → null.
  - `SpeakerProfile? autoEqSuggestion({required OutputDeviceEvent device, required bool enabled, required bool systemWide, required Set<String> dismissed, required Set<String> askedThisSession, required String? activeProfile, required List<SpeakerProfile> profiles})`.
  - `class AutoEqDismissals { static Set<String> load(SharedPreferences); static Future<void> add(SharedPreferences, String deviceName); static Future<void> reset(SharedPreferences); }`, stored under pref `eqAutoEqDismissed` (StringList of normalised names).
- `AutoEqSuggestions(AppController app, {Stream<OutputDeviceEvent>? devices})`:
  - By default it maps `AudioSession.instance.devicesChangedEventStream.devicesAdded`: outputs of type `bluetoothA2dp` or `bluetoothLe` → bluetooth, `usbAudio` → usb, everything else ignored; deduplicated by normalised name.
  - It shows a dialog: "Apply" (`applySpeakerProfile`), "Not now" (session only) and "Don't ask for this device" (`AutoEqDismissals.add`).
  - `start()`, `dispose()`.

- [ ] **Step 1: Failing tests.** Fixture profiles: Sony WH-1000XM4, Sony WH-1000XM4 (ANC Off), Apple AirPods, Apple AirPods Pro, Apple Airpods Pro 2, Samsung Galaxy Buds Pro, FlipEars Aegis, Cardas A8.
  - Matching:
    - "WH-1000XM4" → Sony WH-1000XM4.
    - "Bruno's AirPods Pro" → Apple AirPods Pro.
    - "Galaxy Buds Pro (A1B2)" → Samsung Galaxy Buds Pro.
    - "JBL Flip 5" → null; "Pro" → null.
  - Gating — each of these returns null: `enabled` false; `systemWide` true; the name in `dismissed`; the name in `askedThisSession`; `activeProfile` == the match; kind `other`. The happy path returns the profile.
  - Dismissals: `add('WH-1000XM4')` → `load` contains 'wh1000xm4'; `reset` → empty.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run — PASS; `flutter analyze` shows no new issues (no `depend_on_referenced_packages`).

---

### Task 10: Settings → Equalizer page

**Files:**
- Create `lib/pages/equalizer_settings_section.dart`, styled like `crossfade_settings_section.dart` (cards, a bottom-sheet chooser for Number of bands and the two value-label choices).
- Modify `lib/pages/Settings.dart`:
  - The Equalizer category becomes the Global EQ section (Android) plus this section.
  - Remove `_buildEqualizerSection` and the frequency/Q rows from `_buildToneSection`; the tone on/off switch and the Limiter stay.
  - Add `SettingsEntry` rows (`SettingsCategory.equalizer`) for every label.
- Test: `test/pages/equalizer_settings_section_test.dart`.

**Interfaces — consumes:** `EqualizerSettings`, `bandCountLabel`, `AppController.eqSettings`, `restoreEqPresets()`, `resetAutoEqSuggestions()`.

**Interfaces — produces:** `EqualizerSettingsSection({required EqualizerSettings settings, required ValueChanged<EqualizerSettings> onChanged, required VoidCallback onResetAutoEqSuggestions, required VoidCallback onRestorePresets})`.
- `static const labels`: Number of bands, Enable custom bands, Custom number of bands, First frequency, Last frequency, Bass frequency, Bass Q, Treble frequency, Treble Q, Equalizer values, Tone values, Auto save, Smooth equalizer/tone gains, Suggest AutoEq presets, Reset disabled AutoEq suggestions, Restore equalizer presets.
- Sliders:
  - Custom count 5–32, step 1.
  - First 5–200 Hz, 1 Hz steps, shown "20 Hz".
  - Last 14.0–20.0 kHz, 0.5 kHz steps, shown "16.0 kHz".
  - Bass frequency 20–250 Hz, 10 Hz steps.
  - Treble frequency 5000–15000 Hz, 1 kHz steps.
  - Q 0.10–2.00, 0.05 steps, shown `%.2f`.
- Dimmed rows (not hidden): Number of bands while custom is on; Custom number while custom is off; First/Last while `!usesFirstLast`.
- Restore asks for confirmation.

- [ ] **Step 1: Failing widget tests.**
  - Every label renders.
  - Choosing "24" in the Number of bands chooser reports `bandCount` 24.
  - With custom off, "Custom number of bands" is dimmed and does not report changes; with `bandCount` 10, First/Last are dimmed; with 12 they are active.
  - Restore → Cancel never calls `onRestorePresets`; → Confirm calls it once.
  - "Reset disabled AutoEq suggestions" calls its callback.
  - Every entry in `labels` has a `kSettingsIndex` entry under `SettingsCategory.equalizer`.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3:** Implement and mount.
- [ ] **Step 4:** `flutter test` shows only the known failures; analyze clean. In equalizer-only mode the Equalizer category is still listed (`_visibleCategories`, unchanged).

---

### Task 11: Android system-wide mode carries what it can; the rest is disabled with a reason

**Files:**
- Modify `room_dsp_engine.h/.cpp` (both copies; iOS never sets the flag), `jni_bridge.cpp`, `RoomEffectsProcessor.java`, `GlobalEqSessionManager.java`.
- Modify `lib/audio/dsp_core.dart`, `app_controller.dart`, `lib/pages/volume_controls.dart`, `lib/pages/space_view.dart` (stereo expand slider), `lib/pages/Settings.dart` (DVC rows), and plan 2's `lib/pages/replay_gain_settings_section.dart` (`String? disabledReason`).
- Test: `native_tests/eq/eq_test.cpp`, `test/audio/dvc_routing_test.dart`, `test/pages/volume_controls_test.dart`.

**Interfaces — produces:**
- `RoomDSPEngine::setPlatformEqActive(bool)` and `bool platformEqActive() const`.
  - While on, these run neutral: graphic EQ, tone, the user-preamp and headroom terms, track gain, balance, mono, stereo expand.
  - These are unchanged: speaker EQ and its preamp, parametric EQ, MBC, crossfeed, surround, reverb, **master volume**, limiter.
  - The stored values are kept and come back when the flag goes off.
- JNI: `nativeSetPlatformEqActive(long, boolean)`. `broadcastGlobalEqActive` caches it, applies it to every instance, replays it, and stops masking the EQ-enabled flag.
- `GlobalEqSessionManager.applyState`:
  - Input gain = (EQ on ? preamp : 0) + cached headroom.
  - T = that preamp + cached system volume dB + headroom; scales from `RoomEffectsProcessor.nativeSmoothScales(T, cachedSmoothGains)`.
  - Band i gain = nominal × eqDb/15, plus (tone on) bass × bassDb/22.5 where centre ≤ bassFreq, plus treble × eqDb/15 where centre ≥ trebleFreq.
  - Limiter per Decision 15. The unused ceiling/release caches are removed.
- Dart:
  - `bool dvcInEffect({required bool isAndroid, required bool dvcEnabled, required bool systemWide})`.
  - `List<DvcStep> systemWideDvcSteps({required bool systemWideOn, required bool dvcEnabled})`: on with DVC → `dvcToggleSteps(enable: false)`; off with DVC → `dvcToggleSteps(enable: true)`; DVC off → `[]`.
  - `const kSystemWideReason = 'Not available while the equalizer applies to all apps'`.
  - `AppController.systemWideActive` (Android && global EQ on).
  - The `globalEqEnabled` setter runs `systemWideDvcSteps` and re-pushes the headroom.
  - The startup DVC enable, `_pushHeadroom`, `_pushMasterVolume` and the volume-key handling all use `dvcInEffect`.
  - The stored `dvcEnabled` value is never changed.
- `VolumeControls({..., String? disabledReason})` disables Balance and Mono and shows the reason; Tempo and Reset stay usable. The Stereo Expand slider, the DVC switch/volume/steps rows and `ReplayGainSettingsSection` take the same reason.

- [ ] **Step 1: Failing tests.**
  - `platform_eq_neutralises_engine_stages`:
    - Setup: graphic +12 band, EQ on, tone on with bass 10, preamp +6, headroom −6, track gain −10, balance −1, mono, expand 1.0, limiter off; `setPlatformEqActive(true)`.
    - After 2048 settling frames, an input of L 0.3 / R −0.2 comes out unchanged (± 1e-6).
    - `setPlatformEqActive(false)` brings back balance −1 (R == 0).
  - `platform_eq_keeps_speaker_preamp_and_master`: speaker EQ on, speaker preamp −6, user preamp +6, master −12, platform on → output = input × 10^(−18/20) (± 1e-5). The user preamp is excluded, so it is not applied twice.
  - Dart:
    - `dvcInEffect(true, true, false)` → true; `(true, true, true)` → false; `(false, true, false)` → false.
    - `systemWideDvcSteps(on: true, dvc: true)` == `[disableDvc, pushMasterVolume]`; `(on: false, dvc: true)` == `[pushMasterVolume, flushIfPaused, enableDvc]`; `(on: true, dvc: false)` == `[]`.
  - Widget: with `disabledReason: 'X'`, "X" is shown, dragging Balance and tapping Mono report nothing, and Tempo `+` still reports 1.05. Without a reason, behaviour is unchanged.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4: Verify.** All `native_tests/*/run.sh` pass; NDK and iOS syntax checks pass; `flutter test` shows only the two known failures; `flutter analyze` shows no new issues against the Task 0 baseline. `grep -rni` for the reference app's name over the changed files returns nothing.

### Critical Files for Implementation
- /Users/bruno/me/COTE/hype/android/app/src/main/cpp/room_dsp_engine.cpp (and /Users/bruno/me/COTE/hype/ios/HypeDSP/src/room_dsp_engine.cpp)
- /Users/bruno/me/COTE/hype/android/app/src/main/kotlin/x/a/zix/RoomEffectsProcessor.java
- /Users/bruno/me/COTE/hype/android/app/src/main/kotlin/x/a/zix/GlobalEqSessionManager.java
- /Users/bruno/me/COTE/hype/lib/controllers/app_controller.dart
- /Users/bruno/me/COTE/hype/ios/Runner/DSPManager.swift (plus /Users/bruno/me/COTE/hype/ios/Runner.xcodeproj/project.pbxproj for Task 0)
