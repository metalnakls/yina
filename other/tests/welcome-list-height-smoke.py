#!/usr/bin/env python3
"""Check production window fitting against full remaining scroll content; no app launch."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'yina/InitialWindowController.swift').read_text()
start = source.index('private struct WelcomeRecentScrollGeometry: Equatable {')
end = source.index('private struct WelcomeRecentItem:', start)
geometry = source[start:end]
checks = '''
func height(_ content: CGFloat, _ offset: CGFloat) -> CGFloat {
  WelcomeRecentScrollGeometry(offset: offset, contentHeight: content)
    .windowHeight(minimum: 208, maximum: 560)
}
// Scrolling a long list must not shrink its viewport while more content remains.
precondition(height(752, 0) == 560)
precondition(height(752, 100) == 560)
precondition(height(752, 250) == 502)
// Reaching the end retains bottom padding (included in the measured content extent).
precondition(height(56 + 10 * 34 + 16, 34) == 378)
precondition(height(752, 700) == 208)
precondition(height(300, -50) == 300)
precondition(height(752, 0) == height(752, -20))
precondition(!WelcomeRecentScrollGeometry(offset: .infinity, contentHeight: 752).isValid)
precondition(!WelcomeRecentScrollGeometry(offset: 0, contentHeight: .nan).isValid)
print("PASS: full remaining content, cap, minimum, bottom inset, and rubberband offsets")
'''
with tempfile.TemporaryDirectory(prefix='yina-list-height-') as folder:
    folder = Path(folder)
    swift, binary = folder / 'main.swift', folder / 'smoke'
    swift.write_text('import Foundation\n' + geometry + checks)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(folder / 'modules'),
                    str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
