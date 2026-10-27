import 'package:eq_app/services/update/app_version_policy.dart';
import 'package:flutter_test/flutter_test.dart';

AppVersionPolicy p({
  String latest = '1.0.25',
  String min = '1.0.20',
  bool critical = false,
}) =>
    AppVersionPolicy(
      latestVersion: latest,
      minimumVersion: min,
      isCritical: critical,
    );

void main() {
  final now = DateTime(2026, 10, 27, 12);

  group('compareVersions', () {
    test('ignores build suffixes', () {
      expect(compareVersions('1.0.24+57', '1.0.24'), 0);
      expect(compareVersions('1.0.24+99', '1.0.25+1'), lessThan(0));
      expect(compareVersions('1.0.24', '1.0.24+3'), 0);
    });
    test('compares numerically, not lexically', () {
      expect(compareVersions('1.0.9', '1.0.10'), lessThan(0));
      expect(compareVersions('1.10.0', '1.9.9'), greaterThan(0));
      expect(compareVersions('2.0.0', '1.99.99'), greaterThan(0));
    });
    test('garbage compares equal so it never prompts', () {
      expect(compareVersions('abc', '1.0.0'), 0);
      expect(parseVersion('1.0'), isNull);
    });
  });

  group('decideUpdate', () {
    UpdatePrompt d(String installed, AppVersionPolicy pol,
            {UpdateChoices c = const UpdateChoices(), bool ignore = false}) =>
        decideUpdate(
            installed: installed,
            policy: pol,
            now: now,
            choices: c,
            ignoreChoices: ignore);

    test('below minimum blocks', () {
      expect(d('1.0.19+5', p()), UpdatePrompt.blocking);
    });
    test('below minimum blocks even if skipped / later', () {
      final c = UpdateChoices(
          skippedVersion: '1.0.25',
          laterAt: now,
          laterVersion: '1.0.25');
      expect(d('1.0.19', p(), c: c), UpdatePrompt.blocking);
    });
    test('critical and below latest blocks', () {
      expect(d('1.0.24', p(critical: true)), UpdatePrompt.blocking);
    });
    test('critical but up to date is none', () {
      expect(d('1.0.25', p(critical: true)), UpdatePrompt.none);
    });
    test('below latest, above minimum is dismissible', () {
      expect(d('1.0.24', p()), UpdatePrompt.dismissible);
    });
    test('equal and above are none', () {
      expect(d('1.0.25', p()), UpdatePrompt.none);
      expect(d('1.0.26', p()), UpdatePrompt.none);
    });
    test('Later holds for 24h then expires', () {
      UpdateChoices later(Duration ago) => UpdateChoices(
          laterAt: now.subtract(ago), laterVersion: '1.0.25');
      expect(d('1.0.24', p(), c: later(const Duration(hours: 23))),
          UpdatePrompt.none);
      expect(d('1.0.24', p(), c: later(const Duration(hours: 24))),
          UpdatePrompt.dismissible);
      expect(d('1.0.24', p(), c: later(const Duration(hours: 30))),
          UpdatePrompt.dismissible);
    });
    test('Later for an older latest does not hold a newer one', () {
      final c = UpdateChoices(laterAt: now, laterVersion: '1.0.25');
      expect(d('1.0.24', p(latest: '1.0.26'), c: c), UpdatePrompt.dismissible);
    });
    test('Skip holds until latest changes', () {
      const c = UpdateChoices(skippedVersion: '1.0.25');
      expect(d('1.0.24', p(), c: c), UpdatePrompt.none);
      expect(d('1.0.24', p(latest: '1.0.26'), c: c), UpdatePrompt.dismissible);
    });
    test('push tap bypasses Later and Skip', () {
      const c = UpdateChoices(skippedVersion: '1.0.25');
      expect(d('1.0.24', p(), c: c, ignore: true), UpdatePrompt.dismissible);
    });
  });

  group('AppVersionPolicy.tryParse', () {
    test('parses the contract payload', () {
      final pol = AppVersionPolicy.tryParse({
        'platform': 'android',
        'latestVersion': '1.0.25',
        'minimumVersion': '1.0.20',
        'releaseNotes': ' Faster stems ',
        'isCritical': true,
        'storeUrl': null,
      })!;
      expect(pol.releaseNotes, 'Faster stems');
      expect(pol.isCritical, isTrue);
      expect(pol.storeUrl, isNull);
    });
    test('malformed payloads are null', () {
      expect(AppVersionPolicy.tryParse('nope'), isNull);
      expect(AppVersionPolicy.tryParse({'latestVersion': '1.0'}), isNull);
      expect(
          AppVersionPolicy.tryParse(
              {'latestVersion': '1.0.1', 'minimumVersion': 'x'}),
          isNull);
    });
  });
}
