/// Hype Connect on this phone: the one object the rest of the app talks to.
///
/// # What lives where
///
/// The protocol, socket, executor, rpc handler, state publisher and presence
/// rules are each small and tested alone. This is the composition root that
/// plugs them into each other and into the app — and the only class the
/// settings page, the stream page and `main.dart` need to know.
///
/// # Off until the user says otherwise
///
/// The feature is **off by default**: a phone that never opened the Hype
/// Connect page opens no socket and mints no account. It turns itself on in one
/// situation only — the user approved a link, which is an unmistakable "yes, I
/// want this phone controlled from there" — and turns itself off when the hub
/// says the phone was unlinked (close 4003), since a revoked phone that keeps
/// trying only collects refusals.
///
/// # Remote commands never touch the screen
///
/// Commands and rpcs are answered by [ConnectExecutor] and
/// [ConnectRpcHandler], which only know the app through the ports in
/// `app_bindings.dart`. Nothing in this class navigates or shows a dialog; the
/// pages that talk to it do so in response to the user.
library;

import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:on_audio_query/on_audio_query.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eq_app/config/app_config.dart';
import 'package:eq_app/controllers/app_controller.dart';
import 'package:eq_app/services/connect/app_bindings.dart';
import 'package:eq_app/services/connect/connect_account.dart';
import 'package:eq_app/services/connect/connect_api.dart';
import 'package:eq_app/services/connect/connect_client.dart';
import 'package:eq_app/services/connect/connect_executor.dart';
import 'package:eq_app/services/connect/connect_lyrics.dart';
import 'package:eq_app/services/connect/connect_video.dart';
import 'package:eq_app/services/connect/connect_notification.dart';
import 'package:eq_app/services/connect/connect_service.dart';
import 'package:eq_app/services/connect/connect_viz.dart';
import 'package:eq_app/services/connect/connect_volume.dart';
import 'package:eq_app/services/connect/connect_presence.dart';
import 'package:eq_app/services/connect/connect_protocol.dart';
import 'package:eq_app/services/connect/connect_rpc.dart';
import 'package:eq_app/services/connect/connect_state_publisher.dart';
import 'package:eq_app/services/connect/remote/connect_link_direction.dart';
import 'package:eq_app/services/connect/remote/connect_play_router.dart';
import 'package:eq_app/services/connect/remote/connect_remote_session.dart';
import 'package:eq_app/services/connect/remote/connect_takeover.dart';
import 'package:eq_app/services/connect/remote/connect_transfer.dart';
import 'package:eq_app/services/connect/remote/connect_ui_host.dart';

/// The hub's WebSocket address for a REST base such as
/// `http://host:9400/api` — same host, same prefix, `/connect/ws`.
Uri connectWsUri(String apiBase) {
  final base = Uri.parse(apiBase);
  final path = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  return base.replace(
    scheme: base.scheme == 'https' ? 'wss' : 'ws',
    path: '$path/connect/ws',
  );
}

/// What this phone calls itself on other devices' lists.
///
/// Android: the name the user gave the phone in Settings, else "Samsung
/// SM-S921B". iOS: since iOS 16 `name` is only the generic model family
/// ("iPhone") unless the app holds a special entitlement, and a list of three
/// devices all called "iPhone" helps nobody, so the model's marketing name
/// is preferred when `name` is generic.
@visibleForTesting
String deviceDisplayName({
  required bool ios,
  String? name,
  String? manufacturer,
  String? model,
  String? modelName,
}) {
  final given = name?.trim() ?? '';
  if (ios) {
    const generic = {'iphone', 'ipad', 'ipod touch', 'ipod'};
    if (given.isNotEmpty && !generic.contains(given.toLowerCase())) {
      return given;
    }
    final marketing = modelName?.trim() ?? '';
    if (marketing.isNotEmpty) return marketing;
    return given.isNotEmpty ? given : 'iPhone';
  }
  if (given.isNotEmpty) return given;
  final make = manufacturer?.trim() ?? '';
  final type = model?.trim() ?? '';
  if (make.isEmpty && type.isEmpty) return 'Android phone';
  if (make.isEmpty) return type;
  final brand = make[0].toUpperCase() + make.substring(1);
  if (type.isEmpty) return brand;
  // "samsung" + "Samsung Galaxy" must not read "Samsung Samsung Galaxy".
  return type.toLowerCase().startsWith(make.toLowerCase())
      ? type
      : '$brand $type';
}

