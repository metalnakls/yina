#!/bin/bash
set -euo pipefail
readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly TEST_DIR="$(mktemp -d /tmp/yina-optimization-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$REPO_DIR"

swift_flags=(-parse-as-library -target arm64-apple-macos27.0 -module-cache-path "$TEST_DIR/modules")
xcrun swiftc "${swift_flags[@]}" yina/ThumbnailCache.swift yina/CacheManager.swift other/tests/cache-regression-smoke.swift -o "$TEST_DIR/cache"
"$TEST_DIR/cache"

cat > "$TEST_DIR/YINA-Swift.h" <<'HEADER'
#import <Cocoa/Cocoa.h>
@interface FFmpegLogger: NSObject
+ (void)debug:(NSString *)message;
+ (void)error:(NSString *)message;
+ (void)warn:(NSString *)message;
@end
HEADER
cat > "$TEST_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>tsmc.yina.retention-tests</string></dict></plist>
PLIST
xcrun swiftc "${swift_flags[@]}" -import-objc-header "$TEST_DIR/YINA-Swift.h" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$TEST_DIR/Info.plist" \
  yina/Lock.swift yina/Atomic.swift yina/Logger.swift yina/JavascriptPolyfill.swift other/tests/retention-regression-smoke.swift -o "$TEST_DIR/retention"
"$TEST_DIR/retention"

# Tiny audio-only input reaches failure after avformat has opened a descriptor.
python3 - "$TEST_DIR/audio.wav" <<'PY'
import sys, wave
with wave.open(sys.argv[1], 'wb') as wav:
    wav.setnchannels(1)
    wav.setsampwidth(2)
    wav.setframerate(8000)
    wav.writeframes(bytes(16000))
PY
xcrun clang -fobjc-arc -fsanitize=address -mmacosx-version-min=27.0 -I "$TEST_DIR" -I yina -I deps/include \
  yina/FFmpegController.m other/tests/ffmpeg-preview-smoke.m \
  deps/lib/libavcodec.63.dylib deps/lib/libavformat.63.dylib deps/lib/libavutil.61.dylib deps/lib/libswscale.10.dylib \
  -framework Cocoa -framework Accelerate -framework QuartzCore -Wl,-rpath,"$REPO_DIR/deps/lib" -o "$TEST_DIR/ffmpeg"
"$TEST_DIR/ffmpeg" "$TEST_DIR/audio.wav"
