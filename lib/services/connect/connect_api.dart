/// The Hype Connect REST routes this phone calls: approving or denying a link
/// it scanned, and listing or revoking the devices linked to its account.
///
/// Every call carries the account's Bearer token. A 401 is answered once by
/// refreshing and retrying — the token may have expired between being checked
/// and being read, or the account may have just been merged — and a second 401
/// is reported rather than retried for ever.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'connect_account.dart';
import 'connect_protocol.dart';

class ConnectApi {
  ConnectApi({
    required this._client,
    required this._account,
    this.requestTimeout = const Duration(seconds: 15),
  });

  final http.Client _client;
  final ConnectAccount _account;
  final Duration requestTimeout;

  /// Who is asking to be linked. Throws a 404 [ConnectHttpException] when the
  /// code is unknown, expired or already used.
  Future<LinkPreview> previewLink(String code) async =>
      LinkPreview.fromJson(await _send('GET', '/connect/links/$code'));

  /// Says yes. A 409 carries `BOTH_HAVE_ACCOUNTS` when the requester and this
  /// phone both belong to verified accounts that cannot be merged.
  Future<void> approveLink(String code) async {
    await _send('POST', '/connect/links/$code/approve');
  }

  Future<void> denyLink(String code) async {
    await _send('POST', '/connect/links/$code/deny');
  }

  Future<DevicesResponse> devices() async =>
      DevicesResponse.fromJson(await _send('GET', '/connect/devices'));

  Future<void> revokeDevice(String id) async {
    await _send('DELETE', '/connect/devices/${Uri.encodeComponent(id)}');
  }

  Future<Object?> _send(String method, String path) async {
    try {
      return await _once(method, path, await _account.accessToken());
    } on ConnectHttpException catch (e) {
      if (!e.isUnauthorized) rethrow;
      await _account.refresh();
      return _once(method, path, await _account.accessToken());
    }
  }

  Future<Object?> _once(String method, String path, String token) async {
    final request = http.Request(method, _account.resolve(path))
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json';
    if (method == 'POST') {
      // An empty JSON object rather than no body: some proxies refuse a POST
      // without a length, and the routes take no fields.
      request
        ..headers['content-type'] = 'application/json'
        ..body = jsonEncode(const <String, Object?>{});
    }
    final streamed = await _client.send(request).timeout(requestTimeout);
    final response = await http.Response.fromStream(streamed)
        .timeout(requestTimeout);
    return ConnectAccount.decodeResponse(response);
  }
}
