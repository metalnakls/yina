#!/bin/bash
set -euo pipefail
readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly TEST_DIR="$(mktemp -d /tmp/yina-avfoundation.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$REPO_DIR"
python3 other/tests/avfoundation-underrun-smoke.py
python3 - "$TEST_DIR/audio.wav" <<'PY'
import sys, wave
with wave.open(sys.argv[1], 'wb') as audio:
    audio.setnchannels(2)
    audio.setsampwidth(2)
    audio.setframerate(48000)
    audio.writeframes(bytes(48000 * 4 * 20))
PY
xcrun clang -include string.h -I deps/include other/tests/mpv-avfoundation-smoke.c \
  deps/lib/libmpv.2.dylib -Wl,-rpath,"$REPO_DIR/deps/lib" -o "$TEST_DIR/audio"
"$TEST_DIR/audio" "$TEST_DIR/audio.wav"
