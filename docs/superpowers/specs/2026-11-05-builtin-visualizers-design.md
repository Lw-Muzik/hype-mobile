# Built-in spectrum visualizers — design

Date: 2026-11-05 · Status: owner-directed (2026-11-05), builds after the audio
DSP core plan (both touch the iOS audio tap) · Repo rule: do not name the
reference app anywhere in the repo.

## Intent

Replace Hype's assorted visualizers with a set of eleven built-in spectrum-bar
visualizers recreated from a reference player's compiled presets — the same
bars, layouts, colours, peaks, trails and spectrum analysis — working on
**Android and iOS** (drawn in Dart, unlike MilkDrop which is Android-only).
The behaviour and every parameter were recorded clean-room; the full record
(per-preset tables, formulas, evidence, decoded values) is kept outside this
repo in the owner's local reference folder (the implementation plan gives the
path to builders). Builders take numbers from there; **names and wording from
it never enter the repo.**

## Decisions (owner)

- **Keep:** Radial (`radial`), Waveform (`line`), MilkDrop and its presets
  (untouched), and the bottom-player wave (`MultiWaveVisualizer`).
- **Remove:** every other visualizer — on the Visual page (Spectrum, Mirror,
  Terrain, Matrix, Silk, Lissajous, Windmill, Neon Grid, 3D Ring, Ribbons,
  3D Lissajous, Particles, Tunnel, Kaleidoscope, Terrain 3D, Mesh Sphere, Orb,
  Geometry, Waterfall, Metaballs, Warp Mesh, Fractal) and in the Settings style
  list, plus the **background visualizer** (`CircularBarVisualizer` behind the
  app body, its Settings switch and pref).
- **Add:** eleven built-ins, named **Spectrum** + Plain · Narrow · Wide ·
  Centered · Centered Narrow · Centered Wide · Centered Reflected · Reflected
  Wide · Quads Narrow · Quads Reflected · Dots (ids `spectrum_plain`,
  `spectrum_narrow`, … `spectrum_dots`).

The Visual page and the Settings style list therefore offer: Radial,
Waveform, the eleven Spectrum built-ins, and MilkDrop (Android).

## How the built-ins work

One renderer, eleven parameter sets. No per-frame equations.

1. **Spectrum.** One channel (Hype: the mono mix (L+R)/2 — the reference reads
   channel 0, mono-vs-left unknown), at 44.1/48 kHz, Hann-windowed
   (`0.5 − 0.5·cos(2πn/511)`) non-overlapping 512-sample blocks, unnormalised
   real FFT, power `|X[k]|² + 1.5849e-13` for bins 1…256. The newest block per
   frame. Computed **natively on both platforms** in one shared C++ header and
   delivered to Dart as 256 floats per frame next to the existing feeds.
2. **Bars values** (Dart, per frame): band means over the bins — linear bands
   (one bin each) for the first half of the bars, log-spaced bands up to 20 kHz
   for the second half — then `10·log10`, mapped onto the preset's
   sensitivity-dependent dB window (the two lowest bars use the bass window),
   then symmetric smoothing with `bars_smooth^(60/fps)`.
3. **Peaks** for the modes that have them: hold for `bars_peak_delay` seconds,
   then fall with `bars_peak_accel` (bar-heights/s²).
4. **Layout** by `bars_mode & 7` (1 from the bottom, 2 bottom cells with peaks,
   3 mirrored about the vertical centre, 4 centred cells, 6 mirrored left/right
   from the centre and vertically centred, 7 as 6 in cells); bar count, gaps and
   centring per the recorded formulas; rounded caps as 16-segment half-ellipses
   that look circular in pixels; the rect is the visualizer surface, then
   `bars_x/y`, `sx/sy`, `rot` (y up).
5. **Colour** per vertex: `mix(b, t, y/thr) + mix(l, r, x)` (threshold colours
   above `thr`), clamped — drawn with `Canvas.drawVertices`, src-over, rect edges
   not antialiased.
6. **Trails:** an offscreen copy of the previous frame, multiplied by
   `(floor(decay·255)/255)^(60/fps)` then minus 0.002 per channel; decay 0
   simply clears. Dots also zooms the previous frame inward slightly
   (zoom 0.999, zoomexp 1.05).
7. Composite over black. Gamma 1.

## Non-goals

The reference's "scaled bars for faded controls" layout (Hype's player has
no fade-controls mode); equalizer-screen spectrum; MilkDrop changes.

## Anti-goals

A removed style left selectable or crashing when restored from prefs; a
visualizer that differs between Android and iOS; frame drops on mid-range
phones (the renderer must hold 30 fps at the current visualizer frame rate).

## Migration

A stored `visualizerStyle` that no longer exists (any removed id, and the
legacy default `circular`) becomes `radial`. The background-visualizer pref is
ignored and its switch removed. Onboarding text that lists removed modes is
updated.

## Left to the builder

Widget structure (one `CustomPainter` per preset vs one parameterised
painter), the native channel shape for the 256-float feed, and how fps is
measured (use the actual frame interval).

## Still open (decided here)

- FFT scaling: unnormalised, as recorded; if the reference carried a 0.5
  factor the windows would sit 6 dB higher — accepted risk.
- Mono mix instead of channel 0 (keeps both channels' content in the bars).
