import 'package:eq_app/audio/dsp_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  orderingTests();
  systemWideTests();
  group('masterVolumeFor', () {
    test('DVC on passes the level through', () {
      expect(masterVolumeFor(dvcEnabled: true, dvcGainDb: -12), -12);
    });

    test('DVC on clamps below -30 to silence', () {
      expect(masterVolumeFor(dvcEnabled: true, dvcGainDb: -45), -30);
    });

    test('DVC on clamps above 0 to unity', () {
      expect(masterVolumeFor(dvcEnabled: true, dvcGainDb: 6), 0);
    });

    test('DVC off is always unity', () {
      expect(masterVolumeFor(dvcEnabled: false, dvcGainDb: -12), 0);
    });
  });
}

void orderingTests() {
  group('dvcToggleSteps', () {
    test('enable pushes master volume, flushes a paused buffer, then raises', () {
      expect(dvcToggleSteps(enable: true),
          [DvcStep.pushMasterVolume, DvcStep.flushIfPaused, DvcStep.enableDvc]);
    });
    test('disable restores the system volume before resetting the master', () {
      expect(dvcToggleSteps(enable: false),
          [DvcStep.disableDvc, DvcStep.pushMasterVolume]);
    });
  });
}

void systemWideTests() {
  group('dvcInEffect', () {
    test('Android with DVC on, system-wide off: in effect', () {
      expect(
        dvcInEffect(isAndroid: true, dvcEnabled: true, systemWide: false),
        isTrue,
      );
    });
    test('system-wide suspends DVC', () {
      expect(
        dvcInEffect(isAndroid: true, dvcEnabled: true, systemWide: true),
        isFalse,
      );
    });
    test('never in effect off Android', () {
      expect(
        dvcInEffect(isAndroid: false, dvcEnabled: true, systemWide: false),
        isFalse,
      );
    });
    test('DVC off is never in effect', () {
      expect(
        dvcInEffect(isAndroid: true, dvcEnabled: false, systemWide: false),
        isFalse,
      );
    });
  });

  group('systemWideDvcSteps', () {
    test('turning system-wide on with DVC suspends it in the safe order', () {
      expect(
        systemWideDvcSteps(systemWideOn: true, dvcEnabled: true),
        [DvcStep.disableDvc, DvcStep.pushMasterVolume],
      );
    });
    test('turning it off with DVC resumes it', () {
      expect(
        systemWideDvcSteps(systemWideOn: false, dvcEnabled: true),
        [DvcStep.pushMasterVolume, DvcStep.flushIfPaused, DvcStep.enableDvc],
      );
    });
    test('with DVC off there is nothing to do either way', () {
      expect(systemWideDvcSteps(systemWideOn: true, dvcEnabled: false), isEmpty);
      expect(systemWideDvcSteps(systemWideOn: false, dvcEnabled: false), isEmpty);
    });
  });

  group('deferDvcResume', () {
    test('waits while Hype is in the background and silent', () {
      expect(deferDvcResume(appInForeground: false, hypePlaying: false), isTrue);
    });
    test('runs at once in the foreground', () {
      expect(deferDvcResume(appInForeground: true, hypePlaying: false), isFalse);
      expect(deferDvcResume(appInForeground: true, hypePlaying: true), isFalse);
    });
    test('runs at once when Hype itself is playing', () {
      expect(deferDvcResume(appInForeground: false, hypePlaying: true), isFalse);
    });
  });

  test('the disabled-control reason', () {
    expect(
      kSystemWideReason,
      'Not available while the equalizer applies to all apps',
    );
  });
}
