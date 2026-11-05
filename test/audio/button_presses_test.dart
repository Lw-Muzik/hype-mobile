import 'package:eq_app/audio/headset/button_presses.dart';
import 'package:eq_app/audio/headset/headset_settings.dart';
import 'package:eq_app/player/remote_commands.dart';
import 'package:flutter_test/flutter_test.dart';

const _w = ButtonSource.wired;

ButtonEvent _e(int key, bool down, int at, {bool lp = false}) =>
    ButtonEvent(keyCode: key, down: down, atMs: at, source: _w, longPress: lp);

RecognizedPress _p(
  RemoteCommand c, {
  int n = 1,
  bool long = false,
  ButtonSource s = _w,
}) => RecognizedPress(c, presses: n, long: long, source: s);

List<RecognizedPress> _ev(
  PressRecognizer r,
  ButtonEvent e, {
  ButtonMode m = ButtonMode.multiPress,
  bool playing = true,
}) => r.onEvent(e, mode: m, playing: playing);

void _press(PressRecognizer r, int down, int up) {
  _ev(r, _e(MediaKey.headsetHook, true, down));
  _ev(r, _e(MediaKey.headsetHook, false, up));
}

void main() {
  group('multi press', () {
    test('one press emits toggle at the deadline only', () {
      final r = PressRecognizer();
      expect(_ev(r, _e(79, true, 0)), isEmpty);
      expect(_ev(r, _e(79, false, 80)), isEmpty);
      expect(r.deadlineMs, 480);
      expect(r.onDeadline(479, playing: true), isEmpty);
      expect(r.onDeadline(480, playing: true), [_p(RemoteCommand.toggle)]);
      expect(r.deadlineMs, isNull);
    });

    test('second press -> next x2 at 730', () {
      final r = PressRecognizer();
      _press(r, 0, 80);
      _press(r, 250, 330);
      expect(r.deadlineMs, 730);
      expect(r.onDeadline(729, playing: true), isEmpty);
      expect(r.onDeadline(730, playing: true), [_p(RemoteCommand.next, n: 2)]);
    });

    test('third press -> nothing until 960, then previous x3', () {
      final r = PressRecognizer();
      _press(r, 0, 80);
      _press(r, 250, 330);
      _press(r, 500, 560);
      expect(r.deadlineMs, 960);
      expect(r.onDeadline(959, playing: true), isEmpty);
      expect(r.onDeadline(960, playing: true), [
        _p(RemoteCommand.previous, n: 3),
      ]);
    });

    test('fourth press extends the sequence -> previous x4', () {
      final r = PressRecognizer();
      _press(r, 0, 80);
      _press(r, 250, 330);
      _press(r, 500, 560);
      _press(r, 900, 960);
      expect(r.onDeadline(1359, playing: true), isEmpty);
      expect(r.onDeadline(1360, playing: true), [
        _p(RemoteCommand.previous, n: 4),
      ]);
    });

    test('press down inside a pending sequence is not flushed early', () {
      final r = PressRecognizer();
      _press(r, 0, 80);
      _ev(r, _e(79, true, 250));
      expect(r.onDeadline(480, playing: true), isEmpty);
      _ev(r, _e(79, false, 330));
      expect(r.onDeadline(730, playing: true), [_p(RemoteCommand.next, n: 2)]);
    });

    test('PLAY and PAUSE emit at once', () {
      final r = PressRecognizer();
      expect(_ev(r, _e(126, true, 0)), [_p(RemoteCommand.play)]);
      expect(_ev(r, _e(126, false, 10)), isEmpty);
      expect(_ev(r, _e(127, true, 20)), [_p(RemoteCommand.pause)]);
    });

    test('new press after the window settles the old one first', () {
      final r = PressRecognizer();
      _press(r, 0, 80);
      expect(_ev(r, _e(79, true, 500)), [_p(RemoteCommand.toggle)]);
      expect(_ev(r, _e(79, false, 560)), isEmpty);
      expect(r.deadlineMs, 960);
    });

    test('voice-key resend (down and up both at 1000) is one press', () {
      final r = PressRecognizer();
      _ev(r, _e(79, true, 1000));
      _ev(r, _e(79, false, 1000));
      expect(r.onDeadline(1400, playing: true), [_p(RemoteCommand.toggle)]);
    });

    test('playPause key behaves like the hook', () {
      final r = PressRecognizer();
      _ev(r, _e(85, true, 0));
      _ev(r, _e(85, false, 50));
      expect(r.onDeadline(450, playing: true), [_p(RemoteCommand.toggle)]);
    });
  });

  group('single press', () {
    test('toggle on release, no deadline', () {
      final r = PressRecognizer();
      const m = ButtonMode.singlePress;
      expect(_ev(r, _e(79, true, 0), m: m), isEmpty);
      expect(_ev(r, _e(79, false, 80), m: m), [_p(RemoteCommand.toggle)]);
      expect(r.deadlineMs, isNull);
    });
  });

  group('long press mode', () {
    const m = ButtonMode.longPressNext;
    test('short press toggles on release', () {
      final r = PressRecognizer();
      _ev(r, _e(79, true, 0), m: m);
      expect(r.deadlineMs, 600);
      expect(_ev(r, _e(79, false, 200), m: m), [_p(RemoteCommand.toggle)]);
      expect(r.deadlineMs, isNull);
    });

    test('held while playing -> next (long); release is silent', () {
      final r = PressRecognizer();
      _ev(r, _e(79, true, 0), m: m);
      expect(r.onDeadline(600, playing: true), [
        _p(RemoteCommand.next, long: true),
      ]);
      expect(_ev(r, _e(79, false, 900), m: m), isEmpty);
    });

    test('held while not playing -> nothing, release toggles', () {
      final r = PressRecognizer();
      _ev(r, _e(79, true, 0), m: m);
      expect(r.onDeadline(600, playing: false), isEmpty);
      expect(_ev(r, _e(79, false, 900), m: m, playing: false), [
        _p(RemoteCommand.toggle),
      ]);
    });

    test('release past the mark without a deadline call still fires long', () {
      final r = PressRecognizer();
      _ev(r, _e(79, true, 0), m: m);
      expect(_ev(r, _e(79, false, 900), m: m), [
        _p(RemoteCommand.next, long: true),
      ]);
    });
  });

  group('system long press event', () {
    test('long mode while playing -> next (long)', () {
      final r = PressRecognizer();
      expect(_ev(r, _e(79, true, 0, lp: true), m: ButtonMode.longPressNext), [
        _p(RemoteCommand.next, long: true),
      ]);
    });
    test('multi mode -> nothing', () {
      expect(_ev(PressRecognizer(), _e(79, true, 0, lp: true)), isEmpty);
    });
    test('not playing -> nothing', () {
      expect(
        _ev(
          PressRecognizer(),
          _e(79, true, 0, lp: true),
          m: ButtonMode.longPressNext,
          playing: false,
        ),
        isEmpty,
      );
    });
  });

  group('direct keys', () {
    for (final m in ButtonMode.values) {
      test('NEXT/PREVIOUS down emit, up silent in ${m.name}', () {
        final r = PressRecognizer();
        expect(_ev(r, _e(87, true, 0), m: m), [_p(RemoteCommand.next)]);
        expect(_ev(r, _e(87, false, 10), m: m), isEmpty);
        expect(_ev(r, _e(88, true, 20), m: m), [_p(RemoteCommand.previous)]);
        expect(_ev(r, _e(88, false, 30), m: m), isEmpty);
      });
    }
    test('STOP down -> stop', () {
      expect(_ev(PressRecognizer(), _e(86, true, 0)), [_p(RemoteCommand.stop)]);
    });
  });

  group('classifyButtonSource', () {
    test('cases', () {
      expect(
        classifyButtonSource(
          deviceId: 7,
          deviceName: 'h2w headset',
          bluetoothOutput: false,
        ),
        ButtonSource.wired,
      );
      expect(
        classifyButtonSource(deviceId: -1, bluetoothOutput: true),
        ButtonSource.bluetooth,
      );
      expect(
        classifyButtonSource(deviceId: -1, bluetoothOutput: false),
        ButtonSource.wired,
      );
      expect(
        classifyButtonSource(
          deviceId: 5,
          deviceName: 'AVRCP',
          bluetoothOutput: false,
        ),
        ButtonSource.bluetooth,
      );
      expect(
        classifyButtonSource(
          deviceId: 3,
          deviceName: 'Bluetooth HID',
          bluetoothOutput: false,
        ),
        ButtonSource.bluetooth,
      );
    });
  });

  group('buttonEventFromPlatform', () {
    test('hook down from a wired headset', () {
      final e = buttonEventFromPlatform({
        'keyCode': 79,
        'down': true,
        'repeat': 0,
        'deviceId': 4,
        'deviceName': 'h2w headset',
        'btOutput': false,
      }, atMs: 123)!;
      expect(e.keyCode, 79);
      expect(e.down, isTrue);
      expect(e.atMs, 123);
      expect(e.source, ButtonSource.wired);
      expect(e.longPress, isFalse);
    });
    test('null for repeat, unhandled key, malformed', () {
      expect(
        buttonEventFromPlatform({
          'keyCode': 79,
          'down': true,
          'repeat': 1,
        }, atMs: 0),
        isNull,
      );
      expect(
        buttonEventFromPlatform({
          'keyCode': 24,
          'down': true,
          'repeat': 0,
        }, atMs: 0),
        isNull,
      );
      expect(buttonEventFromPlatform({'keyCode': 'x'}, atMs: 0), isNull);
    });
    test('long press from bluetooth', () {
      final e = buttonEventFromPlatform({
        'longPress': true,
        'btOutput': true,
      }, atMs: 5)!;
      expect(e.longPress, isTrue);
      expect(e.source, ButtonSource.bluetooth);
    });
  });

  group('voiceProxyEnabled', () {
    test('defaults off', () {
      expect(voiceProxyEnabled(const HeadsetSettings()), isFalse);
    });
    test('enabled by settings', () {
      expect(
        voiceProxyEnabled(const HeadsetSettings(disableDefaultLongPress: true)),
        isTrue,
      );
      expect(
        voiceProxyEnabled(
          const HeadsetSettings(wiredButtons: ButtonMode.longPressNext),
        ),
        isTrue,
      );
      expect(
        voiceProxyEnabled(
          const HeadsetSettings(bluetoothButtons: ButtonMode.longPressNext),
        ),
        isTrue,
      );
    });
    test('off when respondToButtons is off', () {
      expect(
        voiceProxyEnabled(
          const HeadsetSettings(
            respondToButtons: false,
            disableDefaultLongPress: true,
            wiredButtons: ButtonMode.longPressNext,
          ),
        ),
        isFalse,
      );
    });
  });

  group('longPressWanted', () {
    bool w(HeadsetSettings s, ButtonSource src) => longPressWanted(s, src);
    const lp = ButtonMode.longPressNext;
    const multi = ButtonMode.multiPress;

    test('follows the mode of each source', () {
      const wiredOnly = HeadsetSettings(wiredButtons: lp, bluetoothButtons: multi);
      expect(w(wiredOnly, ButtonSource.wired), isTrue);
      expect(w(wiredOnly, ButtonSource.bluetooth), isFalse);
      const btOnly = HeadsetSettings(wiredButtons: multi, bluetoothButtons: lp);
      expect(w(btOnly, ButtonSource.wired), isFalse);
      expect(w(btOnly, ButtonSource.bluetooth), isTrue);
      const both = HeadsetSettings(wiredButtons: lp, bluetoothButtons: lp);
      expect(w(both, ButtonSource.wired), isTrue);
      expect(w(both, ButtonSource.bluetooth), isTrue);
      expect(w(const HeadsetSettings(), ButtonSource.wired), isFalse);
      expect(w(const HeadsetSettings(), ButtonSource.bluetooth), isFalse);
    });

    test('Disable default long press covers both sources', () {
      const s = HeadsetSettings(disableDefaultLongPress: true);
      expect(w(s, ButtonSource.wired), isTrue);
      expect(w(s, ButtonSource.bluetooth), isTrue);
    });

    test('nothing when Respond to buttons is off', () {
      const s = HeadsetSettings(
        respondToButtons: false,
        disableDefaultLongPress: true,
        wiredButtons: lp,
        bluetoothButtons: lp,
      );
      expect(w(s, ButtonSource.wired), isFalse);
      expect(w(s, ButtonSource.bluetooth), isFalse);
    });

    test('the proxy is on when either source wants it', () {
      expect(
        voiceProxyEnabled(
          const HeadsetSettings(wiredButtons: multi, bluetoothButtons: lp),
        ),
        isTrue,
      );
    });
  });

  group('feedbackFor', () {
    const s = HeadsetSettings();
    test('beeps by command', () {
      expect(feedbackFor(_p(RemoteCommand.next, n: 2), s).beeps, 2);
      expect(feedbackFor(_p(RemoteCommand.previous, n: 3), s).beeps, 3);
      expect(feedbackFor(_p(RemoteCommand.previous, n: 4), s).beeps, 3);
      expect(feedbackFor(_p(RemoteCommand.next, long: true), s).beeps, 1);
    });
    test('single hardware NEXT -> 2 beeps, PREVIOUS -> 3 beeps', () {
      expect(feedbackFor(_p(RemoteCommand.next), s).beeps, 2);
      expect(feedbackFor(_p(RemoteCommand.previous), s).beeps, 3);
    });
    test('toggle: 0, or 1 with beepMore', () {
      expect(feedbackFor(_p(RemoteCommand.toggle), s).beeps, 0);
      expect(
        feedbackFor(_p(RemoteCommand.toggle), s.copyWith(beepMore: true)).beeps,
        1,
      );
    });
    test('beep off silences beepMore', () {
      expect(
        feedbackFor(
          _p(RemoteCommand.toggle),
          s.copyWith(beep: false, beepMore: true),
        ).beeps,
        0,
      );
    });
    test('vibrate', () {
      final f = feedbackFor(
        _p(RemoteCommand.toggle),
        s.copyWith(vibrate: true),
      );
      expect(f.vibrate, isTrue);
      expect(f.isNone, isFalse);
      expect(feedbackFor(_p(RemoteCommand.toggle), s).isNone, isTrue);
    });
  });

  test('beepToneVolume', () {
    expect(beepToneVolume(dvcInEffect: false, dvcGainDb: -10), 60);
    expect(beepToneVolume(dvcInEffect: true, dvcGainDb: 0), 60);
    expect(beepToneVolume(dvcInEffect: true, dvcGainDb: -10), 40);
    expect(beepToneVolume(dvcInEffect: true, dvcGainDb: -25), 10);
    expect(beepToneVolume(dvcInEffect: true, dvcGainDb: -30), 0);
    expect(beepToneVolume(dvcInEffect: true, dvcGainDb: 40), 100);
  });
}
