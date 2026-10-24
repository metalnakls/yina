#!/usr/bin/env python3
"""Lay out the production floating timeline at narrow and wide window sizes."""
import pathlib, subprocess, tempfile
s=pathlib.Path('yina/MainWindowController.swift').read_text()
a=s.index('    playSlider.setContentHuggingPriority');b=s.index('    oscPlaySliderTopConstraint =',a)
setup=s[a:b].replace('self.','').replace('leftLabel.center(.y, with: playSlider)', 'leftLabel.centerYAnchor.constraint(equalTo: playSlider.centerYAnchor).isActive = true').replace('rightLabel.center(.y, with: playSlider)', 'rightLabel.centerYAnchor.constraint(equalTo: playSlider.centerYAnchor).isActive = true')
f=pathlib.Path('yina/OSCFloatingView.swift').read_text();a=f.index('    let preferredWidth =');b=f.index('\n    yConstraint =',a)
width=f[a:b].replace('Self.preferredWidth','460').replace('Self.horizontalInset','16')
code='''import Cocoa
NSApplication.shared.setActivationPolicy(.prohibited)
let window=NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:360),styleMask:[.titled,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
let root=window.contentView!
let videoView=NSView();videoView.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(videoView)
let videoWidth=videoView.widthAnchor.constraint(equalToConstant:640)
NSLayoutConstraint.activate([videoWidth,videoView.heightAnchor.constraint(equalToConstant:360),videoView.leadingAnchor.constraint(equalTo:root.leadingAnchor),videoView.topAnchor.constraint(equalTo:root.topAnchor)])
class Bar: NSView {
 func install(_ videoView:NSView) {
'''+width+'''
 bottomAnchor.constraint(equalTo:videoView.bottomAnchor).isActive=true
 }
}
let bar=Bar();bar.translatesAutoresizingMaskIntoConstraints=false;videoView.addSubview(bar);bar.install(videoView)
var oscSliderView:TimeLabelOverflowedView!
let playSlider=NSSlider();playSlider.translatesAutoresizingMaskIntoConstraints=false
let leftLabel:NSTextField! = NSTextField(labelWithString:"1:23:45")
let rightLabel:NSTextField! = NSTextField(labelWithString:"−1:23:45")
[leftLabel,rightLabel].forEach{$0!.translatesAutoresizingMaskIntoConstraints=false}
var oscSliderLabelConstraints:[NSLayoutConstraint]=[]
'''+setup+'''
bar.addSubview(oscSliderView)
NSLayoutConstraint.activate([
 oscSliderView.leadingAnchor.constraint(equalTo:bar.leadingAnchor,constant:8),
 oscSliderView.trailingAnchor.constraint(equalTo:bar.trailingAnchor,constant:-8),
 oscSliderView.topAnchor.constraint(equalTo:bar.topAnchor,constant:8),
 oscSliderView.bottomAnchor.constraint(equalTo:bar.bottomAnchor,constant:-8),
 playSlider.topAnchor.constraint(equalTo:oscSliderView.topAnchor,constant:6),
 playSlider.bottomAnchor.constraint(equalTo:oscSliderView.bottomAnchor,constant:-6)])
var widths:[CGFloat]=[]
for width in [285.0,320,460,640,1920] {
 videoWidth.constant=width
 root.layoutSubtreeIfNeeded()
 videoView.needsLayout=true
 videoView.layoutSubtreeIfNeeded()
 RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01))
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
view=pathlib.Path('yina/TimeLabelOverflowedView.swift').read_text()
with tempfile.TemporaryDirectory(prefix='yina-timeline-') as d:
 p=pathlib.Path(d)/'main.swift';p.write_text(view+'\n'+code);binary=pathlib.Path(d)/'probe'
 subprocess.run(['xcrun','swiftc','-module-cache-path','/private/tmp/yina-event-module-cache',str(p),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)
