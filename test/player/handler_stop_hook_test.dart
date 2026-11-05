/// A stop tells the app, so a resume held for a call dies with it.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/helpers/audio_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('stop() runs onStopped as it begins', () async {
    final handler = HypeAudioHandler();
    var stopped = 0;
    handler.onStopped = () => stopped++;

    // The players have no platform behind them here, so the stop itself may
    // fail; the hook has already run by then.
    unawaited(handler.stop().then((_) {}, onError: (Object _) {}));
    await pumpEventQueue();

    expect(stopped, 1);
  });
}
