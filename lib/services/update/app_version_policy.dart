/// The "is there a newer Hype Muzik?" decision, free of any I/O so it can be
/// tested exhaustively. The service in `update_service.dart` feeds it.
library;

/// The policy the backend serves at `GET /app-version/<platform>`.
class AppVersionPolicy {
  const AppVersionPolicy({
    required this.latestVersion,
    required this.minimumVersion,
    this.releaseNotes,
    this.isCritical = false,
    this.storeUrl,
  });

  final String latestVersion;
  final String minimumVersion;
  final String? releaseNotes;
  final bool isCritical;
  final String? storeUrl;

  /// Null when the payload is unusable (missing or malformed versions). The
  /// caller treats null as "say nothing": a bad response never blocks the app.
  static AppVersionPolicy? tryParse(Object? json) {
    if (json is! Map) return null;
    final latest = json['latestVersion'];
    final minimum = json['minimumVersion'];
    if (latest is! String || minimum is! String) return null;
    if (parseVersion(latest) == null || parseVersion(minimum) == null) {
      return null;
    }
    final notes = json['releaseNotes'];
    final url = json['storeUrl'];
    return AppVersionPolicy(
      latestVersion: latest.trim(),
      minimumVersion: minimum.trim(),
      releaseNotes: notes is String && notes.trim().isNotEmpty
          ? notes.trim()
          : null,
      isCritical: json['isCritical'] == true,
      storeUrl: url is String && url.trim().isNotEmpty ? url.trim() : null,
    );
  }
}

/// `MAJOR.MINOR.PATCH` as three ints, or null if [raw] is not that shape.
/// A `+build` (or `-pre`) suffix is ignored, as is a leading `v`.
List<int>? parseVersion(String raw) {
  final core = raw.trim().replaceFirst(RegExp(r'^[vV]'), '');
  final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:[+-].*)?$').firstMatch(core);
  if (m == null) return null;
  return [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
}

/// Negative if [a] < [b], 0 if equal, positive if [a] > [b]. Unparseable
/// input compares equal so it can never trigger a prompt.
int compareVersions(String a, String b) {
  final pa = parseVersion(a);
  final pb = parseVersion(b);
  if (pa == null || pb == null) return 0;
  for (var i = 0; i < 3; i++) {
    final d = pa[i].compareTo(pb[i]);
    if (d != 0) return d;
  }
  return 0;
}

enum UpdatePrompt { none, dismissible, blocking }

/// How long "Later" stays quiet.
const Duration kLaterCooldown = Duration(hours: 24);

/// What the user has already said about [AppVersionPolicy.latestVersion].
class UpdateChoices {
  const UpdateChoices({this.laterAt, this.laterVersion, this.skippedVersion});

  /// When "Later" was tapped, and for which `latestVersion`.
  final DateTime? laterAt;
  final String? laterVersion;

  /// The `latestVersion` the user chose to skip.
  final String? skippedVersion;
}

/// The decision table.
///
/// * installed < minimum, or critical and installed < latest: [blocking]. Later
///   and Skip never apply.
/// * installed < latest: [dismissible], unless that exact latest was skipped or
///   "Later" was tapped for it less than [kLaterCooldown] ago.
/// * otherwise [none].
///
/// [ignoreChoices] is for a tap on the push notification: the user asked to see
/// it, so Later and Skip are bypassed (blocking is unaffected).
UpdatePrompt decideUpdate({
  required String installed,
  required AppVersionPolicy policy,
  required DateTime now,
  UpdateChoices choices = const UpdateChoices(),
  bool ignoreChoices = false,
}) {
  final belowMin = compareVersions(installed, policy.minimumVersion) < 0;
  final belowLatest = compareVersions(installed, policy.latestVersion) < 0;
  if (belowMin || (policy.isCritical && belowLatest)) {
    return UpdatePrompt.blocking;
  }
  if (!belowLatest) return UpdatePrompt.none;
  if (!ignoreChoices) {
    if (choices.skippedVersion == policy.latestVersion) return UpdatePrompt.none;
    final at = choices.laterAt;
    if (at != null &&
        choices.laterVersion == policy.latestVersion &&
        now.difference(at) < kLaterCooldown) {
      return UpdatePrompt.none;
    }
  }
  return UpdatePrompt.dismissible;
}
