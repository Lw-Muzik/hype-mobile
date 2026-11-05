import 'package:eq_app/audio/headset/headset_settings.dart';
import 'package:eq_app/player/remote_commands.dart';

/// Android key codes for the media keys Hype reacts to.
abstract final class MediaKey {
  static const headsetHook = 79,
      playPause = 85,
      stop = 86,
      next = 87,
      previous = 88,
      play = 126,
      pause = 127;
  static const handled = {79, 85, 86, 87, 88, 126, 127};
}

enum ButtonSource { wired, bluetooth }

/// One key event from the platform, stamped with a clock reading.
class ButtonEvent {
  const ButtonEvent({
    required this.keyCode,
    required this.down,
    required this.atMs,
    required this.source,
    this.longPress = false,
  });

  final int keyCode;
  final bool down;
  final int atMs;
  final ButtonSource source;

  /// A long press the system turned into a voice-search request.
  final bool longPress;
}

/// A press (or run of presses) turned into a transport command.
class RecognizedPress {
  const RecognizedPress(
    this.command, {
    required this.presses,
    this.long = false,
    required this.source,
  });

  final RemoteCommand command;
  final int presses;
  final bool long;
  final ButtonSource source;

  @override
  bool operator ==(Object other) =>
      other is RecognizedPress &&
      other.command == command &&
      other.presses == presses &&
      other.long == long &&
      other.source == source;

  @override
  int get hashCode => Object.hash(command, presses, long, source);

  @override
  String toString() =>
      'RecognizedPress(${command.name} x$presses${long ? ' long' : ''}, '
      '${source.name})';
}

/// How long after a release another press still joins the sequence.
const kMultiPressWindowMs = 400;

/// How long a button must be held to count as a long press.
const kLongPressMs = 600;

/// Turns raw key events into [RecognizedPress]es. Pure: the caller supplies
/// the clock and calls [onDeadline] when [deadlineMs] passes.
class PressRecognizer {
  // Multi/long mode state of the press that is down or pending.
  ButtonMode? _kind;
  bool _isDown = false;
  int _count = 0;
  int? _deadline;
  bool _longFired = false;
  ButtonSource _source = ButtonSource.wired;

  /// When [onDeadline] next has something to do, or null.
  int? get deadlineMs => _deadline;

  void _reset() {
    _kind = null;
    _isDown = false;
    _count = 0;
    _deadline = null;
    _longFired = false;
  }

  RecognizedPress _sequence() {
    final n = _count;
    final cmd = n == 1
        ? RemoteCommand.toggle
        : n == 2
        ? RemoteCommand.next
        : RemoteCommand.previous;
    return RecognizedPress(cmd, presses: n, source: _source);
  }

  /// Settles whatever is due at [nowMs].
  List<RecognizedPress> onDeadline(int nowMs, {required bool playing}) {
    final d = _deadline;
    if (d == null || nowMs < d) return const [];
    if (_kind == ButtonMode.longPressNext) {
      // Held to the long-press mark.
      _deadline = null;
      if (!playing) return const [];
      _longFired = true;
      return [
        RecognizedPress(
          RemoteCommand.next,
          presses: 1,
          long: true,
          source: _source,
        ),
      ];
    }
    // Multi-press: the window closed (or a press never released).
    final out = _count > 0 ? [_sequence()] : <RecognizedPress>[];
    _reset();
    return out;
  }

  List<RecognizedPress> onEvent(
    ButtonEvent e, {
    required ButtonMode mode,
    required bool playing,
  }) {
    final out = <RecognizedPress>[...onDeadline(e.atMs, playing: playing)];
    RecognizedPress one(RemoteCommand c, {bool long = false}) =>
        RecognizedPress(c, presses: 1, long: long, source: e.source);

    if (e.longPress) {
      if (mode == ButtonMode.longPressNext && playing) {
        out.add(one(RemoteCommand.next, long: true));
      }
      return out;
    }

    switch (e.keyCode) {
      case MediaKey.play:
        if (e.down) out.add(one(RemoteCommand.play));
      case MediaKey.pause:
        if (e.down) out.add(one(RemoteCommand.pause));
      case MediaKey.stop:
        if (e.down) out.add(one(RemoteCommand.stop));
      case MediaKey.next:
        if (e.down) out.add(one(RemoteCommand.next));
      case MediaKey.previous:
        if (e.down) out.add(one(RemoteCommand.previous));
      case MediaKey.headsetHook:
      case MediaKey.playPause:
        _onHook(e, mode, out);
    }
    return out;
  }