/// What to tell the user when linking a device failed.
///
/// One sentence each, saying what happened and what to do — the codes the hub
/// answers with (404 unknown or used, 409 two accounts, 429 too many guesses)
/// each have a different remedy.
String describeLinkError(Object error) {
  if (error is ConnectHttpException) {
    switch (error.statusCode) {
      case 404:
        return 'That code has expired or was already used. '
            'Ask the other device for a new one.';
      case 409:
        if (error.code == 'BOTH_HAVE_ACCOUNTS') {
          return 'Both devices are signed in to different HypeMuzik accounts, '
              'so they cannot be linked. Sign one of them out first.';
        }
        return 'That device changed accounts after the code was made. '
            'Ask it for a new code.';
      case 429:
        return 'Too many attempts. Wait a minute and try again.';
    }
    if (error.statusCode >= 500) {
      return 'HypeMuzik is having trouble right now. Try again in a moment.';
    }
    return 'Could not link that device (${error.statusCode}).';
  }
  if (error is TimeoutException || error is SocketException) {
    return 'Could not reach HypeMuzik. Check your connection and try again.';
  }
  return 'Could not link that device. Try again.';
}

/// Keeps the last `seq` in preferences, so a restart continues after it.
class PrefsConnectSeqStore implements ConnectSeqStore {
  PrefsConnectSeqStore(this._prefs);

  static const key = 'hype_connect.last_seq';

  final SharedPreferences _prefs;

  @override
  int? read() => _prefs.getInt(key);

  @override
  void write(int seq) => unawaited(_prefs.setInt(key, seq));
}

class HypeConnect extends ChangeNotifier with WidgetsBindingObserver {
  /// For tests and for [attach]; the app uses [attach].
  @visibleForTesting
  HypeConnect({
    required this.prefs,
    required this.account,
    required this.api,
    required this.client,
    required this._player,
    required this._library,
    required this._catalog,
    required this._stateSource,
    required this.isMusicMode,
    required this.isPlaying,
    this.lyrics,
    this.video,
    this.currentSong,
    this.vizFeed,
    this.position,
    this.onRemoteModeChanged,
    this.deviceVolume,
    int Function()? nowUs,
    Duration presenceGrace = const Duration(minutes: 2),
    bool backgroundAlways = false,
    ConnectServiceBridge? serviceBridge,
    Future<void> Function()? requestNotifications,
  })  : _nowUs = nowUs ?? timelineNowUs,
        _serviceBridge = serviceBridge {
    _enabled = prefs.getBool(enabledKey) ?? false;
    _presence = ConnectPresence(
      onWanted: _onWanted,
      grace: presenceGrace,
      backgroundAlways: backgroundAlways,
    );
    final bridge = serviceBridge;
    if (bridge != null) {
      _service = ConnectServiceController(
        bridge: bridge,
        content: _notificationContent,
        requestNotifications: requestNotifications,
      );
      bridge
        ..onAction = _onServiceAction
        ..onOpenRequested = (() => unawaited(_openRequested()))
        ..onVolumeKey = _onVolumeKey;
    }
    client.state.addListener(_onClientState);
  }

  /// What this phone tells the hub it can do (protocol v1.3).
  static const List<ConnectCap> deviceCaps = [
    ConnectCap.player,
    ConnectCap.yt,
    ConnectCap.local,
    ConnectCap.lyrics,
    ConnectCap.viz,
    ConnectCap.video,
  ];

  static const enabledKey = 'hype_connect.enabled';

  static HypeConnect? _instance;
  static HypeConnect get instance => _instance!;
  static HypeConnect? get instanceOrNull => _instance;

