#!/usr/bin/env bash
# iOS spectrum feed checks: header twins, bridge symbols, C++ and Obj-C syntax.
set -euo pipefail
cd "$(dirname "$0")/../.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
INC=ios/HypeDSP/include/dsp_bridge.h
SRC=ios/HypeDSP/src/dsp_bridge.h
CPP=ios/HypeDSP/src/dsp_bridge.cpp

echo "[1] dsp_bridge.h twins identical"
diff "$INC" "$SRC"

echo "[2] spectrum functions declared in the public header"
grep -q dsp_bar_spectrum "$INC"
grep -q dsp_bar_spectrum_decimation "$INC"

echo "[3] every dsp_ symbol used by Runner is declared; every declared one is defined"
cat ios/Runner/*.swift ios/Runner/HypeAudioTap.m | sed -E 's/dsp_[a-z0-9_]*\*//g' | grep -oE '\bdsp_[a-z0-9_]*[a-z0-9]' | sort -u > "$T/used.txt"
grep -oE 'dsp_[a-z0-9_]+\s*\(' "$INC" | grep -oE 'dsp_[a-z0-9_]+' | sort -u > "$T/hdr.txt"
grep -oE 'dsp_[a-z0-9_]+\s*\(' "$CPP" | grep -oE 'dsp_[a-z0-9_]+' | sort -u > "$T/cpp.txt"
undeclared=$(comm -23 "$T/used.txt" "$T/hdr.txt" | grep -vE '^dsp_bridge$' || true)
undefined=$(comm -23 "$T/hdr.txt" "$T/cpp.txt" || true)
[ -z "$undeclared" ] || { echo "used but undeclared:"; echo "$undeclared"; exit 1; }
[ -z "$undefined" ] || { echo "declared but undefined:"; echo "$undefined"; exit 1; }

echo "[3b] feed reads host time and the walk function"
grep -q mach_absolute_time ios/Runner/HypeAudioTap.m
grep -q dsp_spectrum_window_end ios/Runner/HypeAudioTap.m
grep -q bandTime ios/Runner/HypeAudioTap.m

echo "[4] dsp_bridge.cpp C++ syntax"
clang -fsyntax-only -x c++ -std=c++17 -I ios/HypeDSP/src -I ios/HypeDSP/include "$CPP"

echo "[5] HypeAudioTap.m Obj-C syntax"
if command -v xcrun >/dev/null 2>&1 && xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1; then
  mkdir -p "$T/inc/HypeDSP"
  ln -s "$PWD/$INC" "$T/inc/HypeDSP/dsp_bridge.h"
  xcrun --sdk iphonesimulator clang -fsyntax-only -fobjc-arc -x objective-c \
    -arch arm64 -target arm64-apple-ios15.1-simulator -I "$T/inc" ios/Runner/HypeAudioTap.m
else
  echo "xcrun/iphonesimulator SDK unavailable, skipping Obj-C syntax check"
fi
echo "ios_checks OK"
