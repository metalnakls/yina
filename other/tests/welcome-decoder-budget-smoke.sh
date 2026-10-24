#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_dir="$(mktemp -d /private/tmp/yina-decoder-budget.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
cat > "$test_dir/YINA-Swift.h" <<'HEADER'
#import <Cocoa/Cocoa.h>
@interface FFmpegLogger:NSObject
+ (void)debug:(NSString*)value;
+ (void)warn:(NSString*)value;
+ (void)error:(NSString*)value;
@end
HEADER
xcrun clang -fobjc-arc -mmacosx-version-min=27.0 -I "$test_dir" -I "$repo_dir/yina" -I "$repo_dir/deps/include" \
 "$repo_dir/yina/FFmpegController.m" "$repo_dir/other/tests/welcome-decoder-budget-smoke.m" \
 "$repo_dir/deps/lib/libavcodec.63.dylib" "$repo_dir/deps/lib/libavformat.63.dylib" \
 "$repo_dir/deps/lib/libavutil.61.dylib" "$repo_dir/deps/lib/libswscale.10.dylib" \
 -framework Cocoa -framework Accelerate -framework QuartzCore -Wl,-rpath,"$repo_dir/deps/lib" -o "$test_dir/probe"
"$test_dir/probe"
