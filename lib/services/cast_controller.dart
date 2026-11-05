import 'dart:async';
import 'dart:convert';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:on_audio_query/on_audio_query.dart';

import 'stream_server.dart';

/// A HypeMuzik desktop discovered on the LAN that can play our music.
class DiscoveredDesktop {
  DiscoveredDesktop({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
  });

  final String id;
  final String name;
  final String host;
  final int port;
}

/// Phone Link — cast (push) direction. Discovers HypeMuzik desktops advertising
/// themselves as players and, when a target is selected, sends tracks + transport
/// commands to that desktop's control server. The desktop pulls the track from
/// this phone and plays it through its DSP chain.
///
/// Only desktops we've already paired with (so we hold a bearer token) can be
/// cast to — pairing is initiated once from the desktop's Phone tab.
class CastController extends ChangeNotifier {
  CastController._();

  static final CastController instance = CastController._();

  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;
  final Map<String, DiscoveredDesktop> _found = {};
  final Map<String, String> _tokens = {}; // desktopId -> bearer token
  DiscoveredDesktop? _target;

  Timer? _pollTimer;

  /// Live now-playing state on the cast target (polled from `GET /now`).
  bool castPlaying = false;
  int castPositionMs = 0;
  int? castDurationMs;

  List<DiscoveredDesktop> get desktops => _found.values.toList();
  DiscoveredDesktop? get target => _target;

  /// Whether taps should be routed to a desktop instead of playing locally.
  bool get isCasting => _target != null;

  bool isPaired(String id) => _tokens.containsKey(id);

  /// Begin browsing for desktops (loads the paired tokens first).
  Future<void> startDiscovery() async {
    await _loadTokens();
    if (_discovery != null) return;
    final discovery = BonsoirDiscovery(
      type: StreamServerController.serviceType,
    );
    await discovery.initialize();
    _sub = discovery.eventStream?.listen(_onEvent);
    await discovery.start();
    _discovery = discovery;
    notifyListeners();
  }

  Future<void> stopDiscovery() async {
    await _sub?.cancel();
    _sub = null;
    await _discovery?.stop();
    _discovery = null;
    _found.clear();
    notifyListeners();
  }

  void setTarget(DiscoveredDesktop? desktop) {
    _target = desktop;
    _stopPolling();
    if (desktop != null) _startPolling();
    notifyListeners();
  }

  void _startPolling() {
    _pollNow();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      _pollNow();
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    castPlaying = false;
    castPositionMs = 0;
    castDurationMs = null;
  }

  Future<void> _pollNow() async {
    final target = _target;
    final token = target == null ? null : _tokens[target.id];
    if (target == null || token == null) return;
    try {
      final res = await http.get(
        Uri.parse('http://${target.host}:${target.port}/now'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode != 200) return;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      castPlaying = j['playing'] == true;
      castPositionMs = (j['positionMs'] as num?)?.toInt() ?? 0;
      castDurationMs = (j['durationMs'] as num?)?.toInt();
      notifyListeners();
    } catch (_) {
      /* best effort */
    }
  }

  Future<void> _loadTokens() async {
    _tokens.clear();
    for (final d in await StreamServerController.instance.loadKnownDesktops()) {
      _tokens[d.id] = d.token;
    }
  }

  void _onEvent(BonsoirDiscoveryEvent event) {
    // bonsoir 7.x models discovery events as a sealed class hierarchy (the old
    // enum `BonsoirDiscoveryEventType` and `ResolvedBonsoirService` are gone).
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent():
        // Found, but not resolved yet — ask for its address.
        _discovery?.serviceResolver.resolveService(event.service);
        break;
      case BonsoirDiscoveryServiceResolvedEvent():
        final service = event.service;
        final attrs = service.attributes;
        if (attrs['role'] != 'player') return;
        // bonsoir 7.x exposes resolved IPs via `hostAddresses` (was `host`).
        final host = service.hostAddresses.isNotEmpty
            ? service.hostAddresses.first
            : service.hostname;
        if (host == null || host.isEmpty) return;
        final id = attrs['id'] ?? service.name;
        _found[id] = DiscoveredDesktop(
          id: id,
          name: attrs['name'] ?? service.name,
          host: host,
          port: service.port,
        );
        notifyListeners();
        break;
      case BonsoirDiscoveryServiceLostEvent():
        final id = event.service.attributes['id'];
        if (id != null && _found.remove(id) != null) {
          if (_target?.id == id) {
            _target = null;
            // Stop the 1.5s /now poll — losing the target used to leave the
            // periodic timer firing for the rest of the session.
            _stopPolling();
          }
          notifyListeners();
        }
        break;
      default:
        break;
    }
  }

  // ---------------------------------------------------------------- commands

  /// Play `song` on the current cast target. No-op if not casting.
  Future<bool> cast(SongModel song) async {
    final target = _target;
    final token = target == null ? null : _tokens[target.id];
    if (target == null || token == null) return false;
    try {
      final res = await http.post(
        Uri.parse('http://${target.host}:${target.port}/cast'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'trackId': song.id.toString(),
          'ext': _extOf(song.data),
          'title': song.title,
          'artist': song.artist == '<unknown>' ? null : song.artist,
        }),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Send a transport command (pause | resume | stop) to the cast target.
  Future<void> transport(String action) async {
    final target = _target;
    final token = target == null ? null : _tokens[target.id];
    if (target == null || token == null) return;
    try {
      await http.post(
        Uri.parse('http://${target.host}:${target.port}/transport'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'action': action}),
      );
    } catch (_) {
      /* best effort */
    }
  }

  String _extOf(String path) {
    final i = path.lastIndexOf('.');
    if (i < 0 || i == path.length - 1) return 'mp3';
    return path.substring(i + 1).toLowerCase();
  }
}
