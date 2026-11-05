import 'dart:convert';
import 'dart:typed_data';

import '../../Helpers/Channel.dart';
import 'rg_tags.dart';

/// URIs of songs in the iOS Music library. They are not files the app can
/// open, so the platform reads their tags.
const kNativeLibraryScheme = 'ipod-library://';

bool isNativeLibraryUri(String path) => path.startsWith(kNativeLibraryScheme);

const _keys = {
  'trackGain': 'replaygain_track_gain',
  'trackPeak': 'replaygain_track_peak',
  'albumGain': 'replaygain_album_gain',
  'albumPeak': 'replaygain_album_peak',
};

/// Replay Gain tags from the raw strings the platform found, keyed
/// `trackGain`, `trackPeak`, `albumGain`, `albumPeak` (any may be missing).
///
/// The numbers go through the same parser as a file's tags ("-6.50 dB" and
/// "0.987654" both read); the strings are handed to it as the comments of a
/// FLAC tag block, so there is one number parser, not two. Never throws.
ReplayGainTags replayGainTagsFromStrings(Map<String, String?> raw) {
  try {
    final comments = <List<int>>[];
    _keys.forEach((k, tag) {
      final v = raw[k];
      if (v != null && v.trim().isNotEmpty) {
        comments.add(utf8.encode('$tag=${v.trim()}'));
      }
    });
    if (comments.isEmpty) return ReplayGainTags.empty;

    final body = BytesBuilder()
      ..add(_le32(0)) // vendor string length
      ..add(_le32(comments.length));
    for (final c in comments) {
      body
        ..add(_le32(c.length))
        ..add(c);
    }
    final size = body.length;
    final block = BytesBuilder()
      ..add(ascii.encode('fLaC'))
      ..add([0x84, (size >> 16) & 0xff, (size >> 8) & 0xff, size & 0xff])
      ..add(body.toBytes());
    return parseReplayGainTags(block.toBytes());
  } catch (_) {
    return ReplayGainTags.empty;
  }
}

List<int> _le32(int n) => [
  n & 0xff,
  (n >> 8) & 0xff,
  (n >> 16) & 0xff,
  (n >> 24) & 0xff,
];

/// Reads the Replay Gain tags of the Music-library item at [uri] on the
/// platform ([fetch], the `rgReadTags` channel method by default). Never
/// throws; an item the platform cannot read yields [ReplayGainTags.empty].
Future<ReplayGainTags> readNativeReplayGainTags(
  String uri, {
  Future<Map<String, String>?> Function(String) fetch = Channel.rgReadTags,
}) async {
  try {
    final raw = await fetch(uri);
    if (raw == null) return ReplayGainTags.empty;
    return replayGainTagsFromStrings(raw);
  } catch (_) {
    return ReplayGainTags.empty;
  }
}
