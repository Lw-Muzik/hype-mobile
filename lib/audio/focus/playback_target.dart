/// What the audio-focus and headset logic needs from the player, and nothing
/// more — so the policy can be driven in a test without a real handler.
abstract interface class PlaybackTarget {
  /// Whether the listener is hearing, or about to hear, music: false from the
  /// moment a pause is asked for, even while its fade is still running.
  bool get playing;

  /// [playing], changes only. Distinct, so a pause that publishes twice is one
  /// event.
  Stream<bool> get playingStream;

  /// Starts playing, asking for audio focus first.
  ///
  /// The returned future completes only when playback next pauses (it is the
  /// player's own `play()`), so never await it for sequencing.
  Future<void> play();

  /// Pauses; with [fade] false at once, with no ramp.
  Future<void> pause({bool fade = true});

  /// Sets Hype's own duck: [level] 1 is full volume, lower is quieter. Glides
  /// while playing; instant while not.
  Future<void> setDuck(double level);

  /// Pauses without a fade, then plays — for a route change that stopped the
  /// platform player behind Hype's back.
  ///
  /// Ends in [play], so like it this completes only on the next pause.
  Future<void> restartPlayback();
}
