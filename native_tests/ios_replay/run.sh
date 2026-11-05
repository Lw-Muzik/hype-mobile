#!/usr/bin/env bash
# Builds and runs the host test for the iOS DSP replay log.
#
#   native_tests/ios_replay/run.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="${TMPDIR:-/tmp}/hype_ios_replay_test"
mkdir -p "$out"
swiftc -parse-as-library -O \
  "$repo/ios/Runner/DSPReplayLog.swift" \
  "$here/replay_test.swift" \
  -o "$out/replay_test"
"$out/replay_test"
