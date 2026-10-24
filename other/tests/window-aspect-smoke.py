#!/usr/bin/env python3
"""Exercise production resize delegation and video hosting with real AppKit geometry.

Run outside the sandbox: unusable WindowServer geometry is a failure, not a pass.
Use --source-ref HEAD to check the fixture against the pre-fix implementation.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--source-ref')
args = parser.parse_args()


def source(path):
    if args.source_ref:
        return subprocess.check_output(['git', 'show', f'{args.source_ref}:{path}'], cwd=ROOT, text=True)
    return (ROOT / path).read_text()


def method(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


window_source = source('yina/MainWindow.swift')
controller_source = source('yina/MainWindowController.swift')
extensions = source('yina/Extensions.swift')
# Include production MainWindow frame overrides if present, so the old bug stays testable.
start = window_source.index('enum VideoWindowGeometry') if 'enum VideoWindowGeometry' in window_source else window_source.index('class MainWindow:')
window_class = window_source[start:window_source.index('  override func keyDown')] + '\n}\n'
backdrop = window_source[window_source.index('final class VideoBackdropView'):] if 'final class VideoBackdropView' in window_source else ''
resize = method(controller_source, 'func windowWillResize(_ sender: NSWindow, to frameSize: NSSize)')
set_aspect = method(controller_source, 'private func setWindowAspectRatio').replace('private func', 'func', 1)
shrink = method(extensions, 'func shrink(toSize size: NSSize)')
centered = method(extensions, 'func centeredResize(to newSize: NSSize)')
# The same fit operation used by handleVideoSizeChange before its final setFrame.
fit_line = 'rect = rect.centeredResize(to: originalVideoSize.shrink(toSize: rect.size))'
assert fit_line in controller_source, 'Opening geometry must fit video before setting its frame'
swift = '''import Cocoa
class CommonWindow: NSWindow {}
class LiveText { func clearAnalysis() {} }
enum AppData { static let mainWindowMinSize = NSSize(width:285,height:120) }
extension NSSize { var aspect: CGFloat { width / height }
''' + shrink + '''
}
extension NSRect {
''' + centered + '''
}
''' + window_class + backdrop + '''
class MainWindowController: NSWindowController, NSWindowDelegate {
  enum State { case windowed, fullscreen }; var fsState = State.windowed
  struct Mode { var isActive = false }; var interactiveMode = Mode()
  var loaded = true; let liveText = LiveText()
  var currentWindowAspectRatio: NSSize { window!.aspectRatio }
''' + resize + '\n' + set_aspect + '''
}
NSApplication.shared.setActivationPolicy(.prohibited)
let window = MainWindow(contentRect:NSRect(x:100,y:100,width:640,height:360),
  styleMask:[.titled,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
let controller = MainWindowController(window:window)
window.delegate = controller
window.minSize = AppData.mainWindowMinSize
window.maxSize = NSSize(width:1000,height:700)
precondition(window.frame.width > 100 && window.frame.height > 100,
  "WindowServer unavailable: do not accept collapsed sandbox geometry")
let root = window.contentView!
root.autoresizesSubviews = false
''' + ('''let backdrop = VideoBackdropView()
root.addSubview(backdrop)
NSLayoutConstraint.activate([
  backdrop.leadingAnchor.constraint(equalTo:root.leadingAnchor),
  backdrop.trailingAnchor.constraint(equalTo:root.trailingAnchor),
  backdrop.topAnchor.constraint(equalTo:root.topAnchor),
  backdrop.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
let video = NSView(); video.translatesAutoresizingMaskIntoConstraints = false
backdrop.documentView = video
let clip = backdrop.contentView
NSLayoutConstraint.activate([
  video.leadingAnchor.constraint(equalTo:clip.leadingAnchor),
  video.trailingAnchor.constraint(equalTo:clip.trailingAnchor),
  video.topAnchor.constraint(equalTo:clip.topAnchor),
  video.bottomAnchor.constraint(equalTo:clip.bottomAnchor)])''' if backdrop else 'let video = root; let clip = root') + '''
func layout() {
  root.layoutSubtreeIfNeeded()
  RunLoop.main.run(until:Date(timeIntervalSinceNow:0.02))
  root.layoutSubtreeIfNeeded()
}
func assertVideoFillsWindow(_ aspect:NSSize) {
  layout()
  let tolerance:CGFloat = 1
  precondition(abs(window.frame.width-window.frame.height*aspect.width/aspect.height)<=max(tolerance,aspect.width/aspect.height),
    "Window aspect differs from displayed video: \\(window.frame)")
  precondition(abs(video.frame.width-root.bounds.width)<tolerance && abs(video.frame.height-root.bounds.height)<tolerance,
    "Video host leaves unused space inside the window")
  precondition(clip.bounds.origin == .zero && video.frame.origin == .zero,
    "Video host shifted inside the window")
}
for aspect in [NSSize(width:9,height:16),NSSize(width:16,height:9),NSSize(width:239,height:100),NSSize(width:1,height:1)] {
  let before = window.frame
  controller.setWindowAspectRatio(aspect)
  precondition(window.aspectRatio == aspect,"Native aspect lock missing")
  precondition(window.frame == before,"Aspect metadata update must not resize before opening geometry is ready")
  // AppKit has already applied size limits before invoking this delegate.
  for proposal in [NSSize(width:600,height:700),NSSize(width:599,height:699),
                   NSSize(width:600,height:700),NSSize(width:285,height:120)] {
    let result = controller.windowWillResize(window,to:proposal)
    precondition(result == proposal,"Resize delegate changed AppKit's constrained proposal: \\(proposal) -> \\(result)")
    precondition(result.width<=window.maxSize.width && result.height<=window.maxSize.height,
      "Resize delegate grew past native size limits")
  }
  for size in [NSSize(width:700,height:650),NSSize(width:640,height:600),NSSize(width:400,height:600),NSSize(width:640,height:600)] {
    for animated in [false,true] {
      let originalVideoSize = aspect
      var rect = NSRect(x:100,y:100,width:size.width,height:size.height)
''' + fit_line + '''
      window.setFrame(rect,display:false,animate:animated)
      RunLoop.main.run(until:Date(timeIntervalSinceNow:0.3))
      assertVideoFillsWindow(aspect)
      precondition(abs(window.frame.midX-rect.midX)<=1 && abs(window.frame.midY-rect.midY)<=1,
        "A second frame correction moved the requested window center")
    }
  }
}
controller.interactiveMode.isActive = true
precondition(controller.windowWillResize(window,to:NSSize(width:900,height:700)) == window.frame.size,
  "Interactive crop mode must retain its existing resize lock")
controller.interactiveMode.isActive = false
controller.fsState = .fullscreen
let screenProposal = NSSize(width:1440,height:900)
precondition(controller.windowWillResize(window,to:screenProposal) == screenProposal,
  "AppKit must own fullscreen geometry")
print("PASS: native resize proposals, portrait/landscape/wide/square opening and animation, video bounds, and fullscreen geometry")
'''
with tempfile.TemporaryDirectory(prefix='yina-aspect-') as directory:
    path = Path(directory) / 'main.swift'
    path.write_text(swift)
    binary = Path(directory) / 'probe'
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', '/private/tmp/yina-event-module-cache', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
