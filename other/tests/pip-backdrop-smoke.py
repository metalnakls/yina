#!/usr/bin/env python3
"""Exercise production reveal policy with real AppKit view reparenting."""
from pathlib import Path
import subprocess,tempfile
repo=Path(__file__).resolve().parents[2]
s=(repo/'yina/MainWindowController.swift').read_text()
a=s.index('  func revealPiPBackdropIfDetached() {');b=s.index('\n  func pipHostWindowDidChange',a)
restore_start=s.index('  private func restoreSourceWindowAfterPiP('); restore_end=s.index('\n  func prepareForPIPClosure', restore_start)
toggle_start=s.index('  func togglePIP()'); toggle_end=s.index('\n  func enterPIP()', toggle_start)
code='''import Cocoa
class Trace { func sample(_ text: String) {} }
class Controller {
 enum Status { case inPIP, intermediate, notInPIP }
 var pipStatus = Status.inPIP
 var window: NSWindow?
 let videoView = NSView(frame: NSRect(x: 0,y: 0,width: 320,height: 180))
 let pipOverlayView = NSView()
 var pipTransitionTrace: Trace?
 var pipTransition = PiPTransitionState()
 var pendingShow = false
 var isWindowHidden = false
 var entries = 0
 var exits = 0
 var hasPendingPiPEntry: Bool { pipTransition.hasPendingEntry }
 func cancelPendingPiPEntry() { pipTransition.cancelPendingEntry() }
 func enterPIP() { entries += 1 }
 func exitPIP(restoringWindow: Bool = true) { exits += 1 }
 func finish(restoring: Bool) { restoreSourceWindowAfterPiP(restoringWindow: restoring) }
'''+s[a:b]+s[restore_start:restore_end]+s[toggle_start:toggle_end]+'''
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
  let session = c.pipTransition.beginEntry()!
  precondition(c.pipTransition.deferExitUntilAttached(restoringWindow: true))
  pip.contentView!.addSubview(c.videoView); c.revealPiPBackdropIfDetached()
  precondition(c.exits == 0, "Do not dismiss inside AppKit attachment callback")
  RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  precondition(c.exits == 1, "Deferred return must be delivered after attachment")
  c.revealPiPBackdropIfDetached()
  RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  precondition(c.exits == 1, "Repeated layouts must not repeat dismissal")
  _ = c.pipTransition.completeExit(session)
  c.exits = 0
  precondition(!c.pipOverlayView.isHidden, "Reveal after video attaches to PiP")
  c.pipStatus = .intermediate; c.pipOverlayView.isHidden = true
  c.revealPiPBackdropIfDetached()
  precondition(c.pipOverlayView.isHidden, "Delayed callbacks must not reveal on exit")
  source.contentView!.addSubview(c.videoView); c.pipStatus = .inPIP
  c.revealPiPBackdropIfDetached()
  precondition(c.pipOverlayView.isHidden, "Reentry must wait for the new handoff")
  c.pipTransition.waitForVideo()
  c.togglePIP()
  precondition(!c.hasPendingPiPEntry && c.entries == 0 && c.exits == 0, "Second toggle cancels waiting entry")
  c.pipStatus = .notInPIP
  c.togglePIP()
  precondition(c.entries == 1)
  source.orderOut(nil)
  c.isWindowHidden = false; c.pendingShow = true; c.pipOverlayView.isHidden = false
  c.finish(restoring: true)
  precondition(source.isVisible && !c.pendingShow && c.pipOverlayView.isHidden, "Restore never-shown source and clear backdrop without will-close")
  source.orderOut(nil)
  c.pendingShow = true; c.pipOverlayView.isHidden = false
  c.finish(restoring: false)
  precondition(!source.isVisible && !c.pendingShow && c.pipOverlayView.isHidden, "Non-restoring close must consume deferred show")
  print("PASS: source host, nil host, PiP attachment, closing callback and reentry")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='yina-backdrop-') as d:
 p=Path(d);(p/'test.swift').write_text(code)
 subprocess.run(['xcrun','swiftc','-parse-as-library','-module-cache-path','/private/tmp/yina-event-module-cache',str(repo/'yina/PiPTransitionState.swift'),str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True,timeout=15)
