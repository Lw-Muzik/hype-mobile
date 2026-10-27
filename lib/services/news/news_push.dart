/// News pushes sent from the admin console (FCM `data.type == NEWS`).
///
/// A tap from the background or a terminated state, or a tap on the in-app
/// banner shown while the app is open, opens `data.link` (https only) in the
/// browser and reports `opened` to the backend. Failures are silent.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../config/app_config.dart';
import '../../widgets/news_banner.dart';
import '../connect/remote/connect_ui_host.dart';
import '../install/install_reporter.dart';

class NewsPayload {
  const NewsPayload({
    required this.id,
    required this.title,
    required this.body,
    this.link,
  });

  final String id;
  final String title;
  final String body;

  /// A validated https link, or null.
  final Uri? link;

  /// Parses an FCM message. [title]/[body] come from the `notification` block
  /// and fall back to `data`. Returns null unless `data.type == NEWS` with an
  /// id.
  static NewsPayload? tryParse(
    Map<String, dynamic> data, {
    String? title,
    String? body,
  }) {
    if (data['type'] != 'NEWS') return null;
    final id = '${data['id'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    final t = (title ?? data['title'] as String? ?? '').trim();
    final b = (body ?? data['body'] as String? ?? '').trim();
    if (t.isEmpty && b.isEmpty) return null;
    return NewsPayload(
      id: id,
      title: t,
      body: b,
      link: safeNewsLink(data['link'] as String?),
    );
  }
}

/// [raw] as a Uri only when it is a non-empty https URL with a host.
Uri? safeNewsLink(String? raw) {
  final s = raw?.trim();
  if (s == null || s.isEmpty || s.length > 500) return null;
  final u = Uri.tryParse(s);
  if (u == null || u.scheme.toLowerCase() != 'https' || u.host.isEmpty) {
    return null;
  }
  return u;
}

class NewsPush {
  NewsPush({
    Future<bool> Function(Uri url)? openUrl,
    Future<int> Function(Uri url, Map<String, dynamic> body)? post,
    Future<String?> Function()? installId,
    GlobalKey<NavigatorState>? navigatorKey,
    String? platform,
    String? apiBase,
    this.bannerDuration = const Duration(seconds: 6),
  })  : _open = openUrl ?? _launch,
        _post = post ?? _httpPost,
        _installId = installId ?? hypeInstallId,
        _navKey = navigatorKey ?? ConnectUiHost.navigatorKey,
        platform = platform ?? (Platform.isIOS ? 'ios' : 'android'),
        _api = apiBase ?? AppConfig.hypeMuzikApiBase;

  static final NewsPush instance = NewsPush();

  final String platform;
  final Duration bannerDuration;
  final Future<bool> Function(Uri) _open;
  final Future<int> Function(Uri, Map<String, dynamic>) _post;
  final Future<String?> Function() _installId;
  final GlobalKey<NavigatorState> _navKey;
  final String _api;
  NewsBannerHandle? _banner;

  String get topic => 'hype-news-$platform';

  /// Tap from background/terminated, or on the banner: open the link, report.
  Future<void> handleTap(NewsPayload news) async {
    final link = news.link;
    if (link != null) {
      try {
        await _open(link);
      } catch (e) {
        debugPrint('News link skipped: $e');
      }
    }
    await reportEvent(news.id, 'opened');
  }

  /// `POST <api>/notifications/<id>/events`. Best effort.
  Future<void> reportEvent(String notificationId, String kind) async {
    try {
      final installId = await _installId();
      if (installId == null || installId.isEmpty) return;
      await _post(
        Uri.parse(
            '$_api/notifications/${Uri.encodeComponent(notificationId)}/events'),
        {'installId': installId, 'platform': platform, 'kind': kind},
      );
    } catch (e) {
      debugPrint('News event skipped: $e');
    }
  }

  /// App is open: show the in-app banner. Tap = [handleTap].
  void showBanner(NewsPayload news) {
    final overlay = _navKey.currentState?.overlay;
    if (overlay == null) return;
    _banner?.dismiss();
    _banner = presentNewsBanner(
      overlay,
      title: news.title,
      body: news.body,
      duration: bannerDuration,
      onTap: () => unawaited(handleTap(news)),
    );
  }

  static Future<bool> _launch(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  static Future<int> _httpPost(Uri url, Map<String, dynamic> body) async {
    final res = await http
        .post(url,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body))
        .timeout(const Duration(seconds: 8));
    return res.statusCode;
  }
}
