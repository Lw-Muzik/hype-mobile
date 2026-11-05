import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Manages data-conscious cloud streaming behavior.
/// Tracks network type, enforces cellular data limits, monitors usage,
/// and provides prefetch decisions.
class StreamingDataGuard {
  static StreamingDataGuard? _instance;
  static StreamingDataGuard get instance => _instance!;

  final SharedPreferences _prefs;
  final Connectivity _connectivity = Connectivity();

  StreamSubscription<List<ConnectivityResult>>? _connSub;
  bool _isWifi = true;
  bool _isOffline = false;

  // Settings
  bool get streamOnCellular => _prefs.getBool('streamOnCellular') ?? true;
  set streamOnCellular(bool v) => _prefs.setBool('streamOnCellular', v);

  bool get warnOnCellular => _prefs.getBool('warnOnCellular') ?? true;
  set warnOnCellular(bool v) => _prefs.setBool('warnOnCellular', v);

  /// Max MB to use on cellular per session (0 = unlimited)
  int get cellularLimitMB => _prefs.getInt('cellularLimitMB') ?? 100;
  set cellularLimitMB(int v) => _prefs.setInt('cellularLimitMB', v);

  bool get prefetchNextTrack => _prefs.getBool('prefetchNextTrack') ?? true;
  set prefetchNextTrack(bool v) => _prefs.setBool('prefetchNextTrack', v);

  /// Only prefetch on WiFi
  bool get prefetchOnlyOnWifi => _prefs.getBool('prefetchOnlyOnWifi') ?? true;
  set prefetchOnlyOnWifi(bool v) => _prefs.setBool('prefetchOnlyOnWifi', v);

  /// Data saver mode: reduces buffer sizes and limits bitrate on cellular
  bool get dataSaver => _prefs.getBool('dataSaver') ?? false;
  set dataSaver(bool v) => _prefs.setBool('dataSaver', v);

  /// Whether data saver should be active right now
  /// (enabled AND on cellular, or force-enabled)
  bool get isDataSaverActive => dataSaver && !_isWifi && !_isOffline;

  // Runtime state
  bool get isWifi => _isWifi;
  bool get isOffline => _isOffline;
  bool get isCellular => !_isWifi && !_isOffline;

  // Data usage tracking (per session, resets on app restart)
  int _cellularBytesUsed = 0;
  int get cellularBytesUsed => _cellularBytesUsed;
  String get cellularUsageFormatted => _formatBytes(_cellularBytesUsed);

  // Cumulative data usage (persisted)
  int get totalCellularBytes => _prefs.getInt('totalCellularBytes') ?? 0;
  String get totalCellularFormatted => _formatBytes(totalCellularBytes);

  // Callbacks
  final _stateController = StreamController<NetworkState>.broadcast();
  Stream<NetworkState> get stateStream => _stateController.stream;

  StreamingDataGuard._(this._prefs);

  static Future<StreamingDataGuard> init(SharedPreferences prefs) async {
    final guard = StreamingDataGuard._(prefs);
    await guard._detectNetwork();
    guard._connSub = guard._connectivity.onConnectivityChanged.listen(
      guard._onConnectivityChanged,
    );
    _instance = guard;
    return guard;
  }

  void dispose() {
    _connSub?.cancel();
    _stateController.close();
  }

  Future<void> _detectNetwork() async {
    final results = await _connectivity.checkConnectivity();
    _updateFromResults(results);
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    _updateFromResults(results);
    _stateController.add(currentState);
  }

  void _updateFromResults(List<ConnectivityResult> results) {
    _isOffline = results.contains(ConnectivityResult.none) || results.isEmpty;
    _isWifi =
        results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);
  }

  NetworkState get currentState {
    if (_isOffline) return NetworkState.offline;
    if (_isWifi) return NetworkState.wifi;
    return NetworkState.cellular;
  }

  /// Whether streaming should proceed given current network conditions.
  /// Returns a reason string if blocked, or null if OK to stream.
  String? shouldBlockStream() {
    if (_isOffline) return 'No internet connection';
    if (isCellular && !streamOnCellular) {
      return 'Cellular streaming is disabled. Connect to WiFi or enable in settings.';
    }
    if (isCellular && cellularLimitMB > 0) {
      final limitBytes = cellularLimitMB * 1024 * 1024;
      if (_cellularBytesUsed >= limitBytes) {
        return 'Cellular data limit reached (${cellularLimitMB}MB). Connect to WiFi to continue.';
      }
    }
    return null;
  }

  int _pendingUsageBytes = 0;
  Timer? _usagePersistTimer;

  /// Record bytes downloaded on cellular.
  /// Called per HTTP chunk (~4-64KB) during cellular caching — persisting on
  /// every call meant hundreds of prefs commits per track. The in-memory
  /// session counter updates immediately (limit checks stay accurate); only
  /// the lifetime-total disk write is coalesced to one commit per 5s.
  void recordCellularUsage(int bytes) {
    if (!isCellular || bytes <= 0) return;
    _cellularBytesUsed += bytes;
    _pendingUsageBytes += bytes;
    _usagePersistTimer ??= Timer(const Duration(seconds: 5), flushPendingUsage);
  }

  /// Flush the debounced usage total to disk (also called on app background).
  void flushPendingUsage() {
    _usagePersistTimer?.cancel();
    _usagePersistTimer = null;
    if (_pendingUsageBytes == 0) return;
    _prefs.setInt(
      'totalCellularBytes',
      totalCellularBytes + _pendingUsageBytes,
    );
    _pendingUsageBytes = 0;
  }

  /// Whether we should prefetch the next track.
  bool shouldPrefetch() {
    if (!prefetchNextTrack) return false;
    if (_isOffline) return false;
    if (prefetchOnlyOnWifi && !_isWifi) return false;
    if (isCellular && cellularLimitMB > 0) {
      final limitBytes = cellularLimitMB * 1024 * 1024;
      // Don't prefetch if we're within 20% of the cellular limit
      if (_cellularBytesUsed > limitBytes * 0.8) return false;
    }
    return true;
  }

  void resetSessionUsage() {
    _cellularBytesUsed = 0;
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

enum NetworkState { wifi, cellular, offline }
