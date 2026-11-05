# Built-in Spectrum Visualizers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Hype's assorted visualizers with eleven built-in spectrum-bar visualizers that look and move exactly like the recorded reference presets, on Android and iOS, keeping Radial, Waveform, MilkDrop and the bottom-player wave.

**Architecture:** A shared C++ header computes a 512-point Hann-windowed power spectrum (256 bins) from the existing mono tap rings on both platforms and ships it to Dart once per visualizer tick. Pure-Dart units turn the bins into bar values and peaks (analyzer), bar values into triangle meshes with per-vertex colours (geometry), and meshes into frames with MilkDrop-style feedback trails (frame compositor). One parameterised widget draws all eleven presets.

**Tech Stack:** C++17 header-only DSP (NDK + HypeDSP pod), Java (ExoPlayer tap), Objective-C/Swift (MTAudioProcessingTap), Flutter 3.47 / Dart 3.13 (`Canvas.drawVertices`, `Picture.toImageSync`, `ColorFilter.matrix`).

**Spec:** `docs/superpowers/specs/2026-11-05-builtin-visualizers-design.md`

**Reference record (outside the repo, numbers only):** `~/me/COTE/.hype-reference/spectrum-bars-record.md` (formulas §3–§8) and `~/me/COTE/.hype-reference/spectrum-bars-presets.json` (every preset field). Section numbers below (§4.1 etc.) point into the record.

## Global Constraints

- Do not name the reference app anywhere in the repo: code, comments, tests, docs, file names, commit messages. Never copy the record's wording; take only numbers and formulas.
- Every header shared by `android/app/src/main/cpp` and `ios/HypeDSP/src` stays byte-identical; `ios/HypeDSP/include/dsp_bridge.h` and `ios/HypeDSP/src/dsp_bridge.h` stay byte-identical.
- The same Dart code draws every preset on both platforms (anti-goal: a visualizer that differs between Android and iOS).
- Hold 30 fps at the current visualizer frame rate on mid-range phones: no per-frame allocation in hot loops beyond the mesh buffers (grow-only, reused).
- Style ids: `radial`, `line`, `spectrum_plain`, `spectrum_narrow`, `spectrum_wide`, `spectrum_centered`, `spectrum_centered_narrow`, `spectrum_centered_wide`, `spectrum_centered_reflected`, `spectrum_reflected_wide`, `spectrum_quads_narrow`, `spectrum_quads_reflected`, `spectrum_dots`, `milkdrop` (Android only). Display names: `Radial`, `Waveform`, `Spectrum Plain`, `Spectrum Narrow`, `Spectrum Wide`, `Spectrum Centered`, `Spectrum Centered Narrow`, `Spectrum Centered Wide`, `Spectrum Centered Reflected`, `Spectrum Reflected Wide`, `Spectrum Quads Narrow`, `Spectrum Quads Reflected`, `Spectrum Dots`, `MilkDrop`.
- MilkDrop, its presets, Radial and the bottom-player wave (`MultiWaveVisualizer`) keep working unchanged.
- **No git commits** on `feat/crossfade-and-fades` until the owner says so (the branch carries uncommitted Plans 5+6). Builders never run `git commit`, `git stash`, `git checkout`, `git restore` or `git add`. The controller snapshots the tree for reviews.
- Never run Gradle/Xcode builds in a task (the owner may be building). Verification is `flutter test`, `flutter analyze`, host `clang++` tests and `clang -fsyntax-only`.
- Analyzer must not gain issues: `flutter analyze` total stays ≤ 134.

## Review Focus

1. **Playback paused / between tracks / tap stalls** — bars must fall to the floor and trails fade, not freeze mid-air. Pinned in Task 7 (`stall feeds silence until the bars settle`).
2. **A removed style restored from prefs** (`bars`, `terrain`, `neon_grid`, legacy `circular`, or `milkdrop` on iOS) — opens as Radial, never crashes. Pinned in Task 8 (`migrateVisualizerStyle` tests).
3. **Hi-res sources (88.2/96/176.4/192 kHz)** — bars cover the same frequencies as at 44.1/48 kHz. Pinned in Task 1 (`decimation table`, `decimated block equals hand-averaged block`) and Task 2 (96 kHz peak bin).
4. **Switching preset mid-song** — no stale peaks, no old trail smeared into the new layout, bar levels carry over. Pinned in Task 7 (`preset change resets peaks and trail, keeps bars`).
5. **Rotation / resize** — the trail image is never stretched across a new size, and bar geometry re-snaps to the new pixel grid. Pinned in Task 7 (`resize drops the trail`).

---

## File Structure

