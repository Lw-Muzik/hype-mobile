// Where the built-in spectrum window ends now (iOS feed). Pure, so it is unit
// tested on the host: native_tests/bar_spectrum/spectrum_window_test.cpp.
#ifndef HYPE_SPECTRUM_WINDOW_H
#define HYPE_SPECTRUM_WINDOW_H

#include <stdint.h>

// The tap hands audio over in big buffers (~4096 frames). The window end is
// walked through the newest completed buffer in real time, one buffer behind:
//   prevCount   samples written before the newest buffer
//   latestCount samples written including the newest buffer
//   ageSeconds  time since the newest buffer completed
// Returns prevCount + age * sampleRate clamped to [prevCount, latestCount];
// latestCount once the age passes two buffer periods (paused or stalled).
inline int64_t spectrumWindowEnd(int64_t prevCount, int64_t latestCount,
                                 double ageSeconds, int sampleRate) {
    if (latestCount <= prevCount || sampleRate <= 0) return latestCount;
    if (!(ageSeconds > 0)) return prevCount;
    const double period = (double)(latestCount - prevCount) / sampleRate;
    if (ageSeconds > 2 * period) return latestCount;
    const int64_t end = prevCount + (int64_t)(ageSeconds * sampleRate);
    return end > latestCount ? latestCount : end;
}

#endif  // HYPE_SPECTRUM_WINDOW_H
