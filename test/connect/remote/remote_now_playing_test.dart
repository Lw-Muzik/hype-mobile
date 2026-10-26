import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/player/remote/remote_mini_player.dart';
import 'package:eq_app/player/remote/remote_player.dart';
import 'package:eq_app/player/remote/remote_scope.dart';
import 'package:eq_app/services/connect/connect_protocol.dart';
import 'package:eq_app/services/connect/remote/connect_remote_session.dart';

const _self = 'phone';

DeviceInfo _device(String id, DeviceKind kind) => DeviceInfo(
  id: id,
  kind: kind,
  name: 'Name of $id',
  platform: null,
  appVersion: null,
  caps: const [ConnectCap.player, ConnectCap.yt],
  online: true,
  lastSeenAt: '2026-01-01T00:00:00Z',
);

TrackRef _yt(String id, {String? art}) => YtTrackRef(
  videoId: id,
  title: 'title $id',
  artist: 'artist $id',
  album: null,
  durationMs: 200000,
  artUrl: art,
);

class _Rig {
  _Rig() {
    session = ConnectRemoteSession(
      selfId: _self,
      send: (_) => true,
      hubNowMs: () => hubNow,
    );
    session.onFrame(
      WelcomeFrame(
        v: 1,
        deviceId: _self,
        serverTime: hubNow,
        devices: [
          _device(_self, DeviceKind.mobile),
          _device('desk', DeviceKind.desktop),
        ],
        activeDeviceId: 'desk',
        states: const {},
      ),
    );
  }

  late final ConnectRemoteSession session;
  int hubNow = 1000000;
  int seq = 0;

  void state(
    TrackRef track, {
    bool playing = true,
    int positionMs = 10000,
    int durationMs = 200000,
  }) {
    session.onFrame(
      StampedStateFrame(
        deviceId: 'desk',
        state: StampedState(
          at: hubNow,
          state: PlayerState(
            seq: ++seq,
            track: track,
            playing: playing,
            positionMs: positionMs,
            durationMs: durationMs,
            volume: 0.5,
            shuffle: false,
            repeat: ConnectRepeat.off,
            queue: const [],
          ),
        ),
      ),
    );
  }
}

String? _backdropImageUrl(WidgetTester tester) {
  final images = find.descendant(
    of: find.byType(RemoteBackdrop),
    matching: find.byType(Image),
  );
  if (images.evaluate().isEmpty) return null;
  var provider = tester.widget<Image>(images.last).image;
  if (provider is ResizeImage) provider = provider.imageProvider;
  return provider is NetworkImage ? provider.url : null;
}

void main() {
  group('remoteProgressOf', () {
    test('playing advances with the hub clock, paused does not, clamps', () {
      final rig = _Rig()..state(_yt('a'));
      expect(remoteProgressOf(rig.session.nowPlaying()!), closeTo(0.05, 1e-6));

      rig.hubNow += 20000;
      expect(remoteProgressOf(rig.session.nowPlaying()!), closeTo(0.15, 1e-6));

      rig.hubNow += 10000000; // far past the end
      expect(remoteProgressOf(rig.session.nowPlaying()!), 1.0);

      rig.state(_yt('a'), playing: false, positionMs: 50000);
      rig.hubNow += 30000;
      expect(remoteProgressOf(rig.session.nowPlaying()!), closeTo(0.25, 1e-6));
      rig.session.dispose();
    });

    test('unknown length is 0', () {
      final rig = _Rig()..state(_yt('a'), durationMs: 0);
      expect(remoteProgressOf(rig.session.nowPlaying()!), 0);
      rig.session.dispose();
    });
  });

  test('remoteArtUrlOf: yt art, none for local', () {
    expect(remoteArtUrlOf(_yt('a', art: 'https://x/a.jpg')), 'https://x/a.jpg');
    expect(remoteArtUrlOf(_yt('a')), isNull);
    expect(
      remoteArtUrlOf(
        const LocalTrackRef(deviceId: 'desk', id: '1', title: 't'),
      ),
      isNull,
    );
    expect(remoteArtUrlOf(null), isNull);
  });

  testWidgets('backdrop follows the remote track when it changes', (
    tester,
  ) async {
    Widget host(TrackRef? t) => MaterialApp(
      home: Scaffold(body: RemoteBackdrop(track: t, fade: false)),
    );
    await tester.pumpWidget(host(_yt('a', art: 'https://x/a.jpg')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_backdropImageUrl(tester), 'https://x/a.jpg');

    await tester.pumpWidget(host(_yt('b', art: 'https://x/b.jpg')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_backdropImageUrl(tester), 'https://x/b.jpg');

    // Art-less (desktop-local) track: no stale image left behind.
    await tester.pumpWidget(host(_yt('c')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(_backdropImageUrl(tester), isNull);
  });

  testWidgets('mini player shows the remote track with moving progress', (
    tester,
  ) async {
    final rig = _Rig()..state(_yt('a'));
    Widget host() =>
        MaterialApp(home: Scaffold(body: RemoteBuilderForTest(rig.session)));
    await tester.pumpWidget(host());
    expect(find.text('title a'), findsOneWidget);
    double value() => tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
        .value!;
    final before = value();
    expect(before, closeTo(0.05, 1e-6));

    rig.hubNow += 40000;
    await tester.pump(const Duration(milliseconds: 250));
    expect(value(), greaterThan(before));

    // The remote moves to the next track: the surface follows.
    rig.state(_yt('b'), positionMs: 0);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('title b'), findsOneWidget);
    expect(value(), closeTo(0, 1e-6));

    // Paused: the line holds still.
    rig.state(_yt('b'), playing: false, positionMs: 100000);
    await tester.pump(const Duration(milliseconds: 250));
    final paused = value();
    rig.hubNow += 60000;
    await tester.pump(const Duration(milliseconds: 250));
    expect(value(), paused);

    await tester.pumpWidget(const SizedBox());
    rig.session.dispose();
  });
}

/// Mirrors the app's RemoteBuilder, but over an injected session.
class RemoteBuilderForTest extends StatelessWidget {
  const RemoteBuilderForTest(this.session, {super.key});
  final ConnectRemoteSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) =>
        RemoteMiniPlayer(remote: session.nowPlaying()!, session: session),
  );
}
