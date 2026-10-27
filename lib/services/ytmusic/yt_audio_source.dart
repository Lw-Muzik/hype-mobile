/// The player source for a YouTube audio stream.
///
/// # Why iOS clips it
///
/// YouTube's audio (itag 140) is a DASH fragmented MP4: an empty `moov`, a
/// `sidx` index, then the music in fragments. YouTube writes the track's full
/// length into the empty moov's `mvhd`/`tkhd`/`mdhd`. By ISO BMFF that field is
/// the length of the samples *in* the moov, and AVFoundation takes it at its
/// word: it counts that length and then appends every fragment after it. So
/// AVPlayer reports twice the real duration — the seek bar showed 8:17 for a
/// 4:09 song — and the clock runs on past the real end with no end-of-track
/// event. ExoPlayer reads the `sidx` and gets it right, so Android is untouched.
///
/// Measured on AVFoundation (Oct 2026, "Get Lucky", 248.69 s): the live url and
/// a local copy both report 497.32 s; zeroing just those three fields reports
/// 248.64 s; `AVURLAssetPreferPreciseDurationAndTimingKey` changes nothing.
///
/// The url states the stream's exact length in its `dur` parameter, so iOS
/// clips the stream there: just_audio's clip sets the item's
/// `forwardPlaybackEndTime` (the track ends, and the next one starts, on time)
/// and reports `end - start` as the duration. Downloads are not affected — the
/// passthrough export in `YtDownloadFinisher.swift` writes a plain m4a.
library;

import 'dart:io';

import 'package:just_audio/just_audio.dart';

import 'yt_innertube.dart';

/// The source to queue for the YouTube stream at [url].
///
/// [clip] defaults to the platform (iOS clips); tests pass it explicitly. A url
/// without a usable `dur` is never clipped: a guessed end could cut the song.
AudioSource ytAudioSource(String url, {dynamic tag, bool? clip}) {
  final end = (clip ?? Platform.isIOS) ? ytStreamDuration(url) : null;
  if (end == null) {
    return AudioSource.uri(
      Uri.parse(url),
      headers: YtInnerTube.audioPlaybackHeaders,
      tag: tag,
    );
  }
  return ClippingAudioSource(
    child: AudioSource.uri(
      Uri.parse(url),
      headers: YtInnerTube.audioPlaybackHeaders,
    ),
    end: end,
    tag: tag,
  );
}

/// The stream's own length, from its `dur` query parameter (seconds, to the
/// millisecond); null when absent or unreadable.
Duration? ytStreamDuration(String url) {
  final raw = Uri.tryParse(url)?.queryParameters['dur'];
  final seconds = raw == null ? null : double.tryParse(raw);
  if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
  return Duration(milliseconds: (seconds * 1000).round());
}
