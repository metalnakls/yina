#!/usr/bin/env python3
"""Lay out the production floating timeline at narrow and wide window sizes."""
import pathlib
import subprocess
import tempfile


def extract_method(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError(f"Unclosed production method: {signature}")


mwc = pathlib.Path("yina/MainWindowController.swift").read_text()
start = mwc.index("    playSlider.setContentHuggingPriority")
end = mwc.index("    oscPlaySliderTopConstraint =", start)
timeline_setup = (mwc[start:end].replace("self.", "")
                  .replace("leftLabel.center(.y, with: playSlider)",
                           "leftLabel.centerYAnchor.constraint(equalTo: playSlider.centerYAnchor).isActive = true")
                  .replace("rightLabel.center(.y, with: playSlider)",
                           "rightLabel.centerYAnchor.constraint(equalTo: playSlider.centerYAnchor).isActive = true"))

floating_source = pathlib.Path("yina/OSCFloatingView.swift").read_text()
floating_source = floating_source[floating_source.index("class OSCFloatingView:"):]
floating_setup = extract_method(floating_source, "  func setupConstraints()")
init_position = extract_method(floating_source, "  func initPosition()")
update_position = extract_method(floating_source, "  func updatePosition()")
bar_size = extract_method(floating_source, "  private var barSize: NSSize")
clamp_x = extract_method(floating_source, "  private func clampedX(")
clamp_y = extract_method(floating_source, "  private func clampedY(")

view = pathlib.Path("yina/TimeLabelOverflowedView.swift").read_text()
code = '''import Cocoa
extension Comparable {
 func clamped(to range:ClosedRange<Self>)->Self { min(max(self,range.lowerBound),range.upperBound) }
}
NSApplication.shared.setActivationPolicy(.prohibited)
let window=NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:360),styleMask:[.titled,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
let root=window.contentView!
let videoView=NSView();videoView.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(videoView)
let videoWidth=videoView.widthAnchor.constraint(equalToConstant:640)
NSLayoutConstraint.activate([videoWidth,videoView.heightAnchor.constraint(equalToConstant:360),videoView.leadingAnchor.constraint(equalTo:root.leadingAnchor),videoView.topAnchor.constraint(equalTo:root.topAnchor)])
enum Preference {
 enum Key { case controlBarPositionHorizontal, controlBarPositionVertical }
 static func float(for key:Key)->CGFloat { key == .controlBarPositionHorizontal ? 0.5 : 0.1 }
}
final class WindowHarness { var videoViewContainer:NSView! }
class Bar: NSView {
 static let preferredWidth:CGFloat=460, horizontalInset:CGFloat=16, verticalMargin:CGFloat=25, assumedHeight:CGFloat=40
 let mainWindow:WindowHarness
 var xConstraint:NSLayoutConstraint!
 var yConstraint:NSLayoutConstraint!
 init(mainWindow:WindowHarness) { self.mainWindow=mainWindow;super.init(frame:.zero) }
 required init?(coder:NSCoder) { fatalError() }
'''+"\n\n".join([floating_setup,init_position,update_position,bar_size,clamp_x,clamp_y])+'''
}
let controller=WindowHarness();controller.videoViewContainer=videoView
let bar=Bar(mainWindow:controller);bar.translatesAutoresizingMaskIntoConstraints=false;videoView.addSubview(bar);bar.setupConstraints()
var oscSliderView:TimeLabelOverflowedView!
let playSlider=NSSlider();playSlider.translatesAutoresizingMaskIntoConstraints=false
let leftLabel:NSTextField! = NSTextField(labelWithString:"1:23:45")
let rightLabel:NSTextField! = NSTextField(labelWithString:"−1:23:45")
[leftLabel,rightLabel].forEach{$0!.translatesAutoresizingMaskIntoConstraints=false}
var oscSliderLabelConstraints:[NSLayoutConstraint]=[]
'''+timeline_setup+'''
bar.addSubview(oscSliderView)
NSLayoutConstraint.activate([
 oscSliderView.leadingAnchor.constraint(equalTo:bar.leadingAnchor,constant:8),
 oscSliderView.trailingAnchor.constraint(equalTo:bar.trailingAnchor,constant:-8),
 oscSliderView.topAnchor.constraint(equalTo:bar.topAnchor,constant:8),
 oscSliderView.bottomAnchor.constraint(equalTo:bar.bottomAnchor,constant:-8),
 playSlider.topAnchor.constraint(equalTo:oscSliderView.topAnchor,constant:6),
 playSlider.bottomAnchor.constraint(equalTo:oscSliderView.bottomAnchor,constant:-6)])
bar.initPosition()
var widths:[CGFloat]=[]
for width in [285.0,320,460,640,1920] {
 videoWidth.constant=width
 root.layoutSubtreeIfNeeded()
 videoView.needsLayout=true
 videoView.layoutSubtreeIfNeeded()
 RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01))
 bar.updatePosition()
 videoView.layoutSubtreeIfNeeded()
 precondition(playSlider.frame.width >= 20, "slider width: \\(playSlider.frame)")
 precondition(leftLabel.frame.maxX <= playSlider.frame.minX && playSlider.frame.maxX <= rightLabel.frame.minX)
 precondition(rightLabel.frame.maxX <= oscSliderView.bounds.maxX)
 precondition(bar.frame.width <= width-31 && bar.frame.width <= 461,"bar: \\(bar.frame), window: \\(width)")
 widths.append(playSlider.frame.width)
}
precondition(widths[0] < widths[3],"Timeline must compress before the labels")
print("PASS: timeline scales from 285 to 1920 points, preserving elapsed/remaining labels without overlap")
'''

with tempfile.TemporaryDirectory(prefix="yina-timeline-") as directory:
    temp = pathlib.Path(directory)
    source = temp / "main.swift"
    source.write_text(view + "\n" + code)
    binary = temp / "probe"
    subprocess.run([
        "xcrun", "swiftc", "-module-cache-path", "/private/tmp/yina-event-module-cache",
        str(source), "-o", str(binary)
    ], check=True)
    subprocess.run([str(binary)], check=True)
