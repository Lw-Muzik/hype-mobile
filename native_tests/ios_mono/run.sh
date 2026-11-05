#!/usr/bin/env bash
# Host test of the iOS tap's mono helpers around the real engine (macOS only:
# HypeAudioTap.h pulls in AVFoundation). Also syntax-checks HypeAudioTap.m.
#
#   native_tests/ios_mono/run.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
i="$repo/ios/HypeDSP/src"
out="${TMPDIR:-/tmp}/hype_ios_mono_test"
mkdir -p "$out/inc"
# <HypeDSP/dsp_bridge.h> as the Xcode framework spells it.
ln -sfn "$repo/ios/HypeDSP/include" "$out/inc/HypeDSP"

xcrun --sdk macosx clang -fsyntax-only -fobjc-arc -Wall -I"$out/inc" \
  "$repo/ios/Runner/HypeAudioTap.m"

xcrun --sdk macosx clang++ -std=c++17 -ObjC++ -fobjc-arc -O2 -Wall -Wextra \
  -I"$repo/ios/Runner" -I"$i" \
  "$here/ios_mono_test.mm" \
  "$i/room_dsp_engine.cpp" "$i/fdn_reverb.cpp" \
  -framework AVFoundation -framework Foundation \
  -o "$out/ios_mono_test"

"$out/ios_mono_test"
