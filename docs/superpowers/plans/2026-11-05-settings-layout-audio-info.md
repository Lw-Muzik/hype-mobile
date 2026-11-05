# Settings layout + Audio Info Implementation Plan (plan 6 of 6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Spec "Target settings tree" + §1 Audio Info: one **Audio** category whose page lists the audio sub-pages in the spec's order, the existing Equalizer and Tone & Effects categories folded into it (nothing lost), Headset & Bluetooth kept as its own category, and a read-only Audio Info page opened from Settings → Audio and by long-pressing the equalizer page's title.

**Spec:** `docs/superpowers/specs/2026-11-05-audio-settings-design.md` — "Target settings tree", §1 Audio Info, the Equalizer-only app mode paragraph (Equalizer, Direct Volume Control, Advanced Tweaks, Effects and Audio Info (DSP part only) shown; Crossfade, Replay Gain, Audio Focus, Headset & Bluetooth, per-output hidden).

## Global Constraints

Same as plan 5 (`docs/superpowers/plans/2026-11-05-dvc-advanced-per-output.md` Global Constraints): no app builds; analyze no new issues vs 135; flutter test only the two known failures; javac / swiftc -parse / plutil where native changes; NDK + iOS `-fsyntax-only` and `native_tests/*/run.sh` if the C++ engine changes (both copies byte-identical); never name the reference app; Android + iOS; no render-thread locks; package `eq_app`; repo casing `lib/Helpers/`, `lib/Global/`; no commits until the owner confirms.

## Review Focus

1. Nothing a user could reach before is lost: every former Equalizer / Tone & Effects / Playback-audio row and page is reachable under Audio, and every `kSettingsIndex` search result opens the page that holds it (Task 2 cross-index test).
2. Equalizer-only app mode shows exactly the spec's list (Task 2).
3. Audio Info never blocks the UI or the audio thread: values come from a cheap snapshot (getters / atomics), polled ≤ 4 Hz while the page is visible, stopped when it closes (Task 1).
4. Audio Info shows the stages in the engine's real chain order, only those active, with their key values; "limiter currently reducing" is live (Task 1).
5. iOS shows only what iOS has (no DVC, no system-wide mode rows); Android-only rows stay hidden on iOS in pages and search (Task 2).

---

### Task 1: Audio Info page (Both)

**Files:** Create `lib/audio/info/audio_info.dart` (pure model + `List<InfoStage> describeChain(...)`), `lib/pages/audio_info_page.dart`, tests `test/audio/audio_info_test.dart`, `test/pages/audio_info_page_test.dart`. Modify (engine, both copies) `room_dsp_engine.h/.cpp` — add a read-only `limiterReductionDb()` (atomic, written by the limiter on the audio thread, read from the control thread) if not present; JNI `nativeGetLimiterReductionDb` + iOS `dsp_get_limiter_reduction_db`; Channel method `getAudioInfo {playerId}` returning `{sampleRate, channels, encoding/codec, bitrate?, limiterReductionDb}` from the current player's engine/processor (Android: RoomEffectsProcessor input format + ExoPlayer format where available; iOS: the tap's processing format + AVPlayerItem asset track info), `lib/Helpers/Channel.dart`, `MainActivity.java`, `AppDelegate.swift`/`DSPManager.swift`.
- The page shows: **Source** (file/stream/cloud/video, codec, sample rate, channels, bitrate where reported); **Processing** — the active DSP stages in chain order with key values: input gain parts (track/Replay Gain dB and which tag source — album/track/untagged preamp —, user preamp, headroom, speaker preamp), speaker EQ, graphic EQ (band count + layout name), parametric EQ (points), tone (bass/treble dB), MBC, crossfeed, surround, reverb (preset), master volume (DVC dB when running), stereo expand (%), mono, balance, limiter (on/off and "reducing x dB" live); system-wide mode note on Android; **Output** route (speaker/wired/Bluetooth/USB + device name).
- Values come from AppController getters (already there for every setting) + one `getAudioInfo` call polled every 250 ms only while the page is visible.
- Equalizer-only mode: DSP part only (no Source / Replay Gain lines).
- Opened from Settings → Audio (Task 2) and by long-pressing the equalizer page's title (lib/pages/Equalizer.dart app bar title).
- [ ] Tests first: `describeChain` order and inclusion rules (inactive stages omitted, values formatted), Replay Gain source line, EQ-only filtering; page renders with a fake info source; polling stops on dispose. Native: engine host test for `limiterReductionDb` (> 0 while a 0 dBFS+6 sine is limited, 0 when quiet), headers identical, syntax checks.

### Task 2: Audio category + folding (Both)

**Files:** Modify `lib/pages/Settings.dart` (categories, index, `_visibleCategories`, `_buildCategory`), create `lib/pages/audio_settings_page.dart` if a separate page helps; tests `test/pages/settings_layout_test.dart`.
- New `SettingsCategory.audio` (group SOUND) whose page lists, in this order: **Audio Info**, **Crossfade, Fade & Gapless**, **Replay Gain**, **Audio Focus**, **Equalizer** (the former Equalizer category's content: Global EQ section + EqualizerSettingsSection), **Direct Volume Control** (DvcSettingsSection), **Advanced Tweaks** (AdvancedSettingsSection), **Outputs** (OutputProfilesPage), **Effects** (the existing Space, Dynamics and Speaker Correction pages + the former Tone & Effects content: tone switch, limiter, VolumeControls balance/mono/tempo). Each entry opens its sub-page (reuse the existing section widgets).
- Remove the `equalizer`, `tone` and `crossfade` categories (their content now lives under Audio) and move Audio Focus + Replay Gain out of Playback into Audio; `headset` stays its own category; Playback keeps Autoplay etc.
- Every `kSettingsIndex` entry previously in `equalizer`/`tone`/`crossfade`/playback-audio moves to `SettingsCategory.audio` with a sub-page key so a search result opens the right sub-page (add a `String? subPage` to `SettingsEntry` if needed).
- Equalizer-only mode: Audio page shows only Audio Info (DSP part), Equalizer, Direct Volume Control, Advanced Tweaks, Effects; App mode + About stay.
- [ ] Tests first: Audio page order; EQ-only list; every former label reachable (a table of every pre-move label → its new sub-page); search opens the sub-page; Android-only rows hidden on iOS; no category left empty. Then implement; full test + analyze.
