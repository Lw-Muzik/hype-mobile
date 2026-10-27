import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/services/connect/connect_notification.dart';
import 'package:eq_app/services/connect/connect_service.dart';
import 'package:eq_app/services/connect/connect_volume.dart';

class _Bridge implements ConnectServiceBridge {
  double? system = 0.4;
  bool setWorks = true;
  final calls = <String>[];
  void Function(double)? changed;

  @override
  Future<double?> getVolume() async {
    calls.add('get');
    return system;
  }

  @override
  Future<bool> setVolume(double value) async {
    calls.add('set:$value');
    if (setWorks) system = value;
    return setWorks;
  }

  @override
  Future<void> watchVolume(bool on) async => calls.add('watch:$on');
  @override
  Future<void> setRemoteVolumeKeys(bool on) async {}
  @override
  set onVolumeChanged(void Function(double value)? handler) => changed = handler;
  @override
  set onVolumeKey(void Function(String direction)? handler) {}
  @override
  set onAction(void Function(String id)? handler) {}
  @override
  set onOpenRequested(void Function()? handler) {}
  @override
  Future<bool> isRunning() async => false;
  @override
  Future<bool> start() async => false;
  @override
  Future<void> update(ConnectNotificationContent content) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> setBootEnabled(bool enabled) async {}
  @override
  Future<bool> isIgnoringBatteryOptimizations() async => true;
  @override
  Future<void> openBatterySettings() async {}
  @override
  Future<bool> takeOpenRequest() async => false;
}

class _Rig {
  _Rig({bool withBridge = true}) {
    if (withBridge) bridge = _Bridge();
    volume = AppConnectDeviceVolume(
      bridge: bridge,
      dvcEnabled: () => dvc,
      dvcGainDb: () => gainDb,
      setDvcGainDb: (db) => gainDb = db,
      legacyRead: () => legacy,
      legacySet: (v) async => legacy = v,
    );
  }

  _Bridge? bridge;
  late final AppConnectDeviceVolume volume;
  bool dvc = false;
  double gainDb = -15;
  double? legacy = 0.9;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('read', () {
    test('DVC on reads the gain as a fraction of -30..0 dB', () async {
      final r = _Rig()..dvc = true;
      await r.volume.start();
      r.gainDb = -30;
      expect(r.volume.read(), 0);
      r.gainDb = -15;
      expect(r.volume.read(), 0.5);
      r.gainDb = 0;
      expect(r.volume.read(), 1);
    });

    test('DVC off reads the system volume once seeded', () async {
      final r = _Rig();
      expect(r.volume.read(), 0.9, reason: 'before the seed: player gain');
      await r.volume.start();
      expect(r.volume.read(), 0.4);
    });

    test('a native volumeChanged updates the value and emits', () async {
      final r = _Rig();
      var n = 0;
      r.volume.changes.listen((_) => n++);
      await r.volume.start();
      final seeded = n;
      r.bridge!.changed!(0.7);
      expect(r.volume.read(), 0.7);
      expect(n, seeded + 1);
      r.bridge!.changed!(0.7);
      expect(n, seeded + 1, reason: 'unchanged value is not an event');
    });

    test('without a native side the player gain stays the answer (iOS)', () async {
      final r = _Rig(withBridge: false);
      await r.volume.start();
      expect(r.volume.read(), 0.9);
      r.legacy = null;
      expect(r.volume.read(), isNull, reason: 'mid-crossfade');
    });

    test('a native side that cannot read keeps the player gain', () async {
      final r = _Rig();
      r.bridge!.system = null;
      await r.volume.start();
      expect(r.volume.read(), 0.9);
    });
  });

