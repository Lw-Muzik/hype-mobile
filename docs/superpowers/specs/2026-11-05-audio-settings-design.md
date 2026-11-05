# Audio settings — design

Date: 2026-11-05 · Branch: `feat/crossfade-and-fades` (same commit as
`v1.0.0`; the work so far is uncommitted in the working tree) · Status: draft
for approval

## Intent

Rebuild Hype's audio settings so they are laid out and behave like a mature
reference player's Audio section — the same screens, controls, defaults,
ranges and processing — working natively on **Android and iOS**. The behaviour
was recorded clean-room from the reference app (notes kept outside this repo);
this document states every behaviour concretely so nothing here depends on
those notes.

**Rule for everything in this repo (code, comments, tests, docs, commits,
branch names): do not name the reference app.** The repo is public.

## Decisions already made (by the owner, 2026-11-05)

1. **Hype's extra effects stay**: multiband compressor, 3D surround,
   crossfeed, speaker correction EQ, live stems. They keep working and get
   their own place in the new layout.
2. **Output-engine settings are left out** (they need a custom decode-and-
   output engine Hype does not have): output drivers, per-output sample rate /
   format / allowed rates / follow-track rate, Bluetooth codec parameters,
   64-bit pipeline, DSD (remaster, DoP, raw), Perfect Bit Perfect, USB
   Exclusive and its quirks/warm-ups, buffer sizes, reconfiguration delay,
   resampler type and cutoff, dither. Settings that cannot work are **not
   shown** — no dead switches.
3. **Hype's reverb stays as it is.** Only "Restore reverb presets" is added.
4. **Headroom replaces Hype's auto-gain.** The preamp no longer drops by the
   largest EQ boost; instead a fixed headroom ("No DVC – preamp reduction",
   0 to −10 dB) applies whenever direct volume control is not in use, and the
   limiter (on by default) catches peaks. Default **−6 dB on Android, 0 dB on
   iOS** (iOS can never use direct volume control, and must not get quieter).
   Existing Android installs start at 0 dB too, so an update does not make
   them quieter; only new Android installs start at −6 dB.

## Already done on the branch (not built, not device-tested)

- **Crossfade, Fade & Gapless** page — all 10 controls and their behaviour.
- **Stereo Expand** — side gain `1 + 2x` (x 0..1 shown 0–100 %), mid
  untouched, no compensation, bypassed at 0, moved to just before the
  limiter. One slider, no switch.

## Goals

The tree below exists in Hype's Settings, every control does what it says on
both platforms (or on Android only where marked, with iOS hiding it), and the
processing matches the numbers given here.

## Non-goals

Everything in decision 2. Also: tracker-module decoder options (Hype does not
play tracker formats), Chromecast options, Shizuku, "export presets to a
separate equalizer app", "Compensate DVC volume" (a workaround for a firmware
bug in a different volume mechanism than Hype's), "Wait for storage",
"Show app for USB DACs", USB DAC options.

## Anti-goals

- A setting that is shown but has no effect on the platform it is shown on.
- Existing users hearing their music change because of a migration: where
  Hype already had an equivalent setting, its stored value carries over; only
  settings that did not exist before start at the defaults below.
- Clicks, pops or level jumps when a control is changed during playback.

## Constraints

- One C++ DSP engine, two copies (`android/app/src/main/cpp`,
  `ios/HypeDSP/src`). Shared headers must stay byte-identical; host tests
  check that (see `native_tests/stereo/run.sh`).
- Players stay ExoPlayer (just_audio fork) and AVPlayer; Hype's two-player
  crossfade engine stays.
- Verification by `flutter analyze`, Dart tests, native host tests and
  syntax-only native checks. **No app builds until the owner asks.**

## Platform key

**Both** — same behaviour on Android and iOS. **Android** — iOS has no
equivalent; the control is hidden on iOS. **Both (iOS: …)** — iOS gets the
stated nearest behaviour.

## Target settings tree

Settings index (Hype's existing category index) gains an **Audio** category
whose page lists these sub-pages in this order, plus a **Headset &
Bluetooth** category. Hype's extras get an **Effects** entry (the existing
Space, Dynamics and Speaker Correction pages) inside Audio, after the
reference items. Existing Sound categories (Equalizer, Tone & Effects) are
folded into this tree; nothing they control is lost.

