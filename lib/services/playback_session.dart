/// Where the user was when they last closed the app.
///
/// # What is worth saving
///
/// The queue, which track of it was playing, how far into that track, and the
/// two settings that decide what plays next. Not the playing state: an app that
/// starts making noise because it was opened is a bad guest, so a restored
/// session is always paused and waits to be told.
///
/// # Written to a file, not to preferences
///
/// A radio queue is routinely a few hundred entries and each is a map of a
/// dozen fields. `SharedPreferences` is loaded whole on every launch and every
/// other setting in the app shares it; putting a 200 KB queue in there taxes
/// code that has nothing to do with playback.
///
/// # Serialisation is separate from storage
///
/// [PlaybackSession] knows how to become JSON and back; [PlaybackSessionStore]
/// knows about the disk. The half that has the edge cases — a queue longer than
/// the cap, a shuffled order referring to tracks that are gone, a file written
/// by an older version — is the half that can be tested without a device.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:path_provider/path_provider.dart';

import '../navigation/playback_origin.dart';

/// The most tracks a saved session will hold.
///
/// An endless radio queue grows for as long as someone listens, and restoring
/// ten thousand entries would cost more than the feature is worth. Beyond this,
/// a window around the playing track is kept — what is behind you matters less
/// than what is ahead.
const int kMaxSessionTracks = 500;

/// How many of the kept tracks sit *behind* the playing one when a queue is
/// windowed, so "previous" still works after a restore.
const int kSessionLookBehind = 50;

@immutable
class PlaybackSession {
  /// The queue in its original, unshuffled order.
  final List<SongModel> songs;

  /// The shuffled order as a list of song ids, or null when not shuffled.
  ///
  /// Ids rather than a second copy of every track: the two lists always hold
  /// the same songs, so storing both would double the file for no information.
  final List<int>? shuffledOrder;

  /// Index into the *effective* list — the shuffled one when shuffled.
  final int index;

  final Duration position;
  final bool shuffled;

  /// `LoopMode.index`, kept as an int so this file does not depend on the
  /// player package.
  final int loopMode;

  /// Whether the queue was being *watched* rather than heard.
  ///
  /// Watching is a mode the queue stays in, not a property of one track: while
  /// it is on, the tracks that follow resolve as video too and a station keeps
  /// showing pictures. Losing it across a restart turns a restored video queue
  /// into an audio one from the second track onward.
  final bool videoMode;

  /// The library pages the queue was started from, or null when it did not
  /// come from one (or the save predates this field).
  final PlaybackOrigin? origin;

  const PlaybackSession({
    required this.songs,
    required this.index,
    required this.position,
    this.shuffledOrder,
    this.shuffled = false,
    this.loopMode = 0,
    this.videoMode = false,
    this.origin,
  });

  /// The queue in the order it should play.
  ///
  /// A shuffled order that refers to tracks no longer present is repaired
  /// rather than trusted: entries that resolve are kept in their saved order
  /// and anything the order forgot is appended, so a queue can never lose
  /// tracks to a stale index.
  List<SongModel> get effectiveQueue {
    final order = shuffledOrder;
    if (!shuffled || order == null) return songs;

    final byId = {for (final song in songs) song.id: song};
    final result = <SongModel>[];
    final placed = <int>{};
    for (final id in order) {
      final song = byId[id];
      if (song != null && placed.add(id)) result.add(song);
    }
    for (final song in songs) {
      if (!placed.contains(song.id)) result.add(song);
    }
    return result;
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'index': index,
    'positionMs': position.inMilliseconds,
    'shuffled': shuffled,
    'loopMode': loopMode,
    'videoMode': videoMode,
    if (origin != null) 'origin': origin!.toJson(),
    'songs': [for (final song in songs) song.getMap],
    if (shuffledOrder != null) 'shuffledOrder': shuffledOrder,
  };

