import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:on_audio_query/on_audio_query.dart';

import 'package:eq_app/services/connect/connect_protocol.dart';
import 'package:eq_app/services/connect/connect_state_publisher.dart';

SongModel song(int id, {String? ytVideoId}) => SongModel({
      '_id': id,
      '_data': '/music/$id.mp3',
      'title': 'Track $id',
      'artist': 'Artist',
      'album': 'Album',
      'duration': 200000,
      '_display_name': '$id.mp3',
      '_display_name_wo_ext': '$id',
      '_size': 0,
      'file_extension': 'mp3',
      'is_music': true,
    });

class FakeSource implements ConnectStateSource {
  final _changes = StreamController<void>.broadcast(sync: true);

  SongModel? track = song(1);
  bool playing = true;
  Duration position = Duration.zero;
  double? volume = 0.5;
  bool shuffle = false;
  bool video = false;
  ConnectRepeat repeat = ConnectRepeat.off;
  List<UpcomingSong> upcoming = const [];

  void poke() => _changes.add(null);

  @override
  Stream<void> get changes => _changes.stream;

  @override
  ConnectSnapshot read() => ConnectSnapshot(
        track: track,
        playing: playing,
        position: position,
        duration: null,
        volume: volume,
        shuffle: shuffle,
        repeat: repeat,
        upcoming: upcoming,
        video: video,
      );
}

class MemorySeqStore implements ConnectSeqStore {
  MemorySeqStore([this.value]);
  int? value;

  @override
  int? read() => value;

  @override
  void write(int seq) => value = seq;
}