| File | Responsibility |
|---|---|
| `android/app/src/main/cpp/bar_spectrum.h` (+ identical `ios/HypeDSP/src/bar_spectrum.h`) | Decimate, window, 512-pt FFT, 256 bin powers |
| `native_tests/bar_spectrum/{bar_spectrum_test.cpp,run.sh}` | Host tests + header identity check |
| `android/.../cpp/fft_visualizer.h`, `jni_bridge.cpp`, `kotlin/x/a/zix/VisualizerTapProcessor.java`, `MainActivity.java` | Android: spectrum per tick on `eq_app/spectrum` |
| `ios/HypeDSP/src/dsp_bridge.{h,cpp}`, `ios/HypeDSP/include/dsp_bridge.h`, `ios/Runner/HypeAudioTap.{h,m}`, `ios/Runner/AppDelegate.swift` | iOS: spectrum per tick inside `onFftVisualization` |
| `lib/helpers/audio_visualizer.dart` | `AudioVisualizer.spectrumFrames` + `SpectrumFeed` |
| `lib/visualizers/spectrum_bars/presets.dart` | The eleven parameter sets |
| `lib/visualizers/spectrum_bars/analyzer.dart` | Bands, dB windows, smoothing, peaks |
| `lib/visualizers/spectrum_bars/geometry.dart` | Layout per mode → triangle mesh + colours |
| `lib/visualizers/spectrum_bars/frame.dart` | One frame: trail feedback + bars |
| `lib/visualizers/spectrum_bars/spectrum_bars_view.dart` | Widget: feed, fps, stall, lifecycle, paint |
| `lib/visualizers/visualizer_styles.dart` | Style list, names, migration |
| `lib/visualizers/radial_burst_painter.dart`, `waveform_line_painter.dart` | Radial + Waveform painters moved out of the deleted file |

---

### Task 1: Shared spectrum header

**Files:**
- Create: `android/app/src/main/cpp/bar_spectrum.h`, identical copy `ios/HypeDSP/src/bar_spectrum.h`
- Test: `native_tests/bar_spectrum/bar_spectrum_test.cpp`, `native_tests/bar_spectrum/run.sh` (shape of `native_tests/stereo/run.sh`: `cmp` the two copies, `clang++ -std=c++17 -O2 -Wall -Wextra`, run)

**Interfaces:**
- Produces:
  ```cpp
  class BarSpectrum {
  public:
      static constexpr int kBlock = 512;          // samples per analysis block (after decimation)
      static constexpr int kBins = 256;           // output powers, FFT bins 1..256
      static constexpr int kMaxDecimation = 8;
      static constexpr float kFloor = 1.5849e-13f;
      static int decimation(int sampleRate);      // 1..kMaxDecimation
      BarSpectrum();                              // precomputes window + twiddles, no allocation later
      // mono: kBlock*decim samples, oldest first. out: kBins powers.
      void compute(const float* mono, int decim, float* out);
  };
  ```

Algorithm (record §3): block[n] = mean of `mono[n·D .. n·D+D−1]` (box average); `w[n] = 0.5 − 0.5·cos(2πn/511)`, n = 0..511; unnormalised forward DFT (iterative radix-2, no scaling); `out[j] = re² + im²` of bin j+1, plus `kFloor`, j = 0..255 (j = 255 is Nyquist, im = 0). `decimation`: `sr < 88200 → 1`; else `sr % 48000 == 0 ? sr/48000 : sr/44100`, clamped 1..8; non-positive → 1.

- [ ] **Step 1: Write the failing tests** in `bar_spectrum_test.cpp` (plain checks with messages, like `stereo_expander_test.cpp`):
  - `decimation table`: 0→1, 22050→1, 44100→1, 48000→1, 64000→1, 88200→2, 96000→2, 176400→4, 192000→4, 384000→8, 768000→8.
  - `silence is the floor`: zeros in → every `out[j] == kFloor`.
  - `full-scale sine on a bin`: `x[n] = cos(2π·10·n/512)`, D = 1 → `out[9]` within 1 % of `127.75² = 16320.06` (10·log10 ≈ 42.13 dB); `out[j] < out[9]·1e-3` for every `|j − 9| ≥ 4`.
  - `decimated block equals hand-averaged block`: 1024 random samples with D = 2 give exactly the same `out` as `compute` on the 512 pairwise means with D = 1.
- [ ] **Step 2: Run** `native_tests/bar_spectrum/run.sh` — expected: compile failure (header missing).
- [ ] **Step 3: Implement `BarSpectrum`** in the Android copy, copy byte-identical to iOS. The header comment explains what it computes in Hype's own words.
- [ ] **Step 4: Run** `native_tests/bar_spectrum/run.sh` — expected: all checks pass, exit 0.
- [ ] **Step 5: Snapshot** — controller only.

---

### Task 2: Android spectrum feed

**Files:**
- Modify: `android/app/src/main/cpp/fft_visualizer.h` (include `bar_spectrum.h`; member `BarSpectrum spectrum_`; member `int64_t spectrumSeen_ = -1`)
- Modify: `android/app/src/main/cpp/jni_bridge.cpp` (next to `nativeComputeBeat`)
- Modify: `android/app/src/main/kotlin/x/a/zix/VisualizerTapProcessor.java`, `android/app/src/main/kotlin/x/a/zix/MainActivity.java`
- Test: `native_tests/bar_spectrum/fft_visualizer_spectrum_test.cpp` (built by the same `run.sh`)

