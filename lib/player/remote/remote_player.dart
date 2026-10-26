/// The full player while another device is the player.
///
/// Everything here is that device's: its track, its queue, its progress. The
/// controls send commands to it. EQ and DSP stay on this phone; lyrics and the
/// visualiser belong to the other device, and a footer line says so rather than
/// showing stale local ones.
///
/// The layout follows the *constraints*, not the device orientation, so a
/// split-screen window gets the right one: portrait stacks the artwork over the
/// controls with the queue as a bottom sheet; landscape puts the artwork and
/// the queue side by side above a strip carrying the transport and the wave.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:eq_app/Themes/app_fonts.dart';
import 'package:eq_app/services/connect/connect_protocol.dart';
import 'package:eq_app/services/connect/hype_connect.dart';
import 'package:eq_app/services/connect/remote/connect_remote_session.dart';
import 'package:eq_app/themes/ember.dart';
import 'package:eq_app/widgets/common.dart';

import 'connect_device_picker.dart';
import 'remote_scope.dart';

/// The local transport's own gold, so the toggles read the same in both modes.
const _toggleGold = Color(0xFFD4A825);

/// Height of the collapsed queue sheet, handle and "Next:" line included.
const _peekHeight = 88.0;

class RemotePlayerView extends StatelessWidget {
  const RemotePlayerView({super.key, required this.remote, this.session});

  final RemoteNowPlaying remote;

  /// Injected by tests; the app uses the live Connect session.
  final ConnectRemoteSession? session;

  @override
  Widget build(BuildContext context) {
    final s = session ?? HypeConnect.instance.session!;
    return Scaffold(
      backgroundColor: Ember.ground,
      body: LayoutBuilder(
        builder: (context, box) {
          final landscape = box.maxWidth > box.maxHeight;
          return Stack(
            children: [
              Positioned.fill(child: RemoteBackdrop(track: remote.track)),
              SafeArea(
                bottom: landscape,
                child: landscape
                    ? _LandscapeLayout(session: s, remote: remote)
                    : _PortraitLayout(session: s, remote: remote),
              ),
            ],
          );
        },
      ),
    );
  }
}

// --- Background --------------------------------------------------------------

/// A tinted glow from the track's own colour, the blurred artwork over it, and
/// the dark fade that keeps text legible. The glow is what stops an art-less
/// local track from being flat black.
class RemoteBackdrop extends StatelessWidget {
  const RemoteBackdrop({super.key, required this.track, this.fade = true});

  final TrackRef? track;

  /// The dark fade keeping player text legible; pages with their own scrim
  /// turn it off.
  final bool fade;

  @override
  Widget build(BuildContext context) {
    final artUrl = remoteArtUrlOf(track);
    final tint = Ember.accentFor(remoteTitleOf(track));
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0, -0.85),
              radius: 1.15,
              colors: [tint.withValues(alpha: 0.75), tint.withValues(alpha: 0)],
            ),
          ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 500),
          child: artUrl == null
              ? const SizedBox.expand(key: ValueKey('no-art'))
              : ImageFiltered(
                  key: ValueKey(artUrl),
                  imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                  child: Image.network(
                    artUrl,
                    fit: BoxFit.cover,
                    cacheWidth: 120,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
        ),
        if (fade)
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Ember.ground.withValues(alpha: 0.55),
                  Ember.ground.withValues(alpha: 0.92),
                  Ember.ground,
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// --- Header ------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.remote, required this.height});

  final RemoteNowPlaying remote;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(
                Icons.keyboard_arrow_down_rounded,
                color: Ember.textPrimary,
                size: 28,
              ),
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'PLAYING ON',
                    style: TextStyle(
                      color: Ember.textTertiary,
                      fontSize: 10,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.6,
                    ),
                  ),
                  const SizedBox(height: 3),
                  _DevicePill(remote: remote),
                ],
              ),
            ),
            // Same width as the close button so the pill stays centred even
            // when the picker button is absent.
            const SizedBox(width: 48, child: ConnectPickerButton(size: 24)),
          ],
        ),
      ),
    );
  }
}

