import 'package:eq_app/config/app_config.dart';
import 'package:eq_app/pages/Settings.dart';
import 'package:flutter_test/flutter_test.dart';

/// Run plain for the store build and with `--dart-define=HYPE_DIRECT=true`
/// for the direct one; the repair tool is listed only in the direct build.
void main() {
  test('Settings lists "Fix YouTube downloads" only in the direct build', () {
    final listed = kSettingsIndex.any((e) => e.label == 'Fix YouTube downloads');
    expect(listed, AppConfig.directBuild);
  });
}
