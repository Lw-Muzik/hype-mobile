import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../audio/eq/autoeq_suggest.dart';
import '../audio/headset/output_kind.dart';
import '../models/speaker_profile.dart';

/// Offers an AutoEq headphone preset when a Bluetooth or USB output connects.
class AutoEqSuggestions {
  AutoEqSuggestions({
    required this.enabled,
    required this.systemWide,
    required this.activeProfile,
    required this.apply,
    required this.profiles,
    required this.prefs,
    required this.navigatorKey,
    this.onApplied,
    this.devices,
    this.initialDevices,
    this.nextFrame,
  });

  final bool Function() enabled;
  final bool Function() systemWide;
  final String? Function() activeProfile;
  final Future<void> Function(String profileName) apply;

  /// Told after a profile was applied for a device, so it can be bound to
  /// that device (see `OutputProfiles`).
  final void Function(String profileName, OutputDeviceEvent device)? onApplied;
  final Future<List<SpeakerProfile>> Function() profiles;
  final SharedPreferences prefs;
  final GlobalKey<NavigatorState> navigatorKey;
  final Stream<OutputDeviceEvent>? devices;

  /// Outputs already connected when [start] runs (defaults to the session's).
  final Future<List<OutputDeviceEvent>> Function()? initialDevices;

  /// Waits for the next frame while no navigator exists yet (a headset already
  /// connected at launch). Injectable for tests.
  final Future<void> Function()? nextFrame;

  /// How many frames a launch-time suggestion waits for the navigator.
  static const _maxFrameWaits = 10;

  Future<void> _defaultNextFrame() async {
    try {
      // A headless engine (the background service) may never draw a frame, so
      // each wait is bounded rather than left hanging.
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(seconds: 1),
        onTimeout: () {},
      );
    } catch (_) {}
  }

  final Set<String> _asked = {};
  StreamSubscription<OutputDeviceEvent>? _sub;
  bool _showing = false;

  Future<void> start() async {
    if (_sub != null) return;
    _sub = (devices ?? await _sessionDevices()).listen(
      (e) => unawaited(_onDevice(e)),
      onError: (_) {},
    );
    try {
      for (final e in await (initialDevices ?? _currentDevices)()) {
        await _onDevice(e);
      }
    } catch (e) {
      debugPrint('AutoEq initial devices failed: $e');
    }
  }

  Future<List<OutputDeviceEvent>> _currentDevices() async {
    final session = await AudioSession.instance;
    final all = await session.getDevices(includeInputs: false);
    return all
        // ignore: experimental_member_use
        .map((d) => OutputDeviceEvent(name: d.name, kind: outputKindOf(d.type)))
        .where(_isHeadphoneKind)
        .toList();
  }

  Future<Stream<OutputDeviceEvent>> _sessionDevices() async {
    final session = await AudioSession.instance;
    return session.devicesChangedEventStream.expand(
      (change) => change.devicesAdded
          .where((d) => d.isOutput)
          // ignore: experimental_member_use
          .map(
            (d) => OutputDeviceEvent(name: d.name, kind: outputKindOf(d.type)),
          )
          .where(_isHeadphoneKind),
    );
  }

  static bool _isHeadphoneKind(OutputDeviceEvent e) =>
      e.kind == AudioOutputKind.bluetooth || e.kind == AudioOutputKind.usb;

  Future<void> _onDevice(OutputDeviceEvent e) async {
    var waits = 0;
    late final SpeakerProfile match;
    late final BuildContext context;
    while (true) {
      if (_showing) return;
      final list = await profiles();
      if (_showing) return;
      final found = autoEqSuggestion(
        device: e,
        enabled: enabled(),
        systemWide: systemWide(),
        dismissed: AutoEqDismissals.load(prefs),
        askedThisSession: _asked,
        activeProfile: activeProfile(),
        profiles: list,
      );
      if (found == null) return;
      final ctx = navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        match = found;
        context = ctx;
        break;
      }
      // No navigator yet: park the event and look again after a frame. Not
      // marked asked until it is shown. Gives up silently when none appears.
      if (++waits > _maxFrameWaits) return;
      await (nextFrame ?? _defaultNextFrame)();
    }
    _asked.add(normaliseDeviceName(e.name));
    _showing = true;
    try {
      final choice = await showDialog<_Choice>(
        // Checked mounted in the loop above with no await since.
        // ignore: use_build_context_synchronously
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Tune for these headphones?'),
          content: Text(
            '${e.name} connected. Apply the "${match.name}" AutoEq preset?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, _Choice.never),
              child: const Text("Don't ask for this device"),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, _Choice.later),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, _Choice.apply),
              child: const Text('Apply'),
            ),
          ],
        ),
      );
      if (choice == _Choice.apply) {
        try {
          await apply(match.name);
          onApplied?.call(match.name, e);
        } catch (err) {
          debugPrint('AutoEq apply failed: $err');
        }
      } else if (choice == _Choice.never) {
        await AutoEqDismissals.add(prefs, e.name);
      }
    } finally {
      _showing = false;
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }
}

enum _Choice { apply, later, never }
