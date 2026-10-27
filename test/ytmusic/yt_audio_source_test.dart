/// The player source for a YouTube audio stream, and why iOS clips it.
///
/// YouTube's audio (itag 140) is a DASH fragmented MP4 whose `moov` holds no
/// samples yet states the track's full length. AVFoundation takes that length
/// as the moov's own media and appends the fragments after it, so AVPlayer
/// reports twice the real duration and plays on past the real end. ExoPlayer
/// reads the `sidx` instead and is right. iOS therefore clips each stream at
/// the length the url itself states in its `dur` parameter.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

import 'package:eq_app/services/ytmusic/yt_audio_source.dart';
import 'package:eq_app/services/ytmusic/yt_innertube.dart';

const _url = 'https://rr2---sn-n585oo54pcgx-xcce.googlevideo.com/videoplayback'
    '?expire=1793157925&itag=140&source=youtube&mime=audio%2Fmp4'
    '&clen=4025466&dur=248.685&lmt=1714000000000000';

void main() {
  group('ytStreamDuration', () {
    test('reads the dur parameter to the millisecond', () {
      expect(ytStreamDuration(_url), const Duration(milliseconds: 248685));
    });

    test('no dur, an unreadable one or a non-positive one is null', () {
      expect(ytStreamDuration(_url.replaceFirst('&dur=248.685', '')), isNull);
      expect(ytStreamDuration(_url.replaceFirst('248.685', 'abc')), isNull);
      expect(ytStreamDuration(_url.replaceFirst('248.685', '0.000')), isNull);
      expect(ytStreamDuration('not a url at all'), isNull);
    });
  });

  group('ytAudioSource', () {
    test('clipped: ends at the stated length, headers on the stream', () {
      final source = ytAudioSource(_url, tag: 'item', clip: true);
      expect(source, isA<ClippingAudioSource>());
      final clip = source as ClippingAudioSource;
      expect(clip.start, isNull);
      expect(clip.end, const Duration(milliseconds: 248685));
      expect(clip.tag, 'item',
          reason: 'the clip is the queue entry, so it carries the tag');
      expect(clip.child.uri, Uri.parse(_url));
      expect(clip.child.headers, YtInnerTube.audioPlaybackHeaders);
    });

    test('unclipped (Android): the plain stream, unchanged', () {
      final source = ytAudioSource(_url, tag: 'item', clip: false);
      expect(source, isA<UriAudioSource>());
      final uri = source as UriAudioSource;
      expect(uri.uri, Uri.parse(_url));
      expect(uri.headers, YtInnerTube.audioPlaybackHeaders);
      expect(uri.tag, 'item');
    });

    test('a url that states no length is never clipped', () {
      final source = ytAudioSource(
        _url.replaceFirst('&dur=248.685', ''),
        clip: true,
      );
      expect(source, isA<UriAudioSource>(),
          reason: 'a guessed end could cut the song short');
    });
  });
}
