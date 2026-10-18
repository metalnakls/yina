from pathlib import Path
import subprocess
import tempfile

# Compile the production attachment methods in a windowless NSView harness.
# No application is launched, and no user preferences or UI are accessed.
test_directory = tempfile.TemporaryDirectory(prefix="yina-video-layout-")
root = Path(test_directory.name)
source = Path('yina/MainWindowController.swift').read_text()
start = source.index('  func addVideoViewToWindow()')
end = source.index('  private func setupVideoContainerConstraints()', start)
methods = source[start:end]
harness = '''import Cocoa
final class LayoutHarness {
  let videoView = NSView(frame: NSRect(x: 100, y: 200, width: 1920, height: 1080))
  let videoViewContainer: NSView! = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
  let layoutSides: [NSLayoutConstraint.Attribute] = [.leading, .trailing, .top, .bottom]
  var videoViewConstraints: [NSLayoutConstraint.Attribute: NSLayoutConstraint] = [:]
''' + methods + '''}
let player = LayoutHarness()
player.addVideoViewToWindow()
guard !player.videoView.translatesAutoresizingMaskIntoConstraints,
      player.videoViewConstraints.count == 4,
      player.videoViewConstraints.values.allSatisfy({ $0.isActive }) else {
  print("FAIL: video is not pinned to its container at first attachment")
  exit(1)
}
player.updateVideoViewConstraints([.leading: 20])
let pip = NSView()
player.videoView.removeFromSuperview()
pip.addSubview(player.videoView)
player.addVideoViewToWindow()
guard player.videoView.superview === player.videoViewContainer,
      player.videoViewConstraints.count == 4,
      player.videoViewConstraints.values.allSatisfy({ $0.isActive }) else {
  print("FAIL: video is not pinned after PiP reattachment")
  exit(1)
}
print("PASS: initial video attachment and PiP return activate all four sizing constraints")
'''
(root / 'video-layout.swift').write_text(harness)
subprocess.run(['xcrun','swiftc','-module-cache-path',str(root / 'modules'),str(root / 'video-layout.swift'),'-o',str(root / 'video-layout')],check=True)
subprocess.run([str(root / 'video-layout')],check=True)
