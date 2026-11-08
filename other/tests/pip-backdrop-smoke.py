#!/usr/bin/env python3
"""Exercise production reveal policy with real AppKit view reparenting."""
from pathlib import Path
import subprocess,tempfile
repo=Path(__file__).resolve().parents[2]
s=(repo/'yina/MainWindowController.swift').read_text()
a=s.index('  func revealPiPBackdropIfDetached() {');b=s.index('\n  func pipHostWindowDidChange',a)
code='''import Cocoa
class Trace { func sample(_ text: String) {} }
class Controller {
 enum Status { case inPIP, intermediate, notInPIP }
 var pipStatus = Status.inPIP
 var window: NSWindow?
 let videoView = NSView(frame: NSRect(x: 0,y: 0,width: 320,height: 180))
 let pipOverlayView = NSView()
 var pipTransitionTrace: Trace?
'''+s[a:b]+'''
}
@main struct Test {
 static func main() {
  NSApplication.shared.setActivationPolicy(.prohibited)
  let source = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 320,height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
  let pip = NSWindow(contentRect: source.frame, styleMask: [.borderless], backing: .buffered, defer: false)
  source.isReleasedWhenClosed = false; pip.isReleasedWhenClosed = false
  let c = Controller(); c.window = source; c.pipOverlayView.isHidden = true
  source.contentView!.addSubview(c.videoView)
  c.revealPiPBackdropIfDetached()
  precondition(c.pipOverlayView.isHidden, "Must not reveal over source video")
  c.videoView.removeFromSuperview(); c.revealPiPBackdropIfDetached()
  precondition(c.pipOverlayView.isHidden, "Intermediate nil host is not a completed handoff")
  pip.contentView!.addSubview(c.videoView); c.revealPiPBackdropIfDetached()
  precondition(!c.pipOverlayView.isHidden, "Reveal after video attaches to PiP")
  c.pipStatus = .intermediate; c.pipOverlayView.isHidden = true
  c.revealPiPBackdropIfDetached()
  precondition(c.pipOverlayView.isHidden, "Delayed callbacks must not reveal on exit")
  source.contentView!.addSubview(c.videoView); c.pipStatus = .inPIP
  c.revealPiPBackdropIfDetached()
  precondition(c.pipOverlayView.isHidden, "Reentry must wait for the new handoff")
  print("PASS: source host, nil host, PiP attachment, closing callback and reentry")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='yina-backdrop-') as d:
 p=Path(d);(p/'test.swift').write_text(code)
 subprocess.run(['xcrun','swiftc','-parse-as-library','-module-cache-path','/private/tmp/yina-event-module-cache',str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True,timeout=15)
