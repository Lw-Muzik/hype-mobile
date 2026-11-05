/// Stereo Expand's setting: the range, the label, and what an earlier
/// version's width-and-switch setting becomes.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/models/stereo_expand.dart';

void main() {
  group('migrating the old width (0..2, 1 = unchanged) and switch', () {
    test('widening carries over', () {
      expect(StereoExpand.migrate(legacyEnabled: true, legacyWidth: 1.5), 0.5);
      expect(StereoExpand.migrate(legacyEnabled: true, legacyWidth: 2.0), 1.0);
    });

    test('unchanged or narrowing becomes off — it no longer narrows', () {
      expect(StereoExpand.migrate(legacyEnabled: true, legacyWidth: 1.0), 0);
      expect(StereoExpand.migrate(legacyEnabled: true, legacyWidth: 0.3), 0);
    });

    test('switched off, or never set, is off', () {
      expect(StereoExpand.migrate(legacyEnabled: false, legacyWidth: 2.0), 0);
      expect(StereoExpand.migrate(), 0);
    });
  });

  test('clamped to 0..1', () {
    expect(StereoExpand.clamp(-1), 0);
    expect(StereoExpand.clamp(2), 1);
  });

  test('shown in whole percent', () {
    expect(StereoExpand.label(0), '0%');
    expect(StereoExpand.label(0.374), '37%');
    expect(StereoExpand.label(1), '100%');
  });
}
