import 'dart:async';

import 'package:flutter/foundation.dart';

/// The Replay Gain each player has been given in the native engine, in dB.
///
/// Remembered per player and sent again whenever just_audio rebuilds the player
/// under a new platform id (after a `stop()`), so the engine for the new id has
/// it too. Generic over the player, with the id, the id stream and the sender
/// injected, so it is a unit test without a real `AudioPlayer`.
class EngineTrackGain<P> {
  EngineTrackGain({
    required this.idOf,
    required this.idStream,
    required this.send,
  });

  /// The id native code knows [P] by; '' before it has one.
  final String Function(P player) idOf;

  /// Emits whenever [P]'s platform id changes (null before one exists).
  final Stream<String?> Function(P player) idStream;

  /// Sets the track gain of the engine addressed by an id.
  final Future<void> Function(String id, double dB) send;

  final Map<P, double> _db = Map.identity();
  final Map<P, Object?> _subject = Map.identity();
  final Map<P, int> _seq = Map.identity();
  final Map<P, StreamSubscription<String?>> _subs = Map.identity();

  /// Gives [player] a gain of [dB], sent now and on every new id. [subject] is
  /// whatever the gain was worked out for (a song), kept for a later re-gain.
  void set(P player, double dB, {Object? subject}) {
    _db[player] = dB;
    _subject[player] = subject;
    _seq[player] = (_seq[player] ?? 0) + 1;
    _subs.putIfAbsent(player, () {
      return idStream(player).listen((id) {
        if (id == null || id.isEmpty) return;
        _send(player);
      });
    });
    _send(player);
  }

  /// The gain last given to [player]; 0 if never set.
  double dbOf(P player) => _db[player] ?? 0.0;

  /// What [player]'s gain was worked out for, if it was said.
  Object? subjectOf(P player) => _subject[player];

  /// Counts the gains given to [player]; changes whenever one is set.
  int seqOf(P player) => _seq[player] ?? 0;

  void _send(P player) {
    final id = idOf(player);
    if (id.isEmpty) return;
    unawaited(
      send(id, dbOf(player)).catchError((Object e) {
        debugPrint('dspSetTrackGainDb: $e');
      }),
    );
  }
}
