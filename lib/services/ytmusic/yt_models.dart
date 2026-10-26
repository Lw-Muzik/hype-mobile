/// The things YouTube Music's catalog is made of.
///
/// These mirror `hm-ytmusic`'s Rust models in hype-desktop one for one, so both
/// apps describe the catalog the same way and a fix found on one surface reads
/// the same on the other.
///
/// Every one of these is a plain value object with no native resources, which is
/// what lets the worker isolate send them straight back over its port — see
/// [YtWorker]. Keep them that way.
library;

/// What an [ExploreItem] is, which is also how to open it.
enum ExploreKind { playlist, album, artist, song, video }

/// A browsable thing on a catalog page.
///
/// One shape for every kind: the id plus the kind is what tells us how to open
/// it, and the UI only renders.
class ExploreItem {
  /// What to open, read according to [kind]:
  ///
  /// * [ExploreKind.album] — the `MPREb…` browse id.
  /// * [ExploreKind.playlist] — the **`VL`-prefixed** browse id. The bare `PL…`
  ///   form answers HTTP 400; see `playlistBrowseId`.
  /// * [ExploreKind.artist] — the `UC…` channel id.
  /// * [ExploreKind.song] / [ExploreKind.video] — the video id. These are rows
  ///   rather than cards: they name a thing to play, not a page to open.
  final String id;
  final ExploreKind kind;
  final String title;

  /// The subtitle runs joined as YouTube wrote them ("Album • A Pass • 2019").
  ///
  /// Deliberately not split by run index: fixed-index reads of this exact field
  /// are what broke desktop's library listing ("Made for " parsed as an author).
  /// Joining is honest and cannot misattribute.
  final String? subtitle;
  final String? thumbnail;

  /// The runs that link to an artist page, joined — so a collaboration reads
  /// "Dave, Tems" rather than whichever half sat at the index we picked.
  ///
  /// Null where the row credits someone without linking them: inventing a name
  /// from the byline's text is how that becomes wrong rather than absent.
  final String? artist;

  /// The run that links to an album page, wherever the surface put it.
  final String? album;

  /// Filled for rows that state a running time. Songs on a genre page don't —
  /// they state a view count instead — so this stays null rather than borrowing
  /// a number that isn't one.
  final double? durationSecs;

  /// Whether there's real footage, on the same terms as [YtTrack.hasVideo].
  final bool hasVideo;

  const ExploreItem({
    required this.id,
    required this.kind,
    required this.title,
    this.subtitle,
    this.thumbnail,
    this.artist,
    this.album,
    this.durationSecs,
    this.hasVideo = false,
  });

  /// Whether this names something to play rather than a page to open.
  bool get isPlayable =>
      kind == ExploreKind.song || kind == ExploreKind.video;

  /// This item as a track, for the rows that already said everything a track
  /// needs. Costs no request at all — the id it carries is the video id.
  YtTrack asTrack({String? playlistId, String? playlistTitle}) => YtTrack(
        videoId: id,
        title: title,
        artist: artist ?? subtitle,
        album: album,
        durationSecs: durationSecs,
        thumbnail: thumbnail,
        playlistId: playlistId ?? '',
        playlistTitle: playlistTitle ?? '',
        hasVideo: hasVideo,
      );
}

/// One shelf on a catalog page ("Featured playlists", "Albums", "Songs", …).
class ExploreShelf {
  final String title;
  final List<ExploreItem> items;

  const ExploreShelf({required this.title, required this.items});
}

/// One credited artist, and their channel when the credit links one.
///
/// Kept per artist rather than joined, so a collaboration can offer each of
/// its artists' pages — "Burna Boy & Ed Sheeran" is two places to go.
class YtArtistRef {
  final String name;

  /// The `UC…` channel id, or null where YouTube credits the name without
  /// linking it.
  final String? id;

  const YtArtistRef(this.name, {this.id});

  /// The artist as something to open.
  ExploreItem? asItem({String? thumbnail}) => id == null
      ? null
      : ExploreItem(
          id: id!,
          kind: ExploreKind.artist,
          title: name,
          thumbnail: thumbnail,
        );
}

