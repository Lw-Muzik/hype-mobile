# Reference-Style Navigation and Motion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Hype open on the player and move between the player, its library and every list exactly like the reference player (three motion clocks, zoom-and-crossfade pages, item → header morphs, finger-driven drags and back swipes, one-list pinch zoom), without changing any screen's design.

**Architecture:** A root `MotionShell` hosts two scenes — today's `Player` and a library scene (today's drawer around a nested `LibraryNavigator` whose root is a new `PlacesPage`) — plus today's mini player on its own clock. A small in-house motion kit (progress driver, page layer, morph overlay, back swipe) drives every transition; one `AppNav` facade replaces the ~30 hard-wired `Routes.playerTo`/`push` calls; a `ZoomStepList` replaces the continuous `PinchZoomGrid`.

**Tech Stack:** Flutter 3.47 / Dart 3.13, Provider, `flutter_test`; no new packages.

**Spec:** `docs/superpowers/specs/2026-11-06-reference-navigation-design.md`

**Behaviour records (outside the repo; numbers only):** `~/me/COTE/.hype-reference/motion-record.md` (T1–T14, §2 geometry, §3 reconciliation, §5.2 requirements) and its detail reports in the same folder (`scene-engine-report.md`, `list-navigation-report.md`, `list-zoom-report.md`, `runtime-report.md`, `library-structure.md`).

## Global Constraints

- Never name the reference app anywhere in the repo (code, comments, tests, docs, commits). Forbidden list: `~/me/COTE/.hype-reference/forbidden-names.txt`. Say "the reference player". Never copy the records' wording.
- Keep every existing screen's design pixel-identical at rest (player, rows, tiles, headers, YouTube/cloud/Home pages, EQ, Settings, sheets). Only navigation and motion change.
- Motion values come from `motion-record.md`; where this plan and the record disagree, the record wins. Progress is time-based (works at 60/90/120 Hz); no horizontal slides, no overshoot, no stagger, no haptics.
- Same behaviour on Android and iOS.
- No new dependencies. Keep one import spelling per file (git tracks `lib/Visualizers`, `lib/Helpers`, `lib/Routes` capitalised; imports use lowercase `visualizers/`, `helpers/`, `routes/`).
- Builders never run `git commit/add/stash/checkout/restore` and never run Gradle/Xcode/pod builds. The controller snapshots for review and builds the dev copy after each wave.
- `flutter test` keeps only the two known pre-existing failures (template counter, splash); `flutter analyze` gains no issues. Format only the files you create; edit existing files hunk-locally.

## Review Focus

1. **Back sequences** — back at the player leaves the app; back in a deep list steps exactly one level; back at Places goes to the player; a second back during a running transition neither skips a level nor throws. Pinned in Task 6 (`back_sequences_test`) and Task 7 (`route_back_test`).
2. **Origin can't be rebuilt** (cloud folder gone, YouTube list offline, restored session with an old origin) — pulling the player away lands on the deepest page that can be rebuilt, else Places, never a crash or blank page. Pinned in Task 6 (`origin_fallback_test`).
3. **Interrupting a transition** — tapping the mini player during player → library, or grabbing the art mid-animation, reverses from the current on-screen state without a jump. Pinned in Task 2 (`retarget_test`) and Task 6 (`interrupt_test`).
4. **EQ-only mode, Hype Connect remote player, floating video window** stay reachable and behave as today. Pinned in Task 6 (`modes_test`).
5. **Pinch edge cases** — 0 or 1 item, pinch at the first/last step, pinch started while a scroll fling runs, rotation mid-pinch: no exception, ends on a valid step. Pinned in Task 3 (`zoom_edge_test`).

---

## Waves (≤ 4 builders at once)

