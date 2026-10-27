import 'package:eq_app/services/install/install_reporter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _id = '3f0c1a52-9d1e-4b0e-8a57-0e6c2f2b7a11';

void main() {
  late List<(Uri, Map<String, dynamic>)> calls;
  late DateTime clock;
  late int status;

  Future<InstallReporter> make() async {
    SharedPreferences.setMockInitialValues({});
    return InstallReporter(
      prefs: await SharedPreferences.getInstance(),
      installId: () async => _id,
      details: () async => const InstallDetails(
          platform: 'android',
          osVersion: '14',
          deviceModel: 'Samsung SM-S921B',
          appVersion: '1.0.25'),
      post: (u, b) async {
        calls.add((u, b));
        return status;
      },
      now: () => clock,
      apiBase: 'https://api.test/api',
    );
  }

  setUp(() {
    calls = [];
    clock = DateTime(2026, 10, 27, 9);
    status = 200;
  });

  test('first launch registers with platform details and the install id',
      () async {
    final r = await make();
    await r.report();
    expect(calls, hasLength(1));
    expect(calls[0].$1.toString(), 'https://api.test/api/installs');
    expect(calls[0].$2, {
      'installId': _id,
      'platform': 'android',
      'os': 'android',
      'osVersion': '14',
      'deviceModel': 'Samsung SM-S921B',
      'appVersion': '1.0.25',
    });
  });

  test('pings at most every 6 hours', () async {
    final r = await make();
    await r.report(); // register
    clock = clock.add(const Duration(hours: 5, minutes: 59));
    await r.report();
    expect(calls, hasLength(1));
    clock = clock.add(const Duration(minutes: 2));
    await r.report();
    expect(calls, hasLength(2));
    expect(calls[1].$1.toString(), 'https://api.test/api/installs/$_id/ping');
    expect(calls[1].$2.containsKey('installId'), isFalse);
    await r.report(); // just pinged
    expect(calls, hasLength(2));
  });

  test('a failed register is retried at the next trigger, silently', () async {
    final r = await make();
    status = 500;
    await r.report();
    status = 200;
    await r.report();
    expect(calls, hasLength(2));
    expect(calls[1].$1.path, endsWith('/installs'));
    await r.report(); // registered now, throttled
    expect(calls, hasLength(2));
  });

  test('network errors never escape', () async {
    SharedPreferences.setMockInitialValues({});
    final r = InstallReporter(
      prefs: await SharedPreferences.getInstance(),
      installId: () async => _id,
      details: () async => const InstallDetails(platform: 'ios'),
      post: (_, _) async => throw Exception('offline'),
    );
    await r.report();
  });

  test('no id yet (Connect not attached) sends nothing', () async {
    SharedPreferences.setMockInitialValues({});
    final r = InstallReporter(
      prefs: await SharedPreferences.getInstance(),
      installId: () async => null,
      post: (u, b) async {
        calls.add((u, b));
        return 200;
      },
    );
    await r.report();
    expect(calls, isEmpty);
  });

  test('a 404 on ping re-registers next time', () async {
    final r = await make();
    await r.report();
    clock = clock.add(const Duration(hours: 7));
    status = 404;
    await r.report();
    status = 200;
    await r.report();
    expect(calls.last.$1.path, endsWith('/installs'));
  });
}
