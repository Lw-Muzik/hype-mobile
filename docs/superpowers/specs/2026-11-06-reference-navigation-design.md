# Reference-style navigation and motion — design

Date: 2026-11-06 · Status: draft for owner approval · Repo rule: never name the reference app anywhere in the repo (code, comments, tests, docs, commits); call it "the reference player".

## Intent

Hype should move like the reference player: the player is the home screen; the library is reached by pulling the player away; every step between lists is the reference player's zoom-and-crossfade with the tapped item morphing into the next page's header; pinch zoom morphs every item into the next layout. **Only navigation and motion change.** Every existing Hype screen — the player, song rows, album/artist/genre/folder grids, YouTube Music pages, cloud folders, the Home feed shelves, the EQ, Settings, lyrics, visualizer, sheets — keeps its current design.

The behaviour to reproduce is recorded clean-room, number for number, from the reference player's own code (decompiled from the exact build installed on the owner's phone, byte-identical) and 30 frame-by-frame recordings of it on the owner's phone. Builders take every number from these records (outside the repo, neutral paths):

- `~/me/COTE/.hype-reference/motion-record.md` — the authoritative motion record (transitions T1–T14, geometry §2, reconciliation §3, requirements §5.2)
- `~/me/COTE/.hype-reference/library-structure.md` — the reference player's screen map
- detail reports beside them: `scene-engine-report.md`, `scene-values-report.md`, `list-navigation-report.md`, `list-zoom-report.md`, `runtime-report.md`

Where this design and the record disagree on motion, the record wins. Never copy the records' wording into the repo.

## Decisions (owner)

1. Hype opens straight onto the player.
2. Navigation follows the reference model ("option B"): pulling the player away lands on the list the playing track came from, with its row revealed; back walks up that list's hierarchy to a root list of places, and back from the root returns to the player; back from the player leaves the app.
3. Keep every current screen design. Only how screens are reached and the motion between them change.
4. Nothing is removed: the offline library, YouTube Music, cloud and the Home feed all live inside the new flow.
5. The motion engine is Hype's own (the reference player uses no third-party UI or animation library; neither will Hype).
6. Build with four parallel builders once this design is approved.

## How it works

### The three clocks (record §0)

Every navigation step runs up to three independent clocks that start in the same frame:

| Clock | What it moves | Curve and time |
|---|---|---|
| List | the two page layers (zoom about a pivot + cross-fade) and any shared element | cos ease `½ − ½·cos(πt)`, 250 ms by default (150 ms for sibling switches); or the finger |
| Container | the player's chrome (controls, waveform, buttons) | ease-out quart `1 − (1 − t)⁴`, 500 ms entering the player, 250 ms leaving; locked 1:1 to the list when a finger or the back key drives it |
| Mini player | the bottom mini player rising/sinking 74 dp | ease-out quart, ~500 ms, both directions, always its own clock |

No horizontal slides, no spring overshoot on page changes, no per-row stagger, no haptics. Time-based (not per-frame) progress; works at 60/90/120 Hz.

### Screens and where they go

```
Player (launch screen; Hype's current player UI, unchanged)
  │ drag the art/card down (finger-driven) · tap the existing down chevron · back key ×
  ▼
Source list of the playing track (e.g. the album page it was played from), row revealed
  │ back (key, predictive back, or horizontal swipe — finger-driven)
  ▼
… parent lists …
  ▼
Places (new root list)  ── back ──► Player
  For You · Songs · Albums · Artists · Genres · Folders (Android) · Playlists · YouTube Music · Cloud
  └─ each opens today's screen for it, unchanged inside
Mini player (today's EmberMiniPlayer) sits at the bottom of every library screen; tap → Player
```

