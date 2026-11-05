import 'dart:async';

import 'package:eq_app/services/volume_feed.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late StreamController<double> volume;
  late StreamController<bool> playingStream;
  late bool playing;
  late bool visible;
  late bool enabled;
  late List<String> calls;
  late PauseOnVolume sut;

  setUp(() {
    volume = StreamController<double>.broadcast();
    playingStream = StreamController<bool>.broadcast();
    playing = true;
    visible = true;
    enabled = true;
    calls = [];
    sut = PauseOnVolume(
      volume: volume.stream,
      playingChanges: playingStream.stream,
      isPlaying: () => playing,
      enabled: () => enabled,
      visible: () => visible,
      pause: () async {
        calls.add('pause');
        playing = false;
        playingStream.add(false);
      },
      play: () async {
        calls.add('play');
        playing = true;
        playingStream.add(true);
      },
    )..start(initial: 0.5);
  });

  tearDown(() {
    sut.dispose();
    volume.close();
    playingStream.close();
  });

  Future<void> send(double v) async {
    volume.add(v);
    await Future<void>.delayed(Duration.zero);
  }

  test('pauses at 0 and resumes when raised while visible', () async {
    await send(0);
    expect(calls, ['pause']);
    await send(0.2);
    expect(calls, ['pause', 'play']);
  });

  test('does not resume while the UI and notification are hidden', () async {
    await send(0);
    visible = false;
    await send(0.2);
    expect(calls, ['pause']);
  });

  test(
    'a listener play clears the mark so a later raise does nothing',
    () async {
      await send(0);
      // The listener starts music themselves, then pauses it.
      playing = true;
      playingStream.add(true);
      playing = false;
      playingStream.add(false);
      await Future<void>.delayed(Duration.zero);
      await send(0.2);
      expect(calls, ['pause']);
    },
  );

  test('never resumes music the listener paused before volume hit 0', () async {
    playing = false;
    await send(0);
    await send(0.3);
    expect(calls, isEmpty);
  });

  test('does nothing when the setting is off', () async {
    enabled = false;
    await send(0);
    expect(calls, isEmpty);
  });
}
