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

  /// Per-category pinch-zoom level (grid extent): each library
  /// category remembers its own zoom independently. Read once at tab build;
  /// written on pinch release — no notify, nothing else depends on it live.
  double gridExtentFor(String tab, {required double fallback}) =>
      _prefs.getDouble('library_extent_$tab') ?? fallback;

  void setGridExtent(String tab, double extent) =>
      _prefs.setDouble('library_extent_$tab', extent);

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
