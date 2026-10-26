import 'package:flutter_test/flutter_test.dart';

import 'package:eq_app/services/ytmusic/parse/yt_web_video.dart';

Map<String, Object?> fmt(
  int height, {
  String mime = 'video/mp4; codecs="avc1.4d401f"',
  int bitrate = 1000,
  String? url,
  int width = 0,
}) =>
    {
      'itag': height,
      'mimeType': mime,
      'bitrate': bitrate,
      'height': height,
      'width': width == 0 ? height * 16 ~/ 9 : width,
      if (url != 'none')
        'url': url ??
            'https://rr1.googlevideo.com/videoplayback?expire=1793062416&itag=$height',
    };

void main() {
  group('pickWebVideo', () {
    test('prefers the highest height at or under 720', () {
      final r = pickWebVideo([fmt(360), fmt(1080), fmt(720), fmt(480)])!;
      expect(r.height, 720);
    });

    test('falls back to the lowest when everything is taller than 720', () {
      final r = pickWebVideo([fmt(1440), fmt(1080), fmt(2160)])!;
      expect(r.height, 1080);
    });

    test('ignores non-avc1 and non-mp4 renditions', () {
      final r = pickWebVideo([
        fmt(720, mime: 'video/webm; codecs="vp9"'),
        fmt(720, mime: 'video/mp4; codecs="av01.0.05M.08"'),
        fmt(720, mime: 'audio/mp4; codecs="mp4a.40.2"'),
        fmt(480),
      ])!;
      expect(r.height, 480);
      expect(r.mimeType, 'video/mp4; codecs="avc1.4d401f"');
    });

    test('null when nothing qualifies', () {
      expect(pickWebVideo([fmt(720, mime: 'video/webm; codecs="vp9"')]), isNull);
      expect(pickWebVideo(const []), isNull);
      expect(pickWebVideo(null), isNull);
    });

    test('a ciphered format with no url is skipped', () {
      final r = pickWebVideo([fmt(720, url: 'none'), fmt(360)])!;
      expect(r.height, 360);
    });

    test('among equal heights the higher bitrate wins', () {
      final r = pickWebVideo([
        fmt(720, bitrate: 900, url: 'https://x/a?expire=1793062416'),
        fmt(720, bitrate: 2500, url: 'https://x/b?expire=1793062416'),
      ])!;
      expect(r.url, contains('/b'));
    });

    test('carries width, height, mimeType and expiry in unix seconds', () {
      final r = pickWebVideo([fmt(720, width: 1280)])!;
      expect(r.width, 1280);
      expect(r.height, 720);
      expect(r.expiresAt, 1793062416);
    });

    test('a URL without expire= has a null expiry, never a guess', () {
      final r = pickWebVideo([fmt(720, url: 'https://x/videoplayback?itag=1')])!;
      expect(r.expiresAt, isNull);
    });
  });
}
