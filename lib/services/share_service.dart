import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'package:path_provider/path_provider.dart';

import 'remote_link.dart';
import 'stream_server.dart';

/// Foreground-service entry point. `flutter_foreground_task` runs this in its
/// own background isolate — which, with `android:stopWithTask="false"`, keeps
/// running after the app is swiped from recents. Running the sharing server
/// here (rather than in the UI isolate) is what lets a paired desktop keep
/// streaming once the app is gone from memory. Advertising is delegated to the
/// native NsdManager (see `StreamServerController._advertise`), so it survives
/// the secondary-isolate limitation that made bonsoir go silent here before.
@pragma('vm:entry-point')
void shareTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_ShareTaskHandler());
}

/// Runs the music-sharing server inside the foreground service's isolate and
/// relays its runtime state (pin / ip / port / paired list) back to the UI
/// isolate, keeping the persistent notification fresh.
class _ShareTaskHandler extends TaskHandler {
  final StreamServerController _server = StreamServerController.instance;
  VoidCallback? _detach;

  void _relay() {
    FlutterForegroundTask.sendDataToMain(jsonEncode(_server.stateSnapshot()));
    FlutterForegroundTask.updateService(
      notificationTitle: 'Sharing music to desktop',
      notificationText: _notificationText(),
    );
  }

  /// Notification body: pairing state plus the ip:port, so the user can always
  /// connect the desktop by address even if discovery misbehaves.
  String _notificationText() {
    final n = _server.pairedDesktops.length;
    final status = n == 0
        ? 'Ready to pair — code ${_server.pin ?? "------"}'
        : '$n computer${n == 1 ? "" : "s"} paired';
    final ip = _server.ip;
    final port = _server.port;
    if (ip != null && ip.isNotEmpty && port != null) {
      return '$status  •  $ip:$port';
    }
    return status;
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _server.addListener(_relay);
    _detach = () => _server.removeListener(_relay);
    await _server.start();
    _relay();
  }

  // No periodic work — the shelf server runs on its own; this isolate just hosts
  // it and the notification.
  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  void onReceiveData(Object data) {
    if (data == 'refresh') {
      _relay();
      return;
    }
    if (data is String) {
      try {
        final msg = jsonDecode(data) as Map<String, dynamic>;
        switch (msg['cmd']) {
          case 'unpair':
            if (msg['id'] is String) _server.unpair(msg['id'] as String);
            break;
          case 'reloadPairings':
            // The main isolate minted a token (QR/iroh pairing) — pick it up so
            // the tunneled desktop is authorized by this running server.
            _server.reloadPairings();
            break;
        }
      } catch (_) {
        /* ignore malformed command */
      }
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop') FlutterForegroundTask.stopService();
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _detach?.call();
    await _server.stop();
  }
}

/// Main-isolate facade the UI talks to. On Android it drives a foreground
/// service (so sharing survives the app being swiped from memory and shows a
/// persistent notification); on iOS — where the OS suspends background apps —
/// it runs the server in-process while the app is alive. State from the service
/// isolate is relayed here via [FlutterForegroundTask.sendDataToMain].
class ShareService extends ChangeNotifier {
  ShareService._();
  static final ShareService instance = ShareService._();

  final StreamServerController _server = StreamServerController.instance;
  bool get _withService => Platform.isAndroid;

  bool _running = false;
  bool _busy = false;
  bool _inited = false;
  bool _allowUploads = false;
  String? _pin;
  String? _ip;
  int? _port;
  List<PairedDesktop> _paired = const [];

  // Completes when the service isolate first reports it is running with a bound
  // port, so [enable] can start the iroh link against the real ip:port.
  Completer<void>? _startAck;
  // Guards [_startRemoteLink] against concurrent callers (the enable() path and
  // the relay-driven restore path can both fire it), which would otherwise leak
  // a second iroh node.
  bool _startingRemoteLink = false;

