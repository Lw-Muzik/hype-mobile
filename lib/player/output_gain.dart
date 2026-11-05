/// The gains a player's volume is made of, multiplied.
///
/// * The **track gain** — ReplayGain on a load, unity for a video. Set once per
///   track.
/// * The **mix** — where the player is in a crossfade: rising from 0 for the
///   incoming track, falling to 0 for the outgoing one, 1 otherwise.
/// * The **fade** — the short ramps on play, pause, stop and seek.
/// * The **listener volume** — how loud the person wants it. On Android that
///   is the system media volume and this stays at 1; on iOS, which has no
///   public setter for the system volume, it is where a Hype Connect remote's
///   volume lands.
///
/// They used to share the one player gain, so every load and every crossfade
/// step wrote over what the remote had chosen, and a crossfade step wrote over
/// ReplayGain. Here the player always gets `track × mix × fade × listener`, and
/// each part can change without losing the others — a pause can fade out a
/// track that is halfway through a crossfade, and the crossfade picks up where
/// it was when play is pressed again.
///
/// Generic over the player so the arithmetic is a unit test without a real
/// `AudioPlayer`.
library;

class OutputGain<P> {
  OutputGain(this._apply);

  /// Writes the combined gain to a player.
  final void Function(P player, double volume) _apply;

  // Identity-keyed: two players are never equal to each other.
  final Map<P, double> _applied = Map.identity();
  final Map<P, double> _track = Map.identity();
  final Map<P, double> _mix = Map.identity();
  final Map<P, double> _fade = Map.identity();
  double _listener = 1.0;

  /// The listener volume, 0..1.
  double get listener => _listener;

  /// [player]'s own gain, before everything else; unity if never set.
  double trackOf(P player) => _track[player] ?? 1.0;

  /// [player]'s crossfade gain; unity outside a crossfade.
  double mixOf(P player) => _mix[player] ?? 1.0;

  /// [player]'s play/pause/seek fade gain; unity when no fade is running.
  double fadeOf(P player) => _fade[player] ?? 1.0;

  /// What [player] is actually set to.
  double volumeOf(P player) =>
      trackOf(player) * mixOf(player) * fadeOf(player) * _listener;

  /// Sets [player]'s track gain.
  void setTrack(P player, double gain) {
    _track[player] = gain;
    _write(player);
  }

  /// Sets [player]'s crossfade gain.
  void setMix(P player, double gain) {
    _mix[player] = gain;
    _write(player);
  }

  /// Sets [player]'s play/pause/seek fade gain.
  void setFade(P player, double gain) {
    _fade[player] = gain;
    _write(player);
  }

  /// Sets the listener volume and re-applies it to every one of [players] —
  /// all of them, so a change mid-crossfade reaches the outgoing track too.
  void setListener(double volume, Iterable<P> players) {
    _listener = volume;
    for (final player in players) {
      _write(player);
    }
  }

  /// Applies [player]'s volume — unless it is already that. A fade sets a gain
  /// sixty times a second on each of two players, and a step that changes
  /// nothing (the outgoing side sitting at zero) is a platform call for
  /// nothing.
  void _write(P player) {
    final volume = volumeOf(player);
    if (_applied[player] == volume) return;
    _applied[player] = volume;
    _apply(player, volume);
  }
}
