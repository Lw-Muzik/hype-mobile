import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/services/connect/connect_protocol.dart';
import 'package:eq_app/services/connect/remote/connect_takeover.dart';

DeviceInfo device(
  String id, {
  bool online = true,
  List<ConnectCap> caps = const [ConnectCap.player, ConnectCap.yt],
  DeviceKind kind = DeviceKind.desktop,
}) =>
    DeviceInfo(
      id: id,
      kind: kind,
      name: id,
      platform: null,
      appVersion: null,
      caps: caps,
      online: online,
      lastSeenAt: '2026-01-01T00:00:00Z',
    );

const self = 'phone';

class Rig {
  Rig({this._sends = true}) {
    takeover = ConnectTakeover(
      selfId: self,
      sendSelect: (id) {
        if (!_sends) return false;
        selects.add(id);
        return true;
      },
      pauseLocal: () => pauses++,
    );
  }

  late final ConnectTakeover takeover;
  final bool _sends;
  final selects = <String>[];
  int pauses = 0;

  void connect(List<DeviceInfo> devices, String? active) {
    takeover.onConnected();
    takeover.onList(devices, active);
  }

  /// A `welcome` carrying whether the active device's state says playing.
  void welcome(List<DeviceInfo> devices, String? active, {bool? activePlaying}) {
    takeover.onConnected();
    takeover.onList(devices, active, isWelcome: true, activeIsPlaying: activePlaying);
  }
}

