/// The Hype Connect socket: one long-lived WebSocket to the hub, kept open for
/// as long as it is wanted and reopened when it drops.
///
/// # What a close means
///
/// The hub says why it closed a socket, and the answer decides what to do next
/// (contract §3.10):
///
/// | code | meaning                                | here                                  |
/// |------|----------------------------------------|---------------------------------------|
/// | 4001 | token invalid or expired, user gone    | refresh, then reconnect with backoff  |
/// | 4005 | account merged into another            | refresh, then reconnect with backoff  |
/// | 4003 | device revoked / owned by another user | drop the tokens, sign in again, stop, |
/// |      |                                        | and say "This phone was unlinked"     |
/// | 4004 | replaced by a newer socket             | stop — never fight the newer one      |
/// | else | network loss, malformed frame, 4002 …  | reconnect with backoff                |
///
/// 4003 stops rather than reconnecting because a revoked device stays revoked:
/// signing in again resolves the install to the same user, the hub refuses it
/// the same way, and a loop of refusals is all a retry would buy.
///
/// # Backoff
///
/// 1 s, 2 s, 4 s … capped at 30 s, each ±20 % so a hub restart is not answered
/// by every phone at the same instant. A `welcome` resets it: the schedule
/// measures how long the hub has been unreachable, not how many times it has
/// ever dropped.
///
/// # Only the current socket may change anything
///
/// A socket that has been replaced can still deliver its close afterwards — the
/// hub closes an old socket with 4004 *because* a new one said hello. Acting on
/// that close would stop the client that just replaced it. Every handler checks
/// that the socket it belongs to is still the current one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import 'connect_clock.dart';
import 'connect_protocol.dart';

/// One WebSocket, as the client needs it. Production wraps `dart:io`; tests
/// hand in a fake.
abstract interface class ConnectSocket {
  /// Completes once the socket is open; errors if it never opens.
  Future<void> get ready;

  /// Text frames. Done when the socket closes.
  Stream<String> get messages;

  int? get closeCode;
  String? get closeReason;

  void send(String text);

  Future<void> close([int? code, String? reason]);
}

typedef ConnectSocketFactory = ConnectSocket Function(Uri uri);

/// `dart:io`'s WebSocket behind [ConnectSocket].
///
/// The hub pings every 20 s and `dart:io` answers by itself. The client pings
/// as well: a phone that walks off a Wi-Fi network can keep a dead TCP
/// connection "open" for minutes, and an unanswered ping is how it finds out.
class IoConnectSocket implements ConnectSocket {
  IoConnectSocket(Uri uri)
    : _channel = IOWebSocketChannel.connect(
        uri,
        pingInterval: const Duration(seconds: 25),
        connectTimeout: const Duration(seconds: 15),
      );

  final IOWebSocketChannel _channel;

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<String> get messages =>
      _channel.stream.where((m) => m is String).cast<String>();

  @override
  int? get closeCode => _channel.closeCode;

  @override
  String? get closeReason => _channel.closeReason;

  @override
  void send(String text) => _channel.sink.add(text);

  @override
  Future<void> close([int? code, String? reason]) =>
      _channel.sink.close(code, reason);
}

enum ConnectStatus {
  /// Not wanted: disabled, or the app is idle in the background.
  off,

  /// Opening a socket or waiting for `welcome`.
  connecting,

  /// `welcome` received; commands may arrive.
  online,

  /// The last attempt failed; the next one is scheduled.
  retrying,

  /// Closed 4003: this phone was revoked or belongs to another account.
  unlinked,

  /// Closed 4004: another socket for this device took over.
  replaced,
}

@immutable
class ConnectClientState {
  const ConnectClientState(
    this.status, {
    this.welcome,
    this.retryIn,
    this.lastError,
  });

  final ConnectStatus status;

  /// The `welcome` of the current session, while [status] is online.
  final WelcomeFrame? welcome;

  /// How long until the next attempt, while [status] is retrying.
  final Duration? retryIn;

  /// What went wrong last, for the status line.
  final String? lastError;
}

/// The close codes of contract §3.10.
abstract final class ConnectCloseCodes {
  static const malformed = 4000;
  static const unauthorized = 4001;
  static const noHello = 4002;
  static const revoked = 4003;
  static const replaced = 4004;
  static const merged = 4005;
}

/// The reconnect delay before attempt [attempt] (0-based): 1 s doubling to a
/// 30 s cap, scaled by a jitter factor in [0.8, 1.2) drawn from [random].
Duration connectBackoff(int attempt, double random) {
  const base = 1000;
  const cap = 30000;
  final exp = attempt >= 15 ? cap : min(cap, base * (1 << attempt));
  final factor = 0.8 + 0.4 * random;
  return Duration(milliseconds: (exp * factor).round());
}

class ConnectClient {
  ConnectClient({
    required this._wsUri,
    required this._connect,
    required this._accessToken,
    required this._refreshToken,
    required this._resetSession,
    required this._device,
    Random? random,
    this.welcomeTimeout = const Duration(seconds: 15),
    this.clockInterval = const Duration(seconds: 10),
    HubClock? hubClock,
  }) : _random = random ?? Random(),
       hubClock = hubClock ?? HubClock();