class _DevicePill extends StatelessWidget {
  const _DevicePill({required this.remote});

  final RemoteNowPlaying remote;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Ember.accentWash,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showConnectDevicePicker(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                iconForDevice(remote.device.kind),
                size: 14,
                color: Ember.accent,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  remote.device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Ember.accent,
                    fontSize: 13,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              RepaintBoundary(child: _LiveBars(active: remote.playing)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Three bars that dance while the other device plays and rest short while it
/// is paused. The controller only runs while playing: a repeating animation
/// over a paused player is wasted heat.
class _LiveBars extends StatefulWidget {
  const _LiveBars({required this.active});

  final bool active;

  @override
  State<_LiveBars> createState() => _LiveBarsState();
}

class _LiveBarsState extends State<_LiveBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat();
  }

  @override
  void didUpdateWidget(_LiveBars old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.active && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  static const _rest = [0.35, 0.6, 0.35];
  static const _phase = [0.0, 0.33, 0.66];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 14,
      height: 12,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: 3,
                height:
                    12 *
                    (widget.active
                        ? 0.3 +
                              0.7 *
                                  (0.5 +
                                      0.5 *
                                          math.sin(
                                            (_c.value + _phase[i]) *
                                                2 *
                                                math.pi,
                                          ))
                        : _rest[i]),
                decoration: BoxDecoration(
                  color: Ember.accent,
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// --- Hero artwork and track info ---------------------------------------------

class _HeroArt extends StatelessWidget {
  const _HeroArt({
    required this.session,
    required this.remote,
    required this.size,
  });

  final ConnectRemoteSession session;
  final RemoteNowPlaying remote;
  final double size;

  @override
  Widget build(BuildContext context) {
    final glow = Ember.accentFor(remoteTitleOf(remote.track));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Horizontal flings skip, a downward one dismisses: the local player's
      // gestures, so the two feel like one player.
      onHorizontalDragEnd: (d) {
        final vx = d.velocity.pixelsPerSecond.dx;
        if (vx.abs() <= 300) return;
        HapticFeedback.selectionClick();
        vx < 0 ? session.next() : session.prev();
      },
      onVerticalDragEnd: (d) {
        if (d.velocity.pixelsPerSecond.dy > 700) {
          Navigator.of(context).maybePop();
        }
      },
      child: AnimatedScale(
        scale: remote.playing ? 1.0 : 0.94,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
        child: DecoratedBox(
          key: const Key('remote-art'),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Ember.radiusCard),
            boxShadow: [
              ...Ember.lift,
              BoxShadow(
                color: glow.withValues(alpha: 0.7),
                blurRadius: 56,
                spreadRadius: -6,
              ),
            ],
          ),
          child: RemoteArt(
            track: remote.track,
            size: size,
            radius: Ember.radiusCard,
          ),
        ),
      ),
    );
  }
}

class _TrackInfo extends StatelessWidget {
  const _TrackInfo({
    required this.track,
    required this.titleSize,
    required this.titleLines,
  });

  final TrackRef? track;
  final double titleSize;
  final int titleLines;

  @override
  Widget build(BuildContext context) {
    final artist = remoteArtistOf(track);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          remoteTitleOf(track),
          maxLines: titleLines,
          overflow: TextOverflow.ellipsis,
          style: AppFonts.displayStyle(
            fontSize: titleSize,
            height: 1.15,
            color: Ember.textPrimary,
          ),
        ),
        if (artist != null) ...[
          const SizedBox(height: 4),
          Text(
            artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Ember.textSecondary,
              fontSize: 15,
              height: 1.3,
            ),
          ),
        ],
      ],
    );
  }
}

// --- Wave --------------------------------------------------------------------

/// The local player's wave slider, driven by the other device's clock.
///
/// Position ticks locally between the device's reports, but only while it is
/// playing; paused, the parent's rebuilds on each report are enough.
class _RemoteWave extends StatefulWidget {
  const _RemoteWave({
    required this.session,
    required this.playing,
    required this.height,
  });

