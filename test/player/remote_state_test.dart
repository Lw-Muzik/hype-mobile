/// What Hype tells the lock screen and Bluetooth displays about repeat and
/// shuffle, and which of those controls it offers.
library;

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

import 'package:eq_app/helpers/audio_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('publishes shuffle and repeat and offers both controls', () async {
    final handler = HypeAudioHandler();
    handler.shuffleEnabled = true;
    handler.bindPlaybackEvents(Stream.value(PlaybackEvent()));
    await pumpEventQueue();

    final state = handler.playbackState.value;
    expect(state.shuffleMode, AudioServiceShuffleMode.all);
    expect(state.repeatMode, AudioServiceRepeatMode.none);
    expect(state.systemActions, contains(MediaAction.setRepeatMode));
    expect(state.systemActions, contains(MediaAction.setShuffleMode));
  });

  test(
    'changing shuffle republishes without waiting for a player event',
    () async {
      final handler = HypeAudioHandler();
      handler.bindPlaybackEvents(Stream.value(PlaybackEvent()));
      await pumpEventQueue();
      expect(
        handler.playbackState.value.shuffleMode,
        AudioServiceShuffleMode.none,
      );

      handler.shuffleEnabled = true;
      expect(
        handler.playbackState.value.shuffleMode,
        AudioServiceShuffleMode.all,
      );
      handler.shuffleEnabled = false;
      expect(
        handler.playbackState.value.shuffleMode,
        AudioServiceShuffleMode.none,
      );
    },
  );

  test('repeat mode is published and republished on a change', () async {
    final handler = HypeAudioHandler();
    handler.bindPlaybackEvents(Stream.value(PlaybackEvent()));
    await pumpEventQueue();

    // No platform behind the players in a test: the mode is kept and
    // republished even though the platform call has nobody to answer it.
    handler.setLoopMode(LoopMode.all).ignore();
    await pumpEventQueue();
    expect(handler.loopMode, LoopMode.all);
    expect(handler.playbackState.value.repeatMode, AudioServiceRepeatMode.all);
  });
}
