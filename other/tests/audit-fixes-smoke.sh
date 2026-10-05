#!/bin/bash
set -euo pipefail
readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly TEST_DIR="$(mktemp -d /tmp/yina-audit-fixes.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$REPO_DIR"
swift_flags=(-parse-as-library -target arm64-apple-macos27.0 -module-cache-path "$TEST_DIR/modules")

xcrun swiftc "${swift_flags[@]}" yina/Lock.swift yina/Atomic.swift yina/HistoryController.swift \
  other/tests/history-clear-smoke.swift -o "$TEST_DIR/history"
"$TEST_DIR/history"
xcrun swiftc "${swift_flags[@]}" yina/WebSocketServer.swift yina/JavascriptAPIWebSocket.swift \
  other/tests/websocket-lifecycle-smoke.swift -o "$TEST_DIR/websocket"
"$TEST_DIR/websocket"