| Wave | Tasks (parallel) | Files owned (disjoint) |
|---|---|---|
| 0 | 1 | `lib/navigation/motion_spec.dart` |
| 1 | 2, 3, 4, 5 | 2: `lib/navigation/motion/*` · 3: `lib/navigation/zoom/*` · 4: `lib/navigation/{app_nav,library_page_key,playback_origin,library_path}.dart` + play/push call sites + `playback_session.dart` + `app_controller.dart` origin field · 5: `lib/navigation/places/*` |
| 2 | 6, 7, 8 | 6: `lib/navigation/shell/*`, `index_page.dart`, `home_shell.dart`, `loader.dart`, `main.dart`, `routes/routes.dart`, `player_ui.dart`, `player/widgets/Header.dart`, `ember_mini_player.dart`, `player_presence.dart`, onboarding coach marks · 7: `lib/navigation/library/*` + morph tags in pages/widgets + legacy mini-player removal + dead code + `menu_screen.dart` · 8: phone recording (no repo files) |
| 3 | 9, 10 | 9: `song_tile.dart` + the five grid pages + `library_controller.dart` + `pinch_zoom_grid.dart` (delete) · 10: `lib/navigation/{motion_spec,shell,library}` tuning |

Later tasks consume earlier interfaces exactly as written in their **Interfaces** blocks.

---

### Task 1: Motion spec (wave 0)

**Files:** Create `lib/navigation/motion_spec.dart` · Test `test/navigation/motion_spec_test.dart`

**Interfaces — Produces:**
```dart
double cosEase(double t);   // ½ − ½·cos(π·t), t clamped to 0..1
double quartOut(double t);  // 1 − (1 − t)⁴
double cubicOut(double t);  // 1 − (1 − t)³
abstract final class MotionSpec { /* every constant below, each with a comment citing its record section (e.g. "record T4") */ }
```
Constants (verify every value against `motion-record.md`; correct the value, keep the name, if the record differs): `listPage` 250 ms, `listSibling` 150 ms, `containerEnterPlayer` 500 ms, `containerLeavePlayer` 250 ms, `miniPlayer` 500 ms, `miniPlayerRise` 74.0 dp, `dragSlop` 8.0 dp, `dragTravel` 360.0 dp, `commitProgress` 0.3, `flingVelocity` 500.0 dp/s, `settleCommit` 250 ms, `settleCancel` 500 ms, `settleMinCommit` 100 ms, `settleMinCancel` 167 ms, `glideMin` 4.0 /s, `glideMax` 8.0 /s, `cancelGlideMin` 3.5 /s, `playerExitScale` 1.25, `playerEnterFrom` 0.75, `libraryEnterFrom` 0.5, `libraryExitTo` 1.5, `listOpenOldTo` 1.5, `gridOpenOldTo` 2.0, `listNewFrom` 0.5, `chromeHideScale` 0.75, `backRubberBand` 0.25, `backRubberReturn` 350 ms, `zoomGain` 1.25, `zoomSettle` 500 ms, `zoomRubberBand` 0.089, `zoomEndReturn` 350 ms, `zoomOptions` 250 ms.

- [ ] **Step 1: Failing test** `motion_spec_test.dart`: `cosEase(0)==0, cosEase(0.5)==0.5, cosEase(1)==1`; `quartOut(0.5)==0.9375`; `cubicOut(0.5)==0.875`; clamping (`cosEase(-1)==0`, `cosEase(2)==1`); `MotionSpec.listPage == Duration(milliseconds: 250)`, `MotionSpec.containerEnterPlayer == Duration(milliseconds: 500)`, `MotionSpec.miniPlayerRise == 74`.
- [ ] **Step 2:** `flutter test test/navigation/motion_spec_test.dart` → FAIL (missing file).
- [ ] **Step 3:** Implement; read the record for every constant.
- [ ] **Step 4:** Test → PASS; `flutter analyze lib/navigation test/navigation` → no issues.

---

### Task 2: Motion kit (wave 1)

**Files:** Create `lib/navigation/motion/motion_progress.dart`, `page_layer.dart`, `morph.dart`, `back_swipe.dart` · Tests `test/navigation/motion/*_test.dart`

