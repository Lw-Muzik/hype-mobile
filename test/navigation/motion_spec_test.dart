import 'package:eq_app/navigation/motion_spec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cosEase endpoints, midpoint and clamping', () {
    expect(cosEase(0), 0);
    expect(cosEase(0.5), closeTo(0.5, 1e-12));
    expect(cosEase(1), closeTo(1, 1e-12));
    expect(cosEase(-1), 0);
    expect(cosEase(2), closeTo(1, 1e-12));
  });

  test('quartOut and cubicOut', () {
    expect(quartOut(0.5), 0.9375);
    expect(cubicOut(0.5), 0.875);
    expect(quartOut(-1), 0);
    expect(cubicOut(2), 1);
  });

  Duration ms(int v) => Duration(milliseconds: v);
  final table = <String, Object>{
    'listPage': MotionSpec.listPage,
    'listSibling': MotionSpec.listSibling,
    'containerEnterPlayer': MotionSpec.containerEnterPlayer,
    'containerLeavePlayer': MotionSpec.containerLeavePlayer,
    'miniPlayer': MotionSpec.miniPlayer,
    'miniPlayerRise': MotionSpec.miniPlayerRise,
    'dragSlop': MotionSpec.dragSlop,
    'dragTravel': MotionSpec.dragTravel,
    'commitProgress': MotionSpec.commitProgress,
    'flingVelocity': MotionSpec.flingVelocity,
    'settleCommit': MotionSpec.settleCommit,
    'settleCancel': MotionSpec.settleCancel,
    'settleMinCommit': MotionSpec.settleMinCommit,
    'settleMinCancel': MotionSpec.settleMinCancel,
    'glideMin': MotionSpec.glideMin,
    'glideMax': MotionSpec.glideMax,
    'cancelGlideMin': MotionSpec.cancelGlideMin,
    'playerExitScale': MotionSpec.playerExitScale,
    'playerEnterFrom': MotionSpec.playerEnterFrom,
    'libraryEnterFrom': MotionSpec.libraryEnterFrom,
    'libraryExitTo': MotionSpec.libraryExitTo,
    'listOpenOldTo': MotionSpec.listOpenOldTo,
    'gridOpenOldTo': MotionSpec.gridOpenOldTo,
    'listNewFrom': MotionSpec.listNewFrom,
    'gridOpenNewFrom': MotionSpec.gridOpenNewFrom,
    'chromeHideScale': MotionSpec.chromeHideScale,
    'backRubberBand': MotionSpec.backRubberBand,
    'backRubberReturn': MotionSpec.backRubberReturn,
    'zoomGain': MotionSpec.zoomGain,
    'zoomSettle': MotionSpec.zoomSettle,
    'zoomGlideMin': MotionSpec.zoomGlideMin,
    'zoomRubberBand': MotionSpec.zoomRubberBand,
    'zoomEndReturn': MotionSpec.zoomEndReturn,
    'zoomOptions': MotionSpec.zoomOptions,
  };
  final expected = <String, Object>{
    'listPage': ms(250),
    'listSibling': ms(150),
    'containerEnterPlayer': ms(500),
    'containerLeavePlayer': ms(250),
    'miniPlayer': ms(500),
    'miniPlayerRise': 74.0,
    'dragSlop': 8.0,
    'dragTravel': 360.0,
    'commitProgress': 0.3,
    'flingVelocity': 500.0,
    'settleCommit': ms(250),
    'settleCancel': ms(500),
    'settleMinCommit': ms(100),
    'settleMinCancel': ms(167),
    'glideMin': 4.0,
    'glideMax': 8.0,
    'cancelGlideMin': 3.5,
    'playerExitScale': 1.25,
    'playerEnterFrom': 0.75,
    'libraryEnterFrom': 0.5,
    'libraryExitTo': 1.5,
    'listOpenOldTo': 1.5,
    'gridOpenOldTo': 2.0,
    'listNewFrom': 0.5,
    'gridOpenNewFrom': 0.25,
    'chromeHideScale': 0.75,
    'backRubberBand': 0.25,
    'backRubberReturn': ms(350),
    'zoomGain': 1.25,
    'zoomSettle': ms(500),
    'zoomGlideMin': 2.0,
    'zoomRubberBand': 0.0894,
    'zoomEndReturn': ms(350),
    'zoomOptions': ms(250),
  };

  test('every MotionSpec constant has its record value', () {
    expect(table.keys.toSet(), expected.keys.toSet());
    expected.forEach((name, value) {
      expect(table[name], value, reason: name);
    });
  });
}
