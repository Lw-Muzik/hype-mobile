import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '/data/library_repository.dart';
import '/services/library_scanner.dart';

/// App-facing owner of the local library: exposes the [LibraryRepository] for
/// reactive list streams, drives the background [LibraryScanner], and holds the
/// (persisted) Songs-tab sort. Kept deliberately small and separate from the
/// 2k-line AppController so the browsing surface has a focused source of truth.
class LibraryController extends ChangeNotifier {
  LibraryController({
    required this.repo,
    required LibraryScanner scanner,
    required SharedPreferences prefs,
  })  : _scanner = scanner,
        _prefs = prefs {
    _songSort = SongSort.values[_prefs.getInt(_kSortField) ?? 0];
    _songDir = SortDir.values[_prefs.getInt(_kSortDir) ?? 0];
  }

  final LibraryRepository repo;
  final LibraryScanner _scanner;
  final SharedPreferences _prefs;

  static const _kSortField = 'library_song_sort';
  static const _kSortDir = 'library_song_dir';
  static const _kPlayCountsImported = 'library_playcounts_imported';

  late SongSort _songSort;
  late SortDir _songDir;
  SongSort get songSort => _songSort;
  SortDir get songDir => _songDir;

  ScanStatus _scanStatus = const ScanStatus(ScanPhase.idle);
  ScanStatus get scanStatus => _scanStatus;
  bool get isScanning => _scanStatus.isScanning;

  StreamSubscription<ScanStatus>? _statusSub;
  bool _started = false;

  /// Begins listening to scan progress and runs the initial diff scan. Safe to
  /// call more than once (subsequent calls are ignored).
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _statusSub = _scanner.status.listen((s) {
      _scanStatus = s;
      notifyListeners();
    });
    // Listening history is bounded, and the cheapest moment to bound it is the
    // one time per launch this runs. Unawaited: a launch must not wait on
    // housekeeping, and a prune that fails costs disk, never correctness.
    unawaited(
      repo.prunePlayEvents(DateTime.now().millisecondsSinceEpoch ~/ 1000),
    );
    await scan();
  }

  /// One-time migration of the legacy prefs play counts into the DB so
  /// "Most played" survives the switch to the library database.
  Future<void> importLegacyPlayCounts(Map<int, int> counts) async {
    if (_prefs.getBool(_kPlayCountsImported) ?? false) return;
    await repo.importPlayCounts(counts);
    await _prefs.setBool(_kPlayCountsImported, true);
  }

  Future<void> scan({bool force = false}) => _scanner.scan(force: force);

  /// Runs the scan again if the last one failed — called when the app comes to
  /// the front. A scan started with no screen (Hype Connect's background start)
  /// cannot query the media library; the first time the user opens the app is
  /// the first moment it can.
  Future<void> retryIfFailed() async {
    if (!_started || _scanStatus.phase != ScanPhase.error) return;
    await scan();
  }

  Future<void> rescan() => scan(force: true);

  /// Per-list pinch-zoom level, as an index into that list's zoom steps
  /// (higher = more zoomed in, the last step being the list when the list has
  /// one). Read once when the list builds; written when a pinch settles — no
  /// notify, nothing else depends on it live.
  ///
  /// A saved step is clamped to the [stepCount] steps of the ladder; without
  /// one the result is [fallback]. Layouts saved before zoom steps existed are
  /// not mapped here: they depend on the width the list gets, see
  /// [legacyZoomExtent].
  int zoomStepFor(String key, {required int fallback, int stepCount = 0}) {
    final saved = _prefs.getInt('$_kZoomPrefix$key');
    if (saved == null) return fallback;
    return stepCount == 0 ? saved : saved.clamp(0, stepCount - 1);
  }

  /// The grid extent a list saved before zoom steps existed
  /// (`library_extent_<key>`, or the one shared Songs value `songGridExtent`),
  /// while no step has been stored for it yet; otherwise null.
  ///
  /// The old widget always settled on `(screenWidth - 24) / columns`, so the
  /// value stands for a column count that only the list's real width can turn
  /// into a step (`legacyZoomStep`); the list does that at its first layout and
  /// stores the result with [setZoomStep], after which this answers null.
  double? legacyZoomExtent(String key) {
    if (_prefs.getInt('$_kZoomPrefix$key') != null) return null;
    return _legacyExtentFor(key);
  }

  Future<void> setZoomStep(String key, int step) =>
      _prefs.setInt('$_kZoomPrefix$key', step);

  static const _kZoomPrefix = 'library_zoom_';
  static const _songListKeys = {
    'songs',
    'genre_songs',
    'folder_songs',
    'cloud_folder',
    'search',
  };

  double? _legacyExtentFor(String key) {
    final own = _prefs.getDouble('library_extent_$key');
    if (own != null) return own;
    if (!_songListKeys.contains(key)) return null;
    final shared = _prefs.getDouble('songGridExtent');
    if (shared != null) return shared;
    // Older still: songGridScale 0 = list, 1 = two columns, 2 = three.
    final scale = _prefs.getInt('songGridScale');
    if (scale == null) return null;
    return scale == 0 ? 300.0 : (scale == 1 ? 180.0 : 120.0);
  }

  void setSongSort(SongSort sort, SortDir dir) {
    if (sort == _songSort && dir == _songDir) return;
    _songSort = sort;
    _songDir = dir;
    _prefs.setInt(_kSortField, sort.index);
    _prefs.setInt(_kSortDir, dir.index);
    notifyListeners();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    super.dispose();
  }
}
