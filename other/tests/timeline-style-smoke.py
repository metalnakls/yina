#!/usr/bin/env python3
"""Raster-test production timeline drawing with synthetic slider values."""
import pathlib, subprocess, tempfile
s=pathlib.Path('yina/PlaySlider.swift').read_text();a=s.index('private final class FloatingPlaySliderCell');b=s.index('\nextension NSSlider',a)
cell=s[a:b].replace('private final class','final class')
code='''import Cocoa
extension NSColor {
 static func hdrWhite(intensity:CGFloat=1,headroom:CGFloat=2)->NSColor {
  NSColor(white:min(1,intensity*headroom),alpha:1)
 }
}
'''+cell+'''
NSApplication.shared.setActivationPolicy(.prohibited)
let slider=NSSlider(frame:NSRect(x:0,y:0,width:300,height:24))
let cell=FloatingPlaySliderCell();slider.cell=cell;slider.minValue=10;slider.maxValue=110
for value in [10.0,35,60,85,110] {
 slider.doubleValue=value
 let expected=cell.knobRect(flipped:false)
 for headroom in [1.0,2,4] {
  cell.extendedDynamicRangeHeadroom=headroom
  precondition(cell.knobRect(flipped:false)==expected,"HDR moved or resized the thumb")
  let image=NSImage(size:NSSize(width:300,height:24));image.lockFocus()
  cell.drawBar(inside:NSRect(x:5,y:10,width:290,height:4),flipped:false)
  cell.drawKnob(expected)
  image.unlockFocus()
  let pixels=NSBitmapImageRep(data:image.tiffRepresentation!)!
  if headroom > 1 {
   let thumb=pixels.colorAt(x:Int(expected.midX),y:Int(expected.midY))!.usingColorSpace(.genericGray)!.whiteComponent
   precondition(thumb >= 0.95,"HDR thumb tint must stay at least as bright as the played track")
  }
  if value < 85 {
   let unwatched=pixels.colorAt(x:285,y:12)!.usingColorSpace(.genericGray)!
   let gray=unwatched.whiteComponent
   precondition(abs(gray-0.3)<0.025,"Unwatched track is not gray")
   precondition(abs(unwatched.alphaComponent-0.5)<0.025,"Unwatched track is not translucent")
  }
 }
}
print("PASS: HDR tint preserves native knob geometry, and the unwatched track stays gray and translucent")
'''
with tempfile.TemporaryDirectory(prefix='yina-timeline-style-') as d:
 p=pathlib.Path(d)/'main.swift';p.write_text(code);binary=pathlib.Path(d)/'probe'
 subprocess.run(['xcrun','swiftc','-module-cache-path','/private/tmp/yina-event-module-cache',str(p),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)