  final ConnectRemoteSession session;
  final bool playing;
  final double height;

  @override
  State<_RemoteWave> createState() => _RemoteWaveState();
}

class _RemoteWaveState extends State<_RemoteWave> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_RemoteWave old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.playing && _tick == null) {
      _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (mounted) setState(() {});
      });
    } else if (!widget.playing) {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.session.nowPlaying();
    if (now == null) return SizedBox(height: widget.height);
    final known = (now.durationMs ?? 0) > 0;
    final duration = Duration(milliseconds: known ? now.durationMs! : 0);
    final position = known
        ? Duration(milliseconds: now.positionMs.clamp(0, now.durationMs!))
        : Duration.zero;
    return WaveformSeekBar(
      duration: duration,
      position: position,
      bufferedPosition: position,
      isPlaying: now.playing,
      height: widget.height,
      onChangeEnd: known ? (d) => widget.session.seek(d.inMilliseconds) : null,
    );
  }
}

// --- Transport ---------------------------------------------------------------

class _Transport extends StatelessWidget {
  const _Transport({
    required this.session,
    required this.remote,
    this.compact = false,
  });

  final ConnectRemoteSession session;
  final RemoteNowPlaying remote;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final gap = compact ? 8.0 : 12.0;
    final repeatIcon = remote.repeat == ConnectRepeat.one
        ? Icons.repeat_one_rounded
        : Icons.repeat_rounded;
    final device = remote.device.name;
    // Scale down rather than overflow on very narrow windows.
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Toggle(
            icon: Icons.shuffle_rounded,
            on: remote.shuffle,
            tooltip: remote.shuffle ? 'Shuffle on' : 'Shuffle off',
            onPressed: () => session.shuffle(!remote.shuffle),
          ),
          SizedBox(width: gap),
          _Skip(
            icon: Icons.skip_previous_rounded,
            tooltip: 'Previous',
            size: compact ? 30 : 36,
            onPressed: () {
              HapticFeedback.selectionClick();
              session.prev();
            },
          ),
          SizedBox(width: compact ? gap : 16),
          _PlayButton(
            playing: remote.playing,
            size: compact ? 56 : 72,
            tooltip: remote.playing ? 'Pause on $device' : 'Play on $device',
            onPressed: () {
              HapticFeedback.selectionClick();
              remote.playing ? session.pause() : session.resume();
            },
          ),
          SizedBox(width: compact ? gap : 16),
          _Skip(
            icon: Icons.skip_next_rounded,
            tooltip: 'Next',
            size: compact ? 30 : 36,
            onPressed: () {
              HapticFeedback.selectionClick();
              session.next();
            },
          ),
          SizedBox(width: gap),
          _Toggle(
            icon: repeatIcon,
            on: remote.repeat != ConnectRepeat.off,
            tooltip: switch (remote.repeat) {
              ConnectRepeat.off => 'Repeat off',
              ConnectRepeat.all => 'Repeat all',
              ConnectRepeat.one => 'Repeat one',
            },
            onPressed: () => session.repeat(switch (remote.repeat) {
              ConnectRepeat.off => ConnectRepeat.all,
              ConnectRepeat.all => ConnectRepeat.one,
              ConnectRepeat.one => ConnectRepeat.off,
            }),
          ),
        ],
      ),
    );
  }
}

/// Gold, where the local player's is white: the colour is what says "this
/// button drives another device". Solid gold carries a dark glyph.
class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.playing,
    required this.size,
    required this.tooltip,
    required this.onPressed,
  });

  final bool playing;
  final double size;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        onTap: onPressed,
        child: GestureDetector(
          onTap: onPressed,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: Ember.accent,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Ember.accent.withValues(alpha: 0.3),
                  blurRadius: 24,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: size * 0.53,
              color: Ember.ground,
            ),
          ),
        ),
      ),
    );
  }
}

