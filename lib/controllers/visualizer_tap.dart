/// When the native FFT/PCM tap should be running.
///
/// The tap is not free: it runs on every decoded audio buffer, computes an FFT,
/// and pushes a packet over a platform channel ~30 times a second. Whatever is
/// listening then schedules a frame for each packet, so an idle tap does not
/// merely waste its own CPU — it drives the whole render pipeline, including
/// the background blurs, at 30fps for a picture nobody asked for.
///
/// It used to be governed by a master switch that sat alongside the
/// switch for the surface that actually draws it. Two switches for one
/// thing is one too many: the master could be off while a surface was on
/// (a visualizer that silently never moved), or on while both were off (this
/// class's whole cost, invisibly, forever). The tap is now *implied* — it runs
/// exactly when some surface needs it.
///
/// Kept apart from `AppController` because the rule is pure boolean logic whose
/// failures are invisible on screen, and because the redundant-push suppression
/// below is the only thing standing between a rebuild and a platform call.
class VisualizerTap {
  /// The visualizer drawn on the player screen.
  bool playerVisual = false;

  /// Silences the tap without forgetting what the user asked for, so that
  /// backgrounding the app can stop the capture and resuming can restore it.
  bool suspended = false;

  /// A Hype Connect controller is watching this phone's visualiser. Unlike the
  /// player surface it is not on this screen, so backgrounding the app does
  /// not silence it: the phone is typically playing in a pocket while a laptop
  /// draws the spectrum. Hype Connect clears it as soon as nobody watches or
  /// playback stops.
  bool remoteVisual = false;

  /// The last value handed to [pendingPush], or null if the native side has
  /// never been told anything. Native boots in an unknown state, so the first
  /// push always happens even when it agrees with the default.
  bool? _pushed;

  /// Whether the native tap should be capturing right now.
  bool get shouldRun =>
      remoteVisual || (!suspended && playerVisual);

  /// The value to send to the native side, or null when it already agrees.
  ///
  /// Callers may invoke this as often as they like — on a setter, a rebuild, a
  /// lifecycle event — and only a genuine change crosses the platform channel.
  bool? pendingPush() {
    if (_pushed == shouldRun) return null;
    _pushed = shouldRun;
    return _pushed;
  }
}
