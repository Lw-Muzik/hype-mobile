/// The one door every play action in the app goes through (contract §3.12).
///
/// # Pick here, play there
///
/// While another device is the active player, tapping a song, album, playlist,
/// mix, station or radio in this app must play on *that* device. Each play
/// entry point (the list pages, the YouTube pages, mixes, "start radio") asks
/// the router first; the router answers either `null` — "not my business, carry
/// on locally" — or a future that completes when it has dealt with the tap.
///
/// # What the target can play
///
/// A `yt` track plays on any player. A `local` track is a file on *this* phone
/// and an `other` one a drive file or radio stream; neither can be sent. So:
///
/// * the tapped item cannot be sent: ask "'X' is only on this phone. Play it
///   here instead?". Yes plays it locally; the takeover rule (§3.12 Claim) then
///   makes this phone the player;
/// * the tapped item can, but some others cannot: send the rest and say how
///   many stayed behind.
///
/// # Not recursing
///
/// The local path of an entry point calls other entry points
/// (`playTracks` -> `playSongFromList`), and a command arriving from another
/// device plays through the same code. Whatever the router lets through runs
/// inside [local], a zone marker every router call checks first, so a play that
/// has been decided to be local stays local for its whole async life.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../../mixes/mix_track_ref.dart';
import '../../mixes/daily_mixes.dart';
import '../../ytmusic/yt_models.dart';
import '../connect_protocol.dart';
import '../connect_tracks.dart';
import 'connect_remote_session.dart';

/// What the router needs from the screen.
abstract interface class ConnectPlayUi {
  /// "'[title]' is only on this phone. Play it here instead?"
  Future<bool> confirmPlayHere(String title, String deviceName);

  void say(String message);
}

/// What to do with a tap once the target's limits are known.
sealed class RemotePlayPlan {
  const RemotePlayPlan();
}

/// Send [items], starting at the first.
final class SendPlay extends RemotePlayPlan {
  const SendPlay(this.items, this.dropped);
  final List<TrackRef> items;

  /// How many of the tapped list could not be sent.
  final int dropped;
}

/// Nothing sendable where the user pointed: only this phone has [title].
final class OnlyHere extends RemotePlayPlan {
  const OnlyHere(this.title);
  final String title;
}

String _titleOf(TrackRef ref) => switch (ref) {
  YtTrackRef(:final title) => title,
  LocalTrackRef(:final title) => title,
  OtherTrackRef(:final title) => title,
};

/// Decides what to send for a tap on [refs] at [index].
///
/// Strict (the default): the list plays from the tapped item, so that item must
/// be sendable. With [startAtFirstPlayable], as a mix does, playback begins at
/// the first sendable item instead and everything unsendable is simply left
/// out.
@visibleForTesting
RemotePlayPlan planRemotePlay(
  List<TrackRef> refs,
  int index, {
  bool startAtFirstPlayable = false,
}) {
  if (refs.isEmpty || index < 0 || index >= refs.length) {
    return const OnlyHere('That');
  }
  final from = refs.sublist(index);
  final sendable = [
    for (final ref in from)
      if (ref is YtTrackRef) ref,
  ];
  if (sendable.isEmpty) return OnlyHere(_titleOf(refs[index]));
  if (!startAtFirstPlayable && from.first is! YtTrackRef) {
    return OnlyHere(_titleOf(from.first));
  }
  return SendPlay(sendable, from.length - sendable.length);
}

class ConnectPlayRouter {
  ConnectPlayRouter({
    required this.session,
    required this.deviceId,
    required this.ui,
  });

  final ConnectRemoteSession session;
  final String deviceId;
  final ConnectPlayUi ui;

  /// The router the entry points consult; null until Hype Connect starts.
  static ConnectPlayRouter? instance;

  static const _zoneKey = #hypeConnectLocalPlay;

  /// Runs [body] as a local play: nothing started inside it is rerouted.
  static T local<T>(T Function() body) =>
      runZoned(body, zoneValues: {_zoneKey: true});

  static bool get _bypassed => Zone.current[_zoneKey] == true;

  /// The device taps are redirected to right now, or null for "play here".
  static DeviceInfo? get target {
    if (_bypassed) return null;
    return instance?.session.remoteTarget;
  }

  // -- Entry points (static: a call site needs no instance) -------------------

  /// A list of this phone's songs, tapped at [index]. [here] is the local play.
  static Future<void>? songs(
    List<SongModel> songs,
    int index, {
    bool radio = false,
    required Future<void> Function() here,
  }) {
    final router = instance;
    if (router == null || target == null) return null;
    return router._play(
      [for (final s in songs) trackRefOf(s, deviceId: router.deviceId)],
      index,
      radio: radio,
      here: here,
    );
  }