void main() {
  final epoch = DateTime.utc(2026, 10, 12, 8);
  final epochSeconds = epoch.millisecondsSinceEpoch ~/ 1000;

  /// Runs [body] with a virtual clock and a publisher wired to fakes.
  void scenario(
    void Function(
      FakeAsync async,
      FakeSource source,
      List<PlayerState> sent,
      ConnectStatePublisher publisher,
      MemorySeqStore store,
    ) body, {
    bool online = true,
    int? persistedSeq,
    bool Function()? isOnline,
  }) {
    fakeAsync((async) {
      withClock(async.getClock(epoch), () {
        final source = FakeSource();
        final sent = <PlayerState>[];
        final store = MemorySeqStore(persistedSeq);
        final publisher = ConnectStatePublisher(
          source: source,
          send: (frame) {
            if (!(isOnline?.call() ?? online)) return false;
            sent.add(frame.state);
            return true;
          },
          deviceId: 'dev-1',
          seqStore: store,
        );
        publisher.start();
        body(async, source, sent, publisher, store);
        publisher.stop();
      });
    });
  }

  group('when a frame is sent', () {
    test('a change is sent once the debounce has passed, not before', () {
      scenario((async, source, sent, publisher, _) {
        source.poke();
        async.elapse(const Duration(milliseconds: 299));
        expect(sent, isEmpty);
        async.elapse(const Duration(milliseconds: 2));
        expect(sent, hasLength(1));
      });
    });

    test('a burst of changes becomes one frame describing where it ended', () {
      scenario((async, source, sent, publisher, _) {
        source.poke();
        source.track = song(2);
        source.poke();
        source.playing = false;
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(1));
        expect(sent.single.playing, isFalse);
        expect(sent.single.track!.title, 'Track 2');
      });
    });

    test('a notification that changed nothing sends nothing', () {
      scenario((async, source, sent, publisher, _) {
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(1));
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(1));
      });
    });

    test('playing along at the expected rate sends nothing', () {
      scenario((async, source, sent, publisher, _) {
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(1));
        // Ten seconds of playback, as the player reports it: exactly what a
        // controller extrapolates, so there is nothing to tell it.
        async.elapse(const Duration(seconds: 9));
        source.position = const Duration(seconds: 10);
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(1));
      });
    });

    test('a seek is sent', () {
      scenario((async, source, sent, publisher, _) {
        source.poke();
        async.elapse(const Duration(seconds: 1));
        source.position = const Duration(seconds: 90);
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(2));
        expect(sent.last.positionMs, 90000);
      });
    });

    test('a short skip, just past the tolerance, is sent', () {
      scenario((async, source, sent, publisher, _) {
        source.poke();
        async.elapse(const Duration(seconds: 1));
        // ~1.3 s of wall time since the frame; 4 s on the player is ~2.7 s off.
        source.position = const Duration(seconds: 4);
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(2));
      });
    });

    test('a position within the tolerance of the expected one is not', () {
      scenario((async, source, sent, publisher, _) {
        source.poke();
        async.elapse(const Duration(seconds: 1));
        source.position = const Duration(milliseconds: 1500 + 1000);
        source.poke();
        async.elapse(const Duration(seconds: 1));
        // ~2 s of wall time passed; the player is 0.5 s ahead of that.
        expect(sent, hasLength(1));
      });
    });

    test('a paused player is expected to stay where it was', () {
      scenario((async, source, sent, publisher, _) {
        source.playing = false;
        source.position = const Duration(seconds: 30);
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(1));
        // Twenty seconds on, still at 30 s: nothing to report. Had it been
        // treated as playing, 30 s would look 20 s behind and be sent.
        async.elapse(const Duration(seconds: 20));
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(1));
      });
    });

    test('a pause is sent', () {
      scenario((async, source, sent, publisher, _) {
        source.poke();
        async.elapse(const Duration(seconds: 1));
        source.playing = false;
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent.map((s) => s.playing), [true, false]);
      });
    });

    test('a change while offline is not counted as sent', () {
      var online = false;
      scenario((async, source, sent, publisher, _) {
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent, isEmpty);
        online = true;
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(1));
      }, isOnline: () => online);
    });
  });

  group('video flag (v1.3)', () {
    test('a frame is sent when video flips, and the flag is in the state', () {
      scenario((async, source, sent, publisher, _) {
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(1));
        expect(sent.last.video, isFalse);
        expect(sent.last.toJson().containsKey('video'), isFalse);

        source.video = true;
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(2));
        expect(sent.last.video, isTrue);
        expect(sent.last.toJson()['video'], isTrue);

        // Unchanged: nothing more to say.
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(2));

        source.video = false;
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(3));
        expect(sent.last.toJson().containsKey('video'), isFalse);
      });
    });
  });

  group('heartbeat', () {
    test('every 15 seconds while playing', () {
      scenario((async, source, sent, publisher, _) {
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(1));
        // The player advances as it plays; heartbeats fall at 15 s and 30 s.
        for (var s = 1; s <= 30; s++) {
          async.elapse(const Duration(seconds: 1));
          source.position = Duration(seconds: s);
        }
        expect(sent, hasLength(3));
      });
    });

    test('not while paused', () {
      scenario((async, source, sent, publisher, _) {
        source.playing = false;
        source.poke();
        async.elapse(const Duration(seconds: 1));
        async.elapse(const Duration(minutes: 2));
        expect(sent, hasLength(1));
      });
    });

    test('sendNow sends at once even when nothing changed', () {
      scenario((async, source, sent, publisher, _) {
        source.poke();
        async.elapse(const Duration(seconds: 1));
        publisher.sendNow();
        expect(sent, hasLength(2));
      });
    });
  });

  group('contents', () {
    test('only upcoming items, at most 50, with the uids the source gave', () {
      scenario((async, source, sent, publisher, _) {
        source.upcoming = [
          for (var i = 2; i < 80; i++) UpcomingSong('q-$i', song(i)),
        ];
        source.poke();
        async.elapse(const Duration(seconds: 1));
        final queue = sent.single.queue;
        expect(queue, hasLength(50));
        expect(queue.first.uid, 'q-2');
        expect(queue.last.uid, 'q-51');
        expect(queue.any((e) => e.track.title == 'Track 1'), isFalse);
      });
    });

    test('local songs are owned by this device', () {
      scenario((async, source, sent, publisher, _) {
        source.poke();
        async.elapse(const Duration(seconds: 1));
        final track = sent.single.track! as LocalTrackRef;
        expect(track.deviceId, 'dev-1');
        expect(track.id, '1');
      });
    });

    test('volume is clamped to 0..1', () {
      scenario((async, source, sent, publisher, _) {
        source.volume = 1.7;
        source.poke();
        async.elapse(const Duration(seconds: 1));
        source.volume = -3;
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent.map((s) => s.volume), [1.0, 0.0]);
      });
    });

    test('a volume-only change is sent, coalesced by the debounce', () {
      scenario((async, source, sent, publisher, _) {
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(1));
        // A hardware key held down: several steps inside one debounce window.
        for (final v in [0.55, 0.6, 0.65]) {
          source.volume = v;
          source.poke();
          async.elapse(const Duration(milliseconds: 50));
        }
        expect(sent, hasLength(1));
        async.elapse(const Duration(milliseconds: 300));
        expect(sent.map((s) => s.volume), [0.5, 0.65]);
        // Nothing else changed, and the same volume again is not worth a frame.
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent, hasLength(2));
      });
    });

    test('an unreadable volume (mid crossfade) keeps the last one', () {
      scenario((async, source, sent, publisher, _) {
        source.volume = 0.4;
        source.poke();
        async.elapse(const Duration(seconds: 1));
        source.volume = null;
        source.track = song(2);
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent.map((s) => s.volume), [0.4, 0.4]);
      });
    });

    test('an empty player reports no track and no duration', () {
      scenario((async, source, sent, publisher, _) {
        source.track = null;
        source.playing = false;
        source.poke();
        async.elapse(const Duration(seconds: 1));
        expect(sent.single.track, isNull);
        expect(sent.single.durationMs, isNull);
      });
    });
  });

  group('seq', () {
    test('starts at the clock in epoch seconds and increases by one', () {
      scenario((async, source, sent, publisher, _) {
        source.poke();
        async.elapse(const Duration(seconds: 1));
        publisher.sendNow();
        publisher.sendNow();
        expect(sent.map((s) => s.seq),
            [epochSeconds, epochSeconds + 1, epochSeconds + 2]);
      });
    });

    test('a persisted value ahead of the clock wins', () {
      scenario((async, source, sent, publisher, _) {
        publisher.sendNow();
        expect(sent.single.seq, epochSeconds + 1001);
      }, persistedSeq: epochSeconds + 1000);
    });

    test('is saved, so the next launch continues after it', () {
      scenario((async, source, sent, publisher, store) {
        publisher.sendNow();
        publisher.sendNow();
        expect(store.value, epochSeconds + 1);
      });
    });

    test('a failed send does not use a number', () {
      var online = false;
      scenario((async, source, sent, publisher, _) {
        publisher.sendNow();
        online = true;
        publisher.sendNow();
        expect(sent.single.seq, epochSeconds);
      }, isOnline: () => online);
    });

    test('fits in 32 bits', () {
      expect(epochSeconds, lessThan(2147483647));
    });
  });
}
