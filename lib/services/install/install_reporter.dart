/// Anonymous install reporting: "how many people use Hype Muzik on Android and
/// iOS". An install is one app install, identified by the same UUID that is
/// this phone's Hype Connect device id (`ConnectAccount.installId`), so there
/// is exactly one id per install.
///
/// Registers once (`POST /installs`), then pings (`POST /installs/:id/ping`) on
/// launch and resume, at most every [pingEvery]. Best effort: every failure is
/// silent and retried at the next trigger, and nothing here is awaited by
/// startup.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../config/app_config.dart';
import '../connect/hype_connect.dart';

/// This install's id: the Hype Connect device id. Null before Connect is
/// attached; a second id is never minted.
Future<String?> hypeInstallId() async =>
    HypeConnect.instanceOrNull?.account.installId();

/// What this install tells the backend about itself.
class InstallDetails {
  const InstallDetails({
    required this.platform,
    this.osVersion,
    this.deviceModel,
    this.appVersion,
  });

  /// `android` or `ios`.
  final String platform;
  final String? osVersion;
  final String? deviceModel;
  final String? appVersion;

  Map<String, dynamic> toJson() => {
        'platform': platform,
        'os': platform,
        if (osVersion != null) 'osVersion': osVersion,
        if (deviceModel != null) 'deviceModel': deviceModel,
        if (appVersion != null) 'appVersion': appVersion,
      };
}

class InstallReporter {
  InstallReporter({
    SharedPreferences? prefs,
    Future<String?> Function()? installId,
    Future<InstallDetails> Function()? details,
    Future<int> Function(Uri url, Map<String, dynamic> body)? post,
    DateTime Function()? now,
    String? apiBase,
    this.pingEvery = const Duration(hours: 6),
  })  : _prefsOverride = prefs,
        _installId = installId ?? hypeInstallId,
        _details = details ?? _deviceDetails,
        _post = post ?? _httpPost,
        _now = now ?? DateTime.now,
        _api = apiBase ?? AppConfig.hypeMuzikApiBase;

  static final InstallReporter instance = InstallReporter();

  static const _kRegistered = 'install_report.registered_id';
  static const _kLastAt = 'install_report.last_at';

  final Duration pingEvery;
  final SharedPreferences? _prefsOverride;
  final Future<String?> Function() _installId;
  final Future<InstallDetails> Function() _details;
  final Future<int> Function(Uri, Map<String, dynamic>) _post;
  final DateTime Function() _now;
  final String _api;
  bool _busy = false;

  /// Registers on first call, otherwise pings if the last report is older than
  /// [pingEvery]. Never throws.
  Future<void> report() async {
    if (_busy) return;
    _busy = true;
    try {
      final id = await _installId();
      if (id == null || id.isEmpty) return;
      final prefs = _prefsOverride ?? await SharedPreferences.getInstance();
      final registered = prefs.getString(_kRegistered) == id;
      final lastMs = prefs.getInt(_kLastAt);
      if (registered && lastMs != null) {
        final age =
            _now().difference(DateTime.fromMillisecondsSinceEpoch(lastMs));
        if (age < pingEvery) return;
      }
      final body = (await _details()).toJson();
      final int status;
      if (registered) {
        status = await _post(Uri.parse('$_api/installs/$id/ping'), body);
        if (status == 404) {
          await prefs.remove(_kRegistered); // server forgot us: register again
          return;
        }
      } else {
        status = await _post(Uri.parse('$_api/installs'), {
          'installId': id,
          ...body,
        });
      }
      if (status >= 200 && status < 300) {
        await prefs.setString(_kRegistered, id);
        await prefs.setInt(_kLastAt, _now().millisecondsSinceEpoch);
      }
    } catch (e) {
      debugPrint('Install report skipped: $e');
    } finally {
      _busy = false;
    }
  }

  // --- Defaults ------------------------------------------------------------

  static Future<InstallDetails> _deviceDetails() async {
    final platform = Platform.isIOS ? 'ios' : 'android';
    String? osVersion;
    String? model;
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isIOS) {
        final i = await plugin.iosInfo;
        osVersion = i.systemVersion;
        model = i.modelName;
      } else {
        final i = await plugin.androidInfo;
        osVersion = i.version.release;
        model = '${i.manufacturer} ${i.model}'.trim();
      }
    } catch (_) {}
    String? appVersion;
    try {
      appVersion = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    return InstallDetails(
      platform: platform,
      osVersion: osVersion,
      deviceModel: model,
      appVersion: appVersion,
    );
  }

  static Future<int> _httpPost(Uri url, Map<String, dynamic> body) async {
    final res = await http
        .post(url,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body))
        .timeout(const Duration(seconds: 8));
    return res.statusCode;
  }
}
