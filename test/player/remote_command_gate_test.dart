/// The gate in front of the audio handler: every command that reaches Hype
/// from outside (headset, Bluetooth, notification, lock screen) is resolved
/// against Strict and the Bluetooth grace window before it does anything.
library;

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

import 'package:eq_app/audio/headset/headset_settings.dart';
import 'package:eq_app/player/remote_command_gate.dart';
import 'package:eq_app/player/remote_commands.dart';

class _Inner extends BaseAudioHandler {
  _Inner({required bool playing}) {
    playbackState.add(PlaybackState(playing: playing));
  }

  final calls = <String>[];

  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> skipToNext() async => calls.add('next');
  @override
  Future<void> skipToPrevious() async => calls.add('previous');
  @override
  Future<void> seek(Duration position) async => calls.add('seek');
  @override
  Future<void> fastForward() async => calls.add('fastForward');
  @override
  Future<void> rewind() async => calls.add('rewind');
  @override
  Future<void> seekForward(bool begin) async => calls.add('seekForward');
  @override
  Future<void> seekBackward(bool begin) async => calls.add('seekBackward');
  @override
  Future<void> skipToQueueItem(int index) async => calls.add('queueItem');
  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async =>
      calls.add('repeat:${repeatMode.name}');
  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async =>
      calls.add('shuffle:${shuffleMode.name}');
}

class _NeverEndingPlay extends _Inner {
  _NeverEndingPlay({required super.playing});

  @override
  Future<void> play() {
    calls.add('play');
    return Completer<void>().future;
  }
}

void main() {
  late _Inner inner;
  late RemoteCommandGate gate;
  var now = 10000;

  void build({required bool playing, bool strict = true}) {
    inner = _Inner(playing: playing);
    gate = RemoteCommandGate(inner, nowMs: () => now)
      ..settings = HeadsetSettings(strictCommands: strict);
  }

  setUp(() => now = 10000);

  group('strict', () {
    test('play while playing is ignored; pause pauses', () async {
      build(playing: true);
      await gate.play();
      expect(inner.calls, isEmpty);
      await gate.pause();
      expect(inner.calls, ['pause']);
    });

    test('paused: stop still stops (it closes the notification)', () async {
      build(playing: false);
      await gate.stop();
      expect(inner.calls, ['stop']);
    });

    test('paused: play plays', () async {
      build(playing: false);
      await gate.play();
      expect(inner.calls, ['play']);
    });

    test('playing: stop stops', () async {
      build(playing: true);
      await gate.stop();
      expect(inner.calls, ['stop']);
    });
  });

  group('strict off', () {
    test('play while playing toggles to pause', () async {
      build(playing: true, strict: false);
      await gate.play();
      expect(inner.calls, ['pause']);
    });

    test('paused: pause plays, but stop stops and never plays', () async {
      build(playing: false, strict: false);
      await gate.pause();
      expect(inner.calls, ['play']);
      await gate.stop();
      expect(inner.calls, ['play', 'stop']);
    });
  });

  group('click', () {
    test('toggles by state', () async {
      build(playing: true);
      await gate.click();
      expect(inner.calls, ['pause']);
      build(playing: false);
      await gate.click();
      expect(inner.calls, ['play']);
    });

    test('next and previous buttons skip', () async {
      build(playing: true);
      await gate.click(MediaButton.next);
      await gate.click(MediaButton.previous);
      expect(inner.calls, ['next', 'previous']);
    });
  });

  group('bluetooth grace', () {
    setUp(() {
      build(playing: true);
      gate.settings = const HeadsetSettings(ignoreBluetoothCommandsS: 1);
      gate.bluetoothConnectedAtMs = 9500;
    });

    test('drops transport commands inside the window', () async {
      await gate.skipToNext();
      expect(inner.calls, isEmpty);
    });

    test('a wired key is not dropped; a Bluetooth one is', () async {
      expect(await gate.execute(RemoteCommand.next, bluetooth: false), isTrue);
      expect(inner.calls, ['next']);
      expect(await gate.execute(RemoteCommand.next, bluetooth: true), isFalse);
      expect(inner.calls, ['next']);
    });

    test('is over after the configured seconds', () async {
      now = 10500;
      await gate.skipToNext();
      expect(inner.calls, ['next']);
    });

    test('skipToPrevious is dropped too', () async {
      await gate.skipToPrevious();
      expect(inner.calls, isEmpty);
    });

    test('stop is dropped inside the window, and works after it', () async {
      await gate.stop();
      expect(inner.calls, isEmpty);
      now = 10500;
      await gate.stop();
      expect(inner.calls, ['stop']);
    });

    test('seeks and queue jumps are dropped too, then work', () async {
      Future<void> all() async {
        await gate.seek(const Duration(seconds: 3));
        await gate.fastForward();
        await gate.rewind();
        await gate.seekForward(true);
        await gate.seekBackward(true);
        await gate.skipToQueueItem(2);
      }

      await all();
      expect(inner.calls, isEmpty);
      now = 10500;
      await all();
      expect(inner.calls, [
        'seek',
        'fastForward',
        'rewind',
        'seekForward',
        'seekBackward',
        'queueItem',
      ]);
    });
  });

  test('execute answers without waiting for a play to finish', () async {
    // A real play() completes only when playback next pauses.
    final inner = _NeverEndingPlay(playing: false);
    final gate = RemoteCommandGate(inner, nowMs: () => now);
    final acted = await gate
        .execute(RemoteCommand.play, bluetooth: false)
        .timeout(const Duration(seconds: 2));
    expect(acted, isTrue);
    expect(inner.calls, ['play']);
  });

  group('repeat and shuffle', () {
    test(
      'remote repeat group becomes repeat-all, through the callback',
      () async {
        build(playing: true);
        final seen = <LoopMode>[];
        gate.onRemoteRepeat = seen.add;
        await gate.setRepeatMode(AudioServiceRepeatMode.group);
        expect(seen, [LoopMode.all]);
        expect(inner.calls, ['repeat:group']);
      },
    );

    test('ignored when Ignore repeat/shuffle is on', () async {
      build(playing: true);
      gate.settings = const HeadsetSettings(ignoreRepeatShuffle: true);
      final repeat = <LoopMode>[];
      final shuffle = <bool>[];
      gate.onRemoteRepeat = repeat.add;
      gate.onRemoteShuffle = shuffle.add;
      await gate.setRepeatMode(AudioServiceRepeatMode.all);
      await gate.setShuffleMode(AudioServiceShuffleMode.all);
      expect(repeat, isEmpty);
      expect(shuffle, isEmpty);
    });

    test('remote shuffle all turns shuffle on', () async {
      build(playing: true);
      final seen = <bool>[];
      gate.onRemoteShuffle = seen.add;
      await gate.setShuffleMode(AudioServiceShuffleMode.all);
      expect(seen, [true]);
      await gate.setShuffleMode(AudioServiceShuffleMode.none);
      expect(seen, [true, false]);
    });
  });
}
