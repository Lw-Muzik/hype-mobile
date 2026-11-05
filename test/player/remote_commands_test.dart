import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eq_app/player/remote_commands.dart';
import 'package:just_audio/just_audio.dart';

RemoteCommand? r(
  RemoteCommand c,
  bool playing,
  bool strict, {
  bool grace = false,
}) => resolveRemoteCommand(
  c,
  playing: playing,
  strict: strict,
  inBluetoothGrace: grace,
);

void main() {
  group('resolveRemoteCommand', () {
    test('play', () {
      expect(r(RemoteCommand.play, true, true), isNull);
      expect(r(RemoteCommand.play, true, false), RemoteCommand.pause);
      expect(r(RemoteCommand.play, false, true), RemoteCommand.play);
      expect(r(RemoteCommand.play, false, false), RemoteCommand.play);
    });
    test('pause', () {
      expect(r(RemoteCommand.pause, false, true), isNull);
      expect(r(RemoteCommand.pause, false, false), RemoteCommand.play);
      expect(r(RemoteCommand.pause, true, true), RemoteCommand.pause);
      expect(r(RemoteCommand.pause, true, false), RemoteCommand.pause);
    });
    test('stop', () {
      expect(r(RemoteCommand.stop, false, true), isNull);
      expect(r(RemoteCommand.stop, false, false), RemoteCommand.play);
      expect(r(RemoteCommand.stop, true, true), RemoteCommand.stop);
      expect(r(RemoteCommand.stop, true, false), RemoteCommand.stop);
    });
    test('toggle', () {
      for (final s in [true, false]) {
        expect(r(RemoteCommand.toggle, true, s), RemoteCommand.pause);
        expect(r(RemoteCommand.toggle, false, s), RemoteCommand.play);
      }
    });
    test('next and previous pass through', () {
      for (final c in [RemoteCommand.next, RemoteCommand.previous]) {
        for (final p in [true, false]) {
          for (final s in [true, false]) {
            expect(r(c, p, s), c);
          }
        }
      }
    });
    test('everything is dropped in the Bluetooth grace window', () {
      for (final c in RemoteCommand.values) {
        expect(r(c, true, false, grace: true), isNull);
        expect(r(c, false, true, grace: true), isNull);
      }
    });
  });

  group('inBluetoothGrace', () {
    test('window maths', () {
      bool g(int now, int? at, int s) => inBluetoothGrace(
        nowMs: now,
        bluetoothConnectedAtMs: at,
        graceSeconds: s,
      );
      expect(g(10500, 10000, 1), isTrue);
      expect(g(11000, 10000, 1), isFalse);
      expect(g(10500, 10000, 0), isFalse);
      expect(g(10500, null, 1), isFalse);
    });
  });

  group('repeat / shuffle mapping', () {
    test('loopModeFromRemote', () {
      expect(loopModeFromRemote(AudioServiceRepeatMode.none), LoopMode.off);
      expect(loopModeFromRemote(AudioServiceRepeatMode.one), LoopMode.one);
      expect(loopModeFromRemote(AudioServiceRepeatMode.all), LoopMode.all);
      expect(loopModeFromRemote(AudioServiceRepeatMode.group), LoopMode.all);
    });
    test('remoteRepeatModeOf', () {
      expect(remoteRepeatModeOf(LoopMode.off), AudioServiceRepeatMode.none);
      expect(remoteRepeatModeOf(LoopMode.one), AudioServiceRepeatMode.one);
      expect(remoteRepeatModeOf(LoopMode.all), AudioServiceRepeatMode.all);
    });
    test('shuffleFromRemote', () {
      expect(shuffleFromRemote(AudioServiceShuffleMode.none), isFalse);
      expect(shuffleFromRemote(AudioServiceShuffleMode.all), isTrue);
      expect(shuffleFromRemote(AudioServiceShuffleMode.group), isTrue);
    });
  });
}
