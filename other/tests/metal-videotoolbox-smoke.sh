#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/yina-videotoolbox.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
LIBRARY="${YINA_TEST_MPV_LIBRARY:-$REPO_DIR/deps/lib/libmpv.2.dylib}"
clang -fobjc-arc -I "$REPO_DIR/deps/include" "$REPO_DIR/other/metal-deps/metal-smoke.m" \
  "$LIBRARY" -Wl,-rpath,"$(dirname "$LIBRARY")" \
  -framework AppKit -framework Metal -framework QuartzCore -o "$TEST_DIR/probe"
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=640x360:rate=24:duration=5' \
  -c:v libx264 -pix_fmt yuv420p -y "$TEST_DIR/h264.mkv"
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=640x360:rate=24:duration=5' \
  -vf format=yuv420p10le -c:v libx265 -preset ultrafast -x265-params log-level=error -y "$TEST_DIR/hevc10.mkv"
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=640x360:rate=24:duration=5' \
  -c:v mpeg2video -y "$TEST_DIR/software.mkv"
"$TEST_DIR/probe" "$TEST_DIR/h264.mkv" videotoolbox
YINA_TEST_WINDOW_SCREENSHOT=1 "$TEST_DIR/probe" "$TEST_DIR/hevc10.mkv" videotoolbox
"$TEST_DIR/probe" "$TEST_DIR/software.mkv" no
