/// This phone's HypeMuzik account: an install id, and the tokens that prove it.
///
/// # Why a phone needs an account at all
///
/// Hype Connect scopes everything to a backend user — two devices see each
/// other only when they belong to the same one — and a phone had no account
/// until now. It gets one the way the desktop already does: silently. A UUID v4
/// install id is minted once, `POST /auth/anonymous` turns it into a user, and
/// linking a browser or a desktop later joins or merges accounts on the server.
/// Nobody types an email to use their own phone as a speaker.
///
/// The install id is also this phone's Hype Connect device id, which is why it
/// must never change for the life of the install.
///
/// # Refreshing exactly once
///
/// Refresh tokens are single-use: the server rotates them on every refresh and
/// revokes the old one. Two callers refreshing at once — the socket
/// reconnecting while the Hype Connect page loads the device list — would spend
/// the same token twice, and the loser would be told it is invalid. So a
/// refresh is single-flight: whoever asks while one is running gets that one's
/// answer.
///
/// # When the refresh token itself is refused
///
/// It expired, or it was revoked, or the account it belonged to was merged
/// away. All three end the same way: start again anonymously with the same
/// install id. The server resolves an install to whichever user owns it now, so
/// after a merge this lands on the surviving account rather than a fresh one.
/// A refresh that fails for any other reason — no network — keeps the tokens
/// and reports the failure: there is nothing wrong with them, and bootstrapping
/// would fail the same way.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

/// Where the install id and tokens are kept.
abstract interface class ConnectSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// The platform keystore — the same storage the cloud drives' tokens use.
class SecureConnectSecretStore implements ConnectSecretStore {
  const SecureConnectSecretStore([
    this._storage = const FlutterSecureStorage(),
  ]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// What the backend is told about this install when an account is made.
class ConnectInstallInfo {
  const ConnectInstallInfo({required this.os, required this.appVersion});

  /// `android` or `ios`.
  final String os;
  final String appVersion;
}

/// A rejected request, with the backend's status and its machine-readable
/// `code` when the body carried one (`BOTH_HAVE_ACCOUNTS`).
class ConnectHttpException implements Exception {
  const ConnectHttpException(this.statusCode, this.message, {this.code});

  final int statusCode;
  final String message;
  final String? code;

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() =>
      'ConnectHttpException($statusCode${code == null ? '' : ' $code'}): $message';
}

class ConnectTokens {
  const ConnectTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    this.userId,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final String? userId;

  /// Whether the access token still has [margin] of life left.
  bool isFresh({Duration margin = const Duration(seconds: 60)}) =>
      clock.now().add(margin).isBefore(expiresAt);

  Map<String, Object?> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
    'userId': userId,
  };

  static ConnectTokens? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, Object?>;
      return ConnectTokens(
        accessToken: json['accessToken']! as String,
        refreshToken: json['refreshToken']! as String,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          (json['expiresAt']! as num).toInt(),
        ),
        userId: json['userId'] as String?,
      );
    } catch (_) {
      // Unreadable tokens are no tokens: the next request bootstraps again.
      return null;
    }
  }

  /// Reads `{accessToken, refreshToken, expiresIn, user?}` — the shape both
  /// `/auth/anonymous` and `/auth/refresh` answer with.
  static ConnectTokens fromAuthResponse(Object? body) {
    if (body is! Map) throw const FormatException('auth: expected an object');
    final access = body['accessToken'];
    final refresh = body['refreshToken'];
    final expiresIn = body['expiresIn'];
    if (access is! String || refresh is! String || expiresIn is! num) {
      throw const FormatException('auth: missing tokens');
    }
    final user = body['user'];
    return ConnectTokens(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: clock.now().add(Duration(seconds: expiresIn.toInt())),
      userId: user is Map && user['id'] is String ? user['id'] as String : null,
    );
  }
}

class ConnectAccount {
  ConnectAccount({
    required this._client,
    required this._apiBase,
    required this._store,
    required this._installInfo,
    String Function()? newInstallId,
    this.requestTimeout = const Duration(seconds: 15),
  }) : _newInstallId = newInstallId ?? (() => const Uuid().v4());

  static const installIdKey = 'hype_connect.install_id';
  static const tokensKey = 'hype_connect.tokens';

  final http.Client _client;
  final Uri _apiBase;
  final ConnectSecretStore _store;
  final Future<ConnectInstallInfo> Function() _installInfo;
  final String Function() _newInstallId;
  final Duration requestTimeout;

  String? _installId;
  Future<String>? _installIdLoad;
  ConnectTokens? _tokens;
  bool _tokensLoaded = false;
  Future<ConnectTokens>? _inFlight;

