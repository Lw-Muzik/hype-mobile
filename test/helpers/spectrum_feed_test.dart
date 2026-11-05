import 'dart:async';
import 'dart:typed_data';

import 'package:eq_app/Helpers/Channel.dart';
import 'package:eq_app/helpers/audio_visualizer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _deliver(Map<String, Object?> args) async {
  const codec = StandardMethodCodec();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        Channel.channel.name,
        codec.encodeMethodCall(MethodCall('onFftVisualization', args)),
        (_) {},
      );
}

Float32List _frame(int length, {int index = 3, double value = 7}) =>
    Float32List(length)..[index] = value;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <String>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(Channel.channel, (call) async {
          calls.add(call.method);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(Channel.channel, null);
  });

  test('ios handler publishes spectrum frames', () async {
    final got = <Float32List>[];
    final feed = SpectrumFeed(onFrame: got.add);
    await _deliver({
      'fft': <int>[1, 2],
      'spectrum': _frame(256),
    });
    expect(got, hasLength(1));
    expect(got.single[3], 7);
    expect(calls, contains('activate_visualizer'));
    feed.dispose();
    expect(calls, contains('deactivate_visualizer'));
  });

  test('frames without fft still publish spectrum', () async {
    final got = <Float32List>[];
    final feed = SpectrumFeed(onFrame: got.add);
    await _deliver({'spectrum': _frame(256)});
    expect(got, hasLength(1));
    feed.dispose();
  });

  test('wrong length is dropped', () async {
    final got = <Float32List>[];
    final feed = SpectrumFeed(onFrame: got.add);
    await _deliver({'spectrum': _frame(255)});
    expect(got, isEmpty);
    feed.dispose();
  });

  test('dispose stops delivery', () async {
    final got = <Float32List>[];
    final feed = SpectrumFeed(onFrame: got.add);
    await _deliver({'spectrum': _frame(256)});
    feed.dispose();
    await _deliver({'spectrum': _frame(256)});
    expect(got, hasLength(1));
  });

  test('source override is used', () async {
    final ctrl = StreamController<Float32List>();
    final got = <Float32List>[];
    final feed = SpectrumFeed(onFrame: got.add, source: ctrl.stream);
    ctrl.add(_frame(256, index: 5, value: 2));
    await Future<void>.delayed(Duration.zero);
    expect(got.single[5], 2);
    // No native tap is touched when a source is supplied.
    expect(calls, isNot(contains('activate_visualizer')));
    await _deliver({'spectrum': _frame(256)});
    expect(got, hasLength(1));
    feed.dispose();
    await ctrl.close();
  });
}