  final Uri _wsUri;
  final ConnectSocketFactory _connect;
  final Future<String> Function() _accessToken;
  final Future<void> Function() _refreshToken;
  final Future<void> Function() _resetSession;
  final Future<DeviceHello> Function() _device;
  final Random _random;

  /// How long to wait for `welcome` after `hello` before giving up on a socket.
  final Duration welcomeTimeout;

  /// How often the hub clock is re-measured while online (contract §3.7: on
  /// every `welcome` and then every ~10 s).
  final Duration clockInterval;

  /// This phone's offset to the hub's clock, kept fresh by ping/pong.
  final HubClock hubClock;

  final ValueNotifier<ConnectClientState> state = ValueNotifier(
    const ConnectClientState(ConnectStatus.off),
  );

  final StreamController<ConnectFrame> _frames =
      StreamController<ConnectFrame>.broadcast(sync: true);

  /// Every frame after `welcome`, and `welcome` itself.
  Stream<ConnectFrame> get frames => _frames.stream;

  bool _wanted = false;
  int _attempt = 0;

  /// Bumped for every socket, so late events from a replaced one are ignored.
  int _generation = 0;
  ConnectSocket? _socket;
  StreamSubscription<String>? _subscription;
  Timer? _retryTimer;
  Timer? _welcomeTimer;
  Timer? _clockTimer;

  /// Pings in flight: id -> local epoch ms when sent.
  final Map<String, int> _pings = {};
  int _pingCount = 0;

  bool get isOnline => state.value.status == ConnectStatus.online;

  /// How many reconnects have happened since the last `welcome`. For tests.
  @visibleForTesting
  int get attempt => _attempt;

  /// Starts connecting, if not already. Idempotent.
  void start() {
    if (_wanted) return;
    _wanted = true;
    _attempt = 0;
    unawaited(_open());
  }

  /// Closes the socket and stops reconnecting.
  Future<void> stop() async {
    _wanted = false;
    _retryTimer?.cancel();
    _welcomeTimer?.cancel();
    final socket = _socket;
    _detach();
    _set(const ConnectClientState(ConnectStatus.off));
    if (socket != null) {
      try {
        await socket.close(1000, 'bye');
      } catch (_) {}
    }
  }

  /// Sends [frame] if a session is up. Returns whether it was sent.
  bool send(ConnectFrame frame) {
    final socket = _socket;
    if (socket == null || !isOnline) return false;
    try {
      socket.send(frame.encode());
      return true;
    } catch (e) {
      debugPrint('Hype Connect: send failed: $e');
      return false;
    }
  }

  Future<void> dispose() async {
    await stop();
    await _frames.close();
    state.dispose();
  }

  // -------------------------------------------------------------------------

  Future<void> _open() async {
    if (!_wanted) return;
    final generation = ++_generation;
    _set(
      ConnectClientState(
        ConnectStatus.connecting,
        lastError: state.value.lastError,
      ),
    );

    final String token;
    final DeviceHello device;
    try {
      // Before the socket, not after: the hub drops a socket that has not said
      // hello within 5 s, and minting a first account is a network round trip.
      token = await _accessToken();
      device = await _device();
    } catch (e) {
      if (generation != _generation) return;
      _retry('Could not sign in: ${_describe(e)}');
      return;
    }
    if (!_wanted || generation != _generation) return;

    final socket = _connect(_wsUri);
    _socket = socket;
    _subscription = socket.messages.listen(
      (text) => _onMessage(generation, text),
      onError: (Object e) => _onDone(generation, error: e),
      onDone: () => _onDone(generation),
      cancelOnError: true,
    );
    try {
      await socket.ready;
    } catch (e) {
      // The stream reports the same failure; whichever arrives first wins and
      // the generation check makes the other a no-op.
      _onDone(generation, error: e);
      return;
    }
    if (generation != _generation) return;
    try {
      socket.send(HelloFrame(token: token, device: device).encode());
    } catch (e) {
      _onDone(generation, error: e);
      return;
    }
    _welcomeTimer?.cancel();
    _welcomeTimer = Timer(welcomeTimeout, () {
      if (generation != _generation || isOnline) return;
      _drop(generation, 'The hub did not answer hello');
    });
  }

  void _onMessage(int generation, String text) {
    if (generation != _generation) return;
    final ConnectFrame frame;
    try {
      frame = ConnectFrame.decode(text);
    } catch (e) {
      _answerMalformed(text, e);
      return;
    }
    if (frame is WelcomeFrame) {
      _welcomeTimer?.cancel();
      _attempt = 0;
      hubClock.seedFromWelcome(
        serverTimeMs: frame.serverTime,
        receivedMs: clock.now().millisecondsSinceEpoch,
      );
      _set(ConnectClientState(ConnectStatus.online, welcome: frame));
      _startClockSync();
    } else if (frame is PongFrame) {
      _onPong(frame);
    } else if (!isOnline) {
      // Nothing but welcome means anything before welcome.
      if (frame is ErrorFrame) {
        debugPrint('Hype Connect: hub error before welcome: ${frame.code}');
      }
      return;
    } else if (frame is ErrorFrame) {
      debugPrint('Hype Connect: hub error ${frame.code}: ${frame.message}');
    }
    _frames.add(frame);
  }

