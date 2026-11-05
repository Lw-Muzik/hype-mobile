import 'package:eq_app/Helpers/Channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const ctl = MethodChannel('eq_app/media_buttons_ctl');
  const events = EventChannel('eq_app/media_buttons');

  setUp(() => Channel.mediaButtonRetryDelay = const Duration(milliseconds: 5));
  tearDown(() {
    messenger.setMockMethodCallHandler(ctl, null);
    messenger.setMockStreamHandler(events, null);
  });

  test('no native handler yet: listening does not throw, then it connects', () async {
    final got = <Map<Object?, Object?>>[];
    final errors = <Object>[];
    final sub = Channel.mediaButtonEvents.listen(got.add, onError: errors.add);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(errors, isEmpty);
    expect(got, isEmpty);

    messenger.setMockMethodCallHandler(ctl, (call) async => true);
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (arguments, sink) {
          sink.success({'keyCode': 85, 'down': true});
        },
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(got, [
      {'connected': true},
      {'keyCode': 85, 'down': true},
    ]);
    await sub.cancel();
  });

  test('policy and feedback calls survive a missing handler', () async {
    await Channel.setButtonPolicy(
      respond: true,
      playing: false,
      longPressProxy: false,
      wiredLongPress: false,
      bluetoothLongPress: false,
    );
    await Channel.buttonFeedback(beeps: 2, toneVolume: 60, vibrate: false);
  });

  test('policy and feedback send their arguments', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(ctl, (call) async {
      calls.add(call);
      return null;
    });
    await Channel.setButtonPolicy(
      respond: false,
      playing: true,
      longPressProxy: true,
      wiredLongPress: true,
      bluetoothLongPress: false,
    );
    await Channel.buttonFeedback(beeps: 3, toneVolume: 40, vibrate: true);
    expect(calls.map((c) => c.method), ['setButtonPolicy', 'buttonFeedback']);
    expect(calls[0].arguments, {
      'respond': false,
      'playing': true,
      'longPressProxy': true,
      'wiredLongPress': true,
      'bluetoothLongPress': false,
    });
    expect(calls[1].arguments, {'beeps': 3, 'toneVolume': 40, 'vibrate': true});
  });
}
