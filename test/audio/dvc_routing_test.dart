import 'package:eq_app/audio/dsp_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  orderingTests();
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
    test('enable pushes the master volume before raising the system stream', () {
      expect(dvcToggleSteps(enable: true),
          [DvcStep.pushMasterVolume, DvcStep.enableDvc]);
    });
    test('disable restores the system volume before resetting the master', () {
      expect(dvcToggleSteps(enable: false),
          [DvcStep.disableDvc, DvcStep.pushMasterVolume]);
    });
  });
}
