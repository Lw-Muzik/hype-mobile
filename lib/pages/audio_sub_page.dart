/// The sub-pages of Settings → Audio, in the order the Audio page lists them.
enum AudioSubPage {
  info('Audio Info'),
  crossfade('Crossfade, Fade & Gapless'),
  replayGain('Replay Gain'),
  audioFocus('Audio Focus'),
  equalizer('Equalizer'),
  dvc('Direct Volume Control'),
  advanced('Advanced Tweaks'),
  outputs('Outputs'),
  effects('Effects');

  const AudioSubPage(this.title);
  final String title;

  /// Shown in Equalizer-only app mode (the player pages are hidden there).
  bool get inEqualizerOnlyMode => switch (this) {
        info || equalizer || dvc || advanced || effects => true,
        crossfade || replayGain || audioFocus || outputs => false,
      };
}