class _Skip extends StatelessWidget {
  const _Skip({
    required this.icon,
    required this.tooltip,
    required this.size,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final double size;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: Colors.white, size: size),
        ),
      ),
    ),
  );
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.icon,
    required this.on,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final bool on;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: on
              ? BoxDecoration(
                  shape: BoxShape.circle,
                  color: _toggleGold.withValues(alpha: 0.15),
                )
              : null,
          child: Icon(icon, size: 22, color: on ? _toggleGold : Colors.white38),
        ),
      ),
    ),
  );
}

// --- Volume ------------------------------------------------------------------

class _VolumeRow extends StatefulWidget {
  const _VolumeRow({required this.session, required this.remote});

  final ConnectRemoteSession session;
  final RemoteNowPlaying remote;

  @override
  State<_VolumeRow> createState() => _VolumeRowState();
}

class _VolumeRowState extends State<_VolumeRow> {
  double? _dragging;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Widget build(BuildContext context) {
    final value = (_dragging ?? widget.remote.volume).clamp(0.0, 1.0);
    final icon = value <= 0.001
        ? Icons.volume_off_rounded
        : value < 0.5
        ? Icons.volume_down_rounded
        : Icons.volume_up_rounded;
    return Row(
      children: [
        Icon(icon, size: 20, color: Ember.textSecondary),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: Ember.textPrimary.withValues(alpha: 0.8),
              inactiveTrackColor: Ember.outline,
              thumbColor: Ember.textPrimary,
              overlayShape: SliderComponentShape.noOverlay,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: value,
              onChanged: (v) {
                setState(() => _dragging = v);
                final now = DateTime.now();
                if (now.difference(_lastSent) >
                    const Duration(milliseconds: 150)) {
                  _lastSent = now;
                  widget.session.volume(v);
                }
              },
              onChangeEnd: (v) {
                setState(() => _dragging = null);
                widget.session.volume(v);
              },
            ),
          ),
        ),
        SizedBox(
          width: 38,
          child: Text(
            '${(value * 100).round()}%',
            textAlign: TextAlign.end,
            style: TextStyle(
              color: Ember.textTertiary,
              fontSize: 12,
              fontFeatures: AppFonts.tabular,
            ),
          ),
        ),
      ],
    );
  }
}

// --- Queue -------------------------------------------------------------------

/// "UP NEXT", a count chip and a quiet "on" line naming the device.
class _QueueHeader extends StatelessWidget {
  const _QueueHeader({required this.remote});

  final RemoteNowPlaying remote;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('UP NEXT', style: Ember.shelfTitle(context)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Ember.surfaceHigh,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '${remote.queue.length}',
            style: TextStyle(
              color: Ember.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              fontFeatures: AppFonts.tabular,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'on ${remote.device.name}',
            textAlign: TextAlign.end,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Ember.textTertiary, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({required this.session, required this.entry});

  final ConnectRemoteSession session;
  final QueueEntry entry;

  @override
  Widget build(BuildContext context) {
    final artist = remoteArtistOf(entry.track);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          HapticFeedback.selectionClick();
          session.jump(entry.uid);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              RemoteArt(track: entry.track, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      remoteTitleOf(entry.track),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Ember.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    if (artist != null)
                      Text(
                        artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Ember.textTertiary,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rows plus the empty state and the footer, as slivers so the portrait sheet
/// and the landscape pane share them.
List<Widget> _queueSlivers({
  required ConnectRemoteSession session,
  required RemoteNowPlaying remote,
  required double bottomPad,
}) {
  final device = remote.device.name;
  return [
    if (remote.queue.isEmpty)
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 28),
          child: Column(
            children: [
              Icon(
                Icons.queue_music_rounded,
                size: 32,
                color: Ember.textTertiary,
              ),
              const SizedBox(height: 8),
              Text(
                'Nothing queued on $device',
                style: TextStyle(color: Ember.textTertiary, fontSize: 14),
              ),
            ],
          ),
        ),
      )
    else
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        sliver: SliverList.builder(
          itemCount: remote.queue.length,
          itemBuilder: (_, i) =>
              _QueueRow(session: session, entry: remote.queue[i]),
        ),
      ),
    SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + bottomPad),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lyrics_rounded, size: 14, color: Ember.textTertiary),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Lyrics and visuals stay on $device',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Ember.textTertiary, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    ),
  ];
}

