/// Two gains, multiplied: the track's and the listener's.
///
/// The track gain is rewritten all the time — ReplayGain on every load, twenty
/// steps of every crossfade, unity for a video. The listener's volume is what
/// a Hype Connect remote sets on a phone with no system-volume bridge (iOS).
/// When both lived in the one player gain, every load and every crossfade wiped
/// what the remote had chosen; this file is about that not happening.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/player/output_gain.dart';

void main() {
  late Map<String, double> applied;
  late OutputGain<String> gain;

  setUp(() {
    applied = {};
    gain = OutputGain<String>((player, volume) => applied[player] = volume);
  });

  test('starts at unity with nothing applied', () {
    expect(gain.listener, 1.0);
    expect(gain.trackOf('a'), 1.0);
    expect(applied, isEmpty);
  });

  test('a track gain is applied scaled by the listener volume', () {
    gain.setListener(0.5, const ['a', 'b']);
    gain.setTrack('a', 0.8);
    expect(applied['a'], closeTo(0.4, 1e-9));
    expect(gain.trackOf('a'), 0.8, reason: 'the track gain is kept unscaled');
  });

  test('a new track keeps the listener volume (the bug)', () {
    gain.setTrack('a', 1.0);
    gain.setListener(0.3, const ['a', 'b']);
    expect(applied['a'], closeTo(0.3, 1e-9));
    // The next track loads at unity, as every load does.
    gain.setTrack('a', 1.0);
    expect(applied['a'], closeTo(0.3, 1e-9));
  });

  test('a crossfade ramps both players under the listener volume', () {
    gain.setTrack('a', 1.0);
    gain.setListener(0.5, const ['a', 'b']);
    gain.setTrack('b', 0.0);
    // Halfway through the fade.
    gain.setTrack('a', gain.trackOf('a') * 0.5);
    gain.setTrack('b', 1.0 * 0.5);
    expect(applied['a'], closeTo(0.25, 1e-9));
    expect(applied['b'], closeTo(0.25, 1e-9));
    // The fade ends: the incoming player snaps to its gain.
    gain.setTrack('b', 1.0);
    expect(applied['b'], closeTo(0.5, 1e-9));
  });

  test('changing the listener volume re-applies every player at its gain', () {
    gain.setTrack('a', 0.6);
    gain.setTrack('b', 0.2);
    gain.setListener(0.5, const ['a', 'b']);
    expect(applied['a'], closeTo(0.3, 1e-9));
    expect(applied['b'], closeTo(0.1, 1e-9));
  });

  test('a player never given a track gain is re-applied at unity', () {
    gain.setListener(0.7, const ['a']);
    expect(applied['a'], closeTo(0.7, 1e-9));
  });
}
