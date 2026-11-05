#pragma once
#include <algorithm>
#include <cmath>

// "Smooth equalizer / tone gains": the equalizer and tone boosts follow the
// playback level, so a boosted band cannot push the output past full scale.
// Kept byte-identical in android/app/src/main/cpp and ios/HypeDSP/src.
//
// T is the level, in dB, that the signal reaches the equalizer at relative to
// full scale: the user preamp (while it is applied), the master volume, the
// system volume and the headroom trim, summed. The more T rises above the
// point where there is room to spare, the more of every boost is withdrawn.
//
// The result is two "scales", in dB. A stored gain keeps its fixed-scale
// value; the engine plays it at gain x (scale / off-scale), where the
// off-scale is the value with smoothing off (kEqScaleOffDb for the graphic EQ
// and the treble shelf, kBassScaleOffDb for the bass shelf). So with smoothing
// off the factor is 1, and a +12 dB band at T = 0 plays at +10 dB (12.5 / 15).
//
// Nothing is clamped: gains are scaled, not clipped. Taken literally the rule
// would invert the curve once T passes +15 dB (graphic EQ, treble) or +20 dB
// (bass), which only a preamp above +15 dB can reach, so each scale is floored
// at 0 (the boost is gone, never a cut).

struct SmoothScales {
    float eqDb;    // graphic EQ and treble
    float bassDb;  // bass shelf
};

constexpr float kEqScaleOffDb = 15.0f;
constexpr float kBassScaleOffDb = 22.5f;

inline SmoothScales smoothGainScales(float levelDb, bool on) {
    if (!on || !std::isfinite(levelDb)) return {kEqScaleOffDb, kBassScaleOffDb};
    const float t = levelDb;
    const float eq = t > -3.0f ? 12.5f - t * (100.0f / 120.0f) : kEqScaleOffDb;
    const float bass = t > -8.0f ? 15.0f - 0.75f * t : kBassScaleOffDb;
    return {std::max(0.0f, eq), std::max(0.0f, bass)};
}
