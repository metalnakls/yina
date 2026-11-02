#!/usr/bin/env python3
"""Exercise production spinner states using native AppKit labels and progress control."""
from pathlib import Path
import subprocess
import tempfile
repo=Path(__file__).resolve().parents[2]
s=(repo/'yina/BufferIndicatorView.swift').read_text()
def method(signature):
 a=s.index('  '+signature); return s[a:s.index('\n  }',a)+4]
fixture=r'''
import Cocoa
enum Preference {
 enum Key { case showBufferingThrobber, showSeekingThrobber }
 static var enabled = false
 static func bool(for key: Key) -> Bool { enabled }
}
struct FloatingPointByteCountFormatter { static func string(fromByteCount: Int, countStyle: ByteCountFormatter.CountStyle = .file) -> String { "0" } }
final class Info {
 var isNetworkResource=false, pausedForCache=false, isSeeking=false
 var isRemotePlayback: Bool { isNetworkResource }
 var cacheUsed=0, cacheSpeed=0, bufferingState=0
}
final class Player { let info=Info(); var isWaitingForRemoteMedia=false, isWaitingForPlayback=false }
final class MainWindow { var loaded=true }
final class Indicator: NSView {
 let player=Player(), mainWindow=MainWindow()
 let progressIndicator=NSProgressIndicator(), progressLabel=NSTextField(labelWithString:""), detailLabel=NSTextField(labelWithString:"")
// METHODS
}
@main struct IndicatorTest {
 @MainActor static func main() {
  _ = NSApplication.shared
  let view=Indicator()
  view.progressIndicator.style = .spinning
  view.addSubview(view.progressIndicator)
  view.updateNetworkState()
  precondition(view.isHidden)
  view.player.isWaitingForPlayback=true
  view.updateNetworkState()
  precondition(!view.isHidden && view.detailLabel.isHidden && !view.progressLabel.stringValue.isEmpty)
  view.player.isWaitingForRemoteMedia=true
  view.update()
  precondition(!view.isHidden && !view.detailLabel.isHidden)
  view.player.isWaitingForPlayback=false; view.player.isWaitingForRemoteMedia=false
  view.updateNetworkState()
  precondition(view.isHidden, "Ready/paused playback must clear the waiting overlay")
  Preference.enabled=true; view.player.info.pausedForCache=true
  view.updateNetworkState(); precondition(!view.isHidden)
  view.player.info.pausedForCache=false; view.player.info.isSeeking=true
  view.updateNetworkState(); precondition(!view.isHidden)
  view.player.info.isSeeking=false
  view.updateNetworkState(); precondition(view.isHidden)
  print("PASS: stalled Play, reconnect, ready, ordinary cache and seek spinner states")
 }
}
'''.replace('// METHODS',method('func update() {')+'\n'+method('func updateNetworkState() {'))
with tempfile.TemporaryDirectory(prefix='yina-buffer-state-') as d:
 p=Path(d); (p/'test.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-parse-as-library','-module-cache-path','/private/tmp/yina-event-module-cache',str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True,timeout=10)