void main() {
  final phone = device(self, kind: DeviceKind.mobile);
  final desktop = device('desk');

  void scenario(void Function(FakeAsync async) body) => fakeAsync(body);

  group('claim (a): playback starts', () {
    test('claims when playback starts and another player is active', () {
      scenario((_) {
        final r = Rig()..connect([phone, desktop], 'desk');
        r.takeover.onLocalPlaying(true);
        expect(r.selects, [self]);
        expect(r.takeover.claiming, isTrue);
      });
    });

    test('claims when nobody is active', () {
      scenario((_) {
        final r = Rig()..connect([phone, desktop], null);
        r.takeover.onLocalPlaying(true);
        expect(r.selects, [self]);
      });
    });

    test('does not claim when already active', () {
      scenario((_) {
        final r = Rig()..connect([phone, desktop], self);
        r.takeover.onLocalPlaying(true);
        expect(r.selects, isEmpty);
      });
    });

    test('does not claim while disconnected', () {
      scenario((_) {
        final r = Rig();
        r.takeover.onLocalPlaying(true);
        expect(r.selects, isEmpty);
      });
    });

    test('only the not-playing to playing edge claims', () {
      scenario((async) {
        final r = Rig()..connect([phone, desktop], 'desk');
        r.takeover.onLocalPlaying(true);
        r.takeover.onLocalPlaying(true);
        expect(r.selects, hasLength(1));
        r.takeover.onLocalPlaying(false);
        expect(r.selects, hasLength(1));
      });
    });

    test('a failed send is not a claim and may be retried at once', () {
      scenario((_) {
        final r = Rig(sends: false)..connect([phone, desktop], 'desk');
        r.takeover.onLocalPlaying(true);
        expect(r.takeover.claiming, isFalse);
        expect(r.pauses, 0);
      });
    });
  });

  group('claim (b): welcome or devices while playing', () {
    test('claims when active becomes null', () {
      scenario((_) {
        final r = Rig()..connect([phone, desktop], self);
        r.takeover.onLocalPlaying(true);
        expect(r.selects, isEmpty);
        r.takeover.onList([phone, desktop], null);
        expect(r.selects, [self]);
      });
    });

    test('claims on a welcome that arrives while playing', () {
      scenario((_) {
        final r = Rig();
        r.takeover.onLocalPlaying(true); // offline: nothing
        r.takeover.onConnected();
        r.takeover.onList([phone, desktop], null);
        expect(r.selects, [self]);
      });
    });

    test('claims when the active device is offline', () {
      scenario((async) {
        final r = Rig()..connect([phone, desktop], self);
        r.takeover.onLocalPlaying(true);
        expect(r.selects, isEmpty);
        r.takeover.onList([phone, device('desk', online: false)], 'desk');
        expect(r.selects, [self]);
        expect(r.pauses, 0);
      });
    });

    test('claims when the active device is not a player', () {
      scenario((_) {
        final web = device('web', kind: DeviceKind.web, caps: const []);
        final r = Rig()..connect([phone, web], self);
        r.takeover.onLocalPlaying(true);
        r.takeover.onList([phone, web], 'web');
        expect(r.selects, [self]);
        expect(r.pauses, 0);
      });
    });

    test('claims when the active device is missing from the list', () {
      scenario((_) {
        final r = Rig()..connect([phone], self);
        r.takeover.onLocalPlaying(true);
        r.takeover.onList([phone], 'ghost');
        expect(r.selects, [self]);
      });
    });

    test('does nothing while not playing', () {
      scenario((_) {
        final r = Rig()..connect([phone, desktop], null);
        expect(r.selects, isEmpty);
        expect(r.pauses, 0);
      });
    });
  });

  group('yield', () {
    test('pauses when another online player becomes active', () {
      scenario((_) {
        final r = Rig()..connect([phone, desktop], self);
        r.takeover.onLocalPlaying(true);
        r.takeover.onList([phone, desktop], 'desk');
        expect(r.pauses, 1);
        expect(r.selects, isEmpty);
      });
    });

    test('does not pause when not playing', () {
      scenario((_) {
        final r = Rig()..connect([phone, desktop], self);
        r.takeover.onList([phone, desktop], 'desk');
        expect(r.pauses, 0);
      });
    });

    test('yields on welcome too (playing, desk already active)', () {
      scenario((async) {
        final r = Rig();
        r.takeover.onConnected();
        r.takeover.onList([phone, desktop], self);
        r.takeover.onLocalPlaying(true); // claim not needed: self active
        r.takeover.onDisconnected();
        r.takeover.onConnected();
        r.takeover.onList([phone, desktop], 'desk');
        expect(r.pauses, 1);
      });
    });

    test('never yields to an offline player', () {
      scenario((_) {
        final r = Rig()..connect([phone, desktop], self);
        r.takeover.onLocalPlaying(true);
        r.takeover.onList([phone, device('desk', online: false)], 'desk');
        expect(r.pauses, 0);
      });
    });

    test('never yields to a non-player', () {
      scenario((_) {
        final web = device('web', kind: DeviceKind.web, caps: const []);
        final r = Rig()..connect([phone, web], self);
        r.takeover.onLocalPlaying(true);
        r.takeover.onList([phone, web], 'web');
        expect(r.pauses, 0);
      });
    });

    test('does not pause for itself', () {
      scenario((_) {
        final r = Rig()..connect([phone, desktop], self);
        r.takeover.onLocalPlaying(true);
        r.takeover.onList([phone, desktop], self);
        expect(r.pauses, 0);
      });
    });
  });

  group('claiming', () {
    test('postpones yield while claiming, applies it at the timeout', () {
      scenario((async) {
        final r = Rig()..connect([phone, desktop], 'desk');
        r.takeover.onLocalPlaying(true);
        expect(r.takeover.claiming, isTrue);
        // The hub shows the old active device still: not a yield yet.
        r.takeover.onList([phone, desktop], 'desk');
        expect(r.pauses, 0);
        async.elapse(const Duration(seconds: 3));
        expect(r.takeover.claiming, isFalse);
        expect(r.pauses, 1);
      });
    });

    test('the timeout applies the LATEST list', () {
      scenario((async) {
        final r = Rig()..connect([phone, desktop], 'desk');
        r.takeover.onLocalPlaying(true);
        r.takeover.onList([phone, desktop], 'desk');
        r.takeover.onList([phone, device('desk', online: false)], 'desk');
        async.elapse(const Duration(seconds: 3));
        expect(r.pauses, 0);
      });
    });

    test('the timeout does not claim again', () {
      scenario((async) {
        final r = Rig()..connect([phone, desktop], null);
        r.takeover.onLocalPlaying(true);
        async.elapse(const Duration(seconds: 10));
        expect(r.selects, hasLength(1));
      });
    });

    test('winning ends claiming and cancels the timeout', () {
      scenario((async) {
        final r = Rig()..connect([phone, desktop], 'desk');
        r.takeover.onLocalPlaying(true);
        r.takeover.onList([phone, desktop], self);
        expect(r.takeover.claiming, isFalse);
        async.elapse(const Duration(seconds: 5));
        expect(r.pauses, 0);
      });
    });

    test('a list while claiming with a null active does not re-claim', () {
      scenario((_) {
        final r = Rig()..connect([phone, desktop], null);
        r.takeover.onLocalPlaying(true);
        r.takeover.onList([phone, desktop], null);
        expect(r.selects, hasLength(1));
      });
    });

    test('not_a_player ends claiming and applies the yield', () {
      scenario((_) {
        final r = Rig()..connect([phone, desktop], 'desk');
        r.takeover.onLocalPlaying(true);
        r.takeover.onError('not_a_player');
        expect(r.takeover.claiming, isFalse);
        expect(r.pauses, 1);
      });
    });

    test('other errors and errors while not claiming change nothing', () {
      scenario((_) {
        final r = Rig()..connect([phone, desktop], self);
        r.takeover.onLocalPlaying(true);
        r.takeover.onError('not_a_player');
        expect(r.pauses, 0);
        r.takeover.onList([phone, desktop], 'desk'); // yield
        expect(r.pauses, 1);

        final r2 = Rig()..connect([phone, desktop], 'desk');
        r2.takeover.onLocalPlaying(true);
        r2.takeover.onError('rate_limited');
        expect(r2.takeover.claiming, isTrue);
      });
    });

    test('disconnecting ends claiming', () {
      scenario((async) {
        final r = Rig()..connect([phone, desktop], 'desk');
        r.takeover.onLocalPlaying(true);
        r.takeover.onDisconnected();
        expect(r.takeover.claiming, isFalse);
        async.elapse(const Duration(seconds: 5));
        expect(r.pauses, 0);
      });
    });
  });

  group('rate limit', () {
    test('at most one claim per 3 seconds', () {
      scenario((async) {
        final r = Rig()..connect([phone, desktop], 'desk');
        r.takeover.onLocalPlaying(true);
        r.takeover.onList([phone, desktop], self); // win
        r.takeover.onLocalPlaying(false);
        r.takeover.onList([phone, desktop], 'desk');
        async.elapse(const Duration(seconds: 1));
        r.takeover.onLocalPlaying(true); // a second start within 3 s
        expect(r.selects, hasLength(1));
        async.elapse(const Duration(seconds: 2));
        r.takeover.onLocalPlaying(false);
        r.takeover.onLocalPlaying(true);
        expect(r.selects, hasLength(2));
      });
    });
  });

  group('the two-players race', () {
    test('both claim; the loser yields once its claim ends', () {
      scenario((async) {
        // Phone and desktop both start; the hub applies phone first, then desk.
        final phoneRig = Rig()..connect([phone, desktop], null);
        phoneRig.takeover.onLocalPlaying(true);
        expect(phoneRig.selects, [self]);

        // The phone sees active=phone (its own select landed) ...
        phoneRig.takeover.onList([phone, desktop], self);
        expect(phoneRig.takeover.claiming, isFalse);
        // ... then the desktop's select lands and the hub broadcasts desk.
        phoneRig.takeover.onList([phone, desktop], 'desk');
        expect(phoneRig.pauses, 1);
      });
    });

    test('loser still claiming when the winner is announced waits, then yields',
        () {
      scenario((async) {
        final r = Rig()..connect([phone, desktop], null);
        r.takeover.onLocalPlaying(true);
        r.takeover.onList([phone, desktop], 'desk'); // desk won, we are claiming
        expect(r.pauses, 0);
        async.elapse(const Duration(seconds: 3));
        expect(r.pauses, 1);
      });
    });
  });

  group('edges and connection', () {
    test('a repeated playing=true is not a new start', () {
      scenario((async) {
        final r = Rig()..connect([phone, desktop], 'desk');
        r.takeover.onLocalPlaying(true);
        async.elapse(const Duration(seconds: 3)); // claim lapses, yields
        expect(r.selects, hasLength(1));
        async.elapse(const Duration(seconds: 5));
        r.takeover.onLocalPlaying(true);
        expect(r.selects, hasLength(1));
      });
    });

    test('a list that arrives while disconnected changes nothing', () {
      scenario((_) {
        final r = Rig();
        r.takeover.onLocalPlaying(true);
        r.takeover.onList([phone, desktop], 'desk');
        expect(r.pauses, 0);
        r.takeover.onList([phone, desktop], null);
        expect(r.selects, isEmpty);
      });
    });

    test('after a reconnect the old list is forgotten', () {
      scenario((_) {
        final r = Rig()..connect([phone, desktop], self);
        r.takeover.onDisconnected();
        r.takeover.onConnected(); // welcome not seen yet
        r.takeover.onLocalPlaying(true);
        expect(r.selects, [self]); // not "already active" from the stale list
      });
    });
  });

  group('claim (c): welcome', () {
    test('offline start claims on welcome even if another player plays', () {
      scenario((_) {
        final r = Rig();
        r.takeover.onLocalPlaying(true); // no socket
        r.welcome([phone, desktop], 'desk', activePlaying: true);
        expect(r.selects, [self]);
        expect(r.pauses, 0);
      });
    });

    test('stale idle active on welcome claims', () {
      scenario((_) {
        final r = Rig();
        r.takeover.onConnected();
        r.takeover.onLocalPlaying(true); // claim (a) happens; reset via fresh rig
        final r2 = Rig()..takeover.onConnected();
        r2.takeover.onList([phone, desktop], self);
        r2.takeover.onLocalPlaying(true);
        r2.takeover.onDisconnected();
        r2.takeover.onConnected();
        r2.takeover.onList([phone, desktop], 'desk', isWelcome: true, activeIsPlaying: false);
        expect(r2.selects, [self]);
        expect(r2.pauses, 0);
      });
    });

    test('active with no state entry on welcome claims', () {
      scenario((_) {
        final r = Rig()..connect([phone, desktop], self);
        r.takeover.onLocalPlaying(true);
        r.takeover.onList([phone, desktop], 'desk', isWelcome: true, activeIsPlaying: null);
        expect(r.selects, [self]);
      });
    });

    test('active playing on welcome, no offline start: yield', () {
      scenario((_) {
        final r = Rig()..connect([phone, desktop], self);
        r.takeover.onLocalPlaying(true);
        r.takeover.onList([phone, desktop], 'desk', isWelcome: true, activeIsPlaying: true);
        expect(r.pauses, 1);
        expect(r.selects, isEmpty);
      });
    });

    test('the same idle active on a devices frame still yields', () {
      scenario((_) {
        final r = Rig()..connect([phone, desktop], self);
        r.takeover.onLocalPlaying(true);
        r.takeover.onList([phone, desktop], 'desk');
        expect(r.pauses, 1);
        expect(r.selects, isEmpty);
      });
    });

    test('the flag clears once a claim is sent', () {
      scenario((async) {
        final r = Rig();
        r.takeover.onLocalPlaying(true);
        r.welcome([phone, desktop], 'desk', activePlaying: true);
        expect(r.selects, [self]);
        async.elapse(const Duration(seconds: 4));
        final before = r.pauses;
        r.takeover.onDisconnected();
        r.welcome([phone, desktop], 'desk', activePlaying: true);
        expect(r.pauses, before + 1, reason: 'claim consumed the offline start');
        expect(r.selects, hasLength(1));
      });
    });

    test('a postponed check after claiming applies as a devices check', () {
      scenario((async) {
        final r = Rig();
        r.takeover.onLocalPlaying(true);
        r.welcome([phone, desktop], 'desk', activePlaying: false);
        expect(r.selects, [self]);
        async.elapse(const Duration(seconds: 3));
        expect(r.pauses, 1);
      });
    });
  });
  group('hubHasAnswered', () {
    test('only once a list has arrived on a live connection', () {
      scenario((async) {
        final r = Rig();
        expect(r.takeover.hubHasAnswered, isFalse);
        r.takeover.onConnected();
        expect(r.takeover.hubHasAnswered, isFalse, reason: 'no list yet');
        r.takeover.onList([phone, desktop], null);
        expect(r.takeover.hubHasAnswered, isTrue);
        r.takeover.onDisconnected();
        expect(r.takeover.hubHasAnswered, isFalse);
        r.takeover.onConnected();
        expect(r.takeover.hubHasAnswered, isFalse, reason: 'old list forgotten');
      });
    });
  });

  group('otherPlayerActive', () {
    test('true only while another online player is the active device', () {
      scenario((async) {
        final r = Rig();
        expect(r.takeover.otherPlayerActive, isFalse, reason: 'no session');

        r.connect([phone, desktop], 'desk');
        expect(r.takeover.otherPlayerActive, isTrue);

        r.takeover.onList([phone, desktop], self);
        expect(r.takeover.otherPlayerActive, isFalse, reason: 'this phone');

        r.takeover.onList([phone, desktop], null);
        expect(r.takeover.otherPlayerActive, isFalse, reason: 'nobody');

        r.takeover.onList([phone, device('desk', online: false)], 'desk');
        expect(r.takeover.otherPlayerActive, isFalse, reason: 'offline');

        r.takeover.onList([
          phone,
          device('desk', caps: const [ConnectCap.yt]),
        ], 'desk');
        expect(r.takeover.otherPlayerActive, isFalse, reason: 'not a player');

        r.takeover.onList([phone, desktop], 'desk');
        expect(r.takeover.otherPlayerActive, isTrue);
        r.takeover.onDisconnected();
        expect(r.takeover.otherPlayerActive, isFalse, reason: 'socket gone');
      });
    });
  });
}