  bool get running => _running;
  bool get busy => _busy;
  String? get pin => _pin;
  String? get ip => _ip;
  int? get port => _port;
  List<PairedDesktop> get pairedDesktops => _paired;
  String get deviceName => _server.deviceName;

  /// Whether paired desktops may push files to this phone (`POST /upload`).
  bool get allowUploads => _allowUploads;

  /// Call once at startup (registers the task↔UI channel and restores the
  /// running state if the service is still up from a previous session, e.g.
  /// after the app was swiped away and relaunched).
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    _allowUploads = await _server.allowUploads();
    if (_withService) {
      FlutterForegroundTask.initCommunicationPort();
      FlutterForegroundTask.addTaskDataCallback(_onTaskData);
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'hype_share',
          channelName: 'Music sharing',
          channelDescription:
              'Shown while your music is being shared to the desktop app.',
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnBoot: false,
          allowWakeLock: true,
          allowWifiLock: true,
          // If the OS reclaims the process, let the service come back and
          // rebuild the server + advertisement (see AndroidManifest
          // stopWithTask="false").
          allowAutoRestart: true,
        ),
      );
      _running = await FlutterForegroundTask.isRunningService;
      if (_running) {
        // Service survived from a previous session — ask it to relay its
        // current pin/ip/port/paired snapshot.
        FlutterForegroundTask.sendDataToTask('refresh');
      }
    } else {
      _server.addListener(_syncFromController);
    }
    notifyListeners();
  }

  Future<void> toggle(bool on) => on ? enable() : disable();

  /// Opt in/out of receiving files pushed by a paired desktop. Persisted here in
  /// the main isolate; the sharing server — the service isolate on Android —
  /// re-reads the flag from disk on every upload, so this takes effect at once
  /// without restarting the service.
  Future<void> setAllowUploads(bool value) async {
    if (_allowUploads == value) return;
    _allowUploads = value;
    notifyListeners();
    await _server.setAllowUploads(value);
  }

  /// Start sharing (and, on Android, the foreground service + notification).
  Future<void> enable() async {
    if (_running || _busy) return;
    _busy = true;
    notifyListeners();
    try {
      if (_withService) {
        await _requestPermissions();
        _startAck = Completer<void>();
        await FlutterForegroundTask.startService(
          serviceId: 5210,
          notificationTitle: 'Sharing music to desktop',
          notificationText: 'Starting…',
          notificationButtons: const [
            NotificationButton(id: 'stop', text: 'Stop sharing'),
          ],
          callback: shareTaskCallback,
        );
        _running = true; // the task relays the real pin/ip/port shortly after.
        await _awaitStartAck();
      } else {
        await _server.start();
        _syncFromController();
      }
      await _startRemoteLink();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Wait (bounded) for the service isolate to report a bound port, so the iroh
  /// link tunnels to the right ip:port. Proceeds anyway on timeout — the LAN
  /// server still works; the relay may simply arrive a little later.
  Future<void> _awaitStartAck() async {
    final c = _startAck;
    if (c == null || c.isCompleted) return;
    try {
      await c.future.timeout(const Duration(seconds: 8));
    } catch (_) {
      /* proceed without the port */
    }
  }

  /// Stop sharing and tear down the service/notification (and the iroh link).
  Future<void> disable() async {
    if (_busy) return;
    _busy = true;
    notifyListeners();
    try {
      await RemoteLink.instance.stop();
      if (_withService) {
        if (await FlutterForegroundTask.isRunningService) {
          await FlutterForegroundTask.stopService();
        }
      } else {
        await _server.stop();
      }
    } finally {
      _running = false;
      _pin = null;
      _ip = null;
      _port = null;
      _paired = const [];
      _busy = false;
      notifyListeners();
    }
  }

  /// Ensure both the shelf server and this phone's iroh endpoint are running.
  /// Used by the QR-pairing flow: [enable] only starts the iroh endpoint the
  /// first time sharing is turned on, so if sharing is already active (but the
  /// endpoint failed/never started) we must retry it here.
  Future<void> ensureRemoteLink() async {
    if (!_running) {
      await enable(); // also starts the remote link
      return;
    }
    await _startRemoteLink();
  }

  /// Register a desktop paired over the **iroh/QR** flow: mints and persists a
  /// bearer token (read by the cast controller), then — on Android — tells the
  /// service isolate to reload its pairings so its running shelf server
  /// authorizes the tunneled desktop's requests. Returns the token for the QR
  /// handshake.
  Future<String> registerDesktop(String id, String name) async {
    final token = await _server.registerDesktop(id, name);
    if (_withService) {
      FlutterForegroundTask.sendDataToTask(
        jsonEncode({'cmd': 'reloadPairings'}),
      );
    }
    return token;
  }

  /// Forget a paired desktop. On Android the authoritative pairing set lives in
  /// the service isolate, so route the removal there (and drop it from the
  /// relayed snapshot immediately for a responsive UI).
  void unpair(String id) {
    if (_withService) {
      FlutterForegroundTask.sendDataToTask(
        jsonEncode({'cmd': 'unpair', 'id': id}),
      );
      _paired = _paired.where((d) => d.id != id).toList();
      notifyListeners();
    } else {
      _server.unpair(id);
    }
  }

  /// Start this phone's iroh endpoint so desktops can reach it across networks
  /// (best-effort — sharing still works on the LAN if the native lib is absent).
  /// Runs in the **main** isolate and tunnels to the shelf server (which may be
  /// in the service isolate) via `127.0.0.1:$port` — same process, so the
  /// loopback address is shared. The port comes from the relayed snapshot.
  Future<void> _startRemoteLink() async {
    if (!remoteLinkSupported) return;
    if (RemoteLink.instance.running || _startingRemoteLink) return;
    final port = _port;
    if (port == null) return;
    _startingRemoteLink = true;
    try {
      final dir = await getApplicationSupportDirectory();
      await RemoteLink.instance.start('${dir.path}/remote-identity.bin', port);
    } catch (e) {
      debugPrint('ShareService: remote link unavailable: $e');
    } finally {
      _startingRemoteLink = false;
    }
  }

  Future<void> _requestPermissions() async {
    final perm = await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }

  // -- Android: state relayed from the service isolate -----------------------

  void _onTaskData(Object data) {
    if (data is! String) return;
    try {
      final s = jsonDecode(data) as Map<String, dynamic>;
      _running = s['running'] == true;
      _pin = s['pin'] as String?;
      _ip = s['ip'] as String?;
      _port = (s['port'] as num?)?.toInt();
      _paired = ((s['paired'] as List?) ?? const [])
          .map(
            (j) => PairedDesktop(
              id: (j as Map)['id'] as String,
              name: j['name'] as String,
              token: '', // tokens stay in the service isolate.
            ),
          )
          .toList();
      if (_running &&
          _port != null &&
          _startAck != null &&
          !_startAck!.isCompleted) {
        _startAck!.complete();
      }
      // Restore the iroh endpoint after a swipe+relaunch (the service — and its
      // server — survived, but the main isolate that hosted the iroh node did
      // not). During an active enable() (_busy) the explicit call there handles
      // it, so skip to preserve that path's await semantics. Idempotent via the
      // guards in [_startRemoteLink].
      if (_running && _port != null && !_busy) {
        unawaited(_startRemoteLink());
      }
      notifyListeners();
    } catch (_) {
      /* ignore malformed relay */
    }
  }

  // -- iOS: mirror the in-process controller ---------------------------------

  void _syncFromController() {
    _running = _server.running;
    _pin = _server.pin;
    _ip = _server.ip;
    _port = _server.port;
    _paired = _server.pairedDesktops;
    notifyListeners();
  }
}
