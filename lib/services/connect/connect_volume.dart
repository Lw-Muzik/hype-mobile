/// The volume Hype Connect reports and sets for this phone.
///
/// # Which volume
///
/// What the listener hears from a phone is not the just_audio gain. That one is
/// rewritten by ReplayGain, by every video load and at the end of every
/// crossfade, so a remote `volume` command written to it was overwritten within
/// a track, and the value reported back (always about 1) said nothing about the
/// loudness in the room. The volume a person actually moves is:
///
/// * the **DVC gain** (−30..0 dB, shown as 0..100 %) when Direct Volume Control
///   is on, because DVC takes the hardware keys and replaces the system slider;
/// * otherwise the **system media stream**, read and written through the native
///   `ConnectVolume` over the Connect service channel (the headless engine
///   after a reboot has that channel too, unlike MainActivity-only ones).
///
/// Where neither exists (iOS, or a test engine with no native side) it is the
/// handler's **listener volume**: a gain every track gain is multiplied by, so
/// ReplayGain, a crossfade or the next load no longer overwrite it. iOS offers
/// no public way to set the system volume, so this is the best it has.
///
/// The class takes small function seams rather than the whole `AppController`,
/// so each routing rule is a unit test.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'connect_service.dart';

/// Direct Volume Control's range: −30 dB is silence, 0 dB is full.
const double dvcMinDb = -30;

/// This phone's output volume, as 0..1.
abstract interface class ConnectDeviceVolume {
  /// The current volume, or null when there is no real value to give (the
  /// publisher then repeats the last one).
  double? read();

  /// Sets the volume; [value] is clamped to 0..1.
  Future<void> set(double value);

  /// Fires when the volume changes from outside Connect (a hardware key, the
  /// system panel). DVC gain changes are not here: they already notify through
  /// the app controller, which the state source listens to.
  Stream<void> get changes;

  /// Begins watching (and seeds the system value). Idempotent.
  Future<void> start();

  /// Stops watching. Idempotent.
  void stop();
}

class AppConnectDeviceVolume implements ConnectDeviceVolume {
  AppConnectDeviceVolume({
    required this.bridge,
    required this.dvcEnabled,
    required this.dvcGainDb,
    required this.setDvcGainDb,
    required this.legacyRead,
    required this.legacySet,
  }) {
    bridge?.onVolumeChanged = _onNative;
  }

  /// Null on a platform without the native side (iOS): player gain only.
  final ConnectServiceBridge? bridge;
  final bool Function() dvcEnabled;
  final double Function() dvcGainDb;
  final void Function(double gainDb) setDvcGainDb;

  /// The handler's listener volume: iOS today, and the answer wherever the
  /// native side is missing. Null from [legacyRead] means "no real value".
  final double? Function() legacyRead;
  final Future<void> Function(double value) legacySet;

  final _changes = StreamController<void>.broadcast(sync: true);

  /// The system media volume as last heard from native; null until seeded, and
  /// forever on a platform without it.
  double? _system;
  bool _watching = false;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  double? read() {
    if (dvcEnabled()) return ((dvcGainDb() - dvcMinDb) / -dvcMinDb).clamp(0.0, 1.0);
    return _system ?? legacyRead();
  }

  @override
  Future<void> set(double value) async {
    final v = value.isFinite ? value.clamp(0.0, 1.0) : 1.0;
    if (dvcEnabled()) {
      setDvcGainDb(dvcMinDb + -dvcMinDb * v);
      return;
    }
    if (await (bridge?.setVolume(v) ?? Future.value(false))) {
      // At once, not when native echoes it: the next state published should
      // already carry the value that was just asked for.
      _system = v;
      if (!_changes.isClosed) _changes.add(null);
      return;
    }
    await legacySet(v);
    // Nothing else in the app notices this one either. Unannounced, the next
    // state went out only at the 15 s heartbeat, so the remote's overlay
    // expired first and its slider jumped back to the old value.
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> start() async {
    if (_watching) return;
    final native = bridge;
    if (native == null) return;
    _watching = true;
    await native.watchVolume(true);
    final seeded = await native.getVolume();
    if (!_watching) return;
    if (seeded != null) {
      _system = seeded;
      // The first state of the session may already have gone out with the
      // player gain while this was in flight.
      if (!_changes.isClosed) _changes.add(null);
    }
  }

  @override
  void stop() {
    if (!_watching) return;
    _watching = false;
    unawaited(bridge?.watchVolume(false) ?? Future<void>.value());
  }

  void _onNative(double value) {
    if (_system == value) return;
    _system = value;
    if (!_changes.isClosed) _changes.add(null);
  }

  void dispose() {
    stop();
    unawaited(_changes.close());
  }
}

/// One press of a hardware volume key while this phone remote-controls another
/// device. [shownAt] makes two presses landing on the same level still two
/// events, so the HUD restarts its timer.
@immutable
class ConnectVolumeHudEvent {
  const ConnectVolumeHudEvent({
    required this.deviceName,
    required this.volume,
    required this.shownAt,
  });

  final String deviceName;

  /// 0..1, as sent to the device.
  final double volume;
  final DateTime shownAt;
}
