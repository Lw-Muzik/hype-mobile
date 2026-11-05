/// Stereo Expand's one setting: an amount from 0 to 1, shown as 0–100 %.
///
/// Zero is off — there is no separate switch — and the native stage is
/// bypassed exactly there. Above zero the side signal is raised by
/// `1 + 2 × amount` (up to +9.5 dB) with the mid left alone; see
/// `stereo_expander.h` for the whole of it.
library;

abstract final class StereoExpand {
  /// Where the amount is kept.
  static const prefKey = 'dspStereoExpand';

  static const min = 0.0;
  static const max = 1.0;
  static const initial = 0.0;

  /// The slider moves in whole percent.
  static const divisions = 100;

  /// The earlier keys: a switch, and a width of 0..2 where 1 was unchanged,
  /// below 1 narrower, above 1 wider.
  static const legacyEnabledKey = 'stereoExpandEnabled';
  static const legacyWidthKey = 'dspStereoWidth';

  /// The amount an earlier version's setting comes to.
  ///
  /// Widening carries over — width 1.5 becomes 50 %, 2.0 becomes 100 % —
  /// and anything that was off, unchanged or narrowing becomes 0, since the
  /// expander no longer narrows.
  static double migrate({bool? legacyEnabled, double? legacyWidth}) {
    if (legacyEnabled != true || legacyWidth == null) return initial;
    return (legacyWidth - 1.0).clamp(min, max).toDouble();
  }

  static double clamp(double amount) => amount.clamp(min, max).toDouble();

  /// "0%" … "100%".
  static String label(double amount) => '${(clamp(amount) * 100).round()}%';
}
