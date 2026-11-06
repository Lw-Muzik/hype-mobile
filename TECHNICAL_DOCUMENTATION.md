# Hype Muzik — Technical Documentation

> **Version**: 1.1.8 (build 28)
> **Package**: `x.a.zix`
> **Framework**: Flutter 3.38+ / Dart 3.10+
> **Platforms**: Android (API 24+) / iOS (15.0+)
> **Last Updated**: April 2026

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Architecture Overview](#2-architecture-overview)
3. [Initialization Flow](#3-initialization-flow)
4. [State Management](#4-state-management)
5. [Audio Playback Engine](#5-audio-playback-engine)
6. [Native DSP Pipeline (C++)](#6-native-dsp-pipeline-c)
7. [Platform Bridge (Channel)](#7-platform-bridge-channel)
8. [Equalizer & Audio Effects](#8-equalizer--audio-effects)
9. [Cloud Music Streaming](#9-cloud-music-streaming)
10. [Lyrics System](#10-lyrics-system)
11. [Audio Fingerprinting & Recognition](#11-audio-fingerprinting--recognition)
12. [Stem Separation & Mixing](#12-stem-separation--mixing)
13. [Visualizer System](#13-visualizer-system)
14. [Music Library & Querying](#14-music-library--querying)
15. [Search & Discovery](#15-search--discovery)
16. [UI Architecture](#16-ui-architecture)
17. [Player UI & Animations](#17-player-ui--animations)
18. [Onboarding & Coach Marks](#18-onboarding--coach-marks)
19. [Build Configuration](#19-build-configuration)
20. [Platform Differences](#20-platform-differences)
21. [Data Persistence](#21-data-persistence)
22. [Dependencies](#22-dependencies)
23. [File Structure](#23-file-structure)
24. [Design Patterns](#24-design-patterns)
25. [Future Prospects](#25-future-prospects)

---

## 1. Project Overview

Hype Muzik is a professional-grade mobile audio player and DSP processor built with Flutter. It combines a full music library manager with a custom C++ digital signal processing engine that runs in real-time on the audio thread. The app operates in two modes:

- **Music Player Mode** — Full library browsing, cloud streaming, playback with DSP effects
- **EQ-Only Mode** — Standalone system-wide equalizer for any audio app (Android only)

### Key Capabilities

| Domain | Features |
|--------|----------|
| **Playback** | Gapless, crossfade, replay gain, DVC, shuffle, repeat |
| **DSP** | 32-band graphic EQ, parametric EQ, tone controls, MBC, reverb, stereo expander, crossfeed, output limiter |
| **Cloud** | Google Drive, Dropbox streaming with caching and metadata extraction |
| **Lyrics** | Synced LRC display with shimmer reveal animation, editor, multi-source fetching |
| **Recognition** | Chromaprint + AcoustID + ACRCloud audio fingerprinting |
| **Stems** | 4-track separation (vocals/drums/bass/other) with real-time mixer |
| **Visualization** | 15+ custom visualizers + projectM MilkDrop engine |
| **Correction** | 6,028 AutoEq headphone/speaker profiles |

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Flutter UI Layer                       │
│  Provider (ChangeNotifier) + StreamBuilder + Consumer    │
├─────────────────────────────────────────────────────────┤
│                   AppController                          │
│  (Singleton — master state: songs, EQ, DSP, cloud,      │
│   lyrics, stems, visualizer, play counts, settings)      │
├──────────────┬──────────────┬───────────────────────────┤
│ HypeAudioHandler │ Channel.dart │  Service Layer         │
│ (just_audio +    │ (MethodChannel│  (CloudAuth, Cache,   │
│  dual-player     │  + EventCh.) │   Lyrics, Fingerprint,│
│  crossfade)      │              │   StreamingGuard)      │
├──────────────┴──────────────┴───────────────────────────┤
│              Native Platform Layer                        │
│  ┌──────────────────┐  ┌───────────────────────────┐    │
│  │ Android (Java)    │  │ iOS (Swift)               │    │
│  │ RoomEffectsProc.  │  │ AppDelegate + DSPManager  │    │
│  │ DvcController     │  │ HypeAudioTap              │    │
│  │ GlobalEqService   │  │ ProjectMRenderer          │    │
│  │ StemSeparation    │  │                           │    │
│  └────────┬─────────┘  └──────────┬────────────────┘    │
│           │                        │                      │
│  ┌────────┴────────────────────────┴────────────────┐    │
│  │         C++ DSP Engine (shared, platform-agnostic) │    │
│  │  room_dsp_engine → biquad → parametric_eq →       │    │
│  │  compressor → multiband_compressor → tone →       │    │
│  │  limiter → fdn_reverb → stereo_expander →         │    │
│  │  crossfeed → stem_mixer → fft_visualizer          │    │
│  └───────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

### Provider Hierarchy

```dart
MultiBlocProvider
├── ChangeNotifierProvider<AppController>      // Master state
├── ChangeNotifierProvider<PlaylistController>  // Online songs
├── Provider<HypeAudioHandler>.value           // Audio backend
├── ChangeNotifierProvider<PlayerController>    // UI text state
├── ChangeNotifierProvider<DrawerProvider>      // Navigation drawer
└── BlocProvider<BandController>               // Legacy band state
```

---

## 3. Initialization Flow

```
main()
  │
  ├─ WidgetsFlutterBinding.ensureInitialized()
  ├─ Firebase.initializeApp()
  │    └─ Crashlytics error handlers (Flutter + async)
  ├─ Permission requests
  │    ├─ mediaLibrary, storage, audio
  │    └─ iOS: MPMediaLibrary.requestAuthorization
  ├─ AudioService.init<HypeAudioHandler>()
  │    └─ Background playback notification channel
  ├─ SystemChrome: edge-to-edge, transparent overlays
  ├─ SharedPreferences.getInstance()
  ├─ StreamingDataGuard.init()
  └─ runApp(MultiBlocProvider → MaterialApp)

AppController(prefs, handler)
  │
  ├─ _loadSettings()              // Restore all SharedPreferences
  ├─ _loadPlayCounts()            // Play count map
  ├─ Wire handler callbacks       // onSkipToNext, onSkipToPrevious,
  │                                // onCrossfadeStarted, onPlayerSwapped
  ├─ Apply DVC state if enabled
  ├─ _initGlobalEq()
  ├─ Start EQ mode service (if EQ mode)
  ├─ Bind streams:
  │    ├─ _bindDvcVolumeButtons()
  │    ├─ _bindProcessingState()
  │    ├─ _bindCurrentIndex()
  │    ├─ _setupCrossfadeListener()
  │    └─ _bindAudioSessionId()
  ├─ FingerprintService(prefs)
  ├─ Cloud services init:
  │    ├─ CloudAuthService → restore sessions
  │    ├─ CloudCacheService(prefs)
  │    ├─ GoogleDriveService / DropboxService
  │    └─ CloudMetadataService → preload from cache
  ├─ StemController()
  └─ loadSpeakerProfiles() → _applyAllDspParams()

AssetLoader (Splash Screen)
  │
  ├─ First launch: ModeChooser → OnboardingScreen
  ├─ fetchMetaData(context)
  │    ├─ Process songs, artists, albums, genres in batches
  │    ├─ Fetch & cache artwork per entity
  │    └─ iOS: merge MPMediaQuery + LocalMusicScanner
  └─ Navigate to Home
```

---

## 4. State Management

### AppController (Primary — ~20,000 lines)

The AppController is the single source of truth for the entire application. It extends `ChangeNotifier` and is accessed both via Provider and as a static singleton (`AppController.instance`).

**Feature domains managed:**

| Domain | Key Fields |
|--------|-----------|
| **Playback** | `_songs`, `_shuffledSongs`, `_songId`, `_isShuffled`, `_gaplessPlayback`, `_crossfadeDuration`, `_replayGain` |
| **DVC** | `_dvcEnabled`, `_dvcGain` (-30 to 0 dB), `_dvcFineSteps` |
| **Graphic EQ** | `_graphicBandGains` (32 bands), `_graphicEqEnabled`, `_activePresetName`, `_savedPresets`, `_eqBandCount` |
| **Parametric EQ** | `_parametricPoints` (List\<ParametricPoint\>) |
| **Preamp** | `_preampGain` (0–15 dB) |
| **MBC** | `_mbcEnabled`, `_dspNoise`, `_kneeWidth`, `_expandRatio`, `_preGain` |
| **Reverb** | `_reverbEnabled`, `_dspRoomSize`, `_dspDecay`, `_dspDamping`, `_dspPreDelay`, `_dspDiffusion`, `_dspWetDry` |
| **Stereo** | `_stereoExpandEnabled`, `_stereoWidth` (0–2.0) |
| **Crossfeed** | `_crossfeedEnabled`, `_crossfeedCutoff`, `_crossfeedFeed` |
| **Tone** | `_toneEnabled`, `_bassGain/Freq/Q`, `_trebleGain/Freq/Q` |
| **Limiter** | `_limiterEnabled` (on by default) |
| **Speaker EQ** | `_speakerEqEnabled`, `_activeSpeakerProfile`, `_speakerProfileService` |
| **Visualizer** | `_visualizerStyle`, `_visualizerColor`, `_visualizerFrameRate`, `_milkdropFps`, `_milkdropPresetName`, etc. |
| **Global EQ** | `_globalEqEnabled`, `_globalEqAvailable` (API 28+), `_playingApps` |
| **App Mode** | `_appMode` (musicPlayer \| equalizer) |
| **Cloud** | `cloudAuth`, `cloudCache`, `cloudMetadata`, `googleDriveService`, `dropboxService` |
| **Lyrics** | `_currentLyrics`, `_lyricsLoading`, `_lyricsService` |
| **Stems** | `stemController` (StemController) |
| **Play Counts** | `_playCounts` (Map\<int, int\>) — song ID → count |
| **Device** | `_lastOutputDevice`, `_linkAllDevices` |
| **Theme/UI** | `_selectedTheme`, `_songGridExtent`, `_blur`, `_bgQuality`, `_isFancy` |

### PlaylistController
Minimal — manages `List<OnlineSongModel>` for online content discovery.

### DrawerProvider
Controls the ZoomDrawer navigation: `toggleDrawer()`, `openDrawer()`, `closeDrawer()`.

---

## 5. Audio Playback Engine

### HypeAudioHandler (`lib/Helpers/AudioHandler.dart`)

Extends `BaseAudioHandler` for background playback integration with system media controls.

#### Dual-Player Crossfade Architecture

```
┌──────────────┐     ┌──────────────┐
│   Player A   │     │   Player B   │
│  (active)    │ ──▶ │  (inactive)  │
│  Volume: 1.0 │     │  Volume: 0.0 │
└──────────────┘     └──────────────┘
         │                    │
         └───── SWAP ─────────┘
              (20-step fade)
```

- Two `AudioPlayer` instances allow seamless crossfade without audio glitch
- `currentTrackPlayer` points to the player the UI should bind to during crossfade
- After crossfade: old player stops, pointers swap, `onPlayerSwapped` fires to re-bind streams

#### Crossfade Implementation

```
beginCrossfade(nextSource, fadeDuration):
  1. Load next track on _inactivePlayer
  2. Set _inactivePlayer volume = 0.0, play
  3. Compute replay gain volume (if enabled)
  4. 20-step linear fade over fadeDuration:
     - Active:   1.0 → 0.0
     - Inactive: 0.0 → targetVolume
  5. Stop old active player
  6. Swap player pointers
  7. Fire onPlayerSwapped → AppController re-binds all streams
```

#### Buffer Configuration

| Platform | Min Buffer | Max Buffer | Playback Start | After Rebuffer |
|----------|-----------|-----------|----------------|---------------|
| Android | 30s | 30s | 2s | 4s |
| iOS | — | — | auto | 30s forward |

#### Replay Gain

Reads `TXXX:replaygain_track_gain` from ID3 tags, converts dB → linear via `pow(10, dB/20)`, clamps to [0.1, 2.5].

---

## 6. Native DSP Pipeline (C++)

### Signal Chain

All audio processing happens in native C++ code, shared identically between Android and iOS:

```
Input (Interleaved Stereo Float)
  │
  ├─ [Stem Mixer]              // Optional: replaces ExoPlayer audio
  ├─ [Preamp + Auto-Gain]      // ±15 dB, smart peak reduction
  ├─ [Speaker Correction EQ]   // AutoEq profiles, up to 32 biquad bands
  ├─ [Graphic EQ]              // 32-band ISO 1/3-octave (20 Hz–20 kHz)
  ├─ [Parametric EQ]           // 32-band variable type (PK/LS/HS/LP/HP/notch/BP)
  ├─ [Tone Controls]           // Bass shelf + Treble shelf
  ├─ [Multiband Compressor]    // 10 bands, LR4 crossovers (24 dB/oct)
  ├─ [Stereo Expander]         // M/S width control (0.0–2.0)
  ├─ [Crossfeed]               // BS2B headphone spatialization
  ├─ [FDN Reverb]              // Freeverb: 8 comb + 4 allpass per channel
  ├─ [Output Limiter]          // Zero-overshoot, soft-knee, instant attack
  │
  └─ Output (Safety clamp ±1.0f)
```

### Module Details

#### Biquad Filter (`biquad.h`)
- **Design**: Direct Form II Transposed (DF2T), stereo
- **Precision**: Double-precision coefficient computation, float storage
- **Crossfade**: ~2ms coefficient interpolation (96 samples at 48 kHz) prevents clicks
- **Types**: Peaking, LowShelf, HighShelf, LowPass, HighPass, Notch, BandPass
- **Reference**: Audio EQ Cookbook (Robert Bristow-Johnson)

#### Parametric EQ (`parametric_eq.h`)
- 32 bands max, each independently configurable
- Two init modes: generic parametric or ISO 1/3-octave graphic
- Bypass optimization: bands with |gain| < 0.05 dB are skipped (zero CPU)
- `getPeakGain()` returns highest positive boost for auto-gain computation

#### Single-Band Compressor (`compressor.h`)
- Algorithm based on Chromium's DynamicsCompressorKernel
- RMS envelope detection in dB domain
- Log-domain gain computer with soft knee (quadratic interpolation)
- Noise gate / expander below threshold
- Lock-free parameter updates via `std::atomic<>`

#### Multiband Compressor (`multiband_compressor.h`)
- **10 frequency bands** with independent compressors
- **9 Linkwitz-Riley 4th-order crossovers** (two cascaded 2nd-order Butterworth = 24 dB/oct)
- Power-complementary: LP² + HP² = 1 at crossover frequency
- Sequential split topology: input → LP₁/HP₁ → LP₂/HP₂ → ... → 10 bands
- Band centers: 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz
- Stack allocation for ≤512 frames, heap fallback for larger

#### Tone Controls (`tone_controls.h`)
- Bass: low-shelf (default 80 Hz, Q 0.707)
- Treble: high-shelf (default 10 kHz, Q 0.707)
- Gain range: 0–15 dB per control
- Integrated with auto-gain system

#### Output Limiter (`limiter.h`)
- Feed-forward, true-peak, soft-knee
- **Instant attack** (zero overshoot) — gain applied immediately per sample
- Smooth exponential release (default 100 ms)
- Soft knee: 6 dB quadratic transition
- Ceiling: 0.98 (-0.18 dBFS)
- Asymmetric smoothing: instant reduction, smooth recovery

#### FDN Reverb (`fdn_reverb.h/cpp`)
- Freeverb-based feedback delay network
- Per channel: pre-delay → 8 LBCF comb filters → 4 Schroeder allpass filters
- Stereo decorrelation: R channel offset by +23 samples
- Parameters: room size (delay scaling), decay (feedback 0.7–0.98), damping (HF absorption), pre-delay (0–200 ms), diffusion (allpass feedback), wet/dry mix
- Sample-rate adaptive, denormal prevention (ARM FPU flush-to-zero)

#### Stereo Expander (`stereo_expander.h`)
- Mid-Side decomposition with energy-preserving gain compensation
- Width 0.0 (mono) → 1.0 (unity) → 2.0 (max expansion)
- Gain schedule: width ≤ 1.0 reduces side; width > 1.0 boosts side, reduces mid
- Per-sample gain smoothing (~3 ms at 48 kHz)

#### Crossfeed (`crossfeed.h`)
- BS2B-style headphone-to-speaker simulation
- Low-pass on opposite channel (head shadow + ITD simulation)
- Presets: Default (700 Hz, 4.5 dB), Chu Moy (700 Hz, 6.0 dB), Jan Meier (650 Hz, 9.5 dB)

#### Stem Mixer (`stem_mixer.h`)
- 4-track mixer: Vocals, Drums, Bass, Other
- Memory-mapped WAV files via `mmap()` (zero-copy I/O)
- Per-stem: volume (0.0–2.0), mute, solo
- Lock-free atomic controls for thread-safe UI→audio updates
- Sample-accurate seeking

### Auto-Gain System (`room_dsp_engine.cpp`)

```
effectivePreamp = userPreamp - max(graphicPeak, parametricPeak, speakerPeak, tonePeak)
```

- Scans peak boost across all active EQ modules
- Takes single maximum (not sum) — avoids over-reduction
- Asymmetric smoothing: instant reduction, smooth increase
- Output limiter catches residual ~3 dB from adjacent band overlap

### Android Integration

- **`RoomEffectsProcessor.java`**: ExoPlayer `BaseAudioProcessor` subclass
- Per-player instances via `createPlayerInstance()` (critical for crossfade)
- Cached params applied to new native handles in `onFlush()`
- Supports PCM 16-bit and float encoding

### iOS Integration

- **`dsp_bridge.h/cpp`**: Plain C API wrapping C++ engine (usable from Swift)
- **`DSPManager.swift`**: Singleton wrapping all C bridge functions
- Audio tap installed on AVAudioEngine for real-time processing

### Build Configuration

- **C++ Standard**: C++17
- **Optimization**: `-O3 -ffast-math`
- **Prebuilt Libraries**: projectM-4 (visualizer), chromaprint (fingerprinting)

---

## 7. Platform Bridge (Channel)

**MethodChannel**: `"eq_app"` — bidirectional Dart ↔ Native
**EventChannels**: `"eq_app/dvc_volume_button"`, `"eq_app/stem_progress"`

### Complete Method Inventory

#### EQ & DSP Core
| Method | Purpose |
|--------|---------|
| `enableEq(bool)` | Toggle graphic EQ |
| `setGraphicBandGain(band, gain)` | Set single band |
| `setGraphicAllBands(List<double>)` | Set all 32 bands |
| `setParametricBand(band, freq, gain, q, type, enabled)` | Set parametric band |
| `setParametricAllBands(freqs, gains, qs)` | Set all parametric bands |
| `setPreamp(gain)` | Set preamp (0–15 dB) |
| `enableMbc(bool)` | Toggle multiband compressor |

#### Tone Controls
| Method | Purpose |
|--------|---------|
| `dspSetToneEnabled(bool)` | Toggle bass/treble |
| `dspSetBassGain/Freq/Q(double)` | Bass shelf parameters |
| `dspSetTrebleGain/Freq/Q(double)` | Treble shelf parameters |

#### Room Effects
| Method | Purpose |
|--------|---------|
| `dspSetReverbEnabled(bool)` | Toggle reverb |
| `dspSetRoomSize/Decay/Damping/PreDelay/Diffusion/WetDry(double)` | Reverb parameters |
| `dspSetStereoExpandEnabled/Width(bool/double)` | Stereo expander |
| `dspSetCrossfeedEnabled/Params(bool/cutoff,feed)` | BS2B crossfeed |

#### Output Protection
| Method | Purpose |
|--------|---------|
| `dspSetLimiterEnabled(bool)` | Toggle limiter |
| `dspSetLimiterCeiling/Release/Knee(double)` | Limiter parameters |

#### Speaker Correction
| Method | Purpose |
|--------|---------|
| `setSpeakerEqEnabled(bool)` | Toggle speaker EQ |
| `setSpeakerEqBands(List<Map>)` | Apply AutoEq profile bands |
| `clearSpeakerEq()` | Reset speaker EQ |

#### DVC (Direct Volume Control)
| Method | Purpose |
|--------|---------|
| `enableDvc() / disableDvc()` | Toggle DVC |
| `setDvcGain(dB)` | Set gain (-30 to 0 dB) |
| `dvcVolumeButtonStream` | Hardware volume button events |

#### Audio Fingerprinting & Metadata
| Method | Purpose |
|--------|---------|
| `generateFingerprint(filePath)` | Chromaprint generation |
| `extractAudioMetadata(url, headers)` | Native MMR extraction |
| `writeTags(filePath, tags, artworkPath)` | ID3 tag writing |
| `readLyrics / writeLyrics(filePath)` | USLT tag access |

#### Stem Separation
| Method | Purpose |
|--------|---------|
| `separateStems(filePath, outputDir)` | Run Spleeter |
| `loadStems(vocals, drums, bass, other)` | Load WAV stems |
| `setStemVolume/Mute/Solo(stem, value)` | Mixer controls |
| `stemProgressStream` | Separation progress events |

#### Global EQ (Android only)
| Method | Purpose |
|--------|---------|
| `enableGlobalEq(bool)` | System-wide EQ |
| `getPlayingApps()` | List apps playing audio |
| `startEqModeService(preset)` | Foreground service notification |

---

## 8. Equalizer & Audio Effects

### Graphic EQ

- 32 native bands (ISO 1/3-octave: 20 Hz – 20 kHz)
- UI display modes: 5, 10, 16, 20, or 32 bands
- `BandMapping` system maps display sliders → groups of native bands
- **16 built-in presets**: Flat, Bass Boost, Treble Boost, V-Shape, Vocal, Electronic, Rock, Jazz, Classical, Hip Hop, R&B, Pop, Metal, Acoustic, Podcast, Loudness
- Custom presets: save/load/delete with full graphic + parametric + preamp state
- Per-device presets: separate EQ for speaker, bluetooth, wired headphones

### Parametric EQ

- Up to 32 user-defined points
- Per-point: frequency (20–20k Hz), gain (±15 dB), Q (0.3–10.0), enabled flag
- Interactive graph: drag points on logarithmic frequency response curve
- Color-coded points (up to 8 colors)

### Tone Controls

- Dedicated bass/treble shelf filters with rotary knob UI
- Bass: 20–250 Hz, Treble: 5–15 kHz
- Q factor adjustable (0.1–2.0) for slope control

### Room Reverb

- **11 presets**: Off, Small Room, Medium Room, Large Room, Hall, Cathedral, Plate, Studio, Chamber, Arena, Concert
- 6 parameters: room size, decay, damping, pre-delay, diffusion, wet/dry
- Custom preset tracking

### Speaker Correction (AutoEq)

- **6,028 headphone/speaker profiles** from the AutoEq repository
- Sources: oratory1990 (736), crinacle (1,583), Rtings (605), Innerfidelity (764), Super Review (586), + 18 others
- Categories: over-ear (2,055), in-ear (3,862), earbud (111)
- Format: up to 10 biquad filters per profile (PK, LSC, HSC) with preamp
- Search and category filtering in UI

### Multiband Compressor

- 10 bands with Linkwitz-Riley 4th-order crossovers
- Per-band: threshold, ratio, attack/release, pre/post gain
- Global controls: noise gate, knee width, expander ratio, pre-gain

### Mutually Exclusive Features

- Gapless ↔ Crossfade (crossfade > 0 forces gapless OFF)
- Stereo Expand ↔ Crossfeed (auto-disable other when enabling one)

---

## 9. Cloud Music Streaming

### Architecture

```
┌──────────────┐    ┌──────────────┐
│ Google Drive  │    │   Dropbox    │
└──────┬───────┘    └──────┬───────┘
       │                    │
  ┌────┴────────────────────┴────┐
  │       CloudAuthService        │
  │  (OAuth tokens, refresh,      │
  │   flutter_secure_storage)     │
  └──────────────┬───────────────┘
                 │
  ┌──────────────┴───────────────┐
  │      CloudCacheService        │
  │  (LRU eviction, resume DL,   │
  │   file list persistence)      │
  └──────────────┬───────────────┘
                 │
  ┌──────────────┴───────────────┐
  │    CloudMetadataService       │
  │  (Native MMR extraction,      │
  │   batch processing, markers)  │
  └──────────────────────────────┘
```

### Cloud Auth

- **Google Drive**: `google_sign_in` with DRIVE_READONLY scope, automatic token refresh
- **Dropbox**: PKCE OAuth 2.0 via `flutter_appauth`, refresh tokens in secure storage
- Session persistence: auto-restore on app restart

### Caching Strategy

1. Check if file cached → play from disk (zero network)
2. Not cached + StreamingDataGuard allows → stream with Range headers
3. Background prefetch: next 2 tracks on WiFi
4. Resume-capable: `.part` files with Range header support
5. LRU eviction: orphan cleanup after 7 days

### Metadata Extraction

- Native `MediaMetadataRetriever` via Channel — handles ALL audio formats
- Batch processing: 3 concurrent extractions
- `.done` markers prevent re-extraction
- Stale marker cleanup for previously-failed extractions

### Streaming Data Guard

- Network-aware: WiFi, cellular, offline detection
- Configurable MB cap per session on cellular (default 100 MB)
- Data saver mode: reduces buffer sizes, limits bitrate
- Stream notifications: broadcasts network state changes

---

## 10. Lyrics System

### Multi-Source Loading Priority

```
1. .lrc sidecar file (next to audio file)
2. ID3 USLT tag (via id3tag Dart package)
3. Native mp3agic fallback (via Channel)
4. Backend API + LRCLIB.net (auto-save .lrc on success)
```

### LRC Format Support

- Metadata tags: `[ti]`, `[ar]`, `[al]`, `[offset]`
- Synced timestamps: `[mm:ss.xx]` per line
- Word-level timing: `<mm:ss.xx>word` syntax (parsed, ready for future use)
- Bidirectional: `parseLrc()` and `encodeLrc()`

### Display Animation (Apple Music Style)

- **Shimmer reveal**: Left-to-right gradient sweep on current line
  - Warm golden shimmer edge (`#FFF4D6`) at the gradient boundary
  - `TweenAnimationBuilder` smooths between 200ms position stream updates
  - `ShaderMask` with `BlendMode.modulate`: revealed (white) → shimmer → unrevealed (35% alpha)
- **Stretch effect**: Current line `scaleY: 1.0`, past lines compress to `scaleY: 0.94`
- **Opacity cascade**: Current = 1.0, past ±2 = 0.25, future ±1 = 0.55, distant = 0.2
- **Auto-scroll**: `Scrollable.ensureVisible` with 600ms `easeInOutCubic`
- **User scroll lock**: 4-second timeout before snapping back to current line
- **Seek-to-line**: Tap any line to seek player to that timestamp

### Lyrics Editor

- Dual mode: plain text vs synced timestamps
- Line stamping: `[mm:ss.xx]` insertion at cursor position
- Save targets: `.lrc` sidecar file and/or ID3 USLT tag

---

## 11. Audio Fingerprinting & Recognition

### Multi-Stage Pipeline

```
1. Chromaprint fingerprint generation (native C++, Android only)
2. AcoustID lookup (api.acoustid.org)
   └─ Score-ranked results with recording metadata
3. MusicBrainz enrichment
   └─ Artist credits, ISRC, release dates, cover art
4. ACRCloud fallback (all platforms)
   └─ 1MB audio sample, HMAC-SHA1 signed POST
```

### Rate Limiting

- AcoustID: 334ms between calls (3/sec max)
- MusicBrainz: 1 second between calls (per API ToS)
- Batch identification: 350ms delay between songs

### Tag Writing

After identification: populates title, artist, album, year, ISRC, then fetches and embeds cover art from MusicBrainz Cover Art Archive.

### Caching

Two-tier: in-memory + SharedPreferences keyed by file path hash.

---

## 12. Stem Separation & Mixing

### Architecture

- **Engine**: Spleeter (runs in native `StemSeparationService` on Android)
- **Output**: 4 WAV files (vocals.wav, drums.wav, bass.wav, other.wav)
- **Storage**: MD5-hashed song paths in temp directory
- **Progress**: EventChannel streaming percentage + status message

### Real-Time Mixer

- Per-stem controls: volume (0.0–2.0), mute, solo
- Memory-mapped WAV files via `mmap()` (zero-copy)
- Lock-free atomic controls (safe UI → audio thread)
- Presets: Karaoke (mute vocals), Acapella (solo vocals), Instrumental (mute vocals)
- Sample-accurate seeking

### UI States

```
No stems → "Separate" button
Separating → circular progress + cancel button
Ready → mixer panel with 4 faders + mute/solo toggles
```

---

## 13. Visualizer System

### Dual-Path FFT

| Platform | Method | Transport |
|----------|--------|-----------|
| Android | C++ FFT via ExoPlayer AudioProcessor | EventChannel streams |
| iOS | MTAudioProcessingTap + vDSP | MethodChannel callback |

### Built-In Visualizers (15+)

**2D Visualizers:**
- Radial Burst (120 lines from center, bass-reactive ring)
- Mirror Bars (56 mirrored equalizer bars)
- Waveform Line (oscilloscope with glow)
- Spectrum, Terrain, Matrix, Silk, Lissajous, Windmill

**3D Visualizers:**
- Neon Grid Horizon (synthwave receding grid)
- 3D Ring, Ribbons, 3D Lissajous, Particles
- Shared 3D projection with focal length 300.0
- Multi-pass neon glow rendering

### projectM / MilkDrop

- Flutter Texture integration via native renderer
- Preset management: next/previous, auto-cycle, lock
- Performance tuning: FPS (15–60), beat sensitivity, mesh resolution
- Thousands of community presets from `assets/milkdrop_presets/`

---

## 14. Music Library & Querying

### Files.dart — Query Layer

```dart
fetchAllSongs()              → List<SongModel>   // on_audio_query + iOS scanner
fetchAllArtists()            → List<ArtistModel>  // platform + iOS fallback
fetchAllAlbums()             → List<AlbumModel>
fetchAllGenres()             → List<GenreModel>
fetchMostRecentlyPlayed()    → List<SongModel>   // sorted by dateAdded DESC
queryFromFolder(path)        → List<SongModel>
fetchSongsForArtist(id)      → List<SongModel>
fetchSongsForAlbum(id)       → List<SongModel>
fetchSongsForGenre(id)       → List<SongModel>
```

### iOS Local Music Scanner

- Scans `Documents/Music` folder for 9 audio formats
- Supplements iTunes library via `on_audio_query`
- Native AVFoundation metadata extraction
- Filename parsing fallback: "Artist - Title" pattern

### on_audio_query Plugin

Custom fork at `plugins/on_audio_query/`:
- Platform interfaces for Android (MediaStore) and iOS (MPMediaQuery)
- Models: `SongModel`, `ArtistModel`, `AlbumModel`, `GenreModel`, `PlaylistModel`
- Artwork extraction from audio files

---

## 15. Search & Discovery

### Search Page

- Full `StatefulWidget` page (replaced `SearchDelegate`)
- **300ms debounce** on input to prevent excessive rebuilds
- **Empty query**: "Most Played" + "Recently Added" horizontal artwork cards with play count badges
- **With query**: Categorized sections:
  - Songs (max 5, "See all" expand)
  - Artists (horizontal avatar circles)
  - Albums (horizontal artwork cards)
  - Folders (list items, Android only)
  - Playlists (list items, Android only)
  - Cloud files (from cached file lists)
- Lazy-loads supplemental data on first query, caches for session

### Play Count Tracking

- `Map<int, int>` in AppController (song ID → count)
- Persisted as JSON in SharedPreferences (`'playCounts'` key)
- Incremented in `songId` setter when a song starts playing
- `getMostPlayed(limit)` and `getRecentlyAdded(limit)` for search page

### Discover View

- Hot 100 chart, Popular songs, Artist directory
- Data from streaming service (nowviba.com endpoints)
- Coach marks for first-time guidance

---

## 16. UI Architecture

### Navigation Structure

```
Home (SliverAppBar + scrollable TabBar)
├─ Folders (Android)     → FolderSongs    → Player
├─ Playlists (Android)   → PlaylistSongs  → Player
├─ Artists               → ArtistSongs    → Player
├─ Albums                → AlbumSongs     → Player
├─ Genres                → GenreSongs     → Player
├─ Songs                                  → Player
├─ Discover              → search/charts  → Player
└─ Cloud                 → CloudFolderSongs → Player

Full-Screen Routes:
├─ SearchPage (Routes.scaleTo)
├─ Settings (MaterialPageRoute)
├─ Equalizer → GraphicEQ | Tone | Parametric | Space | SpeakerEQ
├─ VisualUI (full-screen visualizer)
├─ Player (full-screen playback)
└─ LyricsView (modal from Player)
```

### Route Transitions

| Method | Effect | Duration |
|--------|--------|----------|
| `Routes.routeTo()` | Fade + Scale | 500ms |
| `Routes.scaleTo()` | Shared-axis Z (scale + fade) | 400ms |
| `Routes.animateTo()` | OpenContainer (expand) | 500ms |

### Hero Animations

All detail pages use Hero transitions on artwork: `tag: 'artist_{id}'`, `'album_{id}'`, `'playlist_{id}'`, `'genre_{id}'`, `'folder_{path}'`

### PinchZoomGrid

Custom widget for continuous pinch-to-zoom between grid and list layouts:
- Two-finger gesture tracking via raw `Listener`
- Continuous extent change (80–300 pt) reflows grid in real-time
- **3D perspective transition** between grid and list modes:
  - 50px blend zone approaching list threshold
  - Grid tilts backward (`rotateX` + translateY + scale down)
  - List tilts forward from below
  - `easeInOutCubic` curve, `ClipRect` prevents overflow
- Snap animation to nearest clean column count on release
- Haptic feedback on snap

---

## 17. Player UI & Animations

### Card Deck (Swipe Navigation)

- `AnimatedPlayerCard` with throw-and-rotate physics
- Each card shows its own track's artwork + title/artist overlay
- Controls trigger `animateToNext()`/`animateToPrevious()` via GlobalKey
- `_animatingFromControls` flag prevents double-fire on page change

### WaveformSeekBar

- `CustomPainter` with seeded random bar heights (regenerated per track)
- Active/inactive coloring based on playback progress
- Interactive: drag and tap via `GestureDetector`, fires `onChangeEnd` for seeking

### Bottom Player (Mini Player)

- Shows when music is playing (below library tabs)
- Small artwork (40×40), title, artist, play/pause
- Tap to expand to full Player

### Settings Shortcuts

Small gear icons (20px, 35–40% opacity) placed in:
- Player Header (replaces balance spacer)
- Lyrics Header (after edit button)
- Visualizer (top-right corner, Positioned)
- Equalizer (AppBar actions — already existed)

---

## 18. Onboarding & Coach Marks

### First-Launch Flow

```
App Launch → ModeChooser (Music Player or EQ-Only)
  → OnboardingScreen (swipeable tutorial pages)
    → Music mode: 6 pages (welcome, EQ, room, library, playback, finish)
    → EQ mode: 3 pages (welcome, EQ, room)
  → AssetLoader (metadata processing)
  → Home
```

### Coach Marks System

- `CoachMarkController` with `tutorial_coach_mark` package
- Target widgets via `GlobalKey`
- Custom `CoachStep` with title, description, icon, tooltip position
- Shown once per screen (tracked in SharedPreferences)
- Auto-trigger after 1.5s delay on first visit

### Pages with Coach Marks

- Home: tabs, discover, songs, search, menu
- Discover: search, charts, popular, artists
- Player: card swipe, seek bar, controls

---

## 19. Build Configuration

### Android

| Setting | Value |
|---------|-------|
| Package | `x.a.zix` |
| Min SDK | Flutter default (24) |
| Target SDK | Flutter default (36) |
| NDK | Flutter default |
| Kotlin | 2.1.0 |
| AGP | 8.13.0 |
| ABIs | armeabi-v7a, arm64-v8a, x86_64 |
| ProGuard | Enabled (release) |

### Android Permissions

```
INTERNET, ACCESS_NETWORK_STATE
READ_EXTERNAL_STORAGE, WRITE_EXTERNAL_STORAGE, READ_MEDIA_AUDIO
BLUETOOTH, BLUETOOTH_CONNECT, BLUETOOTH_ADMIN
MODIFY_AUDIO_SETTINGS, RECORD_AUDIO
WAKE_LOCK, FOREGROUND_SERVICE, FOREGROUND_SERVICE_MEDIA_PLAYBACK
REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
```

### Android Services

| Service | Purpose |
|---------|---------|
| AudioService | Media playback (foreground) |
| GlobalEqService | System-wide EQ processing |
| EqModeService | EQ preset mode |
| EngineService | DSP engine lifecycle |
| StemSeparationService | Background stem separation |
| MediaNotificationListener | System notification interception |

### iOS

| Setting | Value |
|---------|-------|
| Deployment Target | 15.0 |
| Background Modes | audio |
| File Sharing | Enabled |
| Supported Formats | mp3, m4a, flac, wav, ogg, aiff, aac, wma |

### iOS Pods

```
AppAuth ~> 2.0     (OAuth)
HypeDSP (local)    (C++ DSP engine)
ProjectM (local)   (MilkDrop visualizer)
```

---

## 20. Platform Differences

| Feature | Android | iOS |
|---------|---------|-----|
| DSP Engine | JNI → C++ | C bridge → C++ |
| Global EQ | Yes (system session) | No (OS restriction) |
| Stem Separation | Spleeter service | Not available |
| Fingerprinting | Chromaprint native | Not available |
| Tag Writing | jaudiotagger + MediaStore | Not available |
| DVC | LoudnessEnhancer + volume capture | Not available |
| Folders | queryAllPath() | Not available |
| Playlists | queryPlaylists() | Not available |
| Visualizer FFT | ExoPlayer AudioProcessor tap | MTAudioProcessingTap |
| Music Scanner | MediaStore | MPMediaQuery + Documents/Music scan |
| File Import | Automatic (MediaStore) | FilePicker → Documents/Music |
| Deep Linking | Intent filters | URL schemes |

---

## 21. Data Persistence

### SharedPreferences Keys (Complete)

**Playback**: `gaplessPlayback`, `crossfadeDuration`, `replayGain`, `isShuffled`

**DVC**: `dvcEnabled`, `dvcGain`, `dvcFineSteps`

**Graphic EQ**: `graphicEqEnabled`, `activePresetName`, `graphicBandGains` (JSON), `eqPresets` (JSON), `preampGain`, `eqBandCount`, `linkAllDevices`, `lastOutputDevice`

**Parametric EQ**: `parametricPoints` (JSON)

**MBC**: `mbcEnabled`, `dspNoise`, `kneeWidth`, `expandRatio`, `preGain`

**Reverb**: `reverbEnabled`, `dspRoomSize`, `dspDecay`, `dspDamping`, `dspPreDelay`, `dspDiffusion`, `dspWetDry`, `activeRoomPresetName`

**Spatial**: `stereoExpandEnabled`, `dspStereoWidth`, `crossfeedEnabled`, `crossfeedCutoff`, `crossfeedFeed`

**Tone**: `toneEnabled`, `bassGain`, `bassFreq`, `bassQ`, `trebleGain`, `trebleFreq`, `trebleQ`

**Limiter**: `limiterEnabled`

**Speaker EQ**: `speakerEqEnabled`, `activeSpeakerProfile`

**Visualizer**: `visualizerStyle`, `visualizerColor`, `visualizerFrameRate`, `visualizerReactivity`, `visualizerBeatSensitivity`, `milkdropFps`, `milkdropBeatSensitivity`, `milkdropPresetDuration`, `milkdropPresetLocked`, `milkdropPresetName`, `milkdropQuality`

**UI**: `songGridExtent`, `visuals`, `blur`, `bgQuality`, `selectedTheme`, `fancyMode`

**App Mode**: `appMode` (int)

**Play Counts**: `playCounts` (JSON Map\<String, int\>)

**Global EQ**: `globalEqEnabled`

**Cloud**: `cloudFiles_googleDrive` (JSON), `cloudFiles_dropbox` (JSON), OAuth tokens in flutter_secure_storage

---

## 22. Dependencies

### Core Audio
| Package | Version | Purpose |
|---------|---------|---------|
| `just_audio` | ^0.10.4 (custom fork) | Audio playback engine |
| `audio_service` | ^0.18.15 | Background playback + notifications |
| `on_audio_query` | local plugin | Media library querying |
| `id3tag` | ^0.2.0 | ID3 tag parsing |

### State Management
| Package | Version | Purpose |
|---------|---------|---------|
| `provider` | ^6.0.5 | ChangeNotifier state management |
| `flutter_bloc` | ^9.1.1 | BLoC pattern (minimal use) |

### Cloud & Auth
| Package | Version | Purpose |
|---------|---------|---------|
| `google_sign_in` | ^7.2.0 | Google OAuth |
| `flutter_appauth` | ^12.0.0 | OAuth 2.0 / PKCE flows |
| `flutter_secure_storage` | ^9.2.2 | Credential storage |
| `dio` | ^5.9.2 | HTTP client + interceptors |

### Firebase
| Package | Version | Purpose |
|---------|---------|---------|
| `firebase_core` | ^4.2.0 | Firebase base |
| `firebase_analytics` | ^12.0.3 | Usage analytics |
| `firebase_crashlytics` | ^5.0.3 | Crash reporting |

### UI
| Package | Version | Purpose |
|---------|---------|---------|
| `animations` | ^2.0.8 | Material motion transitions |
| `flutter_zoom_drawer` | ^3.2.0 | Navigation drawer |
| `sleek_circular_slider` | ^2.0.1 | Rotary knobs |
| `tutorial_coach_mark` | ^1.2.9 | Onboarding coach marks |
| `flutter_shaders` | ^0.1.3 | GLSL fragment shaders |
| `wiredash` | ^2.1.2 | In-app feedback |

### Storage & Utilities
| Package | Version | Purpose |
|---------|---------|---------|
| `shared_preferences` | ^2.2.1 | Local settings persistence |
| `path_provider` | ^2.1.1 | App directory paths |
| `crypto` | ^3.0.3 | SHA hashing |
| `connectivity_plus` | ^7.0.0 | Network state detection |

---

## 23. File Structure

```
lib/
├── main.dart                          # Entry point, providers, Firebase
├── config/
│   └── app_config.dart                # Environment config (--dart-define)
├── controllers/
│   ├── AppController.dart             # Master state (~20K lines)
│   ├── PlaylistController.dart        # Online songs
│   ├── PlayerController.dart          # UI text state
│   ├── drawer_controller.dart         # Navigation drawer
│   └── stem_controller.dart           # Stem separation state
├── models/
│   ├── cloud_file.dart                # Cloud storage file model
│   ├── eq_models.dart                 # EQ presets, parametric points, band mapping
│   ├── lyrics_model.dart              # LRC parsing, word-level timing
│   ├── OnlineSongModel.dart           # Streaming song model
│   ├── recognition_result.dart        # Fingerprint match result
│   ├── room_preset.dart               # Reverb presets
│   ├── speaker_profile.dart           # AutoEq profiles (6,028)
│   └── stem_model.dart                # Stem cache management
├── services/
│   ├── cloud_auth_service.dart        # Google + Dropbox OAuth
│   ├── cloud_cache_service.dart       # LRU cache, resume downloads
│   ├── cloud_metadata_service.dart    # Native MMR metadata extraction
│   ├── google_drive_service.dart      # Google Drive API wrapper
│   ├── dropbox_service.dart           # Dropbox API wrapper
│   ├── fingerprint_service.dart       # Chromaprint + AcoustID + ACRCloud
│   ├── lyrics_service.dart            # Multi-source lyrics loading
│   ├── local_music_scanner.dart       # iOS Documents/Music scanner
│   ├── streaming_data_guard.dart      # Cellular data metering
│   └── music/                         # Discover/streaming models
├── Helpers/
│   ├── AudioHandler.dart              # HypeAudioHandler (dual-player crossfade)
│   ├── Channel.dart                   # MethodChannel bridge (100+ methods)
│   ├── Files.dart                     # on_audio_query wrapper
│   ├── fileloader.dart                # Metadata batch processor
│   ├── AudioVisualizer.dart           # FFT data provider
│   ├── ProjectMController.dart        # MilkDrop integration
│   ├── VisualizerWidget.dart          # Visualizer builder widget
│   └── index.dart                     # Global helpers, loadAudioSource
├── pages/
│   ├── home.dart                      # Main tab navigation
│   ├── songs.dart / artists.dart / albums.dart / genres.dart
│   ├── folders.dart / playlist.dart / playlist_songs.dart
│   ├── search_page.dart               # Enhanced multi-category search
│   ├── recents.dart                   # Recently played
│   ├── settings.dart                  # All app settings
│   ├── equalizer.dart                 # EQ hub (5 tabs)
│   ├── graphic_eq_view.dart           # 32-band graphic EQ
│   ├── parametric_eq_view.dart        # Interactive parametric EQ
│   ├── tone_view.dart                 # Bass/treble knobs
│   ├── speaker_eq_view.dart           # AutoEq profile browser
│   ├── dynamics_view.dart             # MBC compressor
│   ├── audio_fx.dart                  # Preamp, limiter
│   ├── visual_ui.dart                 # Visualizer page
│   ├── loader.dart                    # Splash screen
│   ├── stem_processing_view.dart      # Stem separation progress
│   └── cloud/
│       ├── cloud_view.dart            # Cloud file browser
│       ├── cloud_folder_songs.dart    # Cloud folder detail
│       └── discover_view.dart         # Charts, trending, artists
├── player/
│   ├── player_ui.dart                 # Full-screen player
│   ├── player_body.dart               # Background artwork + blur
│   ├── swipe_animation.dart           # Card deck swipe
│   ├── lyrics_view.dart               # Synced lyrics + shimmer
│   └── widgets/
│       ├── Header.dart                # NOW PLAYING bar
│       ├── Controls.dart              # Play/pause/skip/shuffle/repeat
│       ├── LyricsEditor.dart          # LRC editor
│       └── stem_button.dart           # Stem mixer toggle
├── widgets/
│   ├── song_tile.dart                 # SongTile + SongListView
│   ├── ArtworkWidget.dart             # Artwork loading/caching
│   ├── BottomPlayer.dart              # Mini player bar
│   ├── Body.dart                      # Page background manager
│   ├── pinch_zoom_grid.dart           # 3D pinch zoom grid/list
│   ├── common.dart                    # WaveformSeekBar, formatTime
│   └── song_options_sheet.dart        # Song context menu
├── onboarding/
│   ├── mode_chooser.dart              # Music vs EQ mode
│   ├── onboarding_screen.dart         # Tutorial pages
│   ├── coach_marks.dart               # Spotlight walkthrough
│   └── home_guide.dart                # Home-specific guide
├── visualizers/
│   ├── radial_burst_painter.dart      # Radial burst painter
│   ├── waveform_line_painter.dart     # Waveform line painter
│   ├── visualizer_styles.dart         # Style registry
│   ├── spectrum_bars/                 # Built-in spectrum styles
│   │   ├── presets.dart               # Preset definitions
│   │   ├── analyzer.dart              # Smoothing, peaks, trails
│   │   ├── geometry.dart              # Bar / mesh geometry
│   │   ├── frame.dart                 # Frame rendering
│   │   └── spectrum_bars_view.dart    # Widget (ticker driven)
│   ├── bass_beat.dart, beat_detector.dart, beat_frame.dart
│   ├── radial_motion.dart, radial_scene.dart
│   ├── multiwave_visualizer.dart
│   └── wave-visualizer.dart           # Wave visualizer
├── Routes/routes.dart                 # Navigation + transitions
├── Global/index.dart                  # Shared widgets, loadAudioSource
└── exports/exports.dart               # Central re-exports

android/app/src/main/
├── kotlin/x/a/zix/
│   ├── MainActivity.java              # MethodChannel, DVC, ProjectM
│   ├── RoomEffectsProcessor.java      # ExoPlayer AudioProcessor (DSP)
│   ├── DvcController.java             # Volume control + observer
│   ├── GlobalEqService.java           # System-wide EQ service
│   ├── StemSeparationService.java     # Spleeter background service
│   ├── AudioVisualizer.java           # FFT extraction
│   ├── FingerprintEngine.java         # Chromaprint JNI
│   ├── ProjectMRenderer.java          # MilkDrop renderer
│   └── ... (22 Java files total)
├── cpp/
│   ├── room_dsp_engine.h/cpp          # DSP orchestrator
│   ├── biquad.h                       # Filter foundation
│   ├── parametric_eq.h                # 32-band EQ
│   ├── compressor.h                   # Single-band compressor
│   ├── multiband_compressor.h         # 10-band MBC
│   ├── tone_controls.h                # Bass/treble shelves
│   ├── limiter.h                      # Output limiter
│   ├── fdn_reverb.h/cpp               # Freeverb delay network
│   ├── stereo_expander.h              # M/S width
│   ├── crossfeed.h                    # BS2B headphone
│   ├── stem_mixer.h                   # 4-track mmap mixer
│   ├── fft_visualizer.h               # FFT analysis
│   ├── jni_bridge.cpp                 # JNI functions
│   └── CMakeLists.txt                 # C++17, -O3, -ffast-math
└── AndroidManifest.xml                # Permissions, services

ios/
├── Runner/
│   ├── AppDelegate.swift              # MethodChannel, DSP, visualizer
│   └── Info.plist                     # Permissions, URL schemes
├── HypeDSP/
│   ├── include/dsp_bridge.h           # C API for Swift
│   └── src/                           # All C++ DSP modules (identical to Android)
└── Podfile                            # AppAuth, HypeDSP, ProjectM

assets/
├── autoeq.json                        # 6,028 speaker correction profiles
├── shaders/sea.frag                   # GLSL visualizer shader
├── milkdrop_presets/                  # projectM preset library
└── icon.png                           # App icon
```

---

## 24. Design Patterns

### Singleton with Dependency Injection
```dart
AppController._instance  // static singleton
AppController(prefs, handler)  // constructor injection
```
Allows both Provider-based reactivity and direct access from non-widget code.

### Dual-Player Crossfade
Two `AudioPlayer` instances swap roles for seamless track transitions without audio glitch.

### Lock-Free DSP Communication
All C++ DSP parameters use `std::atomic<>` for thread-safe UI → audio thread updates without mutexes.

### Cached + Broadcast (Native DSP)
`RoomEffectsProcessor` caches all parameters and broadcasts to all player instances. New handles receive full state on `onFlush()`.

### Platform Channel Forwarding
All DSP commands: `Dart setter → Channel method → JNI/C bridge → C++ engine`. No audio processing in Dart.

### Pre-Compute & Cache
- Artwork → temp directory
- Lyrics → memory cache
- Play counts → JSON in SharedPreferences
- Speaker profiles → asset bundle
- Cloud files → metadata markers + file lists

### Mutually Exclusive Features
Setters enforce exclusivity: gapless ↔ crossfade, stereo expand ↔ crossfeed, music mode ↔ EQ mode.

### Graceful Degradation
Multi-fallback chains (lyrics: lrc → ID3 → native → API; fingerprint: AcoustID → MusicBrainz → ACRCloud) with silent failure at each stage.

### Energy-Preserving Transforms
M/S decomposition and Hadamard mixing include compensation factors to maintain perceived loudness.

### Asymmetric Smoothing
Instant attack + smooth release in limiter and auto-gain — prevents transient clips while avoiding pumping.

---

## 25. Future Prospects

### Audio Engine Enhancements

- **Convolution reverb**: Load custom impulse responses (IR files) for realistic room simulation, replacing the algorithmic Freeverb with true captured spaces
- **Linear-phase EQ mode**: FIR filter alternative for mastering-quality correction without phase distortion
- **Oversampling**: 2x/4x oversampling in the EQ stage to reduce aliasing artifacts on high-frequency boosts
- **AI-powered auto-EQ**: Analyze headphone + ear canal response via microphone measurement, generate personalized correction curve
- **Loudness normalization (EBU R128)**: Integrated loudness measurement with true-peak limiting for consistent playback levels across tracks
- **Spatial audio / binaural rendering**: HRTF-based 3D audio positioning, Dolby Atmos-style object rendering for headphones

### Playback & Library

- **Android Auto / CarPlay integration**: Media browse tree, voice commands, steering wheel controls
- **Chromecast / AirPlay streaming**: Cast audio to external speakers with DSP applied before transmission
- **Playlist intelligence**: Auto-generated playlists based on play history, time of day, and audio features (tempo, energy, mood)
- **Queue management**: Drag-to-reorder, "Play Next" / "Add to Queue" from any song context
- **Multi-room sync**: Synchronized playback across multiple devices on the same network
- **Podcast support**: RSS feed parsing, variable speed playback, chapter markers, sleep timer
- **Audio bookmarks**: Mark and return to specific positions in long-form audio

### Cloud & Sync

- **OneDrive / iCloud support**: Additional cloud storage providers
- **Cross-device sync**: Sync playlists, play counts, EQ presets, and playback position across devices via Firebase
- **Offline mode**: Pre-download entire playlists/folders for airplane mode with intelligent cache management
- **Collaborative playlists**: Share playlists with other Hype users, real-time collaborative editing

### DSP & Effects

- **Per-song EQ memory**: Auto-apply saved EQ settings when a specific song plays
- **Vocal enhancement**: De-esser, presence boost, clarity enhancement for podcast/audiobook content
- **Surround upmixing**: Stereo-to-5.1/7.1 upmixing for headphone virtualization
- **Dynamic EQ**: Frequency-dependent compression (e.g., tame harsh 3 kHz only when it exceeds threshold)
- **Tube/tape saturation**: Analog warmth emulation with harmonic distortion modeling

### Stem Separation

- **iOS support**: Port Spleeter or integrate Demucs for on-device separation on iOS
- **Real-time separation**: GPU-accelerated model inference for live separation during playback
- **5-stem model**: Separate piano/guitar as a 5th stem
- **Remix export**: Export remixed stems as a new audio file (WAV/FLAC)
- **Stem-aware EQ**: Apply different EQ curves to each stem independently

### Lyrics & Recognition

- **Word-level karaoke**: Animate individual words using the already-parsed `<mm:ss.xx>word` timing data
- **Lyrics translation**: Real-time translation overlay for foreign-language songs
- **Crowd-sourced corrections**: Allow users to submit timing corrections back to LRCLIB
- **Music video sync**: Match lyrics to music video timestamps

### Visualizers

- **Audio-reactive wallpaper**: Export visualizer as Android live wallpaper
- **Custom shader editor**: In-app GLSL editor for user-created visualizers
- **AR visualizer**: Camera passthrough with audio-reactive AR overlays
- **Waveform overview**: Full-track waveform thumbnail in seek bar (like SoundCloud)

### Platform & Distribution

- **Wear OS / Apple Watch companion**: Remote control, now-playing display, heart rate-synced BPM
- **Widget support**: Home screen widgets for quick playback control and now-playing info
- **macOS / Windows desktop**: Flutter desktop build with system audio capture for EQ-only mode
- **Plugin system**: Allow third-party DSP plugins (VST-like architecture for mobile)

### Analytics & Social

- **Listening statistics dashboard**: Weekly/monthly reports (top artists, genres, listening time)
- **Scrobbling**: Last.fm, ListenBrainz integration for play history tracking
- **Social sharing**: Share currently playing track with artwork as Instagram/Twitter card
- **Music taste profile**: Genre/mood analysis based on listening history with visual breakdown

---

*This document was generated from a complete codebase analysis of every source file in the Hype Muzik project.*
