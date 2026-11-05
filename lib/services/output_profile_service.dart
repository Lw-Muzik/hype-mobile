// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio/output/output_profiles.dart';

/// Follows the active output and applies its profile.
///
/// On every route change it resolves the profile (a named device's, else its
/// kind's) and carries it out: the EQ preset once for that route, the AutoEq
/// profile bound to the device, and the flags through [onEffective]. The flags
/// are not kept anywhere here: the profile of the route now active is the
/// truth, so going back to an earlier route reverts them by itself.
///
/// The preset is applied when a route becomes active. On a route that stays
/// active, a changed assignment is applied only when the listener has not
/// edited the curve since (`curveEdited`), so the profile never fights the
/// listener's own changes.
class OutputProfileService {
  OutputProfileService({
    required OutputProfiles Function() profiles,
    required Future<ActiveRoute> Function() readRoute,
    required Stream<void> routeEvents,
    required void Function(String preset) applyEqPreset,
    required bool Function() curveEdited,
    required Future<void> Function(String name) applySpeakerProfile,
    required Future<void> Function() clearSpeakerProfile,
    required String? Function() activeSpeakerProfile,
    required void Function(OutputProfile profile, ActiveRoute route)
    onEffective,
    required void Function(ActiveRoute route) onRoute,

    /// Called before the new route's preset is applied, so the curve of the
    /// route being left can still be kept.
    void Function(ActiveRoute? previous, ActiveRoute next)? beforeRouteChange,

    /// The route last seen by the previous run: its preset is not applied
    /// again at launch, which would undo the listener's last edit.
    String? lastRouteKey,

    /// How long a route change settles before the route is read, so a
    /// Bluetooth connect has switched by then.
    this.settle = const Duration(milliseconds: 400),
  }) : _profiles = profiles,
       _readRoute = readRoute,
       _routeEvents = routeEvents,
       _applyEqPreset = applyEqPreset,
       _curveEdited = curveEdited,
       _applySpeaker = applySpeakerProfile,
       _clearSpeaker = clearSpeakerProfile,
       _activeSpeaker = activeSpeakerProfile,
       _onEffective = onEffective,
       _onRoute = onRoute,
       _beforeRouteChange = beforeRouteChange,
       _lastRouteKey = lastRouteKey;

  final OutputProfiles Function() _profiles;
  final Future<ActiveRoute> Function() _readRoute;
  final Stream<void> _routeEvents;
  final void Function(String preset) _applyEqPreset;
  final bool Function() _curveEdited;
  final Future<void> Function(String name) _applySpeaker;
  final Future<void> Function() _clearSpeaker;
  final String? Function() _activeSpeaker;
  final void Function(OutputProfile profile, ActiveRoute route) _onEffective;
  final void Function(ActiveRoute route) _onRoute;
  final void Function(ActiveRoute? previous, ActiveRoute next)?
  _beforeRouteChange;
  final Duration settle;

  String? _lastRouteKey;
  StreamSubscription<void>? _sub;
  Timer? _settleTimer;
  bool _disposed = false;
  Future<void> _queue = Future<void>.value();

  /// The route in use, once read.
  ActiveRoute? route;

  /// The profile of [route].
  OutputProfile effective = const OutputProfile();

  String? _appliedPreset;
  String? _boundAutoEq;

  /// Reads the route now, then follows changes.
  Future<void> start() async {
    if (_sub != null) return;
    _sub = _routeEvents.listen(
      (_) => _schedule(),
      onError: (Object e) => debugPrint('Output route stream: $e'),
    );
    await refresh(atLaunch: true);
  }

  void _schedule() {
    if (_disposed) return;
    if (settle == Duration.zero) {
      unawaited(refresh());
      return;
    }
    _settleTimer?.cancel();
    _settleTimer = Timer(settle, () => unawaited(refresh()));
  }

  /// Reads the route and applies what changed. Also the way to say the
  /// profiles were edited.
  Future<void> refresh({bool atLaunch = false}) {
    final run = _queue.then((_) => _refresh(atLaunch));
    _queue = run.catchError((Object _) {});
    return run;
  }

  Future<void> _refresh(bool atLaunch) async {
    if (_disposed) return;
    final ActiveRoute next;
    try {
      next = await _readRoute();
    } catch (e) {
      debugPrint('Reading the output route failed: $e');
      return;
    }
    if (_disposed) return;
    final prev = route;
    final changed = prev == null || prev.key != next.key;
    final profile = resolveProfile(
      _profiles(),
      kind: next.kind,
      deviceName: next.deviceName,
    );
    final previousProfile = effective;
    final previousBound = _boundAutoEq;

    // The launch route counts as "seen" when it is the one the last run ended
    // on: its preset is the listener's own curve by now.
    final seenAtLaunch = atLaunch && _lastRouteKey == next.key;

    if (changed) {
      if (!seenAtLaunch) _beforeRouteChange?.call(prev, next);
      route = next;
      _lastRouteKey = next.key;
      _onRoute(next);
    }
    effective = profile;

    final preset = profile.eqPreset;
    if (preset != null) {
      final newlyActive = changed && !seenAtLaunch;
      final reassigned = !changed && preset != _appliedPreset;
      if (newlyActive || (reassigned && !_curveEdited())) {
        _applyEqPreset(preset);
        _appliedPreset = preset;
      } else if (changed && seenAtLaunch) {
        _appliedPreset = preset;
      }
    } else if (changed) {
      _appliedPreset = null;
    }

    await _syncAutoEq(profile, previousProfile, previousBound, changed);
    if (changed || profile != previousProfile) _onEffective(profile, next);
  }

  /// The AutoEq profile bound to the device: applied on arrival; cleared on
  /// leaving only if it is still the one that was bound.
  Future<void> _syncAutoEq(
    OutputProfile profile,
    OutputProfile previous,
    String? previousBound,
    bool changed,
  ) async {
    final target = profile.autoEq;
    try {
      if (target != null) {
        if (_activeSpeaker() != target) await _applySpeaker(target);
        _boundAutoEq = target;
      } else if (changed && previousBound != null) {
        if (_activeSpeaker() == previousBound) await _clearSpeaker();
        _boundAutoEq = null;
      } else if (changed) {
        _boundAutoEq = null;
      }
    } catch (e) {
      debugPrint('Output AutoEq profile failed: $e');
    }
  }

  void dispose() {
    _disposed = true;
    _settleTimer?.cancel();
    unawaited(_sub?.cancel());
    _sub = null;
  }
}