  /// Reads a session, or null when there is nothing usable in [json].
  ///
  /// Everything is defended: this file is written by a previous version of the
  /// app, possibly a previous *release* of it, and a launch must never fail
  /// because of what a past version chose to store.
  static PlaybackSession? fromJson(Map<String, Object?> json) {
    final rawSongs = json['songs'];
    if (rawSongs is! List || rawSongs.isEmpty) return null;

    final songs = <SongModel>[];
    for (final entry in rawSongs) {
      if (entry is Map) songs.add(SongModel(Map<dynamic, dynamic>.from(entry)));
    }
    if (songs.isEmpty) return null;

    final shuffled = json['shuffled'] == true;
    final rawOrder = json['shuffledOrder'];
    final shuffledOrder = rawOrder is List
        ? [
            for (final id in rawOrder)
              if (id is num) id.toInt(),
          ]
        : null;

    final rawIndex = (json['index'] as num?)?.toInt() ?? 0;
    final session = PlaybackSession(
      songs: songs,
      shuffledOrder: shuffledOrder,
      shuffled: shuffled,
      index: 0,
      position: Duration(
        milliseconds: (json['positionMs'] as num?)?.toInt() ?? 0,
      ),
      loopMode: (json['loopMode'] as num?)?.toInt() ?? 0,
      videoMode: json['videoMode'] == true,
      origin: PlaybackOrigin.fromJson(json['origin']),
    );
    // Clamped against the queue actually recovered, which may be shorter than
    // the one that was saved.
    final length = session.effectiveQueue.length;
    return PlaybackSession(
      songs: songs,
      shuffledOrder: shuffledOrder,
      shuffled: shuffled,
      index: rawIndex.clamp(0, length - 1),
      position: session.position.isNegative ? Duration.zero : session.position,
      loopMode: session.loopMode,
      videoMode: session.videoMode,
      origin: session.origin,
    );
  }

  /// A copy trimmed to [kMaxSessionTracks] around the playing track.
  ///
  /// Windowing the *effective* queue and rebuilding from that keeps the playing
  /// track's position honest; trimming the unshuffled list instead would drop
  /// tracks the shuffled order still points at.
  PlaybackSession windowed() {
    final queue = effectiveQueue;
    if (queue.length <= kMaxSessionTracks) return this;

    var start = index - kSessionLookBehind;
    if (start < 0) start = 0;
    if (start + kMaxSessionTracks > queue.length) {
      start = queue.length - kMaxSessionTracks;
    }
    final window = queue.sublist(start, start + kMaxSessionTracks);
    final keep = {for (final song in window) song.id};

    return PlaybackSession(
      songs: [
        for (final song in songs)
          if (keep.contains(song.id)) song,
      ],
      shuffledOrder: shuffled ? [for (final song in window) song.id] : null,
      shuffled: shuffled,
      index: index - start,
      position: position,
      loopMode: loopMode,
      videoMode: videoMode,
      origin: origin,
    );
  }
}

/// Reads and writes the saved session.
class PlaybackSessionStore {
  PlaybackSessionStore._();

  static final PlaybackSessionStore instance = PlaybackSessionStore._();

  static const _fileName = 'playback_session.json';

  /// How long to wait for the writes to stop before touching the disk.
  ///
  /// Position updates arrive several times a second while playing. Writing on
  /// each would be a file write per frame of the progress bar; the only thing
  /// lost by waiting is at most this much of the last known position.
  static const _debounce = Duration(seconds: 3);

  Timer? _pending;
  PlaybackSession? _queued;
  File? _file;

  Future<File> _resolveFile() async {
    return _file ??= File(
      '${(await getApplicationSupportDirectory()).path}/$_fileName',
    );
  }

  /// Saves [session] once the writes settle. See [_debounce].
  void save(PlaybackSession session) {
    _queued = session;
    _pending?.cancel();
    _pending = Timer(_debounce, () => unawaited(flush()));
  }

  /// Writes the pending session immediately.
  ///
  /// Called when the app goes to the background, which is the moment most
  /// likely to be followed by the process being killed — the debounce cannot be
  /// allowed to outlive it.
  Future<void> flush() async {
    final session = _queued;
    _pending?.cancel();
    _pending = null;
    _queued = null;
    if (session == null) return;
    try {
      final file = await _resolveFile();
      await file.writeAsString(jsonEncode(session.windowed().toJson()));
    } catch (e) {
      // A session that cannot be written is a convenience the user loses, not
      // a reason to interrupt playback.
      debugPrint('Session save failed: $e');
    }
  }

  Future<PlaybackSession?> load() async {
    try {
      final file = await _resolveFile();
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return PlaybackSession.fromJson(Map<String, Object?>.from(decoded));
    } catch (e) {
      // Corrupt or written by a version that stored something else. Starting
      // fresh is correct and the file is replaced on the next save.
      debugPrint('Session load failed: $e');
      return null;
    }
  }

  Future<void> clear() async {
    _pending?.cancel();
    _pending = null;
    _queued = null;
    try {
      final file = await _resolveFile();
      if (file.existsSync()) await file.delete();
    } catch (e) {
      debugPrint('Session clear failed: $e');
    }
  }
}