**Interfaces:**
- Consumes: Task 1 `BarSpectrum`.
- Produces:
  - `bool FFTVisualizer::computeSpectrum(float* out256, int64_t endIndex, int sampleRate)` — false when fewer than `512·D` samples were ever written, or when `writePos_` has not moved since the last successful call (no new audio → no frame, so Dart can fall to silence). Reads the `512·D` samples ending at `windowEnd(endIndex)`.
  - JNI `private static native float[] nativeComputeSpectrum(long endIndex, int sampleRate)` → 256 floats or null, under `g_vizMutex` like `nativeComputeBeat`.
  - Java `public static void setSpectrumSink(EventChannel.EventSink sink)`; the viz thread runs while `fftSink != null || spectrumSink != null` (start on the first sink, stop when both are null — `setFftSink(null)` must not stop it while `spectrumSink` is set, and vice versa).
  - The viz tick, when `spectrumSink != null`, calls `nativeComputeSpectrum(drawEnd, latestSampleRate)` with the same `drawEnd` the bands use and posts the `float[]` to the sink on `mainHandler`.
  - `MainActivity`: `EventChannel` named `eq_app/spectrum` whose `StreamHandler` calls `setSpectrumSink(events)` / `setSpectrumSink(null)`, next to `eq_app/beat`.

- [ ] **Step 1: Write the failing test** `fft_visualizer_spectrum_test.cpp` against `android/app/src/main/cpp`: push 4096 frames of a 1 kHz stereo sine at 48 kHz → `computeSpectrum(out, -1, 48000)` true, peak at j = 10 (bin 11 ≈ 1031 Hz; accept 9…10); second call without new samples → false; a fresh instance fed 8192 frames of 1 kHz at 96 kHz with `sampleRate` 96000 → same peak bin.
- [ ] **Step 2: Run** `native_tests/bar_spectrum/run.sh` — expected: compile failure (`computeSpectrum` missing).
- [ ] **Step 3: Implement** the C++ method, JNI function, Java sink/thread lifetime and the `MainActivity` channel.
- [ ] **Step 4: Verify** `native_tests/bar_spectrum/run.sh` passes; `clang++ -std=c++17 -fsyntax-only` on `jni_bridge.cpp` with the NDK sysroot and JNI headers (under `$ANDROID_HOME/ndk/*/toolchains/llvm/prebuilt/*/sysroot`) shows no new errors; re-read the Java diff against the existing sink code (no Gradle).
- [ ] **Step 5: Snapshot** — controller only.

---

### Task 3: iOS spectrum feed

**Files:**
- Modify: `ios/HypeDSP/src/dsp_bridge.cpp`, `ios/HypeDSP/src/dsp_bridge.h`, `ios/HypeDSP/include/dsp_bridge.h`
- Modify: `ios/Runner/HypeAudioTap.h`, `ios/Runner/HypeAudioTap.m`, `ios/Runner/AppDelegate.swift`
- Test: `native_tests/bar_spectrum/ios_checks.sh` (called from `run.sh`)

**Interfaces:**
- Consumes: Task 1 `BarSpectrum` (included only by `dsp_bridge.cpp`).
- Produces:
  - C bridge: `int dsp_bar_spectrum_decimation(int sampleRate);` and `int dsp_bar_spectrum(const float* mono, int decim, float* out256);` (returns 256; one static `BarSpectrum` created on first use; called from the main thread only).
  - `HypeAudioTap`: `- (nullable NSData *)takeSpectrum;` — main thread; reads the newest `512·D` samples of the active context's `bandRing` (`D = dsp_bar_spectrum_decimation(ctx->sampleRate)`), returns 256 floats; nil when no active context, fewer than `512·D` written, or `bandWritten` unchanged since the last call (new field `int64_t spectrumSeen` in `TapContext`, main thread only).
  - `AppDelegate.sendVisualizerData`: `let spectrum = tap.takeSpectrum()`; when non-nil add `args["spectrum"] = FlutterStandardTypedData(float32: spectrum)`; send `onFftVisualization` when any of fft / beat / spectrum is non-nil.

- [ ] **Step 1: Write the failing checks** in `ios_checks.sh`: `diff ios/HypeDSP/include/dsp_bridge.h ios/HypeDSP/src/dsp_bridge.h` empty; every `dsp_` symbol used in `ios/Runner/*.swift` and `ios/Runner/HypeAudioTap.m` is declared in `include/dsp_bridge.h`, and every declared one is defined in `dsp_bridge.cpp` (`comm` as in the existing memory recipe); `grep -q dsp_bar_spectrum ios/HypeDSP/include/dsp_bridge.h`; `clang -fsyntax-only -x c++ -std=c++17 -I ios/HypeDSP/src -I ios/HypeDSP/include ios/HypeDSP/src/dsp_bridge.cpp`.
- [ ] **Step 2: Run** `native_tests/bar_spectrum/run.sh` — expected: fails (functions not declared).
- [ ] **Step 3: Implement** bridge, tap method and AppDelegate change. Add to `ios_checks.sh` an Objective-C syntax check: `xcrun --sdk iphonesimulator clang -fsyntax-only -fobjc-arc -x objective-c` on `HypeAudioTap.m` with a temp include dir that maps `HypeDSP/dsp_bridge.h` to `ios/HypeDSP/include/dsp_bridge.h` (skip with a printed note if `xcrun` is unavailable).
- [ ] **Step 4: Verify** `native_tests/bar_spectrum/run.sh` passes end to end.
- [ ] **Step 5: Snapshot** — controller only.

---

### Task 4: Dart spectrum feed

**Files:**
- Modify: `lib/helpers/audio_visualizer.dart`
- Test: `test/helpers/spectrum_feed_test.dart`

