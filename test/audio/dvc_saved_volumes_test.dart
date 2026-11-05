import 'package:eq_app/audio/dvc/dvc_saved_volumes.dart';
import 'package:flutter_test/flutter_test.dart';

const max = 15;

void main() {
  const none = DvcSavedVolumes();

  test('enable saves a missing original; an unchanged raise keeps it', () {
    final a = none.enable('bluetooth:A', 4, max);
    expect(a.saved, {'bluetooth:A': 4});
    expect(a.enable('bluetooth:A', max, max).saved, {'bluetooth:A': 4});
    expect(a.enable('speaker', 7, max).saved, {'bluetooth:A': 4, 'speaker': 7});
  });

  test('re-enable with the volume changed by the listener refreshes it', () {
    final a = none.enable('bluetooth:A', 4, max);
    expect(a.enable('bluetooth:A', 9, max).saved['bluetooth:A'], 9);
  });

  test('never saves max: a device found at max gets half', () {
    expect(none.enable('speaker', max, max).saved['speaker'], 8);
    expect(dvcSafeOriginal(15, 15), 8);
    expect(dvcSafeOriginal(7, 15), 7);
  });

  test('unknown key: nothing saved, never raised', () {
    final s = none.enable('', 5, max);
    expect(s.saved, isEmpty);
    expect(s.canRaise(''), isFalse);
    expect(none.canRaise('speaker'), isFalse);
    expect(none.enable('speaker', 5, max).canRaise('speaker'), isTrue);
  });

  test('repro: headset A, disconnect, disable and re-enable on the speaker', () {
    var s = none.enable('bluetooth:A', 4, max);
    s = s.release(); // A leaves: output changed
    final d1 = s.realDisable('speaker', 7, max);
    expect(d1.restoreIndex, isNull, reason: 'speaker was never raised');
    s = d1.state.enable('speaker', 7, max);
    expect(s.saved, {'bluetooth:A': 4, 'speaker': 7});
    final d2 = s.realDisable('speaker', max, max); // speaker raised by us
    expect(d2.restoreIndex, 7);
    expect(d2.state.saved, {'bluetooth:A': 4});
    final back = d2.state.deviceActive('bluetooth:A', max, max);
    expect(back.restoreIndex, 4);
    expect(back.state.saved, isEmpty);
    expect(back.state.disabling, isFalse);
  });

  test('wired -> BT abs (release) -> speaker (route enable) -> disable', () {
    var s = none.enable('wired:h', 6, max);
    s = s.release();
    s = s.enable('speaker', 9, max);
    final d = s.realDisable('speaker', max, max);
    expect(d.restoreIndex, 9);
    expect(d.state.deviceActive('bluetooth:abs', 3, max).restoreIndex, isNull);
    expect(d.state.deviceActive('wired:h', max, max).restoreIndex, 6);
  });

  test('same device, No DVC turned on: real disable restores, no blast', () {
    final s = none.enable('bluetooth:A', 5, max);
    final d = s.realDisable('bluetooth:A', max, max);
    expect(d.restoreIndex, 5);
    expect(dvcOutputChanged(
        previous: 'bluetooth:A', next: 'bluetooth:A', routeEvent: false),
        isFalse);
  });

  test('output change detection', () {
    expect(dvcOutputChanged(
        previous: 'speaker', next: 'bluetooth:A', routeEvent: true), isTrue);
    expect(dvcOutputChanged(
        previous: 'speaker', next: 'speaker', routeEvent: true), isFalse);
    // A bare type is any of several devices: doubt means changed.
    expect(dvcOutputChanged(
        previous: 'bluetooth', next: 'bluetooth', routeEvent: true), isTrue);
    // A settings re-evaluation never changes the output.
    expect(dvcOutputChanged(
        previous: 'bluetooth', next: 'bluetooth', routeEvent: false), isFalse);
  });

  test('same output re-keyed: no max saved', () {
    // The first key lost its id (bare "bluetooth") while still at our raise.
    final s = none.enable('bluetooth', max, max);
    expect(s.saved['bluetooth'], isNot(max));
  });

  test('stale entry, listener changed the volume: dropped without writing', () {
    final d = none.enable('bluetooth:A', 4, max).realDisable('speaker', 7, max);
    final back = d.state.deviceActive('bluetooth:A', 11, max);
    expect(back.restoreIndex, isNull);
    expect(back.state.saved, isEmpty);
  });

  test('pending restored at activation, and survives a restart', () {
    final d = none
        .enable('bluetooth:A', 4, max)
        .enable('speaker', 7, max)
        .realDisable('speaker', max, max);
    final restarted = DvcSavedVolumes.fromJson(d.state.toJson());
    expect(restarted.saved, {'bluetooth:A': 4});
    expect(restarted.disabling, isTrue);
    expect(restarted.deviceActive('bluetooth:A', max, max).restoreIndex, 4);
    expect(DvcSavedVolumes.fromJson('garbage').saved, isEmpty);
    expect(DvcSavedVolumes.fromJson(null).saved, isEmpty);
  });

  test('entries only restore after a real disable', () {
    final s = none.enable('bluetooth:A', 4, max);
    expect(s.deviceActive('bluetooth:A', max, max).restoreIndex, isNull);
  });

  test('re-enabling while entries wait keeps them', () {
    final d = none.enable('bluetooth:A', 4, max).realDisable('speaker', 7, max);
    final s = d.state.enable('speaker', 7, max);
    expect(s.disabling, isFalse);
    expect(s.saved['bluetooth:A'], 4);
  });
}