// --- Portrait ----------------------------------------------------------------

class _PortraitLayout extends StatefulWidget {
  const _PortraitLayout({required this.session, required this.remote});

  final ConnectRemoteSession session;
  final RemoteNowPlaying remote;

  @override
  State<_PortraitLayout> createState() => _PortraitLayoutState();
}

class _PortraitLayoutState extends State<_PortraitLayout> {
  static const _maxSheet = 0.88;
  final _sheet = DraggableScrollableController();

  @override
  void dispose() {
    _sheet.dispose();
    super.dispose();
  }

  void _toggleSheet(double peek) {
    if (!_sheet.isAttached) return;
    final open = _sheet.size > (peek + _maxSheet) / 2;
    _sheet.animateTo(
      open ? peek : _maxSheet,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final remote = widget.remote;
    return LayoutBuilder(
      builder: (context, box) {
        final peekPx = _peekHeight + bottomInset;
        final peek = (peekPx / box.maxHeight).clamp(0.0, 0.5);
        final headerH = box.maxHeight >= 600 ? 56.0 : 48.0;
        return Stack(
          children: [
            Column(
              children: [
                _Header(remote: remote, height: headerH),
                Expanded(
                  child: _NowPlayingBlock(
                    session: widget.session,
                    remote: remote,
                  ),
                ),
                SizedBox(height: peekPx),
              ],
            ),
            Positioned.fill(
              child: DraggableScrollableSheet(
                controller: _sheet,
                initialChildSize: peek,
                minChildSize: peek,
                maxChildSize: _maxSheet,
                snap: true,
                builder: (context, scroll) => DecoratedBox(
                  decoration: BoxDecoration(
                    color: Ember.surface,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                    boxShadow: Ember.lift,
                  ),
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                    child: CustomScrollView(
                      key: const Key('remote-queue'),
                      controller: scroll,
                      slivers: [
                        SliverPersistentHeader(
                          pinned: true,
                          delegate: _PeekDelegate(
                            remote: remote,
                            onTap: () => _toggleSheet(peek),
                          ),
                        ),
                        ..._queueSlivers(
                          session: widget.session,
                          remote: remote,
                          bottomPad: bottomInset,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The collapsed sheet: handle, count, and what plays after this track.
class _PeekDelegate extends SliverPersistentHeaderDelegate {
  _PeekDelegate({required this.remote, required this.onTap});

  final RemoteNowPlaying remote;
  final VoidCallback onTap;

  @override
  double get minExtent => _peekHeight;
  @override
  double get maxExtent => _peekHeight;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    final next = remote.queue.isEmpty ? null : remote.queue.first.track;
    final artist = next == null ? null : remoteArtistOf(next);
    return Material(
      color: Ember.surface,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Ember.outline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _QueueHeader(remote: remote),
              const SizedBox(height: 6),
              Text(
                next == null
                    ? 'Nothing up next'
                    : 'Next: ${remoteTitleOf(next)}${artist == null ? '' : ' — $artist'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Ember.textSecondary, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_PeekDelegate old) => old.remote != remote;
}

/// Art, info, wave, transport, volume: sized to the room so nothing scrolls on
/// a normal phone, with a scroll fallback for split-screen slivers.
class _NowPlayingBlock extends StatelessWidget {
  const _NowPlayingBlock({required this.session, required this.remote});

  final ConnectRemoteSession session;
  final RemoteNowPlaying remote;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final big = MediaQuery.sizeOf(context).shortestSide >= 600;
        final w = math.min(box.maxWidth, big ? 680.0 : 560.0);
        final h = box.maxHeight;
        final titleSize = big ? 28.0 : 24.0;
        final gap = (h * 0.015).clamp(6.0, 16.0);
        final infoH = titleSize * 1.15 * 2 + 4 + 20 + 4;
        const transportH = 72.0;
        const volumeH = 40.0;
        double fixed(double waveH) =>
            infoH + (waveH + 6 + 20) + transportH + volumeH + 4 * gap + 8;

        var waveH = 85.0;
        var art = math.min(w - 48, h - fixed(waveH));
        if (art < 120) {
          // Short screens: trade wave height before giving up on the layout.
          waveH = 60;
          art = math.min(w - 48, h - fixed(waveH));
        }
        final scrolls = art < 120;
        art = art.clamp(120.0, big ? 620.0 : 520.0);

        final column = Column(
          mainAxisSize: scrolls ? MainAxisSize.min : MainAxisSize.max,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _HeroArt(session: session, remote: remote, size: art),
            SizedBox(height: gap * 1.5),
            SizedBox(
              height: infoH,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: _TrackInfo(
                    track: remote.track,
                    titleSize: titleSize,
                    titleLines: 2,
                  ),
                ),
              ),
            ),
            SizedBox(height: gap),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _RemoteWave(
                session: session,
                playing: remote.playing,
                height: waveH,
              ),
            ),
            SizedBox(height: gap),
            _Transport(session: session, remote: remote),
            SizedBox(height: gap),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SizedBox(
                height: volumeH,
                child: _VolumeRow(session: session, remote: remote),
              ),
            ),
          ],
        );
        final body = Center(
          child: SizedBox(width: w, child: column),
        );
        return scrolls
            ? SingleChildScrollView(child: body)
            : SizedBox(height: h, child: body);
      },
    );
  }
}

// --- Landscape ---------------------------------------------------------------

class _LandscapeLayout extends StatelessWidget {
  const _LandscapeLayout({required this.session, required this.remote});

  final ConnectRemoteSession session;
  final RemoteNowPlaying remote;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final h = box.maxHeight;
        final big = MediaQuery.sizeOf(context).shortestSide >= 600;
        final wide = w >= 720;
        final headerH = h >= 600 ? 56.0 : 48.0;
        final waveH = (h * 0.1).clamp(44.0, 85.0);
        final stripH = waveH + 6 + 20 + 20;
        final middleH = h - headerH - stripH;
        final art = math.max(120.0, math.min(middleH - 16, w * 0.42));
        return Column(
          children: [
            _Header(remote: remote, height: headerH),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                // The art's height bounds the queue column too, so the two
                // panes start and end on the same lines.
                child: Center(
                  child: SizedBox(
                    height: art,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: _HeroArt(
                            session: session,
                            remote: remote,
                            size: art,
                          ),
                        ),
                        const SizedBox(width: 24),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _TrackInfo(
                                track: remote.track,
                                titleSize: big ? 28 : 20,
                                titleLines: 1,
                              ),
                              if (!wide) ...[
                                const SizedBox(height: 4),
                                SizedBox(
                                  height: 36,
                                  child: _VolumeRow(
                                    session: session,
                                    remote: remote,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 8),
                              Expanded(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Ember.surface.withValues(
                                      alpha: 0.78,
                                    ),
                                    borderRadius: BorderRadius.circular(
                                      Ember.radiusTile,
                                    ),
                                    border: Border.all(color: Ember.outline),
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(
                                      Ember.radiusTile,
                                    ),
                                    child: Column(
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                            16,
                                            12,
                                            16,
                                            6,
                                          ),
                                          child: _QueueHeader(remote: remote),
                                        ),
                                        Expanded(
                                          child: CustomScrollView(
                                            key: const Key('remote-queue'),
                                            slivers: _queueSlivers(
                                              session: session,
                                              remote: remote,
                                              bottomPad: 0,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: stripH,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    _Transport(session: session, remote: remote, compact: true),
                    const SizedBox(width: 4),
                    Expanded(
                      child: _RemoteWave(
                        session: session,
                        playing: remote.playing,
                        height: waveH,
                      ),
                    ),
                    if (wide) ...[
                      const SizedBox(width: 4),
                      SizedBox(
                        width: 170,
                        child: _VolumeRow(session: session, remote: remote),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