/// A button on a page that starts playback: the video it opens on and the
/// list it plays from.
class YtWatchRef {
  final String videoId;
  final String? playlistId;

  const YtWatchRef(this.videoId, {this.playlistId});
}

/// The top of an artist's page.
class YtArtistHeader {
  final String name;

  /// The wide banner behind the name (about 2.4:1), resizable.
  final String? banner;

  /// A round portrait, on the pages that have one apart from the banner.
  final String? avatar;

  /// "1.93M subscribers".
  final String? subscribers;

  /// "3.21M monthly audience".
  final String? audience;
  final String? description;

  /// YouTube's own Shuffle and Mix buttons.
  final YtWatchRef? shuffle;
  final YtWatchRef? radio;

  const YtArtistHeader({
    required this.name,
    this.banner,
    this.avatar,
    this.subscribers,
    this.audience,
    this.description,
    this.shuffle,
    this.radio,
  });
}

/// An artist's page: who they are, then their shelves.
class YtArtistPageData {
  final YtArtistHeader? header;
  final List<ExploreShelf> shelves;

  const YtArtistPageData({this.header, required this.shelves});
}

/// One mood or genre YouTube offers ("Chill", "African", …).
class ExploreCategory {
  final String title;

  /// The opaque token that opens this category. Passed back verbatim.
  final String params;

  const ExploreCategory({required this.title, required this.params});

  Map<String, dynamic> toJson() => {'title': title, 'params': params};

  static ExploreCategory? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final title = raw['title'];
    final params = raw['params'];
    if (title is! String || params is! String) return null;
    if (title.isEmpty || params.isEmpty) return null;
    return ExploreCategory(title: title, params: params);
  }
}

/// A row of categories ("Moods & moments", "Genres", …).
class ExploreSection {
  final String title;
  final List<ExploreCategory> categories;

  const ExploreSection({required this.title, required this.categories});

  Map<String, dynamic> toJson() => {
        'title': title,
        'categories': [for (final c in categories) c.toJson()],
      };

  static ExploreSection? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final title = raw['title'];
    if (title is! String) return null;
    final rawCategories = raw['categories'];
    if (rawCategories is! List) return null;
    final categories = <ExploreCategory>[];
    for (final entry in rawCategories) {
      final category = ExploreCategory.fromJson(entry);
      if (category != null) categories.add(category);
    }
    if (categories.isEmpty) return null;
    return ExploreSection(title: title, categories: categories);
  }
}

/// A playable track.
class YtTrack {
  final String videoId;
  final String title;
  final String? artist;
  final String? album;
  final double? durationSecs;
  final String? thumbnail;

  /// The playlist or album this track was listed under.
  final String playlistId;
  final String playlistTitle;

  /// YT Music marks region-blocked / removed tracks. They stay listed (so the
  /// list matches what the user sees on YouTube) but can't be played.
  final bool isAvailable;

  /// Whether there's real footage to watch.
  ///
  /// A song (`MUSIC_VIDEO_TYPE_ATV`) is an audio entity: YouTube still serves
  /// "video" renditions for it, but they're a square 1080×1080 still at ~95 kbps
  /// — the cover art you already have, re-downloaded. Only music videos
  /// (OMV/UGC/…) have anything worth showing, so the UI offers the watch action
  /// on those alone rather than promising a picture and delivering a photograph.
  final bool hasVideo;

  const YtTrack({
    required this.videoId,
    required this.title,
    this.artist,
    this.album,
    this.durationSecs,
    this.thumbnail,
    this.playlistId = '',
    this.playlistTitle = '',
    this.isAvailable = true,
    this.hasVideo = false,
  });

  YtTrack copyWith({
    String? artist,
    String? playlistId,
    String? playlistTitle,
    String? thumbnail,
    String? album,
  }) =>
      YtTrack(
        videoId: videoId,
        title: title,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        durationSecs: durationSecs,
        thumbnail: thumbnail ?? this.thumbnail,
        playlistId: playlistId ?? this.playlistId,
        playlistTitle: playlistTitle ?? this.playlistTitle,
        isAvailable: isAvailable,
        hasVideo: hasVideo,
      );
}

