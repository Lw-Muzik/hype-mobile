/// "A new version is available" notices.
///
/// Policy comes from the backend (`GET <api>/app-version/<platform>`), is
/// compared with the installed `MAJOR.MINOR.PATCH`, and is shown as a Hype
/// dialog once the main shell is up. Triggers: launch, resume (at most once per
/// 10 minutes), a foreground FCM `APP_UPDATE` message, and a tap on that push.
/// Every failure is silent: this must never get between a user and their music.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/app_config.dart';
import '../../widgets/update_dialog.dart';
import '../connect/remote/connect_ui_host.dart';
import 'app_version_policy.dart';

class UpdateService with WidgetsBindingObserver {
  UpdateService({
    SharedPreferences? prefs,
    Future<AppVersionPolicy?> Function(String platform)? fetchPolicy,
    Future<String?> Function()? installedVersion,
    Future<bool> Function(Uri url)? openUrl,
    DateTime Function()? now,
    GlobalKey<NavigatorState>? navigatorKey,
    String? platform,
    this.resumeThrottle = const Duration(minutes: 10),
  })  : _prefsOverride = prefs,
        _fetch = fetchPolicy ?? _httpFetch,
        _installed = installedVersion ?? _packageVersion,
        _open = openUrl ?? _launch,
        _now = now ?? DateTime.now,
        _navKey = navigatorKey ?? ConnectUiHost.navigatorKey,
        platform = platform ?? (Platform.isIOS ? 'ios' : 'android');

  static final UpdateService instance = UpdateService();

  static const _kLaterAt = 'update_notice.later_at';
  static const _kLaterVersion = 'update_notice.later_version';
  static const _kSkipped = 'update_notice.skipped_version';
  static const _kAskedNotif = 'update_notice.asked_notifications';

  /// Play listing for the production id (the `.dev` flavor shares it).
  static const _playFallback =
      'https://play.google.com/store/apps/details?id=x.a.zix';

  final String platform;
  final Duration resumeThrottle;
  final SharedPreferences? _prefsOverride;
  final Future<AppVersionPolicy?> Function(String) _fetch;
  final Future<String?> Function() _installed;
  final Future<bool> Function(Uri) _open;
  final DateTime Function() _now;
  final GlobalKey<NavigatorState> _navKey;

  bool _shellReady = false;
  bool _showing = false;
  bool _checking = false;
  bool _pushWired = false;
  DateTime? _lastCheck;

  String get topic => 'hype-updates-$platform';