  /// Builds the real thing against [app] and starts it. Call once, at startup.
  static HypeConnect attach(AppController app, SharedPreferences prefs) {
    final http0 = http.Client();
    final account = ConnectAccount(
      client: http0,
      apiBase: Uri.parse(AppConfig.hypeMuzikApiBase),
      store: const SecureConnectSecretStore(),
      installInfo: () async => ConnectInstallInfo(
        os: Platform.isIOS ? 'ios' : 'android',
        appVersion: await _appVersion(),
      ),
    );
    final client = ConnectClient(
      wsUri: connectWsUri(AppConfig.hypeMuzikApiBase),
      connect: IoConnectSocket.new,
      accessToken: account.accessToken,
      refreshToken: account.refresh,
      resetSession: account.resetSession,
      device: () => _deviceHello(account),
    );
    // One bridge for the whole channel: a second Dart MethodChannel on the same
    // name would replace the first one's handler.
    final bridge = Platform.isAndroid ? MethodChannelConnectService() : null;
    final volume = AppConnectDeviceVolume(
      bridge: bridge,
      // DVC exists only on Android; the iOS toggle drives native no-ops, so a
      // remote's volume routed there would vanish.
      dvcEnabled: () => Platform.isAndroid && app.dvcEnabled,
      dvcGainDb: () => app.dvcGain,
      setDvcGainDb: (db) => app.dvcGain = db,
      // The listener volume, not a player's gain: it survives loads and
      // crossfades, and it has a real value even mid-fade.
      legacyRead: () => app.handler.listenerVolume,
      legacySet: (v) async => app.handler.setListenerVolume(v),
    );
    final connect = HypeConnect(
      prefs: prefs,
      account: account,
      api: ConnectApi(client: http0, account: account),
      client: client,
      player: AppConnectPlayer(app, volume),
      library: RepositoryConnectLibrary(() => AppController.libraryRepo),
      catalog: YtConnectCatalog(app),
      stateSource: AppConnectStateSource(app, volume),
      deviceVolume: volume,
      isMusicMode: () => !app.isEqMode,
      isPlaying: () => app.handler.playbackState.value.playing,
      lyrics: AppConnectLyrics(app),
      video: AppConnectVideo(app),
      currentSong: () {
        final i = app.songId;
        return i >= 0 && i < app.songs.length ? app.songs[i] : null;
      },
      vizFeed: AppConnectVizFeed(app),
      position: () => app.handler.currentTrackPlayer.position,
      onRemoteModeChanged: app.refreshRemoteMode,
      // Android keeps the phone on the hub in the background, held up by the
      // foreground service; iOS cannot, so it keeps the grace rule.
      backgroundAlways: Platform.isAndroid,
      serviceBridge: bridge,
      requestNotifications: Platform.isAndroid ? _requestNotifications : null,
    );
    app.addListener(connect.inputsChanged);
    app.handler.playbackState.listen((_) => connect.inputsChanged());
    connect.start();
    return _instance = connect;
  }

  /// Android 13+ keeps a notification hidden until it is allowed. Asked when
  /// the user turns Hype Connect on; a "no" leaves the service running (its
  /// entry is still in the system's task manager), just without the shade card.
  static Future<void> _requestNotifications() async {
    if (await Permission.notification.status.isGranted) return;
    await Permission.notification.request();
  }

  final SharedPreferences prefs;
  final ConnectAccount account;
  final ConnectApi api;
  final ConnectClient client;
  final bool Function() isMusicMode;
  final bool Function() isPlaying;

  /// Answers the `lyrics` rpc; without it the rpc is `unsupported`.
  final ConnectLyricsSource? lyrics;

  /// Answers the `video` rpc (v1.3); without it the rpc is `unsupported`.
  final ConnectVideoSource? video;
  final SongModel? Function()? currentSong;

  /// The native analysis for the visualiser stream, and the playback position.
  final ConnectVizFeed? vizFeed;
  final Duration Function()? position;
  final int Function() _nowUs;

  ConnectVizStreamer? _viz;

  /// Called when remote mode starts or ends.
  final VoidCallback? onRemoteModeChanged;
  bool _wasRemote = false;

  /// What the listener hears from this phone (DVC gain or system media volume);
  /// watched while the socket is up, so hardware keys reach the hub.
  final ConnectDeviceVolume? deviceVolume;

  /// The latest hardware-key press while this phone remote-controls another
  /// device, for the "Volume on (device)" HUD. Null until the first press.
  final ValueNotifier<ConnectVolumeHudEvent?> volumeHud = ValueNotifier(null);

  final ConnectPlayer _player;
  final ConnectLibrary _library;
  final ConnectCatalog _catalog;
  final ConnectStateSource _stateSource;

  late final ConnectPresence _presence;
  final ConnectServiceBridge? _serviceBridge;
  ConnectServiceController? _service;

  /// The device that last sent this phone a command, for the notification's
  /// "Controlled from …". Forgotten when that device goes offline.
  String? _controllerId;
  ConnectExecutor? _executor;
  ConnectRpcHandler? _rpc;
  ConnectStatePublisher? _publisher;
  ConnectRemoteSession? _session;
  ConnectTakeover? _takeover;
  ConnectTransfer? _transfer;
  ConnectLinkDirection? _direction;
  StreamSubscription<RemoteEvent>? _remoteEvents;
  StreamSubscription<ConnectFrame>? _frames;
  bool _started = false;

