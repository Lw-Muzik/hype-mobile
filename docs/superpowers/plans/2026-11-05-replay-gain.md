# Replay Gain Implementation Plan (plan 2 of 6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Hype's MP3-only, track-only replay gain with the spec's Replay Gain (Don't apply / Apply gain / Apply gain, prevent clipping by peak; Album / Track; RG preamp; preamp for untagged songs), applied per player inside the engine — and first close the DVC-while-paused blast left by plan 1.

**Architecture:** A pure-Dart tag reader (MP3/FLAC/OGG/Opus/M4A) and a pure gain function feed `Channel.dspSetTrackGainDb(playerId, dB)` (plan 1) for whichever player is about to play the track. The handler remembers each player's gain and re-sends it when just_audio rebuilds that player under a new platform id. The old linear replay gain on the player volume goes.

**Tech Stack:** Dart/Flutter; Java (task 0).

**Spec:** `docs/superpowers/specs/2026-11-05-audio-settings-design.md` §3 Replay Gain. Plan 1 ledger: `.superpowers/sdd/2026-11-05-audio-dsp-core/progress.md` (task 0 comes from its parked items).

## Global Constraints

- No app builds; verify with `flutter analyze` (no new issues vs 138), `flutter test` (only `widget_test.dart` and `intro_splash_test.dart` may fail), syntax-only native checks.
- Do not name the reference app anywhere in the repo.
- Both platforms; no commits until the owner confirms (leave changes in the working tree).
- Existing users keep their sound: a stored `replayGain = true` becomes Apply gain, prevent clipping by peak + Track (owner-relayed note, 2026-11-05: the old switch could only turn songs down); false becomes Don't apply.

## Review Focus

1. A crossfade or skip into a tagged track: the incoming player's engine has that track's gain before its first buffer; the outgoing player keeps its own (Task 3).
2. just_audio rebuilds a player under a new platform id after `stop()`: the gain is re-sent for the new id (Task 3).
3. Malformed or truncated tags never throw out of the reader — it returns empty tags (Task 1 tests).
4. Peak prevention never lets gain + preamp exceed `−20·log10(peak)` (Task 2 test).
5. Streams and cloud tracks without readable tags get the untagged preamp, not 0 dB (Task 2/3 tests).

---

### Task 0: DVC enabled while paused must not blast on resume

**Files:** Modify `android/app/src/main/kotlin/x/a/zix/DvcController.java`, `lib/controllers/app_controller.dart`, `lib/audio/dsp_core.dart`; Test `test/audio/dvc_routing_test.dart`.

