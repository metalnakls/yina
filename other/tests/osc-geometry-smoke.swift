import AppKit

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  precondition(condition(), message)
}

let video = NSSize(width: 1280, height: 720)
let windowFrame = NSRect(x: 0, y: 90, width: 1280, height: 720)
let fullscreenFrame = NSRect(x: 0, y: 0, width: 1280, height: 900)
let windowImage = OSCFloatingGeometry.displayedRect(in: NSRect(origin: .zero, size: windowFrame.size), videoSize: video)
let fullscreenImage = OSCFloatingGeometry.displayedRect(in: NSRect(origin: .zero, size: fullscreenFrame.size), videoSize: video)
check(windowImage.offsetBy(dx: windowFrame.minX, dy: windowFrame.minY) ==
      fullscreenImage.offsetBy(dx: fullscreenFrame.minX, dy: fullscreenFrame.minY),
      "The fixture must display the same picture at the same screen position")

let bar = NSSize(width: 460, height: 60)
let oldWindowY = windowFrame.minY + windowFrame.height * 0.1
let oldFullscreenY = fullscreenFrame.minY + fullscreenFrame.height * 0.1
check(abs(oldWindowY - oldFullscreenY) > 50, "Current viewport fractions must reproduce the drift")
let windowAnchor = OSCFloatingGeometry.anchor(horizontal: 0.5, vertical: 0.1, in: windowImage, barSize: bar)
let fullscreenAnchor = OSCFloatingGeometry.anchor(horizontal: 0.5, vertical: 0.1, in: fullscreenImage, barSize: bar)
check(abs(windowAnchor.x + windowFrame.minX - fullscreenAnchor.x - fullscreenFrame.minX) < 0.001,
      "Same image rect moved the OSC horizontally")
check(abs(windowAnchor.y + windowFrame.minY - fullscreenAnchor.y - fullscreenFrame.minY) < 0.001,
      "Same image rect moved the OSC vertically")

let migrated = OSCFloatingGeometry.fractions(for: NSPoint(x: 410, y: 72), in: windowImage, barSize: bar)
let restored = OSCFloatingGeometry.anchor(horizontal: migrated.x, vertical: migrated.y, in: windowImage, barSize: bar)
check(abs(restored.x - 410) < 0.001 && abs(restored.y - 72) < 0.001,
      "Legacy placement did not survive conversion to image fractions")

let portrait = OSCFloatingGeometry.displayedRect(in: NSRect(x: 0, y: 0, width: 1280, height: 900),
                                                 videoSize: NSSize(width: 720, height: 1280))
check(abs(portrait.height - 900) < 0.001 && portrait.width < 600 && portrait.minX > 300,
      "Rotated portrait video should pillarbox within the viewport")
let pip = OSCFloatingGeometry.displayedRect(in: NSRect(x: 0, y: 0, width: 320, height: 180), videoSize: video)
let pipAnchor = OSCFloatingGeometry.anchor(horizontal: 0.5, vertical: 0.1, in: pip,
                                            barSize: NSSize(width: 200, height: 40))
check(pip.contains(pipAnchor), "A small displayed video lost its control anchor")
print("PASS: current viewport drift reproduced; identical picture rect keeps OSC anchor; migration, rotation and small PiP geometry")