### 1. Audio Info — Both

An action opening a read-only page describing the processing right now:
source (file/stream, codec, sample rate, channels, bitrate where the player
reports them), the active DSP stages in chain order with their key values
(preamp/headroom, EQ bands, tone, MBC, crossfeed, surround, reverb, stereo
expand, mono, balance, limiter and whether it is currently reducing gain),
Replay Gain applied (dB and which tag), and the output route (speaker / wired
/ Bluetooth / USB). Opened from Settings → Audio and by
long-pressing the equalizer page's title (no format line is added to the
player screen).

### 2. Crossfade, Fade & Gapless — done

### 3. Replay Gain — Both

| Control | Default | Values |
|---|---|---|
| Replay Gain | Don't apply | Don't apply · Apply gain · Apply gain, prevent clipping by peak |
| Source | Album | Album · Track |
| RG preamp | 0.0 dB | −16.0…+16.0 dB, 0.1 dB steps, snaps at 0 |
| Preamp for songs without RG info | 0.0 dB | same |

Behaviour: gain = tag gain for the chosen source (falling back to the other
source's tag when the chosen one is missing) + RG preamp. A track with
neither tag gets "Preamp for songs without RG info" alone. In peak mode the
gain is capped at `−20·log10(peak)` dB for the same source's peak. Applied as
the track gain (`OutputGain.track`), so it survives crossfades and stacks
under the play/pause fade and listener volume. Gains above 0 dB are allowed;
the limiter catches the peaks — so the gain is applied **inside each player's
engine**, as its first stage, not on the player volume (which is capped at
1.0 on both platforms and sits after the DSP on Android). On iOS this means
one engine per player tap rather than one shared engine, which a crossfade
needs anyway so two players never share filter state. Tags read: ID3v2 `TXXX:replaygain_*`
(MP3), Vorbis comments `REPLAYGAIN_*` (FLAC/OGG/Opus, plus Opus `R128_*`
with its −23 LUFS reference converted to the 89 dB ReplayGain reference),
MP4 freeform `----:com.apple.iTunes:replaygain_*` (M4A/ALAC). Streams and
cloud tracks without readable tags count as untagged. Replaces Hype's current
"Replay gain" switch (ID3 track gain only); an existing "on" migrates to
"Apply gain" + Track.

### 4. Audio Focus — Both (iOS: see column)

| Control | Default | Android | iOS |
|---|---|---|---|
| Resume after call | on | resume on call end if paused by it | resume when an interruption ends with "should resume" |
| Resume on start | off | resume the saved session when the app starts | same |
| Resume on reopen | off | also when reopened from the launcher while running (needs Resume on start) | when returning to foreground (needs Resume on start) |
| Short audio focus change / calls | on | pause on transient focus loss | — hidden (iOS always interrupts) |
| Pause in call | on | pause on call; forced on and disabled while the above is on | — hidden |
| Resume on focus gain | on | resume when transient focus returns (needs Short…) | resume when an interruption ends with "should resume" (same switch as Resume after call on iOS — show one) |
| Duck volume | on | duck to 25 % on "can duck" focus loss instead of pausing (needs Short…) | — hidden (the system ducks) |
| Permanent audio focus change | on | pause on permanent loss (another player) | — hidden |

Implementation: just_audio's own interruption handling is switched off and
both platforms go through `audio_session`'s interruption, becoming-noisy and
device-change streams, so one Dart policy decides.

### 5. Equalizer — Both

| Control | Default | Values |
|---|---|---|
| Graphic Equalizer Bands → Number of bands | 10 | 5 · 10 (ISO) · 12 · 15 (ISO) · 16 · 24 · 31 (ISO) · 32 |
| → Enable custom bands | off | |
| → Custom number of bands | 10 | 5–32 |
| → First frequency | 20 Hz | 5–200 Hz |
| → Last frequency | 16.0 kHz | 14–20 kHz, 0.5 kHz steps |
| Tone → Bass frequency | 90 Hz | 20–250 Hz |
| Tone → Bass Q | 0.80 | 0.10–2.00 |
| Tone → Treble frequency | 10000 Hz | 5000–15000 Hz |
| Tone → Treble Q | 0.60 | 0.10–2.00 |
| Equalizer values | dB | Hidden · dB · % (labels on EQ sliders) |
| Tone values | % | Hidden · dB · % |
| Auto save | on | mirrors the equalizer screen's autosave |
| Smooth equalizer/tone gains | on | reduce EQ/tone gains near maximum volume to avoid overload |
| Suggest AutoEq presets | on | when a Bluetooth/USB device connects, offer its speaker-correction profile (Hype's AutoEq-backed Speaker Correction) |
| Reset disabled AutoEq suggestions | action | |
| Restore equalizer presets | action, confirm | |

ISO distributions are the standard octave (10), 2/3-octave (15) and
1/3-octave (31) centres; the other counts and custom bands are spaced
logarithmically between first and last. **The EQ becomes N real bands** (the
engine runs one filter per band at the chosen centres; today's fixed 32-band
grid with grouped views goes). Presets store per-band frequency and gain.
Migration keeps each user's sound: their current curve is interpolated (in
log-frequency) onto the new centres; a band count in the new list is kept,
20 becomes 24, any other count the nearest listed one. Tone frequency/Q carry
over, clamped to the new ranges.

**Auto save** follows the reference: on (default), edits are written into the
selected preset, built-in presets included ("Restore equalizer presets" brings
built-ins back); off, edits are temporary and the preset shows as unsaved
until saved. A user's existing "Custom" curve becomes a user preset named
Custom.

### 6. Direct Volume Control — Android (headroom: Both)

| Control | Default | Platform |
|---|---|---|
| Enable direct volume control | carries Hype's current DVC value; new installs on | Android |
| No DVC for Bluetooth absolute volume | on | Android — disable DVC on Bluetooth when absolute volume is detected or cannot be detected |
| No DVC – preamp reduction | Android −6.0 dB · iOS 0.0 dB | Both — −10.0…0 dB, 0.5 dB steps; applied before the EQ whenever DVC is not in use (always on iOS). Replaces auto-gain (decision 4) |
| Volume | carries Hype's DVC Volume | Android — the DVC level itself (Hype's existing "DVC Volume" slider, kept here and on the EQ page) |

