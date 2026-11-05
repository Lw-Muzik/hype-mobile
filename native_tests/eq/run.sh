#!/usr/bin/env bash
# Builds and runs the host unit tests for the N-band graphic EQ.
#
#   native_tests/eq/run.sh
#
# The shared headers are checked to be identical across platforms first. The
# whole-engine tests compile the iOS engine (the Android one also pulls in the
# stems code); the Android copy is covered by the NDK syntax check.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
a="$repo/android/app/src/main/cpp"
i="$repo/ios/HypeDSP/src"
for h in graphic_eq.h smooth_gains.h tone_controls.h biquad.h parametric_eq.h output_stages.h limiter.h stereo_expander.h; do
  if ! cmp -s "$a/$h" "$i/$h"; then
    echo "$h differs between Android and iOS:" >&2
    diff "$a/$h" "$i/$h" >&2 || true
    exit 1
  fi
done

out="${TMPDIR:-/tmp}/hype_eq_test"
mkdir -p "$out"
clang++ -std=c++17 -O2 -Wall -Wextra -pthread \
  -I"$i" \
  "$here/eq_test.cpp" \
  "$i/room_dsp_engine.cpp" "$i/fdn_reverb.cpp" \
  -o "$out/eq_test"

"$out/eq_test"

# Setters on other threads while the audio thread processes, under
# ThreadSanitizer (skipped when the toolchain has none).
if echo 'int main(){}' | clang++ -x c++ -fsanitize=thread - -o "$out/tsan_probe" 2>/dev/null; then
  clang++ -std=c++17 -O1 -g -pthread -fsanitize=thread \
    -I"$i" \
    "$here/eq_test.cpp" \
    "$i/room_dsp_engine.cpp" "$i/fdn_reverb.cpp" \
    -o "$out/eq_test_tsan" 2>/dev/null
  "$out/eq_test_tsan" stress
else
  echo "ThreadSanitizer unavailable: stress run skipped"
fi
