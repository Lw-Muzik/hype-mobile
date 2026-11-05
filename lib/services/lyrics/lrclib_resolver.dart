import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart';

/// Resolves lyrics from LRCLIB (https://lrclib.net), trying hard not to come
/// back empty. Port of the desktop app's `lrclib_resolve` (`lyrics.rs`).
///
/// Real-world titles and artists are messy — YouTube "(Official Video)",
/// "feat." credits, "Artist - Title" names, "ArtistVEVO" channels, placeholder
/// artists like "YouTube Music" — so this runs several strategies from precise
/// to broad and stops at the first hit:
///   1. exact `/api/get` (track + artist + duration), original then normalized;
///   2. strict scored search (title AND artist must match);
///   3. relaxed scored search (artist optional, then title-only);
///   4. an "Artist - Title" split of the title.
class LrclibResolver {
  LrclibResolver({Client? client}) : _client = client ?? Client();

  final Client _client;

  static const _headers = {
    'User-Agent': 'HypeMuzik/1.0 (https://github.com/Lw-Muzik)',
  };
  static const Duration _timeout = Duration(seconds: 15);

  /// Transport failures (timeouts, no network) after which the chain gives up
  /// rather than walking every remaining attempt into the same dead network.
  static const int _maxTransportFailures = 2;

  /// Breathing room after a failed request, so a rate limit can clear.
  static const Duration _retryPause = Duration(milliseconds: 700);

  /// Returns raw lyrics (timestamped LRC when available, else plain text), or
  /// null. [isCancelled] is checked between requests so a resolve for a track
  /// the user already skipped stops early.
  Future<String?> resolve({
    required String title,
    required String artist,
    int? durationMs,
    bool Function()? isCancelled,
  }) async {
    final attempts = buildAttempts(title, artist);
    if (attempts.isEmpty) return null;
    final knownArtist = primaryArtist(normalizeArtist(artist));

    final durationSecs = durationMs != null && durationMs > 0
        ? durationMs / 1000.0
        : null;
    // One resolve often asks the same search query in strict and relaxed mode;
    // the hits are the same, only the scoring differs.
    final searchCache = <String, List<Map<String, dynamic>>?>{};
    var failures = 0;

    for (final a in attempts) {
      if (isCancelled?.call() ?? false) return null;
      if (failures >= _maxTransportFailures) return null;

      // Exact get first when an artist is known (very precise; 404s fast).
      if (a.requireArtist && a.artist.isNotEmpty) {
        final got = await _get(a.title, a.artist, durationSecs);
        if (got.failed) {
          failures++;
          await Future<void>.delayed(_retryPause);
        }
        if (got.text != null) return got.text;
        if (isCancelled?.call() ?? false) return null;
      }

      final query = a.artist.isEmpty ? a.title : '${a.title} ${a.artist}';
      List<Map<String, dynamic>>? hits;
      if (searchCache.containsKey(query)) {
        hits = searchCache[query];
      } else {
        final res = await _search(query);
        if (res.failed) {
          failures++;
          await Future<void>.delayed(_retryPause);
        }
        hits = res.hits;
        // Don't cache a transport failure — a later attempt may retry it.
        if (!res.failed) searchCache[query] = hits;
      }
      if (hits == null || hits.isEmpty) continue;

      // A title-only query still checks hits against the artist we know —
      // dropping it from the query must not drop it from the verdict.
      final best = pickBest(
        hits,
        title: a.title,
        artist: a.artist.isNotEmpty ? a.artist : knownArtist,
        durationSecs: durationSecs,
        requireArtist: a.requireArtist,
      );
      if (best != null) return best;
    }
    return null;
  }

  Future<_GetResult> _get(
    String title,
    String artist,
    double? durationSecs,
  ) async {
    final params = <String, String>{
      'track_name': title,
      'artist_name': artist,
      if (durationSecs != null) 'duration': durationSecs.round().toString(),
    };
    try {
      final res = await _client
          .get(Uri.https('lrclib.net', '/api/get', params), headers: _headers)
          .timeout(_timeout);
      if (res.statusCode != 200) {
        return _GetResult(failed: _transient(res.statusCode));
      }
      final json = jsonDecode(utf8.decode(res.bodyBytes));
      if (json is! Map<String, dynamic>) return const _GetResult();
      return _GetResult(text: lyricsOf(json));
    } catch (e) {
      debugPrint('LRCLIB get error: $e');
      return const _GetResult(failed: true);
    }
  }

  Future<_SearchResult> _search(String query) async {
    try {
      final res = await _client
          .get(
            Uri.https('lrclib.net', '/api/search', {'q': query}),
            headers: _headers,
          )
          .timeout(_timeout);
      if (res.statusCode != 200) {
        return _SearchResult(failed: _transient(res.statusCode));
      }
      final json = jsonDecode(utf8.decode(res.bodyBytes));
      if (json is! List) return const _SearchResult();
      return _SearchResult(
        hits: json.whereType<Map<String, dynamic>>().toList(),
      );
    } catch (e) {
      debugPrint('LRCLIB search error: $e');
      return const _SearchResult(failed: true);
    }
  }
}