  group('set', () {
    test('DVC on moves the DVC gain, never the system volume', () async {
      final r = _Rig()..dvc = true;
      await r.volume.start();
      await r.volume.set(0.5);
      expect(r.gainDb, -15);
      await r.volume.set(2);
      expect(r.gainDb, 0);
      await r.volume.set(-1);
      expect(r.gainDb, -30);
      expect(r.bridge!.calls.where((c) => c.startsWith('set')), isEmpty);
      expect(r.legacy, 0.9);
    });

    test('system volume: asks native and updates the cache at once', () async {
      final r = _Rig();
      var n = 0;
      r.volume.changes.listen((_) => n++);
      await r.volume.start();
      final before = n;
      await r.volume.set(0.25);
      expect(r.bridge!.calls.last, 'set:0.25');
      expect(r.volume.read(), 0.25);
      expect(n, before + 1);
      await r.volume.set(5);
      expect(r.bridge!.calls.last, 'set:1.0');
    });

    test('falls back to the player gain when native refuses', () async {
      final r = _Rig();
      r.bridge!.setWorks = false;
      await r.volume.set(0.3);
      expect(r.legacy, 0.3);
    });

    test('no bridge: player gain', () async {
      final r = _Rig(withBridge: false);
      await r.volume.set(0.6);
      expect(r.legacy, 0.6);
    });

    // Nothing else notices a player-gain change, so without this the phone
    // published nothing, the remote's overlay expired after 3 s and its slider
    // jumped back to the old value until the next 15 s heartbeat (iOS).
    test('no bridge: the change is announced at once', () async {
      final r = _Rig(withBridge: false);
      var n = 0;
      r.volume.changes.listen((_) => n++);
      await r.volume.set(0.6);
      expect(n, 1);
      expect(r.volume.read(), 0.6);
    });

    test('native refusing: the player-gain change is announced too', () async {
      final r = _Rig();
      r.bridge!.setWorks = false;
      var n = 0;
      r.volume.changes.listen((_) => n++);
      await r.volume.set(0.3);
      expect(n, 1);
    });
  });

  group('start / stop', () {
    test('watching follows start and stop, idempotently', () async {
      final r = _Rig();
      await r.volume.start();
      await r.volume.start();
      r.volume.stop();
      r.volume.stop();
      expect(r.bridge!.calls.where((c) => c.startsWith('watch')), ['watch:true', 'watch:false']);
    });
  });

  group('MethodChannelConnectService volume', () {
    const name = 'x.a.zix/connect_service';
    late MethodChannel channel;
    late MethodChannelConnectService service;
    final log = <MethodCall>[];

    setUp(() {
      log.clear();
      channel = const MethodChannel(name);
      service = MethodChannelConnectService(channel);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        log.add(call);
        return call.method == 'getVolume' ? 0.42 : null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<void> fromNative(String method, Object? args) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );
    }

    test('the four calls reach native with their arguments', () async {
      expect(await service.getVolume(), 0.42);
      expect(await service.setVolume(0.5), isTrue);
      await service.watchVolume(true);
      await service.setRemoteVolumeKeys(true);
      expect(log.map((c) => c.method), ['getVolume', 'setVolume', 'watchVolume', 'setRemoteVolumeKeys']);
      expect(log[1].arguments, 0.5);
      expect(log[2].arguments, true);
      expect(log[3].arguments, true);
    });

    test('volumeChanged and volumeKey reach the callbacks', () async {
      double? volume;
      String? key;
      service
        ..onVolumeChanged = ((v) => volume = v)
        ..onVolumeKey = (d) => key = d;
      await fromNative('volumeChanged', 0.75);
      await fromNative('volumeKey', 'down');
      expect(volume, 0.75);
      expect(key, 'down');
    });

    test('an int from native still arrives as a double', () async {
      double? volume;
      service.onVolumeChanged = (v) => volume = v;
      await fromNative('volumeChanged', 1);
      expect(volume, 1.0);
    });

    test('missing plugin degrades to unavailable, never throws', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(await service.getVolume(), isNull);
      expect(await service.setVolume(0.5), isFalse);
      await service.watchVolume(true);
      await service.setRemoteVolumeKeys(false);
    });

    test('a native error on setVolume is "unavailable", not a throw', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'connect_service', message: 'boom');
      });
      expect(await service.setVolume(0.5), isFalse);
      expect(await service.getVolume(), isNull);
    });
  });
}