  bool _enabled = false;
  String? _notice;
  List<DeviceInfo> _devices = const [];
  String? _activeDeviceId;
  String? _thisDeviceId;

  /// Whether the user has Hype Connect switched on.
  bool get enabled => _enabled;

  /// Why the feature switched itself off, e.g. "This phone was unlinked".
  /// Cleared when it is switched on again.
  String? get notice => _notice;

  /// Where the socket stands.
  ConnectClientState get connection => client.state.value;

  /// Whether the app is meant to be on the hub right now. Differs from
  /// [enabled] while the app sits in the background, or in equalizer mode.
  bool get wantsConnection => _presence.wanted;

  /// Whether this phone has a background service to keep it reachable
  /// (Android). The page offers the battery-optimisation shortcut only then.
  bool get hasBackgroundService => _serviceBridge != null;

  /// Whether the system lets the app run unrestricted in the background; true
  /// when there is nothing to ask.
  Future<bool> isIgnoringBatteryOptimizations() async =>
      await _serviceBridge?.isIgnoringBatteryOptimizations() ?? true;

  /// Opens the system page for exempting the app from battery optimisation.
  Future<void> openBatterySettings() async =>
      _serviceBridge?.openBatterySettings();

  /// Every linked device of this account.
  List<DeviceInfo> get devices => _devices;
  String? get activeDeviceId => _activeDeviceId;

  /// This phone's id on the hub, once known.
  String? get thisDeviceId => _thisDeviceId;

  /// This phone as a remote for the active player (null until started).
  ConnectRemoteSession? get session => _session;

  /// Moves playback between devices (null until started).
  ConnectTransfer? get transfer => _transfer;

  /// The "where should music play?" logic after linking a desktop.
  ConnectLinkDirection? get linkDirection => _direction;