- [ ] **Step 1:** In `DvcController.init`, create the `Handler` only `if (handler == null)`, so a pending raise can always be cancelled.
- [ ] **Step 2:** Add a `flushIfPaused` step to `dvcToggleSteps` between the master-volume push and `enableDvc`; update the test to assert the enable order `pushMasterVolume, flushIfPaused, enableDvc`.
- [ ] **Step 3:** Implement `flushIfPaused` in the `dvcEnabled` setter: when the active player has a track loaded (processing state not idle) and is not playing, `await handler.player.seek(handler.player.position)` (a seek in place empties the AudioTrack's buffered unity-gain audio).
- [ ] **Step 4:** `flutter test test/audio` passes; `flutter analyze` no new issues.

### Task 1: Replay Gain tag reader

**Files:** Create `lib/audio/replay_gain/rg_tags.dart`; Test `test/audio/rg_tags_test.dart`.

**Interfaces — produces:**
- `class ReplayGainTags { final double? trackGainDb, trackPeak, albumGainDb, albumPeak; bool get isEmpty; }`
- `Future<ReplayGainTags> readReplayGainTags(String path)` — never throws; empty tags on any error.
- `ReplayGainTags parseReplayGainTags(Uint8List head)` — pure; `readReplayGainTags` supplies the first 256 KiB (and for MP4, the `moov` atom wherever it is).

- [ ] **Step 1: Failing tests** with byte fixtures built in the test:
  - ID3v2.3 `TXXX` `replaygain_track_gain` = `-6.54 dB`, `replaygain_track_peak` = `0.988`, album gain `+1.20 dB`, album peak `1.05` → those four values.
  - FLAC (`fLaC` + VORBIS_COMMENT block) `REPLAYGAIN_TRACK_GAIN=-3.00 dB` (keys case-insensitive) → −3.0.
  - Ogg Vorbis comment packet with album tags → album values.
  - Opus `OpusTags` with `R128_TRACK_GAIN=-512` → `-512/256 + 5` = 3.0 dB.
  - MP4 `moov/udta/meta/ilst/----` (mean `com.apple.iTunes`, name `replaygain_track_gain`, data `-7.10 dB`) → −7.1.
  - Garbage, empty, truncated mid-frame → empty tags, no throw.
- [ ] **Step 2: Run** `flutter test test/audio/rg_tags_test.dart` — FAIL.
- [ ] **Step 3: Implement** the parsers (ID3v2.2–2.4 incl. syncsafe sizes and Latin-1/UTF-16 text; FLAC metadata blocks; first Ogg packets; MP4 atom walk); numbers parse from `"-6.54 dB"`, `"+1.2"`, `"0.988"`.
- [ ] **Step 4: Run** — PASS; analyze clean for the new files.

### Task 2: Settings and the gain rule

**Files:** Create `lib/audio/replay_gain/replay_gain.dart`; Test `test/audio/replay_gain_test.dart`.

**Interfaces — produces:**
- `enum ReplayGainMode { off, apply, applyPreventClipping }` — labels "Don't apply", "Apply gain", "Apply gain, prevent clipping by peak".
- `enum ReplayGainSource { album, track }` — labels "Album", "Track".
- `class ReplayGainSettings { ReplayGainMode mode; ReplayGainSource source; double preampDb; double untaggedPreampDb; copyWith; static ReplayGainSettings load(SharedPreferences); Future<void> save(SharedPreferences); }` — prefs `rgMode`, `rgSource`, `rgPreampDb`, `rgUntaggedPreampDb`; defaults off / album / 0.0 / 0.0; dB clamped −16…+16, snapped to 0.1; legacy bool `replayGain` → true: apply + track, false: off (only when `rgMode` is absent).
- `double replayGainDb(ReplayGainSettings s, ReplayGainTags? tags)`.

- [ ] **Step 1: Failing tests:** off → 0; apply + album, album gain −4, preamp +1 → −3; album chosen but only a track tag → falls back to track; null/empty tags → `untaggedPreampDb`; preventClipping, track gain +6, preamp +2, track peak 0.794 → capped at `-20*log10(0.794)`; peak taken from the same source as the gain used; migration; clamps/snaps; save→load round-trip.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.

### Task 3: Apply it per player in the engine

**Files:** Modify `lib/global/index.dart` (`prepareTrack`, `loadAudioSource`), `lib/helpers/audio_handler.dart`, `lib/controllers/app_controller.dart` (replace `_replayGain` with `ReplayGainSettings`; crossfade loads; gapless index changes; apply-all path); Test `test/audio/rg_player_gain_test.dart`.

**Interfaces:**
- Consumes: `readReplayGainTags`, `replayGainDb`, `Channel.dspSetTrackGainDb(String playerId, double dB)`, `AudioPlayer.playerId`, `AudioPlayer.platformIdStream`.
- Produces: `HypeAudioHandler.setEngineTrackGainDb(AudioPlayer player, double dB)` — remembers the value per player, sends it now, re-sends on every new `platformIdStream` value of that player. `PreparedTrack` gains `final double rgDb`; the player-volume track gain becomes unity for every track. `Future<double> trackGainDbFor({required String path, required ReplayGainSettings settings, Future<ReplayGainTags> Function(String) read = readReplayGainTags})` — pure apart from `read`.

- [ ] **Step 1: Failing tests** for `trackGainDbFor`: a local file (`/…`) uses its tags; `http…` and video ids use the untagged preamp without calling `read`; a `read` that throws → untagged preamp.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement** the helper and the wiring: `prepareTrack` computes `rgDb`; every load sends it via `setEngineTrackGainDb` for the exact player that will play the track (inside the crossfade `load:` closures for the incoming player; `handler.player` for a cut); the gapless queue computes and sends on each `currentIndex` change; a settings change recomputes for the current track. Delete `HypeAudioHandler.computeReplayGainVolume`.
- [ ] **Step 4: Run** `flutter test` (only the two known failures) and `flutter analyze` (no new issues).

### Task 3b: Gapless queue items get their gain at the sample boundary (added after review)

In a gapless queue one player plays every item, and `currentIndex` only moves after the sink has already processed several hundred ms of the next item, so a Dart-side re-gain arrives late and the level steps at each boundary.

**Files:** Modify `lib/helpers/Channel.dart`, `lib/controllers/app_controller.dart` (gapless queue paths), `android/app/src/main/kotlin/x/a/zix/RoomEffectsProcessor.java`, `android/app/src/main/kotlin/x/a/zix/MainActivity.java`, `ios/Runner/HypeAudioTap.h/.m`, `ios/Runner/DSPManager.swift`, `ios/Runner/AppDelegate.swift`; Test `test/audio/rg_player_gain_test.dart` (Dart decision), `native_tests/ios_replay` if Swift logic is added.

**Interfaces — produces:** `Channel.dspSetNextTrackGainDb(String playerId, String uri, double dB)` (method `dspSetNextTrackGainDb {playerId, uri, dB}`).
- Dart: whenever a gapless queue starts at index i or its index moves to i, send the current gain (as today) and then `dspSetNextTrackGainDb` for item i+1 (none when i is last; repeat-one sends item i again, repeat-all wraps). A seek to another item sends current first, then next, then seeks.
- Android: the processor keeps one pending next gain per player. `onSinkStreamChange` applies it as the track gain (updating the per-player cache) and clears it — **only** when at least one buffer has passed since the last flush (a seek's stream change is not a gapless boundary). `onFlush` keeps the pending value.
- iOS: `DSPManager` keeps `uri → dB` per player (latest wins, at most a few entries). An item's tap, on its first process call, looks up its `trackUrl` and, when found, sets that engine's track gain (lock-free; recorded so a reinit replays it).

- [ ] **Step 1:** Failing Dart test for the "which next item" rule (`nextGaplessIndex(index, length, repeatMode)`); run — FAIL.
- [ ] **Step 2:** Implement Dart, Android, iOS; `swiftc -parse` the touched Swift; Java syntax by inspection.
- [ ] **Step 3:** `flutter test` (only the two known failures), `flutter analyze` (no new issues).

### Task 4: Replay Gain settings UI

**Files:** Create `lib/pages/replay_gain_settings_section.dart` — `ReplayGainSettingsSection({required ReplayGainSettings settings, required ValueChanged<ReplayGainSettings> onChanged})`, styled like `crossfade_settings_section.dart` (bottom-sheet choosers for mode and source; sliders −16.0…+16.0 dB, 0.1 dB steps, centre snap at 0, shown `%.1f dB`). Modify `lib/pages/Settings.dart` — replace the "Replay gain" switch in the Playback section with this section; `SettingsEntry` rows "Replay Gain", "Source", "RG preamp", "Preamp for songs without RG info". Test `test/pages/replay_gain_settings_section_test.dart`.

- [ ] **Step 1: Failing widget tests:** the four labels render; choosing "Apply gain" reports `ReplayGainMode.apply`; Source and the preamps are dimmed (not hidden) while mode is off; every `SettingsEntry` for the section names a label on it.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** `flutter test`, `flutter analyze` — only the two known failures, no new issues.