**Interfaces:**
- Produces:
  ```dart
  /// 256 bin powers per visualizer tick (FFT bins 1..256 of a 512-point block).
  static final Stream<Float32List> spectrumFrames; // on AudioVisualizer
  class SpectrumFeed {
    SpectrumFeed({required void Function(Float32List power) onFrame, Stream<Float32List>? source});
    void dispose();
  }
  ```
  Android: `EventChannel('eq_app/spectrum').receiveBroadcastStream()` mapped to `Float32List` (accept `Float32List` or `List<double>`), dropping anything not 256 long. iOS: a static broadcast controller fed from the shared `onFftVisualization` handler's `spectrum` argument — handled **before** the existing `if (raw == null) break;`, only when it has listeners. `SpectrumFeed` with no `source`: on iOS it owns an activated `AudioVisualizer` (ref-counted native tap) and disposes it; on Android it only subscribes. With `source` it only listens (tests).

- [ ] **Step 1: Write the failing tests:** `ios handler publishes spectrum frames` — construct `SpectrumFeed` without source (the test host is not Android), deliver `onFftVisualization` with `{'spectrum': Float32List(256)..[3] = 7}` on `Channel.channel` through the test binary messenger, expect one frame with `[3] == 7`; `frames without fft still publish spectrum` (args hold only `spectrum`); `wrong length is dropped` (255 floats → no frame); `dispose stops delivery`; `source override is used`.
- [ ] **Step 2: Run** `flutter test test/helpers/spectrum_feed_test.dart` — expected: FAIL (`SpectrumFeed` undefined).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the test file and `flutter test test/visualizers test/connect` — expected: PASS.
- [ ] **Step 5: Snapshot** — controller only.

---

### Task 5: Presets and analyzer

**Files:**
- Create: `lib/visualizers/spectrum_bars/presets.dart`, `lib/visualizers/spectrum_bars/analyzer.dart`
- Test: `test/visualizers/spectrum_bars/presets_test.dart`, `test/visualizers/spectrum_bars/analyzer_test.dart`

**Interfaces:**
- Produces:
  ```dart
  enum BarsLayout { bottom, bottomCells, centred, centredCells, reflected, reflectedCells } // record modes 1,2,3,4,6,7
  class SpectrumBarsPreset {
    final String id, name;            // id 'spectrum_plain', name 'Spectrum Plain' …
    final BarsLayout layout;
    final int numX, numY, rounding;
    final double spacingX, spacingY, smooth, sens, bassSens, sx, sy;
    final double peakHeight, peakSpacing, peakDelay, peakAccel;
    final double decay, zoom, zoomExp, thr;
    final Color colorT, colorB, colorL, colorR, thrT, thrB, thrL, thrR, peakT, peakB;
    int get barCount;                  // clamp(numX,1,128), halved (>>1) for reflected layouts
    bool get hasPeaks => peakHeight != 0;
    bool get hasTrail => decay > 0;
    double get decayMultiplier;        // floor(decay*255)/255
  }
  const List<SpectrumBarsPreset> kSpectrumBarsPresets; // spec order
  SpectrumBarsPreset? spectrumBarsPresetById(String id);

  class BarBand { final int start, count; }
  class DbWindow { final double lo, hi; }
  class BarPeaks {
    BarPeaks({required double height, required double spacing, required double delay, required double accel});
    double get reserve;                // height+spacing, 0 when height == 0
    Float64List get pos;               // 128 slots, bar-space fraction
    void reset();
    void update(Float64List bars, int n, double t, double dt); // uses b = bars[i]*(1-reserve)
  }
  class SpectrumBarsAnalyzer {
    SpectrumBarsAnalyzer(SpectrumBarsPreset preset);
    SpectrumBarsPreset get preset;
    Float64List get bars;              // 128 slots, 0..1; first preset.barCount used
    BarPeaks get peaks;
    void setPreset(SpectrumBarsPreset p); // keeps bars, resets peaks
    void update(Float32List power, {required double fps, required double time});
    static List<BarBand> bandsFor(int n);                  // record §4.1
    static DbWindow window(double sens, double bassSens, {required bool bass}); // §4.2
  }
  ```

Preset values (`0xAARRGGBB`; every unlisted colour is `0x00000000`; every preset has rot 0, bars_x/y 0):