**Interfaces — Consumes:** Task 1. **Produces:**
```dart
class ReleaseRules { const ReleaseRules({required double commitAt, required double flingPerSecond, required Duration settleCommit, required Duration settleCancel, required Duration minCommit, required Duration minCancel, required double glideMin, required double glideMax, required double cancelGlideMin});
  static const artDrag; static const backSwipe; } // values per record T4 / T8 from MotionSpec
class MotionProgress extends ChangeNotifier implements ValueListenable<double> {
  MotionProgress({required TickerProvider vsync, double initial = 0});
  double get value; bool get isFingerDriven; bool get isAnimating;
  Future<void> run({required double to, required Duration duration, required double Function(double) curve}); // from the current value; a new run retargets from the current value
  void beginDrag(); void dragTo(double progress);
  Future<bool> release({required double velocityPerSecond, required ReleaseRules rules}); // true = committed to 1; settle per record (time-scaled by remaining distance, floors, constant-speed glide after a fling)
  void jumpTo(double v); }
class PageLayer extends StatelessWidget { const PageLayer({super.key, required ValueListenable<double> progress, required double scaleAt0, required double scaleAt1, required double opacityAt0, required double opacityAt1, required Offset pivot /* local px */, required Widget child}); } // linear in progress; Transform about pivot + Opacity; RepaintBoundary
class MorphScope extends StatefulWidget { const MorphScope({super.key, required Widget child}); static MorphScopeState of(BuildContext c); }
class MorphScopeState extends State<MorphScope> { Rect? rectOf(Object tag); Future<void> fly({required Object from, required Object to, required ValueListenable<double> progress}); }
class MorphTag extends StatefulWidget { const MorphTag({super.key, required Object tag, required Widget child}); } // hidden (not removed) while its tag flies
class BackSwipeDetector extends StatelessWidget { const BackSwipeDetector({super.key, required bool enabled, required VoidCallback onStart, required ValueChanged<double> onUpdate /* dx ÷ width, 1:1 */, required ValueChanged<double> onEnd /* progress velocity per second */, VoidCallback? onCancel, required Widget child}); }
```
`fly` draws, in an overlay, the source tag's widget at a rect lerped linearly (on `progress`) from the source's rect to the target's rect, cross-fading into the target's widget; both real tags stay hidden until the flight ends. `BackSwipeDetector` starts after `MotionSpec.dragSlop` of mostly-horizontal (rightward) travel and never steals vertical scrolls.

- [ ] **Step 1: Failing tests:** `motion_progress_test` — `run(to:1, 250 ms, cosEase)` at 125 ms value ≈ 0.5 (±0.02); `retarget_test` — run to 1, at 100 ms call `run(to:0)`: value continues from the value at 100 ms (no jump > 0.01 between frames); `release` with progress 0.31 and velocity 0 → true and ends at 1; 0.29 → false, ends at 0; velocity ≥ fling (in progress/s for 360 dp) → commits regardless of progress; settle durations obey floors. `page_layer_test` — at progress 0.5 with scale 1→1.25 the child's transform scale is 1.125 about the pivot and opacity 0.5. `morph_test` — two `MorphTag`s at different rects; during `fly` at 0.5 the overlay rect is the midpoint and both real tags are invisible; after completion they are visible. `back_swipe_test` — a 100 px rightward drag on a 400 px-wide detector reports 0.25 after slop; a vertical drag reports nothing and the ListView scrolls.
- [ ] **Step 2:** `flutter test test/navigation/motion` → FAIL.
- [ ] **Step 3:** Implement (Ticker-based; `release` math per record T4/T8 "settle" rows).
- [ ] **Step 4:** Tests → PASS; analyze clean.

---

### Task 3: Zoom engine (wave 1)

**Files:** Create `lib/navigation/zoom/zoom_steps.dart`, `zoom_physics.dart`, `zoom_step_list.dart` · Tests `test/navigation/zoom/*_test.dart`

