#!/usr/bin/env python3
"""Replay recorded resize offset resets through the production AppKit anchor helper."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'yina/InitialWindowController.swift').read_text()
start = source.index('@MainActor\nprivate enum WelcomeRecentScrollAnchor')
end = source.index('private struct WelcomeRecentScrollGeometry:', start)
helper = source[start:end]
checks = '''
final class Document: NSView { override var isFlipped: Bool { true } }
@main struct AnchorSmoke {
  @MainActor static func main() {
    _ = NSApplication.shared
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 560))
    let scroll = NSScrollView(frame: root.bounds)
    root.addSubview(scroll)
    scroll.documentView = Document(frame: NSRect(x: 0, y: 0, width: 400, height: 700))
    func replay(offset: CGFloat, height: CGFloat, expected: CGFloat) {
      scroll.setFrameSize(NSSize(width: 400, height: 560))
      scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: offset))
      WelcomeRecentScrollAnchor.preserve(in: root, offsetY: offset) {
        scroll.setFrameSize(NSSize(width: 400, height: height))
        // Actual trace: resizing reset the origin to the previous 140-point limit.
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 140))
      }
      precondition(abs(scroll.contentView.bounds.origin.y - expected) < 0.01,
                   "Lost native position after resize: \\(scroll.contentView.bounds.origin.y), expected \\(expected)")
    }
    replay(offset: 192, height: 508, expected: 192)
    replay(offset: 504, height: 208, expected: 492)
    replay(offset: 140, height: 560, expected: 140)
    for _ in 0..<50 {
      replay(offset: 300, height: 400, expected: 300)
      replay(offset: 140, height: 560, expected: 140)
    }
    var resized = false
    WelcomeRecentScrollAnchor.preserve(in: nil, offsetY: nil) { resized = true }
    precondition(resized)
    print("PASS: recorded resize resets, native bottom constraint, expansion, and repeated direction changes")
  }
}
'''
with tempfile.TemporaryDirectory(prefix='yina-scroll-anchor-') as folder:
    folder = Path(folder)
    swift, binary = folder / 'Smoke.swift', folder / 'smoke'
    swift.write_text('import Cocoa\n' + helper + checks)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'modules'),
                    str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