| id suffix | layout | numX×numY | spacingX/Y | round | smooth | sens/bass | sx/sy | peaks h, sp, delay, accel | decay | zoom/exp | thr | colorT | colorB | colorR | thrT | thrB | thrR | peakT/peakB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| plain | bottom | 32×24 | .09/.5 | 0 | .75 | .5/.5 | 1/1 | .012,.002,1.5,.25 | .94 | 1/1 | .81 | FF768BBF | FF94A2C3 | – | FFFFFFFF | FFFFFFFF | – | FFFFFFFF/FF94A2C3 |
| narrow | bottom | 128×24 | .5/.2 | 0 | .9 | .55/0 | 1/1 | – | 0 | 1/1 | .8 | FF111199 | FF3333AA | – | FFAA0000 | FF443333 | – | – |
| wide | bottom | 16×24 | .25/.25 | 2 | .9 | .775/1 | 1/1 | – | 0 | 1/1 | .8 | FF111199 | FF3333AA | – | FFAA0000 | FF443333 | – | – |
| centered | centred | 128×24 | .5/.5 | 0 | .83 | .5/0 | 1/1 | – | 0 | 1/1 | .5 | FFFFFFFF | FFEEEEEE | – | FFEEEEEE | FFFFFFFF | – | – |
| centered_narrow | centred | 64×24 | .3/.3 | 1 | .85 | .5/0 | 1/1 | – | 0 | 1/1 | .5 | FF98C8FF | FF050709 | – | FF98C8FF | FF98C8FF | FF050709 | – |
| centered_wide | centred | 16×24 | .3/.5 | 1 | .875 | .5/0 | 1/1 | – | 0 | 1/1 | .5 | FF98C8FF | FF98C8FF | – | FF98C8FF | FF98C8FF | – | – |
| centered_reflected | reflected | 64×24 | .8/.8 | 0 | .5 | .9/.9 | 1/.65 | – | .95 | 1/1 | .5 | FFFFFFFF | FF536C82 | – | FFFFFFFF | FFFFFFFF | – | – |
| reflected_wide | reflected | 32×24 | .8/.8 | 0 | .5 | .9/.9 | 1/.65 | – | .95 | 1/1 | .5 | FFFFFFFF | FF373782 | – | FFFFFFFF | FFFFFFFF | – | – |
| quads_narrow | bottomCells | 32×48 | .1/.1 | 0 | .83 | .8/.5 | 1/1 | .025,.01,.65,.85 | .9 | 1/1 | .85 | FF768BBF | FF768BBF | FF000033 | FFFFFFFF | FFFFFFFF | – | FFFFFFFF/FF94A2C3 |
| quads_reflected | reflectedCells | 49×99 | .2/.2 | 0 | .9 | .75/1 | 1/1 | – | 0 | 1/1 | .8 | FF111199 | FF3333AA | – | FFAA0000 | FF443333 | – | – |
| dots | centredCells | 64×24 | .5/.5 | 0 | .1 | .95/1 | 1/.75 | – | .963 | .999/1.05 | .5 | FF768BBF | FF94A2C3 | FF94A2C3 | FFCAC3FF | FF7A87FF | – | – |