/// A reply worth retrying rather than believing: server trouble or a rate
/// limit (LRCLIB answers bursts with 429). Never cached as "no lyrics".
bool _transient(int status) => status >= 500 || status == 429;

class _GetResult {
  const _GetResult({this.text, this.failed = false});
  final String? text;
  final bool failed;
}

class _SearchResult {
  const _SearchResult({this.hits, this.failed = false});
  final List<Map<String, dynamic>>? hits;
  final bool failed;
}

/// One `(title, artist, requireArtist)` lookup the resolver will try.
@immutable
class LrclibAttempt {
  const LrclibAttempt(this.title, this.artist, this.requireArtist);
  final String title;
  final String artist;
  final bool requireArtist;

  @override
  bool operator ==(Object other) =>
      other is LrclibAttempt &&
      other.title == title &&
      other.artist == artist &&
      other.requireArtist == requireArtist;

  @override
  int get hashCode => Object.hash(title, artist, requireArtist);

  @override
  String toString() => 'LrclibAttempt($title, $artist, $requireArtist)';
}

/// The attempts for a track, most precise first, deduplicated.
@visibleForTesting
List<LrclibAttempt> buildAttempts(String title, String artist) {
  final tries = <LrclibAttempt>[];
  void push(String t, String a, bool requireArtist) {
    t = t.trim();
    a = a.trim();
    if (t.isEmpty) return;
    final attempt = LrclibAttempt(t, a, requireArtist);
    if (!tries.contains(attempt)) tries.add(attempt);
  }

  final rawArtist = normalizeArtist(artist);
  final cleanT = cleanTitle(title);
  final cleanA = primaryArtist(rawArtist);

  push(title, rawArtist, true);
  push(cleanT, cleanA, true);

  // "Artist - Title": YouTube uploads and untagged files carry the artist in
  // the title. When the left side is the artist we already have (or we have
  // none), the right side is the real title.
  final split = splitArtistTitle(cleanT);
  if (split != null) {
    final (sa, st) = split;
    final splitArtist = primaryArtist(normalizeArtist(sa));
    if (cleanA.isEmpty || _sameArtist(splitArtist, cleanA)) {
      push(st, splitArtist, true);
    } else {
      push(st, cleanA, true);
      push(st, splitArtist, true);
    }
  }

  push(cleanT, cleanA, false);
  if (split != null) push(split.$2, '', false);
  push(cleanT, '', false);
  return tries;
}

bool _sameArtist(String a, String b) {
  final x = a.toLowerCase();
  final y = b.toLowerCase();
  return x == y || x.contains(y) || y.contains(x);
}

/// Picks the best hit by title/artist/duration, preferring synced lyrics. With
/// [requireArtist] false, a non-matching artist no longer disqualifies a hit
/// (it just earns no artist bonus) — the broad fallback.
@visibleForTesting
String? pickBest(
  List<Map<String, dynamic>> hits, {
  required String title,
  required String artist,
  double? durationSecs,
  required bool requireArtist,
}) {
  final titleL = _fold(title);
  final artistL = _fold(artist);
  if (titleL.isEmpty) return null;

  Map<String, dynamic>? best;
  var bestScore = -1;
  for (final h in hits) {
    if (h['instrumental'] == true) continue;
    if (lyricsOf(h) == null) continue;
    final rt = _fold(h['trackName'] as String? ?? '');
    final ra = _fold(h['artistName'] as String? ?? '');
    if (rt.isEmpty) continue;

    var score = 0;
    // Title must be relevant.
    final exactTitle = rt == titleL;
    if (exactTitle) {
      score += 10;
    } else if (rt.contains(titleL) || titleL.contains(rt)) {
      score += 5;
    } else {
      continue;
    }
    // Artist: a match earns a bonus.
    var artistMatched = false;
    if (artistL.isNotEmpty) {
      if (ra == artistL) {
        score += 10;
        artistMatched = true;
      } else if (ra.isNotEmpty &&
          (ra.contains(artistL) ||
              artistL.contains(ra) ||
              _squash(ra) == _squash(artistL))) {
        // The last test is "DuaLipa" (a VEVO channel) against "Dua Lipa".
        score += 5;
        artistMatched = true;
      } else if (requireArtist) {
        continue;
      }
    }
    // Without a confirmed artist, a title alone is not evidence — "P.2" by
    // King Saha matched "Dark Tomb p.2" by Cloud Pastel. Such a hit needs the
    // exact title AND the same length; with no length to check it is accepted
    // only when there was never an artist to confirm in the first place.
    if (!artistMatched) {
      if (!exactTitle) continue;
      final rd = h['duration'];
      if (durationSecs != null) {
        if (rd is! num || (rd.toDouble() - durationSecs).abs() > 3) continue;
      } else if (artistL.isNotEmpty) {
        continue;
      }
    }
    // Duration proximity.
    final rd = h['duration'];
    if (durationSecs != null && rd is num) {
      final diff = (rd.toDouble() - durationSecs).abs();
      if (diff <= 2) {
        score += 5;
      } else if (diff <= 5) {
        score += 3;
      } else if (diff <= 10) {
        score += 1;
      }
    }
    if (_nonBlank(h['syncedLyrics']) != null) score += 3;

    if (score > bestScore) {
      bestScore = score;
      best = h;
    }
  }
  return best == null ? null : lyricsOf(best);
}