**DVC is rebuilt as a gain stage inside the engine.** Today it forces the
system volume to maximum and attenuates with an Android LoudnessEnhancer bound
to one player's session — so during a crossfade the *other* player plays at
the forced maximum, a loud burst on every skip now that skips crossfade. The
level instead becomes a software master-volume stage in each player's engine
(see the chain order below); the system volume is still held at maximum while
DVC is on, and the LoudnessEnhancer path is removed. This stage must land
before or with any release of the crossfade work.

### 7. Advanced Tweaks

| Control | Default | Platform |
|---|---|---|
| Volume levels | System default | Android — System default · 30 · 50 · 75 · 100 steps for Hype's volume keys/DVC. Replaces "Fine volume steps": fine (1 %) migrates to 100, coarse (5 %) to 30 |
| Volume panel | off | Android — Hype's own volume overlay when volume is changed in the app |
| Pause/resume on volume | off | Both — pause at volume 0, resume when raised from 0 while Hype's UI or notification is visible |
| MusicFX | off | Android — show a button opening the system audio effects panel |
| Force audio on audio focus change | off | Android — re-request focus/restart output if audio stops after notifications |
| Restore equalizer presets | action | Both |
| Restore reverb presets | action | Both (Hype's room presets) |

### 8. Headset & Bluetooth (separate category) — Both (iOS: see column)

| Control | Default | Android | iOS |
|---|---|---|---|
| Resume on wired headset | off | resume on plug | resume on route change to wired |
| Resume on Bluetooth | off | resume on A2DP connect | resume on route change to Bluetooth |
| Pause on headset disconnect | on | pause on becoming-noisy | pause on old device unavailable |
| Pause on USB DAC connection | on | pause when a USB audio device appears | — hidden |
| Respond to buttons | on | | hidden (system owns buttons) |
| Wired headset buttons | Double/triple press | Single press · Double/triple press for next/prev · Long press for next (when playing) | hidden |
| Bluetooth buttons | Double/triple press | same | hidden |
| Strict resume/pause/stop | on | a "play" while playing / "pause" while paused is ignored rather than toggled | same, for remote commands |
| Ignore Bluetooth commands | 1 s | 0–20 s after a Bluetooth connection | same |
| Ignore repeat/shuffle | off | ignore remote repeat/shuffle commands | same |
| Beep · Beep more · Vibrate | on · off · off | feedback on button commands | hidden |
| Disable default long press | off | stop long press from starting voice search while playing | hidden |

### 9. Per output — Both

For each output kind (speaker, wired, Bluetooth, USB, other; named Bluetooth
and USB devices can get their own profile): an assigned **EQ preset**
(applied automatically when that output becomes active), **No Equ/Tone**,
**No Duck** (pause instead of ducking), **Ignore audio focus**, **No DVC**
(Android), **No headroom gain reduction**. Reached from the Audio page as
"Outputs"; the active output is detected from the route on both platforms.

### 10. Equalizer-screen controls (on the EQ/Tone pages, not in Settings)

| Control | Default | Behaviour |
|---|---|---|
| EQ on/off · Tone on/off | on · on | |
| Limiter | **on** | rebuilt: no look-ahead, ceiling 1.0, linear gain slopes — full attack (1→0) in ~5.3 ms, full release (0→1) in ~341 ms, both rescaled by sample rate |
| Preamp | 0 dB | ±24 dB |
| Balance | 0 (centre) | −1 (left) … +1 (right), centre snap; the opposite channel is attenuated by 48·|b| dB, silent at ±1 |
| Mono | off | L = R = (L+R)/2 |
| Tempo | off, 1.00× | 0.50–3.00×, centre snap at 1.00×, pitch preserved; +/− buttons |
| Stereo Expand | 0 % | done |
| Reset | action | resets balance, stereo expand, tempo, mono (confirm) |

**Final chain order** (both engines, one engine per player): Replay Gain +
preamp + headroom → speaker correction → EQ → tone → MBC → crossfeed → 3D
surround → reverb → **DVC volume → stereo expand → mono → balance →
limiter** → output. Stems stay first (they replace the decoded audio).

**Android system-wide EQ mode** (Hype extra; DynamicsProcessing instead of the
engine): it carries what DynamicsProcessing can — the N EQ bands, preamp and
headroom, tone as today's band offsets, and its limiter set as close to the
timings above as it allows. Replay Gain, DVC, balance, mono and stereo expand
cannot run there: their controls are shown disabled with a one-line reason
while system-wide mode is on.

**Equalizer-only app mode** shows Equalizer, Direct Volume Control, Advanced
Tweaks, Effects and Audio Info (DSP part only); the player pages (Crossfade,
Replay Gain, Audio Focus, Headset & Bluetooth, per-output) are hidden.

## Left to the builder

- Exact widgets and placement, following Hype's existing settings and EQ page
  styles (cards, sliders, segmented buttons, bottom-sheet choosers as on the
  Crossfade page).
- How Audio Info gathers its data from each platform.
- Per-output storage format.
- Phasing. A sensible order: DSP core (limiter, balance, mono, headroom,
  tempo) → Replay Gain → Equalizer settings → Audio focus + Headset &
  Bluetooth → DVC, Advanced Tweaks, per-output → Settings layout + Audio Info.

## Smooth equalizer/tone gains — the rule

Not a limiter: it reads no signal. Each band's gain is a stored value X times
a scale in dB — X in −1…1 for EQ bands, and for tone as stored (confirm the
tone range, −1…1 or 0…1, against Hype's tone model before building that
stage). Switched **off**, the scale is fixed: **15 dB** for every EQ band and
treble, **22.5 dB** for bass. Switched **on** (default), the scale shrinks as
the level nears full scale:

    T = preamp + master volume + headroom          (all in dB; 0 = full scale)
    EQ bands, treble:  scale = 12.5 − T·(100/120)  if T > −3 dB, else 15
    bass:              scale = 15 − 0.75·T         if T > −8 dB, else 22.5

(The constants are as recorded: per-millibel 1/120 and 0.0075; the bass step
of 1.5 dB at −8 dB is as recorded.) Boosts and cuts scale together; nothing
is clamped. Master volume is the DVC level when DVC is on, otherwise the
system media volume in dB (Android: the stream's dB for the current index;
iOS: 20·log10 of the output volume). Headroom counts only while it applies
(DVC off, and the output has no "No headroom gain reduction"). Recomputed
whenever preamp, volume, headroom or a gain changes — never per block — and
the new filter gains take effect at the next block.