  /// Prepares the executor and rpc handler (they need this install's id, which
  /// comes from secure storage) and then applies the stored switch.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    final deviceId = await account.installId();
    _thisDeviceId = deviceId;
    _executor = ConnectExecutor(
      player: _player,
      library: _library,
      deviceId: deviceId,
    );
    _rpc = ConnectRpcHandler(
      catalog: _catalog,
      library: _library,
      deviceId: deviceId,
      lyrics: lyrics,
      video: video,
      currentSong: currentSong,
    );
    final feed = vizFeed;
    final positionOf = position;
    if (feed != null && positionOf != null) {
      _viz = ConnectVizStreamer(
        feed: feed,
        send: client.send,
        isPlaying: isPlaying,
        position: positionOf,
        hubNowMs: client.hubClock.nowMs,
        nowUs: _nowUs,
      );
    }
    _publisher = ConnectStatePublisher(
      source: _stateSource,
      send: client.send,
      deviceId: deviceId,
      seqStore: PrefsConnectSeqStore(prefs),
    );
    final session = _session = ConnectRemoteSession(
      selfId: deviceId,
      send: client.send,
      hubNowMs: client.hubClock.nowMs,
    );
    _takeover = ConnectTakeover(
      selfId: deviceId,
      sendSelect: (id) => client.send(SelectFrame(id)),
      pauseLocal: () => unawaited(_player.pause()),
    );
    _transfer = ConnectTransfer(
      session: session,
      selfId: deviceId,
      localState: _stateSource,
      pauseLocal: _player.pause,
      playLocal: (command) => _executor!.execute(
        CmdFrame(id: 'transfer-${DateTime.now().microsecondsSinceEpoch}', cmd: command),
      ),
      select: (id) => client.send(SelectFrame(id)),
      nameOf: (id) {
        for (final d in session.devices) {
          if (d.id == id) return d.name;
        }
        return 'the other device';
      },
    );
    _direction = ConnectLinkDirection(
      session: session,
      transfer: _transfer!,
      selfId: deviceId,
      phonePlaying: isPlaying,
      isOnline: () => client.isOnline,
      select: (id) => client.send(SelectFrame(id)),
    );
    ConnectPlayRouter.instance = ConnectPlayRouter(
      session: session,
      deviceId: deviceId,
      ui: ConnectUiHost.instance,
    );
    session.addListener(() {
      if (session.isRemote != _wasRemote) {
        _wasRemote = session.isRemote;
        // Phone as a remote: its volume keys now belong to the playing device.
        unawaited(_serviceBridge?.setRemoteVolumeKeys(_wasRemote));
        onRemoteModeChanged?.call();
      }
      _service?.refresh();
    });
    _remoteEvents = session.events.listen((event) {
      if (event is RemoteWentOffline) {
        ConnectUiHost.instance.say('${event.deviceName} went offline');
      }
    });
    _frames = client.frames.listen(_onFrame);
    final state = WidgetsBinding.instance.lifecycleState;
    _presence
      ..foreground = state == null || state == AppLifecycleState.resumed
      ..musicMode = isMusicMode()
      ..playing = isPlaying()
      ..enabled = _enabled;
    // The service learns what is already running before it is told what to do:
    // after a reboot native has started it and this process has no screen.
    await _service?.init(
      wanted: _serviceWanted,
      foreground: state == null || state == AppLifecycleState.resumed,
    );
    notifyListeners();
    // The notification may have been tapped while the app was not running.
    if (await _serviceBridge?.takeOpenRequest() ?? false) {
      unawaited(ConnectUiHost.instance.openConnectPage());
    }
  }

  /// The foreground service runs exactly when the socket is meant to be held:
  /// Hype Connect on, in music-player mode.
  bool get _serviceWanted => _enabled && isMusicMode();

  /// The app's mode or playback changed.
  void inputsChanged() {
    if (!_started) return;
    _presence
      ..musicMode = isMusicMode()
      ..playing = isPlaying();
    _takeover?.onLocalPlaying(isPlaying());
    _viz?.refresh();
    _service
      ?..setWanted(_serviceWanted)
      ..refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _presence.foreground = foreground;
    // Resuming is also the moment to start a service that could not be started
    // from the background, and the battery shortcut is re-checked by the page.
    _service?.setForeground(foreground);
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    if (value) _notice = null;
    await prefs.setBool(enabledKey, value);
    if (_started) {
      _presence.enabled = value;
      if (value) await _service?.userEnabled();
      _service?.setWanted(_serviceWanted);
    }
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Linking
  // -------------------------------------------------------------------------

  /// Who is asking to be linked by [code]. Throws [ConnectHttpException].
  Future<LinkPreview> previewLink(String code) => api.previewLink(code);

  /// Approves [code], then switches Hype Connect on and refreshes the list —
  /// approving is the user asking for this phone to be reachable.
  Future<void> approveLink(String code) async {
    await api.approveLink(code);
    await setEnabled(true);
    unawaited(refreshDevices());
  }

  Future<void> denyLink(String code) => api.denyLink(code);

  // -------------------------------------------------------------------------
  // Devices
  // -------------------------------------------------------------------------

  /// Reads the linked devices over REST — the list is also pushed over the
  /// socket while connected, but the page has to show it when it is not.
  Future<void> refreshDevices() async {
    try {
      final response = await api.devices();
      _devices = response.devices;
      _activeDeviceId = response.activeDeviceId;
      notifyListeners();
    } catch (e) {
      debugPrint('Hype Connect: could not list devices: $e');
      rethrow;
    }
  }

  Future<void> revokeDevice(String id) async {
    await api.revokeDevice(id);
    _devices = [
      for (final device in _devices)
        if (device.id != id) device,
    ];
    notifyListeners();
  }

  // -------------------------------------------------------------------------

  void _onWanted(bool wanted) {
    if (wanted) {
      client.start();
    } else {
      unawaited(client.stop());
    }
    notifyListeners();
  }

  void _onClientState() {
    final state = client.state.value;
    if (state.status == ConnectStatus.online) {
      _takeover?.onConnected();
      _publisher?.start();
      unawaited(deviceVolume?.start());
      _viz?.setOnline(true);
    } else {
      _publisher?.stop();
      deviceVolume?.stop();
      // Nothing is left to control, so the keys go back to this phone.
      unawaited(_serviceBridge?.setRemoteVolumeKeys(false));
      _viz?.setOnline(false);
      _takeover?.onDisconnected();
      _session?.onDisconnected();
    }
    if (state.status == ConnectStatus.unlinked) {
      _notice = state.lastError;
      unawaited(setEnabled(false));
    }
    _service?.refresh();
    notifyListeners();
  }

  void _onFrame(ConnectFrame frame) {
    _session?.onFrame(frame);
    switch (frame) {
      case WelcomeFrame():
        _devices = frame.devices;
        _activeDeviceId = frame.activeDeviceId;
        _takeover?.onList(
          frame.devices,
          frame.activeDeviceId,
          isWelcome: true,
          activeIsPlaying: frame.states[frame.activeDeviceId]?.state.playing,
        );
        _publisher?.sendNow();
        _forgetOfflineController();
        _service?.refresh();
        notifyListeners();
      case DevicesFrame():
        _devices = frame.devices;
        _activeDeviceId = frame.activeDeviceId;
        _takeover?.onList(frame.devices, frame.activeDeviceId);
        _forgetOfflineController();
        _service?.refresh();
        notifyListeners();
      case ErrorFrame():
        _takeover?.onError(frame.code);
      case CmdFrame():
        final from = frame.from;
        if (from != null && from != _thisDeviceId && from != _controllerId) {
          _controllerId = from;
          _service?.refresh();
        }
        final executor = _executor;
        if (executor == null) return;
        unawaited(executor.execute(frame).then(client.send));
      case RpcFrame():
        final rpc = _rpc;
        if (rpc == null) return;
        unawaited(rpc.handle(frame).then(client.send));
      case VizSubFrame():
        _viz?.setSubscribed(frame.on);
      default:
        break;
    }
  }

  // -------------------------------------------------------------------------
  // The background service's notification
  // -------------------------------------------------------------------------

  void _forgetOfflineController() {
    final id = _controllerId;
    if (id == null) return;
    final online = _devices.any((d) => d.id == id && d.online);
    if (!online) _controllerId = null;
  }

  ConnectNotificationContent _notificationContent() {
    final remote = _session?.nowPlaying();
    final song = currentSong?.call();
    final retry = client.state.value;
    return buildConnectNotification(
      ConnectNotificationInput(
        status: retry.status,
        retryIn: retry.retryIn,
        thisDeviceId: _thisDeviceId,
        devices: _devices,
        remoteDevice: remote?.device,
        remoteTrack: remote?.track,
        remotePlaying: remote?.playing ?? false,
        hasLocalTrack: song != null,
        localTitle: song?.title,
        localArtist: song?.artist,
        localPlaying: isPlaying(),
        controllerId: _controllerId,
      ),
    );
  }

  /// A button on the notification: the transport buttons drive the remote
  /// player exactly as the in-app remote mini-player does, and "Turn off" is
  /// the switch on the Hype Connect page.
  void _onServiceAction(String id) {
    final session = _session;
    switch (id) {
      case 'previous':
        unawaited(session?.prev());
      case 'next':
        unawaited(session?.next());
      case 'toggle':
        final playing = session?.nowPlaying()?.playing ?? false;
        unawaited(playing ? session?.pause() : session?.resume());
      case 'off':
        unawaited(setEnabled(false));
    }
  }

  /// A hardware volume key while this phone is a remote: one step on the
  /// playing device, and a HUD saying which device and where it landed.
  void _onVolumeKey(String direction) {
    final session = _session;
    if (session == null) return;
    final target = session.remoteTarget;
    final value = session.nudgeVolume(direction == 'up' ? 1 : -1);
    if (value == null || target == null) return;
    volumeHud.value = ConnectVolumeHudEvent(
      deviceName: target.name,
      volume: value,
      shownAt: DateTime.now(),
    );
  }

  Future<void> _openRequested() async {
    if (await _serviceBridge?.takeOpenRequest() ?? false) {
      await ConnectUiHost.instance.openConnectPage();
    }
  }

  // -------------------------------------------------------------------------

  static Future<String> _appVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return 'unknown';
    }
  }

  static Future<DeviceHello> _deviceHello(ConnectAccount account) async {
    final plugin = DeviceInfoPlugin();
    final String name;
    if (Platform.isIOS) {
      final info = await plugin.iosInfo;
      name = deviceDisplayName(
        ios: true,
        name: info.name,
        modelName: info.modelName,
      );
    } else {
      final info = await plugin.androidInfo;
      name = deviceDisplayName(
        ios: false,
        name: info.name,
        manufacturer: info.manufacturer,
        model: info.model,
      );
    }
    return DeviceHello(
      id: await account.installId(),
      kind: DeviceKind.mobile,
      name: name,
      platform: Platform.isIOS ? 'ios' : 'android',
      appVersion: await _appVersion(),
      caps: deviceCaps,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_frames?.cancel());
    unawaited(_remoteEvents?.cancel());
    _takeover?.dispose();
    _session?.dispose();
    if (ConnectPlayRouter.instance?.session == _session) {
      ConnectPlayRouter.instance = null;
    }
    _presence.dispose();
    _service?.dispose();
    _publisher?.stop();
    deviceVolume?.stop();
    unawaited(_serviceBridge?.setRemoteVolumeKeys(false));
    volumeHud.dispose();
    _viz?.dispose();
    client.state.removeListener(_onClientState);
    super.dispose();
  }
}
