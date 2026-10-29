import AppKit

@main struct PiPSubtitleGeometrySmoke {
static func main() {
let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
let pip = NSRect(x: 900, y: 300, width: 420, height: 236)
let first = PiPSubtitleGeometry.frame(below: pip, height: 60, in: screen)!
precondition(first.maxY == pip.minY && first.minX == pip.minX)

// The child must keep the same offset when the system PiP window moves, and
// its width must change when PiP is resized.
let moved = pip.offsetBy(dx: -200, dy: 140)
let movedFrame = PiPSubtitleGeometry.frame(below: moved, height: 60, in: screen)!
precondition(movedFrame == first.offsetBy(dx: -200, dy: 140))
let resized = NSRect(x: moved.minX, y: moved.minY, width: 300, height: 169)
let resizedFrame = PiPSubtitleGeometry.frame(below: resized, height: 40, in: screen)!
precondition(resizedFrame.width == resized.width && resizedFrame.maxY == resized.minY)

// At the screen edge, native mpv subtitles remain visible because no child
// panel can safely fit beneath the video.
let bottom = NSRect(x: 900, y: 25, width: 420, height: 236)
precondition(PiPSubtitleGeometry.frame(below: bottom, height: 60, in: screen) == nil)
precondition(PiPSubtitleGeometry.frame(below: pip, height: 0, in: screen) == nil)
let otherScreen = NSRect(x: 1440, y: 0, width: 1440, height: 900)
precondition(PiPSubtitleGeometry.frame(below: pip, height: 60, in: otherScreen) == nil)
print("PASS: PiP subtitle panel follows movement and resize; screen-edge and screen-switch fallback")
}
}