- **Places** is the only new screen. It lists the destinations that are today's tabs and library chips. It is drawn with Hype's existing list-row/tile style (`LibraryListRow` or the existing grid tile) — no new visual language. Its app bar keeps today's HomeShell buttons: menu (opens today's drawer/`MenuScreen`, unchanged) and search (opens today's `SearchPage`, unchanged).
- **For You** opens today's `HomeSurface` (shelves). **YouTube Music** opens today's `DiscoverView`. **Cloud** opens today's `CloudView`. **Songs/Albums/Artists/Genres/Folders/Playlists** open today's `AllSongs`/`Albums`/`Artists`/`Genres`/`Folders`/`PlayListView`. Everything they open (album/artist/genre/folder/playlist songs, `MixPlaylistPage`, `YtCategoryPage`, `YtOpenedListPage`, `YtArtistPage`, `YtSearchPage`, `CloudFolderSongs`, search "see all") opens inside the library flow with the list transitions below.
- **Removed (navigation chrome only):** the 4-tab bottom bar and `IndexedStack` of `HomeShell`; the `ZoomDrawer` wrapper around the shell (the drawer *menu* stays, opened from Places); the library chip row (its destinations move into Places); the duplicate mini players inside pages (legacy `BottomPlayer`, `LocalMiniPlayerBar`, unused `MiniPlayer`) because the one shell mini player covers every library screen; dead code (`Recents`, `OnlinePlaylist` stub, the no-op drawer "Cloud Music" item — it now opens Cloud).
- **Unchanged and opened as today, over the shell:** Equalizer (and EQ-only app mode, which still replaces the whole app with the Equalizer), Settings and its pages, Visualizer, Lyrics, the queue sheet, Listen, song actions sheet and its pages, Hype Connect page (incl. the notification deep open), video full screen and the floating video mini window, the remote (Hype Connect) player, onboarding and the loader.

### Transitions to build (record IDs)

| Moment in Hype | Record | Notes |
|---|---|---|
| Player → library by tapping the player's down chevron | T1 | player layer 1 → 1.25× about the art centre + fade; library 0.5 → 1 about screen centre; chrome fades + shrinks to 0.75× in place; mini player rises |
| Library → player by tapping the mini player, or by playing a song from a list | T2 / T5 | mirror; the art flies from the playing row/mini-player art into the player art |
| Back key at Places | T3 | as T2, chrome locked to the list clock |
| Dragging the player's art/card down | T4 | finger-driven: 8 dp slop, progress = travel / 360 dp, commit p > 0.3 or fling ≥ 500 dp/s; settle per record; the art morphs straight into the playing track's row/cell in its source list (replaces today's card drag-to-dismiss) |
| Opening any item that has a page (album, artist, genre, folder, playlist, mix, YT category/playlist/album/artist, cloud folder, Places entries) | T6 | tapped row/tile lifts and morphs into the new page's existing header (rect lerp + art/title morph); old page zooms to 1.5× (lists) / 2× (grids) about the tapped item and fades; new page grows in (0.5× about centre for lists; grid rect-fit from the tapped tile) |
| Back key / Android predictive back | T7 / T8 | mirror (header → row); predictive back is finger-driven at 1:1 of screen width |
| Horizontal swipe in a list to go back (Android and iOS) | T8 | finger-driven; commit rules and settle per record; rubber band at the root |
| Switching between siblings without a parent/child relation (e.g. Places entry ↔ search) | T9 | 150 ms pivot |
| Pinch zoom in a list or grid | T10 | see below |
| Picking a layout from a list's own options (if the list has one) | T11 | same morph, 250 ms |

Opening the tools listed under "Unchanged" keeps today's transitions (non-goal to change them).

### Pinch zoom (record T10, §2.4)

- Each zoomable list has a fixed set of **steps built from Hype's existing designs**: the current list row, then grids of 2, 3 and 4 columns using the current grid tile (fewer if a list has only one design). The step is persisted per list (reuse `LibraryController.gridExtentFor/ setGridExtent` keys, mapped to step indices; the global `songGridExtent` becomes a per-list step).
- **One list, never two copies:** every item visible in both steps moves from its old rect to its new rect on one shared progress; its art rect morphs and its text cross-fades between the row and tile designs; items present in only one step zoom about the list centre and fade (record values). Scroll anchored on the middle visible item.
- Gesture and release exactly per record T10: start after touch slop, progress `1.25·(span/span₀ − 1)` (in) / `1.25·(1 − span/span₀)` (out), **one step per pinch** with rubber band past 1, ±8.9 % rubber band at the end steps with a 350 ms ease-out-cubic return, release rules (fling ≥ 500 dp/s, else commit p > 0.3), settle 0.5 s × remaining with the record's floors and constant-speed clamps.
- Replaces today's continuous-extent `PinchZoomGrid` behaviour wherever it is used (songs-type lists, albums, artists, genres, folders, cloud folder songs, search lists). Lists that have no grid design today (Home shelves, YouTube shelves, Playlists) get no pinch zoom.

### Playback origin

To land on "the list the playing track came from", every place that starts playback from a list records a **playback origin**: the path of library pages that leads to that list (e.g. Places → Albums → album X; Places → YouTube Music → playlist Y; Places → Cloud → folder Z; search with its query; For You shelf). Pulling the player away rebuilds that path in the library (without animating the intermediate pages) and reveals the playing row (today's `PlayerRevealBus` reveal). If the origin is unknown (restored session without one, or the source no longer exists), land on Places.

### Rules that fall out of the model

- Tapping a song in any list plays it and runs library → player (T2). This now includes local album, artist and playlist pages (their song rows and Play/Shuffle buttons), which today stay on the page (owner, 2026-11-06).
- "Go to album/artist" from the player's song actions runs player → library landing on that page.
- When the queue becomes empty while the player shows (today it auto-closes), go to Places. On a fresh install with nothing ever played, open on Places.
- `YtPlayback`, `MixPlayback` and the other ~30 direct `Routes.playerTo` / `Navigator.push` call sites go through one navigation API (no service pushes routes itself).
- The Hype Connect remote player (`RemotePlayerView`) is the player scene while another device plays; the same transitions apply.

## Goals

- The four moments the owner named feel exactly like the reference player: player ↔ library, opening/closing lists, back gestures, pinch zoom.
- Every Hype module reachable in the new flow, with nothing lost.
- Identical behaviour on Android and iOS.

## Non-goals

- Any visual redesign of an existing screen, list row, tile, header or the player.
- New library categories the reference player has but Hype lacks data for (years, composers, ratings, bookmarks, streams, album artists, folder hierarchy, long, queue as a place).
- Changing how Equalizer, Settings, Visualizer, Lyrics, sheets or Hype Connect pages open.
- The reference player's other container morphs (play/pause morph, visualization modes, EQ as a scene, search as a navbar scene, track-change art pager).

## Anti-goals (failure even if it "works")

- Any existing screen looks different at rest.
- A module, action or entry point disappears (downloads, cloud connect, mixes, search, radio/stations, Hype Connect, EQ mode, video).
- Back traps the user or skips a level; back from the player does not leave the app.
- Dropped frames during a transition or pinch on a mid-range phone at 60 Hz.
- Android and iOS behave differently.
- The reference app named anywhere in the repo.

## Constraints

- Flutter 3.47 / Dart 3.13, existing Provider controllers; no new third-party navigation/animation packages.
- Import paths: git tracks `lib/Visualizers`, `lib/Helpers`, `lib/Routes` capitalised on a case-insensitive disk; keep one spelling per file (two spellings = two Dart libraries).
- Tests: `flutter test` keeps only the two known pre-existing failures (template counter, splash); `flutter analyze` gains no issues.
- Builders never run Gradle/Xcode builds. After each builder round the controller builds the side-by-side dev copy and installs it on the owner's S24 (owner OK, 2026-11-06), fast: `flutter build apk --release --android-project-arg=dev=true --target-platform android-arm64` → "Hype Muzik Dev" (`x.a.zix.dev`, debug-signed, beside the Play install), `adb install -r --user 0`. Disk is nearly full — clear build intermediates if a build fails for space.
- Device sign-off is the owner's, on the S24 dev copy, side by side with the reference player.

## Left to the builder

Widget and file structure of the motion engine (shell, list-page route or custom page stack, shared-element overlay, finger-progress driver); how existing rows/tiles/headers are tagged as morph sources/targets without changing their look; rect computation for targets off screen (reveal first, then morph); how predictive back is wired on Android and the horizontal back swipe on iOS; how each list maps its existing designs to zoom steps.

## My calls (owner to check)

- Places order: For You, Songs, Albums, Artists, Genres, Folders, Playlists, YouTube Music, Cloud.
- The drawer menu and search stay reachable from the Places app bar (today's buttons), rather than a new bottom button bar.
- The player's existing down chevron and card drag become the player → library moves; the shell keeps today's `EmberMiniPlayer` as the mini player.
- Fresh install / empty queue → Places.
- **Top of a place page.** The pages opened from Places (Songs, Albums, Artists, Genres, Folders, Playlists, For You, YouTube Music, Cloud) have no header of their own today — HomeShell's app bar sat above them. Each now gets that same app bar (today's height, typography, search and menu buttons) with the place's name as its title and a back chevron in place of the hamburger. The Places row's icon and title morph into that app bar's title for T6/T7/T8. Library sort controls that lived beside the chips (Songs' sort button, import button) sit in that app bar's actions, unchanged in look.
- **Origin when the playing track isn't in its source list** (radio continuation, mixes continuing into YouTube radio, stations, Play next, queue edits): one origin per queue — the list the queue was started from — kept in the saved session (`playback_session.dart`). Pulling the player away lands on that list; if the playing track has no row there, nothing is revealed and the art fades with the player layer (T1's zoom, still finger-driven) instead of morphing into a row. No origin → Places.
- **Record unknowns** (U1 grid start scale for 3/4-column grids, U2 leftward swipe and right-edge back, U4 cross-fade layer order, predictive back at Places): builders pick the behaviour the record makes most likely, and a parallel phone recording session settles them for tuning; it does not gate the build. Predictive back at Places: the player moves in with the finger (T3 as finger-driven T2), commits per T8 rules.
- **Zoom steps on wide screens:** steps are today's grid tile extents (not fixed column counts) plus the list row: e.g. list → today's largest tile → medium → smallest. Columns come from the width exactly as today (`SliverGridDelegateWithMaxCrossAxisExtent`), so tablets, landscape and foldables look the same at rest as now; a pinch moves one extent step. Lists with no grid design (Home shelves, YouTube shelves, Playlists) get no pinch zoom.
