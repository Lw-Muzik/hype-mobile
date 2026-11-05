#!/usr/bin/env bash
# Builds and runs the host unit tests for Stereo Expand.
#
#   native_tests/stereo/run.sh
#
# The header under test is shared by both platforms; the two copies are
# checked to be identical first.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
android="$repo/android/app/src/main/cpp/stereo_expander.h"
ios="$repo/ios/HypeDSP/src/stereo_expander.h"
if ! cmp -s "$android" "$ios"; then
  echo "stereo_expander.h differs between Android and iOS:" >&2
  diff "$android" "$ios" >&2 || true
  exit 1
fi

out="${TMPDIR:-/tmp}/hype_stereo_test"
mkdir -p "$out"
clang++ -std=c++17 -O2 -Wall -Wextra \
  -I"$repo/android/app/src/main/cpp" \
  "$here/stereo_expander_test.cpp" \
  -o "$out/stereo_expander_test"

"$out/stereo_expander_test"
