/// Choosing where music plays right after linking a desktop (contract §3.12,
/// "Choosing a direction when linking").
///
/// After this phone approves a desktop's link it asks: play on the desktop
/// (this phone is the remote) or on this phone (the desktop is the remote). The
/// preselected answer is whichever of the two is playing, else the desktop; when
/// both are, this phone, which is in the user's hand.
///
/// # Waiting for the merge
///
/// Approving merges the two accounts, and the hub closes the absorbed side's
/// socket with 4005; it reconnects as a new session. So right after approving,
/// the hub may not yet list the desktop, or this phone may be mid-reconnect.
/// [waitForDesktop] waits (up to [timeout]) until this phone is on the hub and
/// the desktop is listed online.
///
/// # Doing it
///
/// Choosing the device that is *not* playing while the other is moves the
/// playback there (§3.9, [ConnectTransfer]); anything else just `select`s the
/// chosen device.
library;

import 'dart:async';

import '../connect_protocol.dart';
import 'connect_remote_session.dart';
import 'connect_transfer.dart';

enum LinkChoice { desktop, phone }

/// Whether the desktop or this phone should be selected when the sheet opens.
LinkChoice preselectedChoice({
  required bool phonePlaying,
  required bool desktopPlaying,
}) {
  if (phonePlaying) return LinkChoice.phone;
  if (desktopPlaying) return LinkChoice.desktop;
  return LinkChoice.desktop;
}

class ConnectLinkDirection {
  ConnectLinkDirection({
    required this.session,
    required this.transfer,
    required this.selfId,
    required this.phonePlaying,
    required this.isOnline,
    required this.select,
    this.timeout = const Duration(seconds: 20),
  });

  final ConnectRemoteSession session;
  final ConnectTransfer transfer;
  final String selfId;
  final bool Function() phonePlaying;

  /// Whether the socket is up (past `welcome`).
  final bool Function() isOnline;
  final bool Function(String? deviceId) select;
  final Duration timeout;

  /// The online desktop player called [name], or null. When several share the
  /// name, the one seen most recently.
  DeviceInfo? findDesktop(String name) {
    DeviceInfo? best;
    for (final device in session.devices) {
      if (device.kind != DeviceKind.desktop ||
          device.name != name ||
          !device.online ||
          !device.isPlayer) {
        continue;
      }
      if (best == null || device.lastSeenAt.compareTo(best.lastSeenAt) > 0) {
        best = device;
      }
    }
    return best;
  }

  bool _ready(String name) {
    if (!isOnline() || findDesktop(name) == null) return false;
    return session.devices.any((d) => d.id == selfId && d.online);
  }

  LinkChoice preselect(DeviceInfo desktop) => preselectedChoice(
    phonePlaying: phonePlaying(),
    desktopPlaying: session.isPlaying(desktop.id),
  );

  /// The desktop named [name] once this phone and it are both online, or null
  /// after [timeout].
  Future<DeviceInfo?> waitForDesktop(String name) {
    if (_ready(name)) return Future.value(findDesktop(name));
    final done = Completer<DeviceInfo?>();
    late final Timer timer;
    void check() {
      if (done.isCompleted || !_ready(name)) return;
      timer.cancel();
      session.removeListener(check);
      done.complete(findDesktop(name));
    }

    timer = Timer(timeout, () {
      session.removeListener(check);
      if (!done.isCompleted) done.complete(null);
    });
    session.addListener(check);
    return done.future;
  }

  /// Carries out [choice] for [desktop].
  Future<TransferResult> apply(LinkChoice choice, DeviceInfo desktop) async {
    final chosen = choice == LinkChoice.desktop ? desktop.id : selfId;
    final other = choice == LinkChoice.desktop ? selfId : desktop.id;
    final chosenPlaying = chosen == selfId
        ? phonePlaying()
        : session.isPlaying(chosen);
    final otherPlaying = other == selfId
        ? phonePlaying()
        : session.isPlaying(other);
    if (!chosenPlaying && otherPlaying) {
      return transfer.transfer(from: other, to: chosen);
    }
    return select(chosen)
        ? const TransferResult.ok()
        : const TransferResult.failed('Not connected right now.');
  }
}