**Interfaces — Consumes:** Task 1. **Produces:**
```dart
sealed class ZoomStep { const factory ZoomStep.list({required double rowExtent}) = ListZoomStep; const factory ZoomStep.grid({required double maxTileExtent, required double childAspectRatio, double spacing}) = GridZoomStep; }
List<Rect> zoomLayout(ZoomStep step, {required int itemCount, required double width, EdgeInsets padding}); // grid columns exactly as SliverGridDelegateWithMaxCrossAxisExtent
double pinchProgress({required double span, required double startSpan, required bool zoomIn}); // record T10: 1.25·(span/startSpan − 1) in, 1.25·(1 − span/startSpan) out
class ZoomRelease { final bool commit; final Duration duration; final double? glidePerSecond; }
ZoomRelease decideZoomRelease({required double progress, required double spanVelocityDpPerSecond, required bool zoomIn}); // record T10 incl. the sign quirk
class ZoomStepList extends StatefulWidget { const ZoomStepList({super.key, required List<ZoomStep> steps, required int step, required ValueChanged<int> onStepChanged, required int itemCount, required Widget Function(BuildContext context, int index, ZoomStep step) itemBuilder, ScrollController? controller, EdgeInsets padding = EdgeInsets.zero, Widget Function(BuildContext, Widget list)? listWrapper /* e.g. AlphabetFastScroll in the list step */}); }
```
During a pinch one scrollable shows every visible item at a rect lerped from its rect in the current step to its rect in the target step; each item's from-step and to-step widgets cross-fade inside that rect (art moving continuously with the rect). Items present in only one step zoom about the list centre (1.5× / 0.5× per record T10) and fade. One step per pinch; ±`zoomRubberBand` rubber band past 1 and at end steps with `zoomEndReturn` ease-out-cubic return. The new step's scroll keeps the middle visible item centred (record T10 anchor rule).

- [ ] **Step 1: Failing tests:** `zoom_steps_test` — grid of maxTileExtent 200 on width 400 → 2 columns, on 412 → 3 (match `SliverGridDelegateWithMaxCrossAxisExtent`); list step rects stack by rowExtent. `zoom_physics_test` — `pinchProgress(span: 180, startSpan: 100, zoomIn: true) == 1.0`; `(span: 20, startSpan: 100, zoomIn: false) == 1.0`; release at progress 0.31, velocity 0 → commit; 0.29 → cancel; |velocity| ≥ 500 dp/s decides by direction; durations = 0.5 s × remaining with record floors. `zoom_step_list_test` — two-pointer pinch spreading 1.8× on a 20-item list moves from step 0 to step 1 and calls `onStepChanged(1)` once; mid-pinch an item's rect lies between its two step rects. `zoom_edge_test` — 0 items, 1 item, pinch past the last step, pinch during a fling, viewport resize mid-pinch: no exceptions, step valid.
- [ ] **Step 2:** `flutter test test/navigation/zoom` → FAIL.
- [ ] **Step 3:** Implement (custom layout over a `CustomScrollView`/`ListView` with per-item positioned children during the pinch; idle steps render as a normal `ListView`/`GridView` for performance).
- [ ] **Step 4:** Tests → PASS; analyze clean.

---

### Task 4: Navigation API, playback origin, call sites (wave 1)

**Files:** Create `lib/navigation/app_nav.dart`, `library_page_key.dart`, `playback_origin.dart`, `library_path.dart` · Modify `lib/services/playback_session.dart` (origin in JSON), `lib/controllers/app_controller.dart` (`PlaybackOrigin? playbackOrigin` + setter, restored with the session), every `Routes.playerTo` call site and every library-page push listed below · Tests `test/navigation/app_nav_test.dart`, `test/navigation/library_page_key_test.dart`, `test/audio/playback_session_origin_test.dart`

