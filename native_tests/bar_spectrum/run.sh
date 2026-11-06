#!/usr/bin/env bash
# Builds and runs the host unit tests for the built-in visualizer spectrum.
#
#   native_tests/bar_spectrum/run.sh
#
# The header under test is shared by both platforms; the two copies are
# checked to be identical first.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
android="$repo/android/app/src/main/cpp/bar_spectrum.h"
ios="$repo/ios/HypeDSP/src/bar_spectrum.h"
if ! cmp -s "$android" "$ios"; then
  echo "bar_spectrum.h differs between Android and iOS:" >&2
  diff "$android" "$ios" >&2 || true
  exit 1
fi

out="${TMPDIR:-/tmp}/hype_bar_spectrum_test"
mkdir -p "$out"
for t in bar_spectrum_test fft_visualizer_spectrum_test spectrum_window_test; do
  clang++ -std=c++17 -O2 -Wall -Wextra \
    -I"$repo/android/app/src/main/cpp" \
    -I"$repo/ios/HypeDSP/src" \
    "$here/$t.cpp" \
    -o "$out/$t"
done

"$out/bar_spectrum_test"
"$out/fft_visualizer_spectrum_test"
"$out/spectrum_window_test"

"$here/ios_checks.sh"
