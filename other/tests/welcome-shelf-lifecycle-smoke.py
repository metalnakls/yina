#!/usr/bin/env python3
"""A late layout must not resurrect a closing welcome window's native child shelf."""
from pathlib import Path
import subprocess
import tempfile
repo=Path(__file__).resolve().parents[2]
s=(repo/'yina/InitialWindowController.swift').read_text()
a=s.index('  private func updateShelfWindowVisibility() {')
method=s[a:s.index('\n  }',a)+4]
fixture='''
import Cocoa
final class Welcome {
 var window: NSWindow?, shelfWindow: NSWindow?
 var showFolders = ["Generated show"]
 var isShowingWelcome = false
 init(_ w: NSWindow, _ s: NSWindow) { window=w; shelfWindow=s }
 func refresh() { updateShelfWindowVisibility() }
// METHOD
}
@main struct ShelfTest {
 @MainActor static func main() {
  _ = NSApplication.shared
  let parent = NSWindow(contentRect: NSRect(x:0,y:0,width:200,height:100), styleMask: [.titled], backing: .buffered, defer:false)
  let shelf = NSWindow(contentRect: NSRect(x:0,y:0,width:200,height:100), styleMask: [.borderless], backing: .buffered, defer:false)
  parent.alphaValue=0; parent.level=NSWindow.Level(rawValue: -1000); parent.isReleasedWhenClosed=false
  shelf.level=parent.level; shelf.isReleasedWhenClosed=false
  parent.orderBack(nil)
  parent.addChildWindow(shelf, ordered:.above)
  shelf.orderOut(nil)
  let welcome=Welcome(parent,shelf)
  // A queued layout runs during will-close, while AppKit still reports the parent visible.
  welcome.refresh()
  precondition(shelf.alphaValue == 0 && !shelf.isVisible && shelf.parent == nil,
               "Closing welcome shelf was resurrected by a late layout")
  welcome.isShowingWelcome=true
  welcome.refresh()
  precondition(shelf.parent === parent && shelf.isVisible && shelf.alphaValue == 1)
  welcome.showFolders=[]
  welcome.refresh()
  precondition(!shelf.isVisible && shelf.parent == nil)
  parent.close(); shelf.close()
  print("PASS: welcome shelf cannot survive closing, reattaches on reopen, and hides when empty")
 }
}
'''.replace('// METHOD',method)
with tempfile.TemporaryDirectory(prefix='yina-shelf-lifecycle-') as d:
 p=Path(d); (p/'test.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-parse-as-library','-module-cache-path','/private/tmp/yina-event-module-cache',str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True,timeout=10)