  void _onHook(ButtonEvent e, ButtonMode mode, List<RecognizedPress> out) {
    if (e.down) {
      if (_isDown) return; // a resend of a press already down
      _isDown = true;
      _source = e.source;
      if (_count == 0 || _kind == null) _kind = mode;
      switch (_kind!) {
        case ButtonMode.singlePress:
          _deadline = null;
        case ButtonMode.longPressNext:
          _longFired = false;
          _deadline = e.atMs + kLongPressMs;
        case ButtonMode.multiPress:
          // While a press is down the sequence waits for its release; the
          // long-press mark only guards against a release that is lost (a
          // first press held past it settles to nothing, as a long press
          // never reaches the app in this mode).
          _deadline = e.atMs + kLongPressMs;
      }
      return;
    }
    // Release.
    if (!_isDown) return;
    final kind = _kind ?? mode;
    switch (kind) {
      case ButtonMode.singlePress:
        out.add(
          RecognizedPress(RemoteCommand.toggle, presses: 1, source: e.source),
        );
        _reset();
      case ButtonMode.longPressNext:
        if (!_longFired) {
          out.add(
            RecognizedPress(RemoteCommand.toggle, presses: 1, source: e.source),
          );
        }
        _reset();
      case ButtonMode.multiPress:
        _isDown = false;
        _count++;
        _source = e.source;
        _deadline = e.atMs + kMultiPressWindowMs;
    }
  }
}

/// Wired or Bluetooth, from the key's device and the current output route.
ButtonSource classifyButtonSource({
  required int deviceId,
  String? deviceName,
  required bool bluetoothOutput,
}) {
  final name = deviceName?.toLowerCase() ?? '';
  if (name.contains('bluetooth') ||
      name.contains('avrcp') ||
      name.contains('a2dp')) {
    return ButtonSource.bluetooth;
  }
  // Synthesised events (id <= 0) carry no device: trust the output route.
  if (deviceId <= 0) {
    return bluetoothOutput ? ButtonSource.bluetooth : ButtonSource.wired;
  }
  return ButtonSource.wired;
}

/// Reads the platform channel payload; null for anything Hype ignores.
ButtonEvent? buttonEventFromPlatform(
  Map<Object?, Object?> m, {
  required int atMs,
}) {
  final bt = m['btOutput'] == true;
  if (m['longPress'] == true) {
    return ButtonEvent(
      keyCode: MediaKey.headsetHook,
      down: true,
      atMs: atMs,
      source: bt ? ButtonSource.bluetooth : ButtonSource.wired,
      longPress: true,
    );
  }
  final keyCode = m['keyCode'];
  final down = m['down'];
  if (keyCode is! int || down is! bool) return null;
  if (!MediaKey.handled.contains(keyCode)) return null;
  final repeat = m['repeat'];
  if (repeat != null && (repeat is! int || repeat > 0)) return null;
  final deviceId = m['deviceId'];
  final name = m['deviceName'];
  return ButtonEvent(
    keyCode: keyCode,
    down: down,
    atMs: atMs,
    source: classifyButtonSource(
      deviceId: deviceId is int ? deviceId : -1,
      deviceName: name is String ? name : null,
      bluetoothOutput: bt,
    ),
  );
}

/// Whether a hold of the headset button on [source] is wanted as a long press:
/// the source's mode is Long press, or Disable default long press swallows the
/// system's voice search for both. When it is not, the system's voice search
/// should go on to the app that handles it.
bool longPressWanted(HeadsetSettings s, ButtonSource source) =>
    s.respondToButtons &&
    (s.disableDefaultLongPress ||
        (source == ButtonSource.bluetooth
                ? s.bluetoothButtons
                : s.wiredButtons) ==
            ButtonMode.longPressNext);

/// Whether the native side should take over the system's long-press
/// voice-search proxy (for at least one source).
bool voiceProxyEnabled(HeadsetSettings s) =>
    longPressWanted(s, ButtonSource.wired) ||
    longPressWanted(s, ButtonSource.bluetooth);

/// Beeps and vibration for one command.
class ButtonFeedback {
  const ButtonFeedback({this.beeps = 0, this.vibrate = false});

  final int beeps;
  final bool vibrate;

  bool get isNone => beeps == 0 && !vibrate;

  @override
  bool operator ==(Object other) =>
      other is ButtonFeedback &&
      other.beeps == beeps &&
      other.vibrate == vibrate;

  @override
  int get hashCode => Object.hash(beeps, vibrate);

  @override
  String toString() => 'ButtonFeedback(beeps: $beeps, vibrate: $vibrate)';
}

ButtonFeedback feedbackFor(RecognizedPress p, HeadsetSettings s) {
  var beeps = 0;
  if (s.beep) {
    if (p.long) {
      beeps = 1;
    } else if (p.command == RemoteCommand.next) {
      beeps = 2;
    } else if (p.command == RemoteCommand.previous) {
      beeps = 3;
    } else if (s.beepMore) {
      beeps = 1;
    }
  }
  return ButtonFeedback(beeps: beeps, vibrate: s.vibrate);
}

/// ToneGenerator volume (0...100): 60 is 20 dB under the stream; with DVC in
/// effect the beep follows the DVC gain so it stays 20 dB under the music.
int beepToneVolume({required bool dvcInEffect, required double dvcGainDb}) {
  if (!dvcInEffect || !dvcGainDb.isFinite) return 60;
  return (60 + 2 * dvcGainDb).round().clamp(0, 100);
}
