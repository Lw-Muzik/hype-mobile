/// The mini player while another device is the player.
///
/// Opaque, like the Ember one it replaces (no live blur over a scrolling
/// list). Shows what the other device plays, says where, and sends its
/// transport to that device.
library;

import 'package:flutter/material.dart';

import 'package:eq_app/routes/routes.dart';
import 'package:eq_app/services/connect/hype_connect.dart';
import 'package:eq_app/services/connect/remote/connect_remote_session.dart';
import 'package:eq_app/themes/ember.dart';

import 'connect_device_picker.dart';
import 'remote_scope.dart';

class RemoteMiniPlayer extends StatelessWidget {
  const RemoteMiniPlayer({super.key, required this.remote, this.session});

  final RemoteNowPlaying remote;

  /// Injected by tests; the app uses the live Connect session.
  final ConnectRemoteSession? session;

  static const height = 60.0;

  @override
  Widget build(BuildContext context) {
    final session = this.session ?? HypeConnect.instance.session!;
    final artist = remoteArtistOf(remote.track);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Routes.playerTo(context),
        child: SizedBox(
          height: height,
          child: Stack(
            children: [
              Positioned.fill(
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    RemoteArt(track: remote.track, size: 42),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            remoteTitleOf(remote.track),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Ember.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(
                                kConnectGlyph,
                                size: 12,
                                color: Ember.accent,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  artist == null
                                      ? 'On ${remote.device.name}'
                                      : '${remote.device.name} · $artist',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Ember.accent,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const ConnectPickerButton(size: 20),
                    _MiniControl(
                      icon: Icons.skip_previous_rounded,
                      onPressed: () => session.prev(),
                      size: 22,
                    ),
                    _MiniControl(
                      icon: remote.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      onPressed: () =>
                          remote.playing ? session.pause() : session.resume(),
                      size: 28,
                      prominent: true,
                    ),
                    _MiniControl(
                      icon: Icons.skip_next_rounded,
                      onPressed: () => session.next(),
                      size: 22,
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: RemoteProgressLine(session: session),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniControl extends StatelessWidget {
  const _MiniControl({
    required this.icon,
    required this.onPressed,
    required this.size,
    this.prominent = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final double size;
  final bool prominent;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 40,
    height: 40,
    child: IconButton(
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      splashRadius: 20,
      icon: Icon(
        icon,
        size: size,
        color: prominent ? Ember.textPrimary : Ember.textSecondary,
      ),
    ),
  );
}
