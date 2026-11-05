import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:eq_app/audio/focus/audio_focus_settings.dart';
import 'package:eq_app/audio/focus/playback_target.dart';
import 'package:eq_app/services/audio_focus_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Target implements PlaybackTarget {
  final calls = <String>[];
  bool _playing = true;
  final _changes = StreamController<bool>.broadcast();

  @override
  bool get playing => _playing;

  @override
  Stream<bool> get playingStream => _changes.stream;

  @override
  Future<void> play() {
    calls.add('play');
    _playing = true;
    _changes.add(true);
    return Completer<void>().future;
  }

  @override
  Future<void> pause({bool fade = true}) async {
    calls.add('pause');
    _playing = false;
    _changes.add(false);
  }

  @override
  Future<void> setDuck(double level) async => calls.add('duck($level)');

  @override
  Future<void> restartPlayback() => Completer<void>().future;
}

void main() {
  late _Target target;
  late StreamController<AudioInterruptionEvent> events;
  var noDuck = false;
  var ignoreFocus = false;

  setUp(() {
    target = _Target();
    events = StreamController<AudioInterruptionEvent>.broadcast();
    noDuck = false;
    ignoreFocus = false;
    AudioFocusService(
      target: target,
      settings: () => const AudioFocusSettings(),
      hasSession: () => true,
      canResume: () => true,
      isIos: false,
      interruptions: events.stream,
      requestFocus: () async => true,
      noDuck: () => noDuck,
      ignoreFocus: () => ignoreFocus,
    ).start();
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 10));

  test('a duckable loss ducks by default', () async {
    events.add(AudioInterruptionEvent(true, AudioInterruptionType.duck));
    await settle();
    expect(target.calls, ['duck(0.25)']);
  });

  test('No Duck pauses instead, and resumes on gain', () async {
    noDuck = true;
    events.add(AudioInterruptionEvent(true, AudioInterruptionType.duck));
    await settle();
    expect(target.calls, ['pause']);
    events.add(AudioInterruptionEvent(false, AudioInterruptionType.duck));
    await settle();
    expect(target.calls, ['pause', 'play']);
  });

  test('Ignore audio focus ignores a loss', () async {
    ignoreFocus = true;
    events.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
    await settle();
    events.add(AudioInterruptionEvent(true, AudioInterruptionType.duck));
    await settle();
    expect(target.calls, isEmpty);
  });

  test(
    'the flags are read at each event, so a route change takes effect',
    () async {
      events.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await settle();
      expect(target.calls, ['pause']);
      events.add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
      await settle();
      ignoreFocus = true;
      events.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await settle();
      expect(target.calls, ['pause', 'play']);
    },
  );
}
