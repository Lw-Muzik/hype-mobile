/// The two gains a player's volume is made of.
///
/// * The **track gain** — ReplayGain on a load, each step of a crossfade,
///   unity for a video. Rewritten all the time, by design.
/// * The **listener volume** — how loud the person wants it. On Android that
///   is the system media volume and this stays at 1; on iOS, which has no
///   public setter for the system volume, it is where a Hype Connect remote's
///   volume lands.
///
/// They used to share the one player gain, so every load and every crossfade
/// wrote over what the remote had chosen. Here the player always gets
/// `track × listener`, and each half can change without losing the other.
///
/// Generic over the player so the arithmetic is a unit test without a real
/// `AudioPlayer`.
library;

class OutputGain<P> {
  OutputGain(this._apply);

  /// Writes the combined gain to a player.
  final void Function(P player, double volume) _apply;

  // Identity-keyed: two players are never equal to each other.
  final Map<P, double> _track = Map.identity();
  double _listener = 1.0;

  /// The listener volume, 0..1.
  double get listener => _listener;

  /// [player]'s own gain, before the listener volume; unity if never set.
  double trackOf(P player) => _track[player] ?? 1.0;

  /// Sets [player]'s track gain and applies it under the listener volume.
  void setTrack(P player, double gain) {
    _track[player] = gain;
    _apply(player, gain * _listener);
  }

  /// Sets the listener volume and re-applies it to every one of [players] —
  /// all of them, so a change mid-crossfade reaches the outgoing track too.
  void setListener(double volume, Iterable<P> players) {
    _listener = volume;
    for (final player in players) {
      _apply(player, trackOf(player) * volume);
    }
  }
}
