#!/usr/bin/env python3
"""Exercise the actual AppKit soft edge with a generated checkerboard surface."""
import pathlib, subprocess, tempfile
s=pathlib.Path('yina/MainWindow.swift').read_text();host=s[s.index('final class VideoBackdropView'):]
t=pathlib.Path('yina/Titlebar.swift').read_text();a=t.index('    edgeAccessory.layoutAttribute');b=t.index('\n    onTopButton.size',a)
accessory=t[a:b].replace('edgeAccessory','accessory').replace('TitleBarHeightNormal','32')
code='''import Cocoa
'''+host+'''
NSApplication.shared.setActivationPolicy(.prohibited)
let window=NSWindow(contentRect:NSRect(x:100,y:100,width:640,height:360),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
window.titlebarAppearsTransparent=true;window.titleVisibility = .hidden;window.titlebarSeparatorStyle = .none
let root=window.contentView!
let scroll=VideoBackdropView();root.addSubview(scroll)
NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:root.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:root.trailingAnchor),scroll.topAnchor.constraint(equalTo:root.topAnchor),scroll.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
final class Pattern:NSView {
 override func draw(_ rect:NSRect) {
  for y in stride(from:0,to:Int(bounds.height),by:8) {
   for x in stride(from:0,to:Int(bounds.width),by:8) {
    (x/8%2 == y/8%2 ? NSColor.white : .black).setFill()
    NSRect(x:x,y:y,width:8,height:8).fill()
   }
  }
 }
}
let doc=Pattern();doc.translatesAutoresizingMaskIntoConstraints=false;scroll.documentView=doc
NSLayoutConstraint.activate([doc.leadingAnchor.constraint(equalTo:scroll.contentView.leadingAnchor),doc.trailingAnchor.constraint(equalTo:scroll.contentView.trailingAnchor),doc.topAnchor.constraint(equalTo:scroll.contentView.topAnchor),doc.bottomAnchor.constraint(equalTo:scroll.contentView.bottomAnchor)])
let accessory=NSTitlebarAccessoryViewController()
'''+accessory+'''
window.orderBack(nil)
RunLoop.main.run(until:Date(timeIntervalSinceNow:0.2));root.layoutSubtreeIfNeeded()
func descendants(_ view:NSView)->[NSView] { [view] + view.subviews.flatMap{descendants($0)} }
// Observe what AppKit installed; production never accesses these private implementation classes.
let nativeBlur=descendants(scroll).contains{String(describing:type(of:$0)).contains("PocketBlur")}
precondition(nativeBlur,"AppKit did not create its native variable blur")
for size in [NSSize(width:640,height:360),NSSize(width:320,height:180)] {
 window.setContentSize(size);root.layoutSubtreeIfNeeded()
 RunLoop.main.run(until:Date(timeIntervalSinceNow:0.05));root.layoutSubtreeIfNeeded()
 scroll.contentView.scroll(to:NSPoint(x:40,y:50))
 precondition(scroll.contentView.bounds.origin == .zero,"Video must never scroll")
 precondition(abs(doc.frame.width-root.bounds.width)<1 && abs(doc.frame.height-root.bounds.height)<1,"Titlebar must not inset or letterbox the video")
}
window.orderOut(nil)
print("PASS: AppKit installs native variable blur; video remains full-window and cannot scroll")
'''
with tempfile.TemporaryDirectory(prefix='yina-titlebar-native-') as d:
 p=pathlib.Path(d)/'main.swift';p.write_text(code);binary=pathlib.Path(d)/'probe'
 subprocess.run(['xcrun','swiftc','-module-cache-path','/private/tmp/yina-event-module-cache',str(p),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)