  /// The backend user these tokens belong to, when known.
  String? get userId => _tokens?.userId;

  /// This install's id — minted on first use and never changed after.
  Future<String> installId() {
    final known = _installId;
    if (known != null) return Future.value(known);
    // Single-flight, so two first callers cannot mint two ids and leave the
    // install with whichever write landed last.
    return _installIdLoad ??= () async {
      var id = await _store.read(installIdKey);
      if (id == null || id.isEmpty) {
        id = _newInstallId();
        await _store.write(installIdKey, id);
      }
      _installId = id;
      return id;
    }();
  }

  Future<ConnectTokens?> _loadTokens() async {
    if (!_tokensLoaded) {
      _tokens = ConnectTokens.tryParse(await _store.read(tokensKey));
      _tokensLoaded = true;
    }
    return _tokens;
  }

  /// An access token with at least a minute of life left — bootstrapping an
  /// account if there is none, refreshing if the one held is about to expire.
  Future<String> accessToken() async {
    final tokens = await _loadTokens();
    if (tokens != null && tokens.isFresh()) return tokens.accessToken;
    return (await _renew()).accessToken;
  }

  /// Replaces the access token whatever its expiry says — for when the server
  /// has just refused it (a 401, a socket closed 4001 or 4005).
  Future<void> refresh() async {
    await _renew(force: true);
  }

  /// Forgets the tokens (not the install id) and signs in again anonymously.
  ///
  /// For a socket closed 4003: this device was revoked or belongs to another
  /// user, so whatever the tokens say about who this phone is, the server
  /// disagrees.
  Future<void> resetSession() async {
    await _drop();
    await _renew();
  }

  Future<void> _drop() async {
    _tokens = null;
    _tokensLoaded = true;
    await _store.delete(tokensKey);
  }

  /// Bootstraps or refreshes, once, however many callers ask at the same time.
  Future<ConnectTokens> _renew({bool force = false}) {
    final running = _inFlight;
    if (running != null) return running;
    final next = _doRenew(force: force).whenComplete(() => _inFlight = null);
    _inFlight = next;
    return next;
  }

  Future<ConnectTokens> _doRenew({required bool force}) async {
    final held = await _loadTokens();
    if (held != null && !force && held.isFresh()) return held;
    if (held != null) {
      try {
        return await _keep(
          await _post('/auth/refresh', {'refreshToken': held.refreshToken}),
        );
      } on ConnectHttpException catch (e) {
        // 400 as well as 401: a refresh token the validator rejects is just as
        // unusable as one the server has revoked.
        if (e.statusCode != 401 && e.statusCode != 400) rethrow;
        debugPrint(
          'Hype Connect: refresh refused (${e.statusCode}); '
          'signing in again anonymously',
        );
        await _drop();
      }
    }
    return _keep(await _bootstrap());
  }

  Future<Object?> _bootstrap() async {
    final info = await _installInfo();
    // Exactly these keys: the backend rejects unknown fields outright.
    return _post('/auth/anonymous', {
      'installId': await installId(),
      'os': info.os,
      'appVersion': info.appVersion,
    });
  }

  Future<ConnectTokens> _keep(Object? body) async {
    final tokens = ConnectTokens.fromAuthResponse(body);
    _tokens = tokens;
    _tokensLoaded = true;
    await _store.write(tokensKey, jsonEncode(tokens.toJson()));
    return tokens;
  }

  Future<Object?> _post(String path, Map<String, Object?> body) async {
    final response = await _client
        .post(
          resolve(path),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(requestTimeout);
    return decodeResponse(response);
  }

  /// [path] under the API base, which already ends in `/api`.
  Uri resolve(String path) {
    final base = _apiBase.toString().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base$path');
  }

  /// The JSON body of a 2xx response, or a [ConnectHttpException].
  static Object? decodeResponse(http.Response response) {
    Object? body;
    try {
      body = response.body.isEmpty ? null : jsonDecode(response.body);
    } on FormatException {
      body = null;
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return body;
    String? code;
    var message = response.reasonPhrase ?? 'HTTP ${response.statusCode}';
    if (body is Map) {
      if (body['code'] is String) code = body['code'] as String;
      final m = body['message'];
      if (m is String) {
        message = m;
      } else if (m is List && m.isNotEmpty) {
        message = m.join(', ');
      }
      // Nest nests an exception's object under `message` when it was thrown
      // with one, so the code can arrive one level down.
      if (code == null && m is Map && m['code'] is String) {
        code = m['code'] as String;
      }
    }
    throw ConnectHttpException(response.statusCode, message, code: code);
  }
}

/// `android` or `ios`, as the backend and the protocol name them.
String connectPlatformName() => Platform.isIOS ? 'ios' : 'android';
