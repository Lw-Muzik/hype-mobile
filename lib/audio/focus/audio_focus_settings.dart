import 'package:shared_preferences/shared_preferences.dart';

/// The Audio Focus settings, saved in the preferences.
class AudioFocusSettings {
  const AudioFocusSettings({
    this.resumeAfterCall = true,
    this.resumeOnStart = false,
    this.resumeOnReopen = false,
    this.shortFocusChange = true,
    this.pauseInCall = true,
    this.resumeOnFocusGain = true,
    this.duckVolume = true,
    this.permanentFocusChange = true,
  });

  final bool resumeAfterCall;
  final bool resumeOnStart;
  final bool resumeOnReopen;
  final bool shortFocusChange;
  final bool pauseInCall;
  final bool resumeOnFocusGain;
  final bool duckVolume;
  final bool permanentFocusChange;

  /// A call pauses playback when either switch asks for it: a short focus
  /// change already covers calls.
  bool get effectivePauseInCall => shortFocusChange || pauseInCall;

  static const _kResumeAfterCall = 'afResumeAfterCall';
  static const _kResumeOnStart = 'afResumeOnStart';
  static const _kResumeOnReopen = 'afResumeOnReopen';
  static const _kShortFocusChange = 'afShortFocusChange';
  static const _kPauseInCall = 'afPauseInCall';
  static const _kResumeOnFocusGain = 'afResumeOnFocusGain';
  static const _kDuckVolume = 'afDuckVolume';
  static const _kPermanentFocusChange = 'afPermanentFocusChange';

  AudioFocusSettings copyWith({
    bool? resumeAfterCall,
    bool? resumeOnStart,
    bool? resumeOnReopen,
    bool? shortFocusChange,
    bool? pauseInCall,
    bool? resumeOnFocusGain,
    bool? duckVolume,
    bool? permanentFocusChange,
  }) => AudioFocusSettings(
    resumeAfterCall: resumeAfterCall ?? this.resumeAfterCall,
    resumeOnStart: resumeOnStart ?? this.resumeOnStart,
    resumeOnReopen: resumeOnReopen ?? this.resumeOnReopen,
    shortFocusChange: shortFocusChange ?? this.shortFocusChange,
    pauseInCall: pauseInCall ?? this.pauseInCall,
    resumeOnFocusGain: resumeOnFocusGain ?? this.resumeOnFocusGain,
    duckVolume: duckVolume ?? this.duckVolume,
    permanentFocusChange: permanentFocusChange ?? this.permanentFocusChange,
  );

  static AudioFocusSettings load(SharedPreferences prefs) {
    const d = AudioFocusSettings();
    return AudioFocusSettings(
      resumeAfterCall: prefs.getBool(_kResumeAfterCall) ?? d.resumeAfterCall,
      resumeOnStart: prefs.getBool(_kResumeOnStart) ?? d.resumeOnStart,
      resumeOnReopen: prefs.getBool(_kResumeOnReopen) ?? d.resumeOnReopen,
      shortFocusChange:
          prefs.getBool(_kShortFocusChange) ?? d.shortFocusChange,
      pauseInCall: prefs.getBool(_kPauseInCall) ?? d.pauseInCall,
      resumeOnFocusGain:
          prefs.getBool(_kResumeOnFocusGain) ?? d.resumeOnFocusGain,
      duckVolume: prefs.getBool(_kDuckVolume) ?? d.duckVolume,
      permanentFocusChange:
          prefs.getBool(_kPermanentFocusChange) ?? d.permanentFocusChange,
    );
  }

  Future<void> save(SharedPreferences prefs) async {
    await prefs.setBool(_kResumeAfterCall, resumeAfterCall);
    await prefs.setBool(_kResumeOnStart, resumeOnStart);
    await prefs.setBool(_kResumeOnReopen, resumeOnReopen);
    await prefs.setBool(_kShortFocusChange, shortFocusChange);
    await prefs.setBool(_kPauseInCall, pauseInCall);
    await prefs.setBool(_kResumeOnFocusGain, resumeOnFocusGain);
    await prefs.setBool(_kDuckVolume, duckVolume);
    await prefs.setBool(_kPermanentFocusChange, permanentFocusChange);
  }

  @override
  bool operator ==(Object other) =>
      other is AudioFocusSettings &&
      other.resumeAfterCall == resumeAfterCall &&
      other.resumeOnStart == resumeOnStart &&
      other.resumeOnReopen == resumeOnReopen &&
      other.shortFocusChange == shortFocusChange &&
      other.pauseInCall == pauseInCall &&
      other.resumeOnFocusGain == resumeOnFocusGain &&
      other.duckVolume == duckVolume &&
      other.permanentFocusChange == permanentFocusChange;

  @override
  int get hashCode => Object.hash(
    resumeAfterCall,
    resumeOnStart,
    resumeOnReopen,
    shortFocusChange,
    pauseInCall,
    resumeOnFocusGain,
    duckVolume,
    permanentFocusChange,
  );
}
