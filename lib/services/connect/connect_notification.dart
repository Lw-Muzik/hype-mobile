/// What the Hype Connect notification says, worked out from the app's state.
///
/// The notification is the user's window onto a phone that is being kept
/// reachable in the background, so it answers three questions at a glance:
/// *is it working* (the title), *what is happening* (the track line) and *who
/// is involved* (the secondary line). This file is the pure part — facts in,
/// words out — so every sentence is pinned by a table test; pushing the result
/// to the native service is [ConnectServiceController]'s job.
///
/// # Buttons
///
/// When another device is the active player, this phone is a remote for it, so
/// the notification carries previous / play-pause / next for *that* device.
/// When this phone is the player, the normal media notification already has
/// them and a second set would only be confusing; the only action is
/// [ConnectNotificationAction.turnOff]. That one is always there: a service the
/// user cannot stop from the place that announces it would be rude.
///
/// # No clocks
///
/// Nothing here changes as a song progresses — no position, no progress bar —
/// so the text only changes when something worth saying changed, and the
/// notification is not rewritten once a second for nothing.
library;

import 'package:flutter/foundation.dart';

import 'connect_client.dart';
import 'connect_protocol.dart';

enum ConnectNotificationAction {
  previous,
  pause,
  play,
  next,
  turnOff;

  /// The identifier native and Dart agree on. Play and pause share one
  /// button, so they share one id: the Dart side decides which it means.
  String get id => switch (this) {
    previous => 'previous',
    pause || play => 'toggle',
    next => 'next',
    turnOff => 'off',
  };
}

/// The words and buttons of one notification.
@immutable
class ConnectNotificationContent {
  const ConnectNotificationContent({
    required this.title,
    this.text,
    this.subText,
    this.actions = const [ConnectNotificationAction.turnOff],
  });

  final String title;

  /// The track line, e.g. "Hey Jude — The Beatles".
  final String? text;

  /// The secondary line, e.g. "Controlled from Chrome · 2 devices online".
  final String? subText;
  final List<ConnectNotificationAction> actions;

  Map<String, Object?> toJson() => {
    'title': title,
    'text': text,
    'subText': subText,
    'actions': [for (final action in actions) action.name],
  };

  @override
  bool operator ==(Object other) =>
      other is ConnectNotificationContent &&
      other.title == title &&
      other.text == text &&
      other.subText == subText &&
      listEquals(other.actions, actions);

  @override
  int get hashCode =>
      Object.hash(title, text, subText, Object.hashAll(actions));

  @override
  String toString() =>
      'ConnectNotificationContent($title | $text | $subText | '
      '${actions.map((a) => a.name).join(',')})';
}

/// The facts the notification is made from. Plain data, so a test can state a
/// situation in one expression.
@immutable
class ConnectNotificationInput {
  const ConnectNotificationInput({
    required this.status,
    this.retryIn,
    this.thisDeviceId,
    this.devices = const [],
    this.remoteDevice,
    this.remoteTrack,
    this.remotePlaying = false,
    this.localTitle,
    this.localArtist,
    this.hasLocalTrack = false,
    this.localPlaying = false,
    this.controllerId,
  });

  final ConnectStatus status;
  final Duration? retryIn;
  final String? thisDeviceId;

  /// Every linked device of the account, as the hub last listed them.
  final List<DeviceInfo> devices;

  /// The other device that is the active player, when there is one (the remote
  /// session's target), and what it last reported.
  final DeviceInfo? remoteDevice;
  final TrackRef? remoteTrack;
  final bool remotePlaying;

  /// This phone's own player.
  final bool hasLocalTrack;
  final String? localTitle;
  final String? localArtist;
  final bool localPlaying;

  /// The device that most recently sent this phone a command.
  final String? controllerId;
}

/// "Hey Jude — The Beatles", with whatever of the two is known.
@visibleForTesting
String? trackLine(String? title, String? artist) {
  final name = title?.trim() ?? '';
  final by = artist?.trim() ?? '';
  // A placeholder artist says nothing the title does not.
  final hasArtist = by.isNotEmpty && by != '<unknown>';
  if (name.isEmpty && !hasArtist) return null;
  if (name.isEmpty) return by;
  return hasArtist ? '$name — $by' : name;
}

/// The notification for [input]. Pure.
ConnectNotificationContent buildConnectNotification(
  ConnectNotificationInput input,
) {
  switch (input.status) {
    case ConnectStatus.replaced:
      return const ConnectNotificationContent(
        title: 'Taken over by another connection',
        text: 'Turn Hype Connect off and on to take this phone back',
      );
    case ConnectStatus.unlinked:
      return const ConnectNotificationContent(
        title: 'This phone was unlinked',
        text: 'Link it again from the Hype Connect page',
      );
    case ConnectStatus.off:
    case ConnectStatus.connecting:
    case ConnectStatus.retrying:
      final wait = input.retryIn;
      return ConnectNotificationContent(
        title: 'Reconnecting…',
        text: input.status == ConnectStatus.retrying
            ? 'Cannot reach HypeMuzik'
                  '${wait == null ? '' : ', trying again in ${wait.inSeconds.clamp(1, 60)} s'}'
            : null,
      );
    case ConnectStatus.online:
      break;
  }

  final remote = input.remoteDevice;
  final remoteSpeaks =
      remote != null && (input.remoteTrack != null || input.remotePlaying);
  if (remote != null && remoteSpeaks) {
    final track = input.remoteTrack;
    return ConnectNotificationContent(
      title: input.remotePlaying
          ? 'Playing on ${remote.name}'
          : 'Paused on ${remote.name}',
      text:
          trackLine(track?.title, track?.artist) ??
          (track == null ? null : 'Unknown track'),
      subText: _onlineLine(input),
      actions: [
        ConnectNotificationAction.previous,
        input.remotePlaying
            ? ConnectNotificationAction.pause
            : ConnectNotificationAction.play,
        ConnectNotificationAction.next,
        ConnectNotificationAction.turnOff,
      ],
    );
  }

  final controller = _controllerName(input);
  final controlled = controller == null ? null : 'Controlled from $controller';
  final online = _onlineLine(input);
  final secondary = [?controlled, ?online].join(' · ');

  if (input.hasLocalTrack) {
    return ConnectNotificationContent(
      title: input.localPlaying
          ? 'Playing on this phone'
          : 'Paused on this phone',
      text: trackLine(input.localTitle, input.localArtist) ?? 'Unknown track',
      subText: secondary.isEmpty ? null : secondary,
    );
  }
  return ConnectNotificationContent(
    title: 'Ready for your devices',
    text: 'Start music from any linked device',
    subText: secondary.isEmpty ? null : secondary,
  );
}

/// The controller, but only while it is still online — someone who left
/// should not be shown as steering the phone.
String? _controllerName(ConnectNotificationInput input) {
  final id = input.controllerId;
  if (id == null || id == input.thisDeviceId) return null;
  for (final device in input.devices) {
    if (device.id == id) return device.online ? device.name : null;
  }
  return null;
}

/// "2 devices online" — the others, not counting this phone.
String? _onlineLine(ConnectNotificationInput input) {
  final others = input.devices
      .where((d) => d.online && d.id != input.thisDeviceId)
      .length;
  if (others == 0) return null;
  return others == 1 ? '1 device online' : '$others devices online';
}
