#!/usr/bin/env bash
# Builds and runs the host unit tests for the output stages and limiter.
#
#   native_tests/dsp_core/run.sh
#
# The shared headers are checked to be identical across platforms first. The
# whole-engine tests compile the iOS engine (the Android one also pulls in the
# stems code); the Android copy is covered by the NDK syntax check.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
a="$repo/android/app/src/main/cpp"
i="$repo/ios/HypeDSP/src"
for h in output_stages.h limiter.h stereo_expander.h; do
  if ! cmp -s "$a/$h" "$i/$h"; then
    echo "$h differs between Android and iOS:" >&2
    diff "$a/$h" "$i/$h" >&2 || true
    exit 1
  fi
done

out="${TMPDIR:-/tmp}/hype_dsp_core_test"
mkdir -p "$out"
clang++ -std=c++17 -O2 -Wall -Wextra \
  -I"$i" \
  "$here/dsp_core_test.cpp" \
  "$i/room_dsp_engine.cpp" "$i/fdn_reverb.cpp" \
  -o "$out/dsp_core_test"

"$out/dsp_core_test"
