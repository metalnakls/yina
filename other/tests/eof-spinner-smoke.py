"""Exercise the process pipe collector and spinner lifecycle."""
from pathlib import Path
import subprocess, tempfile, os
subprocess.run(["python3", "other/tests/plugin-output-smoke.py"], check=True)
viewPrelude='''import Cocoa
class TranslucentView: NSView {
  init(padding: (Int, Int)) { super.init(frame:.zero) }
  required init?(coder: NSCoder) { fatalError() }
  func setContent(_ view: NSView) { addSubview(view) }
}
enum Padding { case all(Int) }
extension NSView {
  func size(width: Int) {}
  func padding(_ value: Padding) {}
}
final class PlayerCore {
  final class Info {
    var isNetworkResource=false, pausedForCache=false, isSeeking=false
    var cacheUsed=0, cacheSpeed=0, bufferingState=0
  }
  let info=Info()
}
final class MainWindowController { let player=PlayerCore(); var loaded=true }
enum Preference {
  enum Key { case showBufferingThrobber, showSeekingThrobber }
  static func bool(for key: Key) -> Bool { true }
}
enum FloatingPointByteCountFormatter {
  static func string(fromByteCount: Int, countStyle: ByteCountFormatter.CountStyle = .binary) -> String { "fixture" }
}
final class Spinner: NSProgressIndicator {
  var starts=0, stops=0
  override func startAnimation(_ sender: Any?) { starts += 1 }
  override func stopAnimation(_ sender: Any?) { stops += 1 }
}
'''
viewTest='''
@main enum SpinnerSmoke {
 @MainActor static func main() {
  let window=MainWindowController()
  let view=BufferIndicatorView(mainWindow:window)
  let spinner=Spinner()
  view.progressIndicator=spinner
  view.viewDidHide(); precondition(spinner.stops == 1)
  view.viewDidUnhide(); precondition(spinner.starts == 1)
  view.isHidden=false
  view.isHidden=true
  let stopped=spinner.stops
  precondition(stopped>=2, "AppKit hiding invokes stop")
  view.isHidden=false
  precondition(spinner.starts>=2, "AppKit showing invokes restart")
  view.update(); precondition(view.isHidden)
  window.player.info.isNetworkResource=true
  view.update(); precondition(!view.isHidden)
  window.player.info.pausedForCache=true
  view.updateNetworkState(); precondition(!view.isHidden && !view.detailLabel.isHidden)
  window.player.info.pausedForCache=false
  view.updateNetworkState(); precondition(view.isHidden)
  window.player.info.isSeeking=true
  view.updateNetworkState(); precondition(!view.isHidden)
  print("PASS: production spinner hide/show lifecycle, local/network opening, buffering and seeking")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='yina-eof-spinner-') as directory:
 p=Path(directory)
 for name,code,args in [('spinner',viewPrelude+Path('yina/BufferIndicatorView.swift').read_text()+viewTest,['-parse-as-library'])]:
  (p/(name+'.swift')).write_text(code)
  subprocess.run(['xcrun','swiftc',*args,'-module-cache-path',str(p/'modules'),str(p/(name+'.swift')),'-o',str(p/name)],check=True)
  subprocess.run([str(p/name)],check=True,timeout=15)
