/// Shared plumbing for the remote-mode player UI.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:eq_app/services/connect/connect_protocol.dart';
import 'package:eq_app/services/connect/hype_connect.dart';
import 'package:eq_app/services/connect/remote/connect_remote_session.dart';
import 'package:eq_app/themes/ember.dart';

/// The Connect glyph used wherever the UI says "on another device".
const IconData kConnectGlyph = Icons.cast_connected_rounded;

/// Rebuilds with the remote device's player, or null outside remote mode.
class RemoteBuilder extends StatelessWidget {
  const RemoteBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, RemoteNowPlaying? remote) builder;

  @override
  Widget build(BuildContext context) {
    final connect = HypeConnect.instanceOrNull;
    if (connect == null) return builder(context, null);
    return ListenableBuilder(
      listenable: connect,
      builder: (context, _) {
        final session = connect.session;
        if (session == null) return builder(context, null);
        return ListenableBuilder(
          listenable: session,
          builder: (context, _) => builder(context, session.nowPlaying()),
        );
      },
    );
  }
}

/// Artwork of a remote track: its public thumbnail, else a quiet placeholder
/// (a `local` file's art lives on the other device).
class RemoteArt extends StatelessWidget {
  const RemoteArt({
    super.key,
    required this.track,
    required this.size,
    this.radius = 8,
  });

  final TrackRef? track;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final url = remoteArtUrlOf(track);
    final placeholder = Container(
      width: size,
      height: size,
      color: Ember.surfaceHigh,
      child: Icon(
        Icons.music_note_rounded,
        color: Ember.textTertiary,
        size: size * 0.4,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: url == null
          ? placeholder
          : Image.network(
              url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              cacheWidth: (size * 2).round(),
              errorBuilder: (_, _, _) => placeholder,
            ),
    );
  }
}

/// Public artwork URL of a remote track; null for a `local` file (its art lives
/// on the other device).
String? remoteArtUrlOf(TrackRef? track) => switch (track) {
  YtTrackRef(:final artUrl) => artUrl,
  OtherTrackRef(:final artUrl) => artUrl,
  _ => null,
};

/// Progress in 0..1 of a remote player, clamped; 0 when the length is unknown.
double remoteProgressOf(RemoteNowPlaying now) {
  final d = now.durationMs ?? 0;
  if (d <= 0) return 0;
  return (now.positionMs.clamp(0, d)) / d;
}

/// A thin live progress line for a remote player (mini players). Re-reads the
/// session every 200 ms while playing, so it moves between state frames.
class RemoteProgressLine extends StatefulWidget {
  const RemoteProgressLine({super.key, required this.session, this.height = 2});

  final ConnectRemoteSession session;
  final double height;

  @override
  State<RemoteProgressLine> createState() => _RemoteProgressLineState();
}

class _RemoteProgressLineState extends State<RemoteProgressLine> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final now = widget.session.nowPlaying();
      if (mounted && now != null && now.playing) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.session.nowPlaying();
    final value = now == null ? 0.0 : remoteProgressOf(now);
    return SizedBox(
      height: widget.height,
      child: LinearProgressIndicator(
        value: value,
        minHeight: widget.height,
        backgroundColor: Ember.textTertiary.withValues(alpha: 0.25),
        valueColor: const AlwaysStoppedAnimation(Ember.accent),
      ),
    );
  }
}

String remoteTitleOf(TrackRef? track) => switch (track) {
  YtTrackRef(:final title) => title,
  LocalTrackRef(:final title) => title,
  OtherTrackRef(:final title) => title,
  null => 'Nothing playing',
};

String? remoteArtistOf(TrackRef? track) => switch (track) {
  YtTrackRef(:final artist) => artist,
  LocalTrackRef(:final artist) => artist,
  OtherTrackRef(:final artist) => artist,
  null => null,
};

IconData iconForDevice(DeviceKind kind) => switch (kind) {
  DeviceKind.web => Icons.language_rounded,
  DeviceKind.desktop => Icons.desktop_mac_rounded,
  DeviceKind.mobile => Icons.smartphone_rounded,
};

String formatMs(int ms) {
  final total = ms ~/ 1000;
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