**Interfaces — Produces:**
```dart
class LibraryPageKey { const LibraryPageKey(this.kind, [this.args = const {}]); final String kind; final Map<String, Object?> args;
  Map<String, Object?> toJson(); static LibraryPageKey? fromJson(Object? json); /* value == and hashCode */
  factory LibraryPageKey.place(String placeId); /* kinds: 'place', 'album','artist','genre','folder','playlist','mix','ytList','ytCategory','ytArtist','ytSearch','cloudFolder','search','songsAll' — args carry what is needed to rebuild the page */ }
class PlaybackOrigin { const PlaybackOrigin(this.path); final List<LibraryPageKey> path; toJson(); static PlaybackOrigin? fromJson(Object? json); }
class LibraryPathScope extends InheritedWidget { const LibraryPathScope({required List<LibraryPageKey> path, required Widget child}); static List<LibraryPageKey> of(BuildContext c); /* [] when absent */ }
abstract interface class LibraryNavigatorController { Future<void> openPage(Widget page, {required LibraryPageKey key, Object? morphFrom, bool sibling = false}); Future<void> showPath(List<LibraryPageKey> path); bool get canPop; Future<bool> pop(); List<LibraryPageKey> get path; }
abstract interface class NavHost { Future<void> toPlayer({Object? morphFrom}); Future<void> toLibrary({PlaybackOrigin? landOn, Object? morphFrom}); LibraryNavigatorController get library; }
abstract final class AppNav { static NavHost? host;
  static Future<void> toPlayer(BuildContext context, {Object? morphFrom}); // records LibraryPathScope.of(context) as AppController.playbackOrigin when non-empty, then host?.toPlayer ?? legacy Routes.playerTo
  static Future<void> toLibrary(BuildContext context, {PlaybackOrigin? landOn});
  static Future<void> openPage(BuildContext context, Widget page, {required LibraryPageKey key, Object? morphFrom, bool sibling = false}); // sibling = record T9 (e.g. SearchPage from Places); host?.library.openPage ?? legacy Routes.scaleTo wrapped in LibraryPathScope(parent + key) }
```
Call sites (replace; no behaviour change in legacy mode except the owner's rule): every `Routes.playerTo` (`songs.dart`, `genre_songs.dart`, `folder_songs.dart`, `home_surface.dart`, `mix_playlist_page.dart`, `ember_mini_player.dart`, `cloud_folder_songs.dart`, `search_page.dart`, `services/ytmusic/yt_playback.dart`, `remote_mini_player.dart`, `video_mini_player.dart`, `bottom_player.dart`) → `AppNav.toPlayer`; every library-page push (`albums.dart`, `artists.dart`, `genres.dart`, `folders.dart`, `play_list_view.dart`, `artist_songs.dart`, `album_songs.dart`, `song_options_sheet.dart` go-to pages, `discover_view.dart`, `yt_open.dart`, `opened_list_page.dart`, `cloud_view.dart`, `search_page.dart` 1010–1066, `song_actions_sheet.dart` go-to pages, `home_surface.dart` playlists) → `AppNav.openPage(..., key: ...)`. Owner rule: in `album_songs.dart`, `artist_songs.dart`, `playlist_songs.dart`, song taps and Play/Shuffle call `AppNav.toPlayer` after starting playback. `YtPlayback` methods keep their `BuildContext` and call `AppNav.toPlayer` (no service pushes a route itself).

- [ ] **Step 1: Failing tests:** `library_page_key_test` — JSON round trip for each kind; equality. `playback_session_origin_test` — a session with an origin round-trips; a session JSON without `origin` loads with `null` (old saves). `app_nav_test` — with `AppNav.host == null`, `openPage` pushes a route whose page sees `LibraryPathScope.of == [parent…, key]`; `toPlayer` from inside that page sets `AppController.playbackOrigin.path` to that path; with a fake `NavHost`, calls are forwarded and no route is pushed.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement; convert the call sites.
- [ ] **Step 4:** `flutter test test/navigation test/audio test/pages test/player` → PASS; `grep -rn "Routes.playerTo" lib` → only inside `app_nav.dart` and `routes/routes.dart`; analyze clean.

---

### Task 5: Places and place pages (wave 1)

**Files:** Create `lib/navigation/places/places_page.dart`, `place_app_bar.dart`, `place_scaffold.dart` · Tests `test/navigation/places/*_test.dart`

**Interfaces — Produces:**
```dart
enum PlaceId { forYou, songs, albums, artists, genres, folders, playlists, youtube, cloud }
extension PlaceLabel on PlaceId { String get label; IconData get icon; } // 'For You','Songs','Albums','Artists','Genres','Folders','Playlists','YouTube Music','Cloud'; icons from today's chips/nav
List<PlaceId> visiblePlaces({required bool isIos}); // spec order; no folders on iOS
class PlacesPage extends StatelessWidget { const PlacesPage({super.key, required void Function(BuildContext context, PlaceId id) onOpen, required VoidCallback onMenu, required VoidCallback onSearch}); } // rows tagged MorphTag('place:<id>') around icon+title
class PlaceAppBar extends StatelessWidget implements PreferredSizeWidget { const PlaceAppBar({super.key, required String title, Object? titleMorphTag, VoidCallback? onBack, VoidCallback? onMenu, required VoidCallback onSearch, List<Widget> actions = const []}); } // pixel-identical to today's HomeShell AppBar; back chevron replaces the hamburger when onBack != null
class PlaceScaffold extends StatelessWidget { const PlaceScaffold({super.key, required PlaceId id, required VoidCallback onBack, required VoidCallback onMenu, required VoidCallback onSearch}); } // PlaceAppBar(title: id.label, titleMorphTag: 'place:<id>') over the place body
Widget placeBody(PlaceId id); // HomeSurface, AllSongs, Albums, Artists, Genres, Folders, PlayListView, DiscoverView, CloudView — unchanged widgets
```
Rows use today's `LibraryListRow` look. Songs' sort and import buttons (today beside the chip row in `library_surface.dart`) become `PlaceAppBar.actions` for `PlaceId.songs`, same widgets. Uses `MorphTag` from Task 2 (import by path; wave-1 parallel — code against the Interfaces block; tests may wait for Task 2's file).

- [ ] **Step 1: Failing tests:** `places_page_test` — Android shows 9 rows in spec order, iOS 8 (no Folders); tapping "Albums" calls `onOpen(ctx, PlaceId.albums)`; menu/search buttons fire. `place_app_bar_test` — matches today's HomeShell app bar (compare `toolbarHeight`, title style, icon sizes read from `home_shell.dart`); back chevron shown with `onBack`. `place_scaffold_test` — `PlaceScaffold(id: songs)` shows title "Songs" and the sort button.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Tests → PASS; analyze clean.

---

### Task 6: Motion shell and player ↔ library (wave 2)

**Files:** Create `lib/navigation/shell/motion_shell.dart`, `scene_controller.dart` · Modify `lib/pages/index_page.dart` (→ `MotionShell`), `lib/pages/home/home_shell.dart` (removed or reduced to nothing the shell uses), `lib/pages/loader.dart`, `lib/main.dart` (named routes), `lib/routes/routes.dart` (`playerTo` → AppNav), `lib/player/player_ui.dart` (card drag, chevron, empty queue, art `MorphTag('now-playing-art')`), `lib/player/widgets/Header.dart`, `lib/pages/home/widgets/ember_mini_player.dart` (`MorphTag('mini-art')`), `lib/player/player_presence.dart`, onboarding coach-mark keys that pointed at the removed tabs · Tests `test/navigation/shell/*_test.dart`

**Interfaces — Consumes:** Tasks 1, 2, 4, 5; `LibraryNavigator` from Task 7 (`const LibraryNavigator({required GlobalKey<LibraryNavigatorState> key, required Widget root})`, `LibraryNavigatorState implements LibraryNavigatorController`) — code against it; tests use a fake `LibraryNavigatorController`. **Produces:** `MotionShell` (sets `AppNav.host` in `initState`, clears it in `dispose`); `SceneController implements NavHost` with `ValueListenable<Scene> scene` (`enum Scene { player, library }`).

Behaviour (record T1–T5): Stack = library scene (today's `ZoomDrawer(menuScreen: MenuScreen(), mainScreen: LibraryNavigator(root: PlacesPage(...)))`) + player scene (today's `Player`) + mini player bar (today's `EmberMiniPlayer`). Three clocks per spec table; `PageLayer` values from `MotionSpec`; chrome (player controls band) fades/shrinks to `chromeHideScale` in place on the container clock; mini player rises `miniPlayerRise` on its own clock. Player → library lands via `library.showPath(origin.path)` (deepest rebuildable page, else Places) then flies `now-playing-art` → `track:<playing id>` if that row is visible, else T1 zoom only. Card drag-down = finger-driven `MotionProgress` with `ReleaseRules.artDrag`. Library → player (mini player tap, song tap via `AppNav.toPlayer`) flies the row/mini art into `now-playing-art`. `PopScope`: library & `canPop` → `library.pop()`; library at root → toPlayer (finger-driven on Android predictive back); player → let the app exit. Initial scene: player when a track/session exists, else library at Places. Queue empties while on the player → library at Places. EQ-only mode still returns `Equalizer()` for the whole app; `RemoteBuilder`/`RemotePlayerView` stays inside the player scene; `VideoMiniPlayer` overlay unchanged.

- [ ] **Step 1: Failing tests:** `scene_test` — `toLibrary()` then pump 250 ms: player layer scale ≈ 1.25, opacity ≈ 0, library layer scale 1; mini player offset settles at 500 ms (quart); `toPlayer()` mirrors with chrome settling at 500 ms. `drag_test` — dragging the player card 140 dp down and releasing (progress 0.39) commits to library; 90 dp (0.25) cancels back. `back_sequences_test` — player: back lets the route pop (app exit); library depth 2: back → depth 1; at Places: back → player; double back during a transition stays consistent. `origin_fallback_test` — origin path with an unbuildable last page lands on its parent; empty/unknown → Places. `interrupt_test` — tap mini player at 120 ms into toLibrary → reverses from the current value without jump. `modes_test` — EQ-only mode builds `Equalizer`; remote mode shows `RemotePlayerView` in the player scene; video mini window tap calls `AppNav.toPlayer`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `flutter test` → only the two known failures; analyze clean.

---

### Task 7: Library navigator, list routes and morph tags (wave 2)

**Files:** Create `lib/navigation/library/library_navigator.dart`, `list_page_route.dart`, `page_factory.dart` · Modify pages/widgets to add tags and remove legacy mini players: `song_tile.dart` (tags only — no zoom changes), `library_list_row.dart`, `albums.dart`, `artists.dart`, `genres.dart`, `folders.dart`, `play_list_view.dart`, `album_songs.dart`, `artist_songs.dart`, `genre_songs.dart`, `folder_songs.dart`, `playlist_songs.dart`, `home/mix_playlist_page.dart`, `home/home_surface.dart` + `home/widgets/shelf.dart`, `discover/*` (category tiles, `YtTile`, `YtTrackRow`, `MediaPageScaffold` header, `local_media.dart`), `cloud/cloud_view.dart`, `cloud/cloud_folder_songs.dart`, `search_page.dart`, `global/index.dart` (`headerWidget`), `widgets/bottom_player.dart` (delete if unused), `player/mini_player.dart` (delete), `pages/recents.dart` (delete), `pages/online/playlist.dart` (delete), `pages/menu_screen.dart` ("Cloud Music" → opens the Cloud place) · Tests `test/navigation/library/*_test.dart`

**Interfaces — Consumes:** Tasks 1, 2, 4, 5. **Produces:** `LibraryNavigator` / `LibraryNavigatorState implements LibraryNavigatorController` (nested `Navigator` with `ListPageRoute`; maintains `path`; wraps each page in `LibraryPathScope`); `ListPageRoute<T>({required WidgetBuilder builder, required LibraryPageKey key, Object? morphFrom, bool sibling = false})`; `registerLibraryPage(String kind, Widget? Function(LibraryPageKey key) build)` + `buildLibraryPage(LibraryPageKey)` used by `showPath`. Tag names: `item:<key json>` on every tappable row/tile that opens a page, `header:<key json>` on each page's existing header/title (or `place:<id>` app bar title), `track:<songId>` on every song row/cell art.

Behaviour (record T6–T9): open = old layer to `listOpenOldTo` (lists) / `gridOpenOldTo` (grids) about the tapped item's bottom edge, fading; new layer from `listNewFrom` about centre (grid: rect-fit from the tapped tile per record T6), fading in; `morphFrom` item flies into the header tag; list clock `cosEase` `listPage`; back is the mirror; `BackSwipeDetector` + Android predictive back drive back finger-first with `ReleaseRules.backSwipe`, rubber band `backRubberBand` and `backRubberReturn` at the root; `sibling: true` uses `listSibling`. `showPath` rebuilds without animating intermediates. Remove every legacy page mini player (`BottomPlayer`, `LocalMiniPlayerBar` in `MediaPageScaffold`) — the shell's mini player covers them; nothing else in those pages changes.

- [ ] **Step 1: Failing tests:** `route_open_test` — opening from a tagged row: at 125 ms the old layer scale ≈ 1.25, new ≈ 0.75, flight rect at the midpoint between row and header. `route_back_test` — back mirrors; back swipe 30 % + release commits; 25 % cancels; at root rubber-bands and returns in 350 ms. `show_path_test` — `showPath([place albums, album 5])` yields depth 2 with no running animation; an unknown kind truncates to the deepest buildable page. `no_legacy_mini_test` — `FolderSongs`, `GenreSongs`, `CloudFolderSongs`, `AlbumSongs` (via `MediaPageScaffold`) build no `BottomPlayer`/`LocalMiniPlayerBar`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement; tag pages without changing their look.
- [ ] **Step 4:** `flutter test` → only the two known failures; analyze clean; `grep -rn "Routes.scaleTo\|Routes.routeTo" lib/pages` only for non-library pages (settings, EQ, visualizer, lyrics).

---

### Task 8: Phone recording of the record's unknowns (wave 2, research)

No repo files. On the owner's S24 (`adb devices` for the current port), record the reference player at 60 Hz and settle: U1 (start scale of the new list when opening from 3- and 4-column grids), U2 (leftward in-list swipe; right-edge back gesture), U4 (which layer draws on top during the cross-fade), predictive back at the library root. Same rules as the earlier runtime session (no setting changes, restore state). Append findings to `~/me/COTE/.hype-reference/runtime-report.md` under a dated section; reply with the exact values for Task 10.

---

### Task 9: Zoom integration (wave 3)

**Files:** Modify `lib/widgets/song_tile.dart` (`SongListView` → `ZoomStepList`; keep `AlphabetFastScroll` via `listWrapper` in the list step), `albums.dart`, `artists.dart`, `genres.dart`, `folders.dart`, `cloud/cloud_folder_songs.dart` (grid blocks only), `lib/controllers/library_controller.dart` (`int zoomStepFor(String key, {required int fallback})`, `Future<void> setZoomStep(String key, int step)`, migration from `library_extent_<key>` and `AppController.songGridExtent`), `lib/controllers/app_controller.dart` (drop `songGridExtent` use) · Delete `lib/widgets/pinch_zoom_grid.dart` · Tests `test/navigation/zoom/integration_test.dart`, `test/controllers/zoom_step_migration_test.dart`

Steps per list = `[ZoomStep.list(rowExtent: today's row extent)]` + grid steps at today's `maxExtent`, midpoint, `minExtent` (e.g. albums 300/200/100, aspect 0.75, spacing 12). Migration: saved extent ≥ old list-mode threshold (260) → list step; else nearest grid step; default = today's fallback. Song lists keyed per list (`songs`, `genre_songs`, `folder_songs`, `cloud_folder`, `search`).

- [ ] **Step 1: Failing tests:** migration (`library_extent_albums=200` → grid 200 step; `songGridExtent=300` → list step); `integration_test` — `AllSongs` and `Albums` build a `ZoomStepList` with the expected steps; a pinch-out on Albums moves one step and persists it; the list step still shows the A–Z scroller.
- [ ] **Step 2–4:** fail → implement → `flutter test` only the two known failures; analyze clean; `grep -rn PinchZoomGrid lib` → nothing.

---

### Task 10: Tuning from the recording (wave 3)

**Files:** Modify `lib/navigation/motion_spec.dart`, `lib/navigation/library/list_page_route.dart`, `lib/navigation/shell/scene_controller.dart` · Tests: extend the Task 1, 6, 7 tests for every changed value.

Apply Task 8's values (grid start scale per column count, leftward/edge swipe behaviour, layer draw order, root predictive back). Each change cites the runtime-report section in a comment (no reference name).

- [ ] **Step 1:** Update the tests to the recorded values → FAIL. **Step 2:** Implement → PASS. **Step 3:** `flutter test` (two known failures only); analyze clean.

---

## After each wave (controller)

Snapshot → task reviews → build the dev copy: `flutter build apk --release --android-project-arg=dev=true --target-platform android-arm64`, install `adb install -r --user 0 build/app/outputs/flutter-apk/app-release.apk` on the S24 → owner feels it side by side with the reference player. Final whole-branch review after wave 3.
