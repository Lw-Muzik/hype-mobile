class ParametricPoint {
  double frequency; // 20-20000 Hz
  double gain; // -15 to +15 dB
  double q; // Q factor 0.3-10.0 (bandwidth control)
  bool enabled;

  ParametricPoint({
    required this.frequency,
    this.gain = 0.0,
    this.q = 1.4,
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
        'frequency': frequency,
        'gain': gain,
        'q': q,
        'enabled': enabled,
      };

  factory ParametricPoint.fromJson(Map<String, dynamic> json) {
    return ParametricPoint(
      frequency: (json['frequency'] as num).toDouble(),
      gain: (json['gain'] as num?)?.toDouble() ?? 0.0,
      q: (json['q'] as num?)?.toDouble() ?? 1.4,
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  ParametricPoint copyWith({double? frequency, double? gain, double? q, bool? enabled}) {
    return ParametricPoint(
      frequency: frequency ?? this.frequency,
      gain: gain ?? this.gain,
      q: q ?? this.q,
      enabled: enabled ?? this.enabled,
    );
  }
}