  /// Called by the main shell once it is on screen. Nothing is shown before
  /// this, so first-run, onboarding and the splash are never covered.
  void markShellReady() {
    if (_shellReady) return;
    _shellReady = true;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(check());
      unawaited(_wirePush());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_shellReady) return;
    final last = _lastCheck;
    if (last != null && _now().difference(last) < resumeThrottle) return;
    unawaited(check());
  }

  /// Fetches the policy and shows a dialog if one is due. [ignoreChoices]
  /// bypasses Later/Skip (a tap on the push notification).
  Future<void> check({bool ignoreChoices = false}) async {
    if (!_shellReady || _showing || _checking) return;
    _checking = true;
    try {
      _lastCheck = _now();
      final installed = await _installed();
      if (installed == null || parseVersion(installed) == null) return;
      final policy = await _fetch(platform);
      if (policy == null) return;
      final prefs = await _prefs();
      final laterMs = prefs.getInt(_kLaterAt);
      final prompt = decideUpdate(
        installed: installed,
        policy: policy,
        now: _now(),
        ignoreChoices: ignoreChoices,
        choices: UpdateChoices(
          laterAt: laterMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(laterMs),
          laterVersion: prefs.getString(_kLaterVersion),
          skippedVersion: prefs.getString(_kSkipped),
        ),
      );
      if (prompt == UpdatePrompt.none) return;
      await _show(policy, blocking: prompt == UpdatePrompt.blocking, prefs: prefs);
    } catch (e) {
      debugPrint('Update check skipped: $e');
    } finally {
      _checking = false;
    }
  }

  Future<void> _show(
    AppVersionPolicy policy, {
    required bool blocking,
    required SharedPreferences prefs,
  }) async {
    final context = _navKey.currentContext;
    if (context == null || !context.mounted || _showing) return;
    final url = _storeUri(policy);
    _showing = true;
    try {
      // A blocking dialog re-opens after "Update now" returns the user to the
      // app without having updated.
      while (true) {
        if (!context.mounted) return;
        final choice = await showDialog<UpdateChoice>(
          context: context,
          barrierDismissible: !blocking,
          builder: (_) => UpdateDialog(
            latestVersion: policy.latestVersion,
            releaseNotes: policy.releaseNotes,
            blocking: blocking,
            canOpenStore: url != null,
            storeName: platform == 'ios' ? 'the App Store' : 'Google Play',
          ),
        );
        switch (choice) {
          case UpdateChoice.updateNow:
            if (url != null) await _open(url);
            if (blocking) continue;
            return;
          case UpdateChoice.later:
            await prefs.setInt(_kLaterAt, _now().millisecondsSinceEpoch);
            await prefs.setString(_kLaterVersion, policy.latestVersion);
            return;
          case UpdateChoice.skip:
            await prefs.setString(_kSkipped, policy.latestVersion);
            return;
          case null:
            return; // dismissed (barrier / back) on the dismissible variant
        }
      }
    } finally {
      _showing = false;
    }
  }

  Uri? _storeUri(AppVersionPolicy policy) {
    final raw = policy.storeUrl;
    if (raw != null) {
      final u = Uri.tryParse(raw);
      if (u != null && u.hasScheme) return u;
    }
    return platform == 'android' ? Uri.parse(_playFallback) : null;
  }

  Future<SharedPreferences> _prefs() async =>
      _prefsOverride ?? await SharedPreferences.getInstance();

  // --- Push ----------------------------------------------------------------

  Future<void> _wirePush() async {
    if (_pushWired) return;
    _pushWired = true;
    try {
      final fm = FirebaseMessaging.instance;
      FirebaseMessaging.onMessage.listen((m) {
        if (m.data['type'] == 'APP_UPDATE') unawaited(check());
      });
      FirebaseMessaging.onMessageOpenedApp.listen((m) {
        if (m.data['type'] == 'APP_UPDATE') {
          unawaited(check(ignoreChoices: true));
        }
      });
      final initial = await fm.getInitialMessage();
      if (initial?.data['type'] == 'APP_UPDATE') {
        unawaited(check(ignoreChoices: true));
      }

      await _askNotificationPermission(fm);
      if (Platform.isIOS) {
        // The topic subscription needs the APNs token, which can lag the launch.
        for (var i = 0; i < 5 && await fm.getAPNSToken() == null; i++) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        if (await fm.getAPNSToken() == null) return;
      }
      await fm.subscribeToTopic(topic);
    } catch (e) {
      debugPrint('Update push setup skipped: $e');
    }
  }

  /// Android 13+ hides notifications until allowed. Hype Connect already asks
  /// when switched on; this asks once for users who never did, so update
  /// announcements can show. iOS asks through FCM.
  Future<void> _askNotificationPermission(FirebaseMessaging fm) async {
    if (Platform.isIOS) {
      await fm.requestPermission();
      return;
    }
    if (await Permission.notification.status.isGranted) return;
    final prefs = await _prefs();
    if (prefs.getBool(_kAskedNotif) ?? false) return;
    await prefs.setBool(_kAskedNotif, true);
    await Permission.notification.request();
  }

  // --- Defaults ------------------------------------------------------------

  static Future<AppVersionPolicy?> _httpFetch(String platform) async {
    try {
      final res = await http
          .get(Uri.parse('${AppConfig.hypeMuzikApiBase}/app-version/$platform'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      return AppVersionPolicy.tryParse(jsonDecode(res.body));
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _packageVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  static Future<bool> _launch(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);
}