/// One page of a radio: the playable rows and the token for the next page.
///
/// Radio panels chain forever — a missing token is the exception, not the end
/// condition (the caller re-seeds when it happens).
class RadioBatch {
  final List<YtTrack> tracks;
  final String? continuation;

  const RadioBatch({required this.tracks, this.continuation});

  static const empty = RadioBatch(tracks: []);
}

/// Which slice of the catalog to search.
///
/// [SearchFilter.top] sends no filter at all, which is what produces the
/// top-result card and YouTube's own mix of shelves.
/// The tokens are YouTube's own, each verified live to return exactly its shelf
/// ("Songs" 20 rows, "Artists" 13, "Community playlists" 20, …). They are opaque
/// and must be sent verbatim — the percent-encoded tail is part of the token as
/// YouTube issues it, not an encoding this code applied.
enum SearchFilter {
  top('Top', null),
  songs('Songs', 'EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D'),
  videos('Videos', 'EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D'),
  albums('Albums', 'EgWKAQIYAWoKEAkQChAFEAMQBA%3D%3D'),
  artists('Artists', 'EgWKAQIgAWoKEAkQChAFEAMQBA%3D%3D'),
  playlists('Playlists', 'EgeKAQQoAEABagoQAxAEEAkQBRAK');

  const SearchFilter(this.label, this.params);

  /// What the UI calls this filter.
  final String label;

  /// YouTube's own opaque filter token, or null to search everything.
  final String? params;
}

/// What a [StreamTarget]'s `url` actually holds.
enum YtStreamFormat {
  /// A single media URL, played directly.
  progressive,

  /// An adaptive HLS manifest URL, played directly.
  hls,

  /// **Manifest text, not a URL** — a DASH document built by this app, which the
  /// caller has to write to a file before a player can open it. See
  /// `parse/yt_dash.dart` for why music video needs this.
  dash,
}

/// One video-only rendition a browser can play with `<video src>` and no
/// headers: H.264 in MP4. Carried beside a video's [StreamTarget] so Hype
/// Connect can hand it to a web remote; the phone itself never plays it.
///
/// Plain fields only, so it crosses the worker isolate boundary.
class WebVideoRendition {
  final String url;

  /// As YouTube gives it, e.g. `video/mp4; codecs="avc1.4d401f"`.
  final String mimeType;
  final int? width;
  final int height;

  /// Unix seconds, from the URL's own `expire=`; null when it carries none.
  final int? expiresAt;

  const WebVideoRendition({
    required this.url,
    required this.mimeType,
    required this.height,
    this.width,
    this.expiresAt,
  });
}

/// A playable target plus the headers it should be fetched with.
class StreamTarget {
  /// The URL to play — or, when [format] is [YtStreamFormat.dash], the manifest
  /// document itself.
  final String url;
  final Map<String, String> headers;

  /// How [url] should be interpreted.
  final YtStreamFormat format;

  /// Unix seconds after which the CDN stops honouring [url], read from its own
  /// `expire=` parameter. Null when the URL carries none, which reads as "assume
  /// nothing" — a caching caller must treat it as immediately stale rather than
  /// guess a lifetime.
  ///
  /// googlevideo issues these ~6 hours out, so the URL long outlives the track.
  final int? expiresAt;

  /// For a video: the rendition a web remote can play. Null for audio and when
  /// the response held no usable H.264 rendition.
  final WebVideoRendition? webVideo;

  const StreamTarget({
    required this.url,
    required this.headers,
    this.expiresAt,
    this.format = YtStreamFormat.progressive,
    this.webVideo,
  });

  /// Whether this target can still be handed to a player.
  ///
  /// A target with no stated deadline is stale immediately: guessing a lifetime
  /// is how a cache serves a URL the CDN has already stopped honouring.
  bool get isFresh {
    final deadline = expiresAt;
    if (deadline == null) return false;
    // A minute of headroom: a URL that expires mid-buffer is a stall the user
    // reads as the app breaking.
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 < deadline - 60;
  }
}
