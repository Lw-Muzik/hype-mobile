/// When a track ending on its own should start getting ready to crossfade.
///
/// Pulled out of the position listener because the timing is easy to get wrong
/// and impossible to see in a stream callback. The listener itself also sits
/// out any moment a track is being loaded or a crossfade is already under way:
/// press next near the end of a track and, for the length of that load, the
/// old track is still playing and still near its end — starting a fade out of
/// it would fade the track the user chose straight into one they did not.
///
/// Whether this boundary fades at all, and for how long, is decided by
/// `autoCrossfadeMs` in `fade_settings.dart`; this file only answers "is it
/// time yet".
library;

/// Whether a track of [duration] is long enough to crossfade out of over
/// [fadeMs]: longer than the crossfade plus five seconds. Anything shorter
/// simply ends and the next track follows.
bool crossfadeFits(Duration? duration, int fadeMs) =>
    fadeMs > 0 && duration != null && duration.inMilliseconds > fadeMs + 5000;

/// Whether to open the next track now for a crossfade of [fadeMs] that should
/// begin [fadeMs] before the end of the current one.
///
/// The next track is opened [leadMs] ahead of the fade, so a streamed track
/// that takes a moment to open still starts on time; the crossfade itself
/// waits for its moment once the track is open.
bool shouldPrepareCrossfade({
  required int fadeMs,
  required int leadMs,
  required Duration? duration,
  required Duration position,
}) {
  if (!crossfadeFits(duration, fadeMs)) return false;
  final prepareAt = duration! - Duration(milliseconds: fadeMs + leadMs);
  return position >= prepareAt;
}

/// Whether to open the next track now so it can start the instant the current
/// one ends — "Preload gapless tracks", [preloadMs] before the end.
bool shouldPrepareHandoff({
  required int preloadMs,
  required Duration? duration,
  required Duration position,
}) {
  if (preloadMs <= 0 || duration == null) return false;
  return position >= duration - Duration(milliseconds: preloadMs);
}
