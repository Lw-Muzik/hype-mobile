/// "Play on…": the device picker for the mini and full player.
library;

import 'package:flutter/material.dart';

import 'package:eq_app/Themes/app_fonts.dart';
import 'package:eq_app/services/connect/connect_protocol.dart';
import 'package:eq_app/services/connect/hype_connect.dart';
import 'package:eq_app/services/connect/remote/connect_ui_host.dart';
import 'package:eq_app/themes/ember.dart';

import 'remote_scope.dart';

/// A Connect button; absent when Connect is off or no other player is online.
class ConnectPickerButton extends StatelessWidget {
  const ConnectPickerButton({super.key, this.size = 22, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final connect = HypeConnect.instanceOrNull;
    if (connect == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: connect,
      builder: (context, _) {
        final session = connect.session;
        if (!connect.enabled || session == null) return const SizedBox.shrink();
        return ListenableBuilder(
          listenable: session,
          builder: (context, _) {
            if (session.otherPlayers.isEmpty) return const SizedBox.shrink();
            return SizedBox(
              width: 40,
              height: 40,
              child: IconButton(
                tooltip: 'Play on…',
                padding: EdgeInsets.zero,
                splashRadius: 20,
                onPressed: () => showConnectDevicePicker(context),
                icon: Icon(
                  kConnectGlyph,
                  size: size,
                  color:
                      color ??
                      (session.isRemote ? Ember.accent : Ember.textSecondary),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

Future<void> showConnectDevicePicker(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: Ember.surface,
    builder: (_) => const _DevicePickerSheet(),
  );
}

class _DevicePickerSheet extends StatefulWidget {
  const _DevicePickerSheet();

  @override
  State<_DevicePickerSheet> createState() => _DevicePickerSheetState();
}

class _DevicePickerSheetState extends State<_DevicePickerSheet> {
  String? _moving;

  Future<void> _pick(String id) async {
    final connect = HypeConnect.instance;
    final transfer = connect.transfer;
    if (transfer == null || _moving != null) return;
    setState(() => _moving = id);
    final result = await transfer.moveTo(id);
    if (!mounted) return;
    Navigator.of(context).pop();
    if (!result.ok) {
      ConnectUiHost.instance.say(result.message ?? 'Could not move playback.');
    } else if (result.dropped > 0) {
      // Which device the songs stayed on depends on the direction; where they
      // could not go does not.
      final target = id == connect.thisDeviceId
          ? 'this phone'
          : connect.devices
                    .where((d) => d.id == id)
                    .map((d) => d.name)
                    .firstOrNull ??
                'that device';
      ConnectUiHost.instance.say(
        result.dropped == 1
            ? "1 song couldn't move to $target."
            : "${result.dropped} songs couldn't move to $target.",
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final connect = HypeConnect.instance;
    final session = connect.session!;
    return SafeArea(
      child: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final selfId = connect.thisDeviceId ?? '';
          final remoteId = session.remoteTarget?.id;
          final phone = DeviceInfo(
            id: selfId,
            kind: DeviceKind.mobile,
            name: 'This phone',
            platform: null,
            appVersion: null,
            caps: const [ConnectCap.player],
            online: true,
            lastSeenAt: '',
          );
          final devices = [phone, ...session.otherPlayers];
          return Padding(
            padding: const EdgeInsets.fromLTRB(
              Ember.gutter,
              0,
              Ember.gutter,
              16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Play on',
                  style: AppFonts.displayStyle(
                    fontSize: 22,
                    color: Ember.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Music moves with its queue and position.',
                  style: TextStyle(color: Ember.textSecondary),
                ),
                const SizedBox(height: 14),
                for (final device in devices)
                  _PickerTile(
                    device: device,
                    isThisPhone: device.id == selfId,
                    active: device.id == selfId
                        ? remoteId == null
                        : device.id == remoteId,
                    playing: device.id == selfId
                        ? remoteId == null && (connect.isPlaying())
                        : session.isPlaying(device.id),
                    busy: _moving == device.id,
                    onTap: _moving != null ? null : () => _pick(device.id),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PickerTile extends StatelessWidget {
  const _PickerTile({
    required this.device,
    required this.isThisPhone,
    required this.active,
    required this.playing,
    required this.busy,
    required this.onTap,
  });

  final DeviceInfo device;
  final bool isThisPhone;
  final bool active;
  final bool playing;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    const live = Color(0xFF3DDC84);
    final status = playing
        ? 'Playing now'
        : active
        ? 'Selected'
        : 'Available';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: active ? Ember.accentWash : Ember.surfaceHigh,
        borderRadius: BorderRadius.circular(Ember.radiusTile),
        border: Border.all(color: active ? Ember.accent : Ember.outline),
      ),
      child: ListTile(
        onTap: onTap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Ember.radiusTile),
        ),
        leading: Icon(
          iconForDevice(device.kind),
          color: playing ? live : (active ? Ember.accent : Ember.textSecondary),
        ),
        title: Text(
          device.name,
          style: TextStyle(
            color: Ember.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Row(
          children: [
            if (playing)
              Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.only(right: 6),
                decoration: const BoxDecoration(
                  color: live,
                  shape: BoxShape.circle,
                ),
              ),
            Text(
              status,
              style: TextStyle(color: playing ? live : Ember.textTertiary),
            ),
          ],
        ),
        trailing: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : (active ? Icon(Icons.check_rounded, color: Ember.accent) : null),
      ),
    );
  }
}