  /// YouTube tracks tapped at [index].
  static Future<void>? yt(
    List<YtTrack> tracks,
    int index, {
    bool radio = false,
    required Future<void> Function() here,
  }) {
    final router = instance;
    if (router == null || target == null) return null;
    return router._play(
      [for (final t in tracks) ytRefOf(t)],
      index,
      radio: radio,
      here: here,
    );
  }

  /// A mix or saved playlist: plays from the first thing the target can play.
  static Future<void>? mix(
    List<MixTrackRef> tracks, {
    required Future<void> Function() here,
  }) {
    final router = instance;
    if (router == null || target == null) return null;
    return router._play(
      [
        for (final t in tracks)
          switch (t.source) {
            MixSource.youtube when t.track != null => ytRefOf(t.track!),
            MixSource.local when t.song != null => trackRefOf(
              t.song!,
              deviceId: router.deviceId,
            ),
            _ => OtherTrackRef(
              title: t.title,
              artist: t.artist,
              album: null,
              durationMs: null,
              artUrl: null,
            ),
          },
      ],
      0,
      here: here,
      lenient: true,
    );
  }

  /// "Play next" / "add to queue" for this phone's songs.
  static Future<void>? enqueueSongs(List<SongModel> songs, EnqueueMode mode) {
    final router = instance;
    if (router == null || target == null) return null;
    return router._enqueue([
      for (final s in songs) trackRefOf(s, deviceId: router.deviceId),
    ], mode);
  }

  /// "Play next" / "add to queue" for YouTube tracks.
  static Future<void>? enqueueYt(List<YtTrack> tracks, EnqueueMode mode) {
    final router = instance;
    if (router == null || target == null) return null;
    return router._enqueue([for (final t in tracks) ytRefOf(t)], mode);
  }

  // -- Implementation ---------------------------------------------------------

  Future<void> _play(
    List<TrackRef> refs,
    int index, {
    bool radio = false,
    required Future<void> Function() here,
    bool lenient = false,
  }) async {
    final device = session.remoteTarget;
    if (device == null) return local(here);
    final plan = planRemotePlay(refs, index, startAtFirstPlayable: lenient);
    switch (plan) {
      case OnlyHere(:final title):
        final yes = await ui.confirmPlayHere(title, device.name);
        if (yes) await local(here);
      case SendPlay(:final items, :final dropped):
        final ack = await session.cmd(
          device.id,
          PlayCommand(items: items, index: 0, radio: radio ? true : null),
        );
        if (!ack.ok) {
          ui.say(_failure(ack.error, device.name));
          return;
        }
        if (dropped > 0) {
          ui.say(_stayedBehind(dropped));
        }
    }
  }

  Future<void> _enqueue(List<TrackRef> refs, EnqueueMode mode) async {
    final device = session.remoteTarget;
    if (device == null) return;
    final sendable = [
      for (final ref in refs)
        if (ref is YtTrackRef) ref,
    ];
    if (sendable.isEmpty) {
      ui.say(
        refs.length == 1
            ? "'${_titleOf(refs.first)}' is only on this phone, so "
                  '${device.name} cannot queue it.'
            : 'Those are only on this phone, so ${device.name} cannot queue them.',
      );
      return;
    }
    final ack = await session.cmd(
      device.id,
      EnqueueCommand(items: sendable, mode: mode),
    );
    if (!ack.ok) {
      ui.say(_failure(ack.error, device.name));
      return;
    }
    final dropped = refs.length - sendable.length;
    ui.say(
      '${mode == EnqueueMode.next ? 'Playing next' : 'Added to the queue'} '
      'on ${device.name}.${dropped > 0 ? ' ${_stayedBehind(dropped)}' : ''}',
    );
  }

  static String _stayedBehind(int n) => n == 1
      ? '1 song stayed on this phone.'
      : '$n songs stayed on this phone.';

  /// What to tell the user when the target refused or never answered.
  @visibleForTesting
  static String failureMessage(AckError? error, String deviceName) =>
      _failure(error, deviceName);

  static String _failure(AckError? error, String name) => switch (error) {
    AckError.offline => '$name is offline.',
    AckError.timeout => '$name did not answer. Try again.',
    AckError.nothingPlayable => '$name could not play that.',
    AckError.unsupported => '$name cannot do that yet.',
    AckError.notAPlayer => '$name is not a player.',
    _ => 'Could not play on $name.',
  };
}
