/// An auto-advance crossfade whose successor opens late must not start the
/// next song into a pause that happened while it was loading.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/helpers/audio_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Runs [body] where the platform channel errors a bare AudioPlayer raises
  /// (there is no platform in a test) are absorbed.
  Future<void> quietly(Future<void> Function() body) {
    final done = Completer<void>();
    runZonedGuarded(() async {
      await body();
      done.complete();
    }, (_, _) {});
    return done.future;
  }

  Future<({bool started, bool incomingPlayed})> run(
    Future<void> Function(HypeAudioHandler handler) duringLoad,
  ) async {
    final handler = HypeAudioHandler();
    var started = false;
    var incomingPlayed = false;
    await quietly(() async {
      unawaited(handler.player.play());
      await pumpEventQueue();
      expect(handler.player.playing, isTrue);
      final incoming = handler.enginePlayers.last;
      final load = Completer<void>();
      handler.onCrossfadeStarted = () => started = true;
      final fade = handler.crossfade(
        load: (_) => load.future,
        fadeMs: 0,
        startAt: Duration.zero,
      );
      await pumpEventQueue();
      await duringLoad(handler);
      load.complete();
      await fade;
      incomingPlayed = incoming.playing;
    });
    return (started: started, incomingPlayed: incomingPlayed);
  }

  test('happy path: a late successor still blends in', () async {
    final r = await run((_) async {});
    expect(r.started, isTrue);
    expect(r.incomingPlayed, isTrue);
  });

  test('paused during the load: no blend, the successor never plays', () async {
    final r = await run((h) async {
      await h.player.pause().catchError((_) {});
    });
    expect(r.started, isFalse);
    expect(r.incomingPlayed, isFalse);
  });

  test('a pause still fading out (a call) during the load: same', () async {
    final r = await run((h) async {
      h.pausing.value = true;
    });
    expect(r.started, isFalse);
    expect(r.incomingPlayed, isFalse);
  });
}
