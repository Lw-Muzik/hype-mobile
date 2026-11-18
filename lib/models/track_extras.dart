/// The things a streamed track needs to remember about itself.
///
/// # Why these ride in the map
///
/// A queue entry is a `SongModel` — `on_audio_query`'s shape, a row from the
/// device's media store. It has no field for "and this is YouTube video
/// `dQw4w9WgXcQ`, whose URL stops working at 14:32". But it is a thin wrapper
/// over a plain map that it copies verbatim and ignores keys it does not know,
/// so extra keys survive both construction and a round trip through JSON.
///
/// That matters for saving a session. A googlevideo URL is single-use and
/// expires in about six hours; a queue restored the next morning holds a list of
/// dead links and nothing to rebuild them from. Keeping the video id turns a
/// dead entry into one request.
///
/// The `hype_` prefix keeps these clear of every key the media store might
/// itself define.
library;

import 'package:on_audio_query/on_audio_query.dart';

/// The extra keys this app writes into a track's map.
class TrackKeys {
  const TrackKeys._();

  /// The YouTube id, so an expired URL can be resolved again.
  static const videoId = 'hype_video_id';

  /// Unix seconds after which the stored URL stops working.
  static const expiresAt = 'hype_expires_at';

  /// Whether this entry was queued to be *watched* rather than heard.
  static const isVideo = 'hype_is_video';

  /// Which drive a cloud track came from (`CloudProvider.index`), and the id of
  /// the file in it. Together they let a dead link — or a stale sign-in token —
  /// be made good again from the entry alone, the way [videoId] does for
  /// YouTube.
  static const cloudProvider = 'hype_cloud_provider';
  static const cloudFileId = 'hype_cloud_file_id';
}

extension TrackExtras on SongModel {
  /// The YouTube id, or null for anything this app did not stream from YouTube.
  String? get ytVideoId => getMap[TrackKeys.videoId] as String?;

  /// Whether this entry is a music video rather than an audio stream.
  bool get isYtVideo => getMap[TrackKeys.isVideo] == true;

  /// The drive file this track streams from, or null for anything else.
  String? get cloudFileId => getMap[TrackKeys.cloudFileId] as String?;

  /// `CloudProvider.index` of the drive it streams from.
  int? get cloudProviderIndex => (getMap[TrackKeys.cloudProvider] as num?)?.toInt();

  /// Whether the stored URL can still be handed to a player.
  ///
  /// Mirrors `StreamTarget.isFresh`, including its refusal to guess: an entry
  /// with no recorded deadline is stale, because assuming a lifetime is how a
  /// restored queue serves a URL the CDN stopped honouring hours ago.
  ///
  /// A cloud track is the one exception to "no deadline means stale": a Google
  /// Drive link never expires (its sign-in token does, and that is fetched at
  /// load), so it records none and stays fresh. A Dropbox link lasts hours and
  /// records when; an entry past that is stale like any YouTube one. A track
  /// that is neither has no deadline to miss and is always fresh.
  bool get hasFreshTarget {
    final deadline = (getMap[TrackKeys.expiresAt] as num?)?.toInt();
    if (ytVideoId == null) {
      if (cloudFileId == null || deadline == null) return true;
      return _beforeDeadline(deadline);
    }
    if (deadline == null) return false;
    return _beforeDeadline(deadline);
  }

  /// A minute of headroom, so a URL cannot expire mid-buffer.
  static bool _beforeDeadline(int deadline) =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000 < deadline - 60;

  /// Whether this entry must be resolved again before it can be handed to a
  /// player.
  ///
  /// [staged] is whether a video's DASH manifest is currently registered. It is
  /// a parameter rather than a lookup so this stays a pure function of the
  /// track and one fact about it.
  ///
  /// A video needs both halves to be true. Its deadline says only that the URLs
  /// *inside* the manifest are still honoured; it says nothing about whether the
  /// manifest itself is still on disk. Manifests are swept at every launch — one
  /// left by a previous run has no queue entry pointing at it — so a video the
  /// process died two minutes after resolving comes back with a live deadline
  /// and no file behind it. Trusting the deadline alone hands the player a path
  /// to something that is not there.
  bool needsRefresh({required bool staged}) {
    // A cloud track is renewed when its link has aged out, or when a failure
    // stamped it stale (see `markStale`).
    if (ytVideoId == null) return cloudFileId != null && !hasFreshTarget;
    if (!hasFreshTarget) return true;
    return isYtVideo && !staged;
  }

  /// A copy marked as needing a new link and token, for a track the player
  /// just refused. The deadline is set to the start of time, which every check
  /// reads as "already over".
  SongModel markStale() => withTarget(getMap['_data'] as String? ?? '', 1);

  /// A copy of this track pointing at [url], valid until [expiresAt].
  ///
  /// Used when a stale entry has been resolved again: everything the user sees —
  /// title, artist, artwork, the id the queue knows it by — is preserved, and
  /// only the link changes.
  SongModel withTarget(String url, int? expiresAt) => SongModel({
        ...getMap,
        '_data': url,
        TrackKeys.expiresAt: expiresAt,
      });
}