  /// A `cmd` or `rpc` that would not parse still has an id, and its sender is
  /// waiting on it. Answering `failed` costs nothing; staying silent costs the
  /// controller a 10–15 s timeout.
  void _answerMalformed(String text, Object error) {
    debugPrint('Hype Connect: unreadable frame ($error)');
    Map<String, Object?>? raw;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) raw = decoded.cast<String, Object?>();
    } catch (_) {}
    final id = raw?['id'];
    if (!isOnline || id is! String) return;
    switch (raw?['t']) {
      case 'cmd':
        send(AckFrame.failed(id, AckError.failed));
      case 'rpc':
        send(RpcResultFrame.error(id: id, error: RpcError.failed));
    }
  }

  void _onDone(int generation, {Object? error}) {
    if (generation != _generation) return;
    final socket = _socket;
    final code = socket?.closeCode;
    final reason = socket?.closeReason;
    _detach();
    _welcomeTimer?.cancel();
    if (!_wanted) {
      _set(const ConnectClientState(ConnectStatus.off));
      return;
    }

    switch (code) {
      case ConnectCloseCodes.replaced:
        _wanted = false;
        _set(
          const ConnectClientState(
            ConnectStatus.replaced,
            lastError: 'Another connection for this phone took over',
          ),
        );
        return;
      case ConnectCloseCodes.revoked:
        _wanted = false;
        _set(
          const ConnectClientState(
            ConnectStatus.unlinked,
            lastError: 'This phone was unlinked',
          ),
        );
        // The tokens say this phone is something the hub no longer agrees
        // with. A fresh anonymous session is what the next link starts from.
        unawaited(
          _resetSession().catchError((Object e) {
            debugPrint('Hype Connect: could not reset the session: $e');
          }),
        );
        return;
      case ConnectCloseCodes.unauthorized:
      case ConnectCloseCodes.merged:
        // The generation the socket left behind: anything that happens while
        // the refresh is in flight — a stop, a fresh start — moves it on.
        unawaited(_refreshThenRetry(_generation, code!));
        return;
    }
    _retry(_closeMessage(code, reason, error));
  }

  Future<void> _refreshThenRetry(int generation, int code) async {
    try {
      await _refreshToken();
    } catch (e) {
      // The next attempt asks for a token again and will find out properly.
      debugPrint('Hype Connect: refresh after $code failed: $e');
    }
    if (generation != _generation || !_wanted) return;
    _retry(
      code == ConnectCloseCodes.merged
          ? 'Account merged — reconnecting'
          : 'Session expired — reconnecting',
    );
  }

  void _retry(String why) {
    if (!_wanted) return;
    final delay = connectBackoff(_attempt, _random.nextDouble());
    _attempt++;
    _set(
      ConnectClientState(
        ConnectStatus.retrying,
        retryIn: delay,
        lastError: why,
      ),
    );
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () => unawaited(_open()));
  }

  /// Closes the current socket from this side and lets the close handler
  /// schedule the retry.
  void _drop(int generation, String why) {
    if (generation != _generation) return;
    final socket = _socket;
    _detach();
    unawaited(socket?.close(1000, why).catchError((Object _) {}));
    _retry(why);
  }

  /// Measures the hub clock now and again every [clockInterval] while online.
  void _startClockSync() {
    _clockTimer?.cancel();
    _pings.clear();
    _ping();
    _clockTimer = Timer.periodic(clockInterval, (_) => _ping());
  }

  void _ping() {
    final now = clock.now().millisecondsSinceEpoch;
    // A pong that never came back is not coming; do not collect them.
    _pings.removeWhere((_, sent) => now - sent > 30000);
    final id = 'c${++_pingCount}';
    if (send(PingFrame(id))) _pings[id] = now;
  }

  void _onPong(PongFrame pong) {
    final sent = _pings.remove(pong.id);
    if (sent == null) return;
    hubClock.addSample(
      sentMs: sent,
      receivedMs: clock.now().millisecondsSinceEpoch,
      serverTimeMs: pong.serverTime,
    );
  }

  void _detach() {
    _clockTimer?.cancel();
    _clockTimer = null;
    _pings.clear();
    _generation++;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _socket = null;
  }

  void _set(ConnectClientState next) => state.value = next;

  static String _closeMessage(int? code, String? reason, Object? error) {
    if (error != null) return _describe(error);
    if (code == null) return 'Connection lost';
    if (reason != null && reason.isNotEmpty) return '$reason ($code)';
    return 'Disconnected ($code)';
  }

  static String _describe(Object e) => switch (e) {
    SocketException(:final message) => message,
    TimeoutException() => 'Timed out',
    _ => e.toString(),
  };
}
