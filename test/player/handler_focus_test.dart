/// The handler's side of audio focus: it asks before it plays, and a pause
/// that lands while it is still asking wins.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/helpers/audio_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a pause between the request and the grant leaves the player stopped',
    () async {
      final handler = HypeAudioHandler();
      final grant = Completer<bool>();
      var asked = 0;
      handler.onActivateSession = () {
        asked++;
        return grant.future;
      };

      handler.startPlayback();
      await pumpEventQueue();
      expect(asked, 1);
      expect(
        handler.player.playing,
        isFalse,
        reason: 'not until it is granted',
      );

      await handler.pause();
      grant.complete(true);
      await pumpEventQueue();

      expect(handler.player.playing, isFalse);
    },
  );

  test('a denied request plays nothing', () async {
    final handler = HypeAudioHandler();
    handler.onActivateSession = () async => false;

    handler.startPlayback();
    await pumpEventQueue();
    expect(handler.player.playing, isFalse);

    await handler.play();
    expect(handler.player.playing, isFalse);
  });

  test(
    'a request that throws counts as a denial, with no stray error',
    () async {
      final handler = HypeAudioHandler();
      handler.onActivateSession = () async => throw StateError('setActive');

      handler.startPlayback();
      await pumpEventQueue();
      expect(handler.player.playing, isFalse);

      await handler.play();
      expect(handler.player.playing, isFalse);
    },
  );

  test('play() asks, and a pause while it asks supersedes it', () async {
    final handler = HypeAudioHandler();
    final grant = Completer<bool>();
    var asked = 0;
    handler.onActivateSession = () {
      asked++;
      return grant.future;
    };

    final playing = handler.play();
    await pumpEventQueue();
    expect(asked, 1);

    await handler.pause();
    grant.complete(true);
    await playing;

    expect(handler.player.playing, isFalse);
  });

  group('duck', () {
    test('is clamped and instant while not playing', () async {
      final handler = HypeAudioHandler();
      expect(handler.duckLevel, 1.0);
      await handler.setDuck(0.25);
      expect(handler.duckLevel, 0.25);
      await handler.setDuck(-1);
      expect(handler.duckLevel, 0.0);
      await handler.setDuck(7);
      expect(handler.duckLevel, 1.0);
    });
  });

  test('playing is false and playingStream is distinct', () async {
    final handler = HypeAudioHandler();
    expect(handler.playing, isFalse);
    final seen = <bool>[];
    final sub = handler.playingStream.listen(seen.add);
    handler.shuffleEnabled = true; // republishes the same playing=false
    handler.shuffleEnabled = false;
    await pumpEventQueue();
    await sub.cancel();
    expect(seen.where((p) => p), isEmpty);
    expect(seen.length, lessThanOrEqualTo(1));
  });
}