/// Synced lyrics when present, else plain; null for instrumentals/blank.
@visibleForTesting
String? lyricsOf(Map<String, dynamic> hit) {
  if (hit['instrumental'] == true) return null;
  return _nonBlank(hit['syncedLyrics']) ?? _nonBlank(hit['plainLyrics']);
}

/// Letters and digits only: spacing and punctuation differ between sources.
String _squash(String s) =>
    s.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

String? _nonBlank(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

/// Lowercase, unify curly quotes and dashes, collapse spaces —
/// so "Don’t Start Now" matches LRCLIB's "Don't Start Now".
String _fold(String s) => collapseWs(
  s
      .toLowerCase()
      .replaceAll(RegExp('[‘’ʼ`´]'), "'")
      .replaceAll(RegExp('[“”]'), '"')
      .replaceAll(RegExp('[–—]'), '-'),
);

/// Artists the app fills in when it doesn't know one. They match nothing on
/// LRCLIB, so they are treated as "no artist".
const _placeholderArtists = {
  'youtube music',
  'youtube',
  'unknown artist',
  'unknown',
  '<unknown>',
  'various artists',
};

/// Drops placeholder artists and YouTube channel decorations
/// ("Artist - Topic", "ArtistVEVO", "Artist Official").
String normalizeArtist(String artist) {
  var a = collapseWs(artist);
  if (_placeholderArtists.contains(a.toLowerCase())) return '';
  a = a.replaceAll(RegExp(r'\s*-\s*topic$', caseSensitive: false), '');
  a = a.replaceAll(RegExp(r'\s*vevo$', caseSensitive: false), '');
  a = a.replaceAll(RegExp(r'\s+official$', caseSensitive: false), '');
  a = a.trim();
  return _placeholderArtists.contains(a.toLowerCase()) ? '' : a;
}

/// Drop "(Official Video)", "[Lyrics]" bracketed groups, "feat./ft." credits,
/// trailing "| ..." suffixes, and collapse whitespace — the decorations that
/// throw LRCLIB's match off.
String cleanTitle(String title) {
  var t = stripFeat(stripBrackets(title));
  final pipe = t.indexOf('|');
  if (pipe > 0) t = t.substring(0, pipe);
  t = t.replaceAll(
    RegExp(
      r'\s+(official\s+(music\s+)?(video|audio|lyric\s+video|visualizer)|lyric(s)?\s+video|lyrics|audio)$',
      caseSensitive: false,
    ),
    '',
  );
  return collapseWs(t);
}

/// Remove anything inside `()`, `[]`, or `{}` (non-nested, tolerant of unmatched).
String stripBrackets(String s) {
  final out = StringBuffer();
  var depth = 0;
  for (final c in s.split('')) {
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      depth = depth > 0 ? depth - 1 : 0;
    } else if (depth == 0) {
      out.write(c);
    }
  }
  return out.toString();
}

/// Truncate at the first "feat./ft./featuring" marker.
String stripFeat(String s) =>
    _cutAt(s, const [' feat.', ' feat ', ' ft.', ' ft ', ' featuring ']);

/// The primary (first) artist: the part before a "feat./&/,/x" separator,
/// which is how LRCLIB usually stores the credit.
String primaryArtist(String artist) => _cutAt(artist, const [
  ',',
  ' & ',
  ' feat.',
  ' feat ',
  ' ft.',
  ' ft ',
  ' featuring ',
  ';',
  ' x ',
]).trim();

String _cutAt(String s, List<String> markers) {
  final low = s.toLowerCase();
  int? cut;
  for (final m in markers) {
    final i = low.indexOf(m);
    if (i > 0 && (cut == null || i < cut)) cut = i;
  }
  return cut == null ? s : s.substring(0, cut);
}

/// Split an "Artist - Title" string into `(artist, title)` (both non-empty).
@visibleForTesting
(String, String)? splitArtistTitle(String s) {
  final m = RegExp(r'\s[-–—]\s').firstMatch(s);
  if (m == null) return null;
  final a = s.substring(0, m.start).trim();
  final t = s.substring(m.end).trim();
  if (a.isEmpty || t.isEmpty) return null;
  return (a, t);
}

String collapseWs(String s) =>
    s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