Analyzer rules: bands §4.1 (mean power over the band's bins, `start` clamp at 214); level §4.2 with exact `10·log10(P)` — `A = clamp(15·sens,0,15)`, `B = clamp(60−35·sens,25,60)`, `C = clamp(4.5·bassSens,0,4.5)`, `D = clamp(60−46·sens,14,60)`; bars 0–1 use the bass window `[45−C−D, 45−C]`, all others `[45−A−B, 45−A]`, target = `clamp((dB−lo)/(hi−lo), 0, 1)`; smoothing §4.3 `s = clamp(smooth^(60/fps),0,1)`, `bar = target + s·(bar − target)`; peaks §5 (states 0/1/2, `a = max(accel,0)`).

- [ ] **Step 1: Write the failing tests.**
  - presets: 11 presets in spec order with the ids/names from Global Constraints; `barCount` = 32,128,16,128,64,16,32,16,32,24,64; `decayMultiplier·255` = 239, 0, 0, 0, 0, 0, 242, 242, 229, 0, 245; `spectrumBarsPresetById('nope') == null`; spot-check colours of plain, centered_narrow and dots against the table.
  - `windows match the record`: for each preset, normal and bass windows equal (±0.01 dB): plain −5.00…37.50 / 5.75…42.75; narrow −4.00…36.75 / 10.30…45.00; wide 0.50…33.38 / 16.15…40.50; centered, centered_narrow, centered_wide −5.00…37.50 / 8.00…45.00; centered_reflected, reflected_wide 3.00…31.50 / 22.35…40.95; quads_narrow 1.00…33.00 / 19.55…42.75; quads_reflected 0.00…33.75 / 15.00…40.50; dots 4.00…30.75 / 24.20…40.50.
  - `bands for 32`: bars 0–16 are `(start: i, count: 1)`; bars 17–31 have non-decreasing `start` and `start + count ≤ 214`.
  - `bands for 16`: step 125 Hz → starts 0,1,2,4,5,6,8,9 for bars 0–7.
  - `level maps window ends`: a flat spectrum at power `10^(hi/10)` gives target 1, at `10^(lo/10)` gives 0, below clamps to 0 (check one normal and one bass bar).
  - `smoothing is frame-rate compensated`: constant target, two updates at fps 30 equal four at fps 60 (±1e-9).
  - `peaks hold then fall`: `BarPeaks(height .012, spacing .002, delay 1.5, accel .25)`, bar 0.5 at t 0 → `pos[0] == 0.5·(1−.014) + .002`; bars 0 from t 0.1; at t 1.5 pos unchanged; at t 1.7 lower; after enough time `pos[0] == .002` (rests on the bar).
  - `setPreset keeps bars and resets peaks`.
- [ ] **Step 2: Run** `flutter test test/visualizers/spectrum_bars` — expected: FAIL (files missing).
- [ ] **Step 3: Implement** `presets.dart` and `analyzer.dart` (`analyzer.dart` imports only `dart:math`, `dart:typed_data` and `presets.dart`).
- [ ] **Step 4: Run** the tests — expected: PASS.
- [ ] **Step 5: Snapshot** — controller only.

---

### Task 6: Geometry and colour

**Files:**
- Create: `lib/visualizers/spectrum_bars/geometry.dart`
- Test: `test/visualizers/spectrum_bars/geometry_test.dart`

**Interfaces:**
- Consumes: Task 5 `SpectrumBarsPreset`, `BarsLayout`.
- Produces:
  ```dart
  class SpectrumBarsMesh {               // grow-only buffers, reused frame to frame
    Float32List positions;               // x,y pairs, physical pixels, y down
    Int32List colors;                    // ARGB per vertex
    int vertexCount;                     // triangle list: multiple of 3
    ui.Vertices toVertices();            // Vertices.raw(VertexMode.triangles, …) over the used range
  }
  void buildSpectrumBars(SpectrumBarsMesh into, {
    required SpectrumBarsPreset preset,
    required Float64List bars,           // first preset.barCount used
    Float64List? peakPos, double reserve = 0,
    required double width, required double height, // physical pixels
  });
  int spectrumBarsColor(SpectrumBarsPreset p, double x, double y, double div); // §7, bar space → ARGB
  ```

Rules (record §6–§8): bar space x 0..1 left→right, y 0..1 bottom→top; `px = 1/width`, `py = 1/height`, `asp = width/height`; pixel snapping exactly as §6 per mode (modes 6/7 not snapped); caps as 16-triangle half-ellipse fans (`rx = w/2`, `ry = asp·rx`) with §6's base/height rules and `keepRadius` for rounding 2 (bottom semicircle at y = ry plus top cap on `ry + (1−ry)·bar`); centred layouts pass height `h − ε`; bottom rounding-0 splits at `thr' = floor(thr·16384)/16384` with `ε = 1/16384`; dividers per layout: bottom `thr'`, bottomCells `floor(thr/pitch_y)·pitch_y`, all others raw `thr`; peaks (bottom, bottomCells, only when `peakPos` is given and reserve ≠ 0) are appended after the bars, coloured `mix(peakB, peakT, (y−1e−4)/(1−1e−4))`. Colour is computed per vertex from the **untransformed** bar-space position: at/below `div`: `mix(colorB, colorT, y/div) + mix(colorL, colorR, x)`; above: `mix(thrB, thrT, (y−div)/(1−div)) + mix(thrL, thrR, x)`; channels (alpha too) summed and clamped to 0..1, rounded to 8 bits. Transform: `X = 0.5 + sx·(x−0.5)`, `Y = 0.5 + sy·(y−0.5)`, pixel `(X·width, (1−Y)·height)`. Quads are two triangles (0-1-2, 0-2-3).

- [ ] **Step 1: Write the failing tests** (width 1080, height 2340 unless noted):
  - `plain bar columns snap to whole pixels`: bar 0 spans x 13…43 px, bar 1 starts at 46 px (w 30 px, gap 3 px).
  - `plain splits at the threshold`: bar 0.9 with reserve 0.014 → two rects for bar 0, the lower top at `y = 13271/16384`, the upper from `13272/16384` to `0.9·0.986`; colour at y 0 is `0xFF94A2C3`, at the lower top `0xFF768BBF`, upper rect white; one peak quad appended when `peakPos` is given.
  - `wide silence draws circles`: all bars 0 → bar 0's vertices span equal width and height in pixels (±1 px), bottom at y = height.
  - `quads narrow cells`: bar 1.0 with reserve 0.035 → 46 cells in column 0, cell height 44 px, pitch 48 px, column width 30 px.
  - `dots mirror around the middle`: bar 1.0 → 12 cells up and 12 down (row pitch 97 px, cell 49 px); with sy 0.75 the outermost cell edges sit at Y = 0.5 ± 0.75·(11·97 + 49)/2340.
  - `reflected mirrors bass at the centre`: centered_reflected bar 0 of 32 at x 0.5+0.00625 (right) and 0.5−0.00625−0.003125 (left); a full bar spans Y 0.175…0.825.
  - `quads reflected has 24 columns per side and up to 49 cells per side`.
  - `centered narrow caps`: bar 1.0 → top-most vertex at Y 1.0 (±1e-6), each cap is 16 triangles.
  - `colour sums clamp`: dots at (x 1, y 0) = `colorB + colorR` per channel clamped → `0xFFFFFFFF` only where each channel saturates; assert the exact computed int `0xFFFFFFFF` (0x94+0x94, 0xA2+0xA2, 0xC3+0xC3 all > 0xFF).
  - `buffers are reused`: a second, smaller build into the same mesh keeps the same `positions` object.
- [ ] **Step 2: Run** `flutter test test/visualizers/spectrum_bars/geometry_test.dart` — expected: FAIL.
- [ ] **Step 3: Implement** `geometry.dart`.
- [ ] **Step 4: Run** — expected: PASS.
- [ ] **Step 5: Snapshot** — controller only.

---

### Task 7: Frame compositor and view

**Files:**
- Create: `lib/visualizers/spectrum_bars/frame.dart`, `lib/visualizers/spectrum_bars/spectrum_bars_view.dart`
- Test: `test/visualizers/spectrum_bars/frame_test.dart`, `test/visualizers/spectrum_bars/spectrum_bars_view_test.dart`

**Interfaces:**
- Consumes: Task 4 `SpectrumFeed`; Task 5 `SpectrumBarsAnalyzer`, presets; Task 6 `SpectrumBarsMesh`, `buildSpectrumBars`.
- Produces:
  ```dart
  /// Draws one frame: black, the previous frame decayed (and, with zoom ≠ 1, warped), then the bars.
  void paintSpectrumBarsFrame(Canvas canvas, {
    required SpectrumBarsPreset preset, required SpectrumBarsMesh mesh,
    ui.Image? previous, required double fps, required double width, required double height,
  });
  ColorFilter spectrumBarsDecayFilter(double multiplier); // RGB × m, then −0.002 per channel, alpha kept
  class SpectrumBarsView extends StatefulWidget {
    const SpectrumBarsView({super.key, required this.preset, this.frames, this.stallAfter = const Duration(milliseconds: 250)});
    final SpectrumBarsPreset preset;
    final Stream<Float32List>? frames;   // tests; null = SpectrumFeed's platform source
    final Duration stallAfter;
  }
  ```

Rules: per incoming frame, `fps = clamp(1/dt, 5, 120)` from a `Stopwatch` (first frame 30); `time += dt`; analyzer + peaks update; mesh build at physical size (`logical size × devicePixelRatio`). Trail presets (`hasTrail`): record a picture at physical size with `paintSpectrumBarsFrame`, `toImageSync`, dispose the old image, paint the new one scaled by `1/dpr` with `FilterQuality.none`. Decay `m = pow(decayMultiplier, 60/fps)`; the previous image is drawn through `spectrumBarsDecayFilter(m)` (check with the Flutter docs whether the matrix translation column is 0–255 or 0–1 and let the pixel test settle it). Zoom ≠ 1 (dots): draw the previous image through a 32×24-cell vertex grid textured by `ImageShader(previous, clamp, clamp, identity)`; grid point `(gx, gy) ∈ [−1,1]²` at pixel `((gx+1)/2·W, (1−gy)/2·H)`, `rad = min(1, sqrt(gx²+gy²)/√2)`, `z = zoom^(−zoomExp^(2·rad−1))`, texture coordinate `((0.5 + 0.5·gx·z)·W, (0.5 − 0.5·gy·z)·H)`, `FilterQuality.low`. Non-trail presets paint black + mesh straight in the `CustomPainter`. Bars: `canvas.drawVertices(mesh.toVertices(), BlendMode.dst, Paint())` (vertex colours only; the pixel test confirms). Stall: a periodic 33 ms timer; when no frame for `stallAfter`, feed all-`1.5849e-13` frames at 30 fps until every used bar < 0.001 and (trail presets) 3 s have passed, then stop until real frames return. Preset change (`didUpdateWidget`): `analyzer.setPreset`, drop the trail image. Size change: drop the trail image. Dispose: cancel feed/timer, dispose image. State exposes `@visibleForTesting` getters `debugBars`, `debugPeaks`, `debugTrail`.

- [ ] **Step 1: Write the failing tests** (use `tester.runAsync` for image reads):
  - frame: `bars draw their vertex colours` — plain, 64×64 px, bar 0 full → the pixel at the bar's centre one pixel above the bottom is `0xFF94A2C3` (±2 per channel).
  - frame: `trail decays by the multiplier` — frame 1 bars, frame 2 empty mesh with `previous` = frame 1 at fps 60 → that pixel equals `round(v·239/255 − 0.51)` per RGB channel (±1).
  - frame: `no-trail preset clears` — narrow, frame 2 pixel is black.
  - frame: `dots trail drifts inward` — 200×200, frame 1 a bright column at x 180, then 50 empty frames at fps 60 → brightest column at 176 ± 2.
  - view: `renders frames without errors` for every preset (pump a `StreamController<Float32List>` frame of mid-level powers, `pump()`).
  - view: `stall feeds silence until the bars settle` — one loud frame, then none; after `pump(const Duration(seconds: 2))` every `debugBars` value in use is < 0.001.
  - view: `preset change resets peaks and trail, keeps bars` — plain → quads_narrow mid-stream: `debugPeaks` all 0, `debugTrail` null, `debugBars` unchanged at the switch.
  - view: `resize drops the trail` — change the surrounding `SizedBox`; `debugTrail` null until the next frame, then its width is the new physical width.
- [ ] **Step 2: Run** `flutter test test/visualizers/spectrum_bars` — expected: FAIL.
- [ ] **Step 3: Implement** `frame.dart` and `spectrum_bars_view.dart`.
- [ ] **Step 4: Run** `flutter test test/visualizers` — expected: PASS.
- [ ] **Step 5: Snapshot** — controller only.

---

### Task 8: Wire in, remove the rest, migrate

**Files:**
- Create: `lib/visualizers/visualizer_styles.dart`, `lib/visualizers/radial_burst_painter.dart` (`RadialBurstVisualizer`, `kRadialGold`, `kRadialGreen` and the helpers they use, moved unchanged), `lib/visualizers/waveform_line_painter.dart` (`WaveformLineVisualizer`, moved unchanged)
- Modify: `lib/pages/visual_ui.dart`, `lib/pages/Settings.dart`, `lib/widgets/Body.dart`, `lib/controllers/visualizer_tap.dart`, `lib/controllers/app_controller.dart`, `lib/visualizers/wave-visualizer.dart`, `lib/onboarding/onboarding_data.dart`
- Delete: the old reference-named painter file in `lib/visualizers/` (it held Radial, Waveform and seven retired painters), `3d_visualizers.dart`, `3d_visualizers_tier2.dart`, `3d_visualizers_tier3.dart`, `spectrum-visualiser.dart`, `sphere_visualizer.dart`, `bar_visualizer.dart`, `line_visualizer.dart`, `sine_wave_visualizer.dart`, `circular_bar_visualizer.dart`
- Test: `test/visualizers/visualizer_styles_test.dart`, `test/player/visualizer_tap_test.dart` (update)

**Interfaces:**
- Consumes: Task 5 presets, Task 7 `SpectrumBarsView`.
- Produces:
  ```dart
  class VisualizerStyle { final String id, name, description; final IconData icon; }
  List<VisualizerStyle> visualizerStyles({required bool isIos}); // Global Constraints order, no milkdrop on iOS
  String migrateVisualizerStyle(String? stored, {required bool isIos}); // unknown/null/'circular'/(iOS 'milkdrop') → 'radial'
  bool isSpectrumBarsStyle(String id);
  ```

Changes: the Visual page and the Settings style chips both list `visualizerStyles(isIos: Platform.isIOS)`; the Visual page builds `SpectrumBarsView(preset: spectrumBarsPresetById(style)!)` for spectrum ids and the existing `WaveVisualizer` for `radial`/`line`; the colour palette (Visual page panel and Settings colour row) is hidden for spectrum ids as it already is for MilkDrop (their colours are fixed). `WaveVisualizer` keeps only `radial` and `line` (fallback `radial`) and drops state only the removed painters used. Remove the background visualizer: the Settings switch, `AppController.isVisualInBackground` (getter, setter, prefs restore), `VisualizerTap.backgroundVisual` (`shouldRun = remoteVisual || (!suspended && playerVisual)`), and Body's background `VisualizerWidget`/`visualInBackground` (`washed = d.hasSongs`). AppController restores `visualizerStyle` through `migrateVisualizerStyle` and writes the migrated value back when it changed. The onboarding line becomes `'Spectrum, radial & waveform visualizers'`. Descriptions: Radial "Circular burst", Waveform "Oscilloscope", Plain "Bars with falling peaks", Narrow "Fine blue bars", Wide "Rounded pills", Centered "White bars from the middle", Centered Narrow "Glowing mirrored bars", Centered Wide "Wide rounded bars", Centered Reflected "Bass in the middle, with trails", Reflected Wide "Wide mirrored bars", Quads Narrow "LED cells with peaks", Quads Reflected "Mirrored LED cells", Dots "Drifting dot columns", MilkDrop "MilkDrop presets". Icons: keep Radial/Waveform/MilkDrop's; spectrum entries use `Icons.bar_chart_rounded` (bottom layouts), `Icons.align_vertical_center_rounded` (centred/reflected), `Icons.grid_on_rounded` (cell layouts), `Icons.blur_linear_rounded` (dots).

- [ ] **Step 1: Write the failing tests:** `visualizer_styles_test.dart` — the Android list is exactly the 14 ids in Global Constraints order with their display names; the iOS list is the same minus `milkdrop`; `migrateVisualizerStyle` maps `null`, `'circular'`, `'bars'`, `'mirror_bars'`, `'terrain'`, `'dots'`, `'silk'`, `'neon_grid'`, `'fractal_flame'` → `'radial'`, keeps every listed id, maps `'milkdrop'` → `'radial'` on iOS only. `visualizer_tap_test.dart`: background cases removed; `shouldRun` follows `playerVisual`, `suspended`, `remoteVisual`.
- [ ] **Step 2: Run** `flutter test test/visualizers/visualizer_styles_test.dart test/player/visualizer_tap_test.dart` — expected: FAIL.
- [ ] **Step 3: Implement** the changes and deletions.
- [ ] **Step 4: Verify:**
  - `flutter test` — expected: only the two known pre-existing failures (template counter, splash).
  - `flutter analyze` — total ≤ 134.
  - `grep -rnE "'(bars|mirror_bars|terrain|dots|silk|lissajous|windmill|neon_grid|spectrum_ring|ribbon_trail|lissajous_3d|particle_field|waveform_tunnel|kaleidoscope|terrain_3d|mesh_sphere|morphing_orb|reactive_geo|waterfall|metaball|milkdrop_warp|fractal_flame)'" lib` — expected: hits only in `visualizer_styles.dart`'s migration comment/tests, nowhere else.
  - `grep -rniF -f ~/me/COTE/.hype-reference/forbidden-names.txt lib test android/app/src ios/Runner ios/HypeDSP native_tests docs` — expected: nothing.
- [ ] **Step 5: Snapshot** — controller only.

---

## After the tasks (controller)

1. Whole-branch review of all visualizer changes (fresh reviewer, most capable model).
2. Ask the owner before any Gradle/Xcode build; then `flutter build apk --debug` and an iOS simulator build, and a device check of every preset against the reference app side by side (same song, same moment).
3. Commit/push only on the owner's go-ahead.
