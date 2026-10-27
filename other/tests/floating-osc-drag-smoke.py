#!/usr/bin/env python3
"""Compile production floating-OSC positioning and drag methods in native AppKit."""
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / "yina/OSCFloatingView.swift").read_text()


def extract_method(text: str, signature: str) -> str:
    start = text.index(signature)
    opening = text.index("{", start)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise AssertionError(f"Unclosed production method: {signature}")


osc_source = source[source.index("class OSCFloatingView:"):]


def osc_method(signature: str) -> str:
    return extract_method(osc_source, signature)


metrics = "\n".join(
    line.strip().replace("private static let", "static let")
    for line in source.splitlines()
    if re.match(
        r"\s*(?:static let preferredWidth|static let horizontalInset|"
        r"static let verticalMargin|private static let assumedHeight):",
        line,
    )
)
methods = "\n\n".join([
    osc_method("  func setupConstraints()"),
    osc_method("  func initPosition()"),
    osc_method("  func updatePosition()"),
    osc_method("  private var barSize: NSSize"),
    osc_method("  private func clampedX("),
    osc_method("  private func clampedY("),
    osc_method("  override func mouseDown(with event: NSEvent)"),
    osc_method("  override func mouseDragged(with event: NSEvent)"),
    osc_method("  override func mouseUp(with event: NSEvent)"),
])

swift = f'''import Cocoa

extension Comparable {{
  func clamped(to range: ClosedRange<Self>) -> Self {{ min(max(self, range.lowerBound), range.upperBound) }}
}}

final class Preference {{
  enum Key {{ case controlBarPositionHorizontal, controlBarPositionVertical }}
  static var values: [Key: CGFloat] = [.controlBarPositionHorizontal: 0.5, .controlBarPositionVertical: 0.1]
  static func float(for key: Key) -> CGFloat {{ values[key] ?? 0 }}
  static func set(_ value: CGFloat, for key: Key) {{ values[key] = value }}
}}

final class WindowHarness {{
  var videoViewContainer: NSView!
}}

final class FloatingOSCHarness: NSView {{
{metrics}
  let mainWindow: WindowHarness
  private var xConstraint: NSLayoutConstraint!
  private var yConstraint: NSLayoutConstraint!
  var isDragging = false
  private var didDrag = false
  private var dragStartPointerInVideo: NSPoint?
  private var dragStartOriginInVideo: NSPoint?
  var measuredOriginInVideo: NSPoint {{ mainWindow.videoViewContainer.convert(.zero, from: self) }}
  var constraintX: CGFloat {{ xConstraint.constant }}
  var expectedX: CGFloat {{
    min(max(mainWindow.videoViewContainer.bounds.width * Preference.float(for: .controlBarPositionHorizontal) - bounds.width / 2,
      Self.horizontalInset), max(mainWindow.videoViewContainer.bounds.width - bounds.width - Self.horizontalInset, Self.horizontalInset))
  }}
  var expectedY: CGFloat {{
    min(max(mainWindow.videoViewContainer.bounds.height * Preference.float(for: .controlBarPositionVertical), 0),
      max(mainWindow.videoViewContainer.bounds.height - bounds.height - Self.verticalMargin, 0))
  }}

  init(mainWindow: WindowHarness) {{
    self.mainWindow = mainWindow
    super.init(frame: .zero)
  }}
  required init?(coder: NSCoder) {{ fatalError("init(coder:) has not been implemented") }}

{methods}
}}

NSApplication.shared.setActivationPolicy(.prohibited)
let window = NSWindow(contentRect: NSRect(x: 200, y: 140, width: 800, height: 500),
  styleMask: [.borderless], backing: .buffered, defer: false)
precondition(!window.isVisible, "Fixture must remain unshown")
let root = window.contentView!
let nested = NSView(frame: NSRect(x: 29, y: 37, width: 742, height: 426))
root.addSubview(nested)
let controller = WindowHarness()
let video = NSView(frame: NSRect(x: 23, y: 19, width: 688, height: 390))
controller.videoViewContainer = video
nested.addSubview(video)
let osc = FloatingOSCHarness(mainWindow: controller)
osc.translatesAutoresizingMaskIntoConstraints = false
root.addSubview(osc)
osc.setupConstraints()
osc.heightAnchor.constraint(equalToConstant: 44).isActive = true
osc.initPosition()
root.layoutSubtreeIfNeeded()
precondition(!video.isFlipped && !nested.isFlipped, "Fixture must use native unflipped coordinates")
precondition(abs(osc.measuredOriginInVideo.x - osc.expectedX) < 0.5,
  "Default horizontal preference must center the bar")
precondition(abs(osc.measuredOriginInVideo.y - osc.expectedY) < 0.5,
  "Default vertical preference must preserve the bottom-biased position")

func event(atVideoPoint point: NSPoint, type: NSEvent.EventType, number: Int, time: TimeInterval) -> NSEvent {{
  let location = video.convert(point, to: nil)
  return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: time,
    windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 1)!
}}
func drag(_ delta: NSPoint, from point: NSPoint, number: Int) -> NSPoint {{
  let before = osc.measuredOriginInVideo
  osc.mouseDown(with: event(atVideoPoint: point, type: .leftMouseDown, number: number, time: Double(number)))
  osc.mouseDragged(with: event(atVideoPoint: NSPoint(x: point.x + delta.x, y: point.y + delta.y),
    type: .leftMouseDragged, number: number + 1, time: Double(number) + 0.1))
  root.layoutSubtreeIfNeeded()
  let after = osc.measuredOriginInVideo
  precondition(abs(after.x - before.x - delta.x) < 0.5,
    "Bar must follow pointer horizontally: requested \\(delta), measured (\\(after.x - before.x), \\(after.y - before.y))")
  precondition(abs(after.y - before.y - delta.y) < 0.5,
    "Bar must follow pointer vertically: requested \\(delta), measured (\\(after.x - before.x), \\(after.y - before.y))")
  osc.mouseUp(with: event(atVideoPoint: NSPoint(x: point.x + delta.x, y: point.y + delta.y),
    type: .leftMouseUp, number: number + 2, time: Double(number) + 0.2))
  return after
}}

// A multi-event drag uses one original grab point, with nonzero ancestor origins.
var origin = osc.measuredOriginInVideo
let grab = NSPoint(x: origin.x + 110, y: origin.y + 20)
osc.mouseDown(with: event(atVideoPoint: grab, type: .leftMouseDown, number: 10, time: 10))
for (index, delta) in [NSPoint(x: 18, y: 13), NSPoint(x: 14, y: 17)] .enumerated() {{
  let cumulative = NSPoint(x: delta.x + (index == 0 ? 0 : 18), y: delta.y + (index == 0 ? 0 : 13))
  osc.mouseDragged(with: event(atVideoPoint: NSPoint(x: grab.x + cumulative.x, y: grab.y + cumulative.y),
    type: .leftMouseDragged, number: 11 + index, time: 10.1 + Double(index)))
  root.layoutSubtreeIfNeeded()
  let moved = osc.measuredOriginInVideo
  precondition(abs(moved.x - origin.x - cumulative.x) < 0.5 && abs(moved.y - origin.y - cumulative.y) < 0.5,
    "Each drag event must be measured against the original grab point")
}}
osc.mouseUp(with: event(atVideoPoint: NSPoint(x: grab.x + 32, y: grab.y + 30), type: .leftMouseUp, number: 14, time: 12))
origin = osc.measuredOriginInVideo
_ = drag(NSPoint(x: 24, y: -11), from: NSPoint(x: origin.x + 90, y: origin.y + 15), number: 20)
origin = osc.measuredOriginInVideo
_ = drag(NSPoint(x: -19, y: 16), from: NSPoint(x: origin.x + 90, y: origin.y + 15), number: 30)

// Window movement during a drag must not change the pointer-to-bar offset.
origin = osc.measuredOriginInVideo
let movingGrab = NSPoint(x: origin.x + 100, y: origin.y + 18)
osc.mouseDown(with: event(atVideoPoint: movingGrab, type: .leftMouseDown, number: 40, time: 40))
window.setFrameOrigin(NSPoint(x: 420, y: 270))
osc.mouseDragged(with: event(atVideoPoint: NSPoint(x: movingGrab.x + 21, y: movingGrab.y - 9),
  type: .leftMouseDragged, number: 41, time: 40.1))
root.layoutSubtreeIfNeeded()
let afterWindowMove = osc.measuredOriginInVideo
precondition(abs(afterWindowMove.x - origin.x - 21) < 0.5 && abs(afterWindowMove.y - origin.y + 9) < 0.5,
  "Window movement must not alter video-container-relative drag coordinates")
osc.mouseUp(with: event(atVideoPoint: NSPoint(x: movingGrab.x + 21, y: movingGrab.y - 9),
  type: .leftMouseUp, number: 42, time: 40.2))

// Four edge clamps use the laid-out size, including when Auto Layout compresses the bar.
for (index, delta) in [NSPoint(x: -2000, y: -2000), NSPoint(x: 2000, y: -2000),
                       NSPoint(x: -2000, y: 2000), NSPoint(x: 2000, y: 2000)].enumerated() {{
  origin = osc.measuredOriginInVideo
  let grabPoint = NSPoint(x: origin.x + min(80, osc.bounds.width / 2), y: origin.y + min(20, osc.bounds.height / 2))
  osc.mouseDown(with: event(atVideoPoint: grabPoint, type: .leftMouseDown, number: 50 + index * 3, time: 50))
  osc.mouseDragged(with: event(atVideoPoint: NSPoint(x: grabPoint.x + delta.x, y: grabPoint.y + delta.y),
    type: .leftMouseDragged, number: 51 + index * 3, time: 50.1))
  root.layoutSubtreeIfNeeded()
  let clamped = osc.measuredOriginInVideo
  precondition(clamped.x >= OSCFloatingMetrics.horizontalInset - 0.5 &&
    clamped.x <= video.bounds.width - osc.bounds.width - OSCFloatingMetrics.horizontalInset + 0.5,
    "Horizontal edge clamp must use actual laid-out bar width")
  precondition(clamped.y >= -0.5 && clamped.y <= video.bounds.height - osc.bounds.height - OSCFloatingMetrics.verticalMargin + 0.5,
    "Vertical edge clamp must use actual laid-out bar height")
  osc.mouseUp(with: event(atVideoPoint: NSPoint(x: grabPoint.x + delta.x, y: grabPoint.y + delta.y),
    type: .leftMouseUp, number: 52 + index * 3, time: 50.2))
}}

// Existing preference values retain their center/window-width and bottom/window-height meanings.
Preference.values[.controlBarPositionHorizontal] = 0.5
Preference.values[.controlBarPositionVertical] = 0.5
video.setFrameSize(NSSize(width: 200, height: 180))
root.layoutSubtreeIfNeeded()
precondition(abs(video.bounds.width - 200) < 0.5 && abs(video.bounds.height - 180) < 0.5,
  "OSC constraints must not resize the video container during compression")
precondition(osc.bounds.width <= video.bounds.width - 2 * FloatingOSCHarness.horizontalInset + 0.5 &&
  osc.measuredOriginInVideo.x >= FloatingOSCHarness.horizontalInset - 0.5 &&
  osc.measuredOriginInVideo.x + osc.bounds.width <= video.bounds.width - FloatingOSCHarness.horizontalInset + 0.5,
  "Required edge constraints must keep compressed OSC within video bounds before position refresh")
osc.updatePosition()
root.layoutSubtreeIfNeeded()
precondition(osc.bounds.width <= video.bounds.width - 2 * OSCFloatingMetrics.horizontalInset + 0.5,
  "Narrow layouts must compress the bar inside horizontal insets")
origin = osc.measuredOriginInVideo
precondition(abs(origin.x - osc.expectedX) < 0.5,
  "Narrow width restore must retain center preference: origin \\(origin.x), expected \\(osc.expectedX), video \\(video.bounds.width), bar \\(osc.bounds.width), constraint \\(osc.constraintX), root \\(root.bounds)")
precondition(abs(origin.y - osc.expectedY) < 0.5,
  "Resize restore must preserve the established vertical preference meaning")
video.setFrameSize(NSSize(width: 688, height: 390))
root.layoutSubtreeIfNeeded()
osc.updatePosition()
root.layoutSubtreeIfNeeded()
origin = osc.measuredOriginInVideo
precondition(abs(origin.x - osc.expectedX) < 0.5 && abs(origin.y - osc.expectedY) < 0.5,
  "Wide resize restore must preserve the established position preferences")

// The real NSWindow resize preference is lower than defaultHigh. A fixed-parent
// harness cannot catch an OSC that makes its ancestor window grow instead.
let portraitWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 400),
  styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
portraitWindow.minSize = NSSize(width: 285, height: 120)
let portraitRoot = portraitWindow.contentView!
let portraitVideo = NSView()
portraitVideo.translatesAutoresizingMaskIntoConstraints = false
portraitRoot.addSubview(portraitVideo)
NSLayoutConstraint.activate([
  portraitVideo.leadingAnchor.constraint(equalTo: portraitRoot.leadingAnchor),
  portraitVideo.trailingAnchor.constraint(equalTo: portraitRoot.trailingAnchor),
  portraitVideo.topAnchor.constraint(equalTo: portraitRoot.topAnchor),
  portraitVideo.bottomAnchor.constraint(equalTo: portraitRoot.bottomAnchor)])
let portraitController = WindowHarness()
portraitController.videoViewContainer = portraitVideo
let portraitOSC = FloatingOSCHarness(mainWindow: portraitController)
portraitOSC.translatesAutoresizingMaskIntoConstraints = false
portraitVideo.addSubview(portraitOSC)
portraitOSC.heightAnchor.constraint(equalToConstant: 44).isActive = true
portraitOSC.setupConstraints()
portraitRoot.layoutSubtreeIfNeeded()
portraitOSC.initPosition()
portraitRoot.layoutSubtreeIfNeeded()
portraitWindow.aspectRatio = NSSize(width: 9, height: 16)
for width: CGFloat in [360, 300, 285, 360, 300] {{
  portraitWindow.setContentSize(NSSize(width: width, height: width * 16 / 9))
  portraitRoot.layoutSubtreeIfNeeded()
  RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
  portraitRoot.layoutSubtreeIfNeeded()
  precondition(abs(portraitWindow.frame.width - width) <= 1,
    "OSC forced portrait window wider than requested: requested \\(width), actual \\(portraitWindow.frame)")
  precondition(abs(portraitWindow.frame.width - portraitWindow.frame.height * 9 / 16) <= 1,
    "OSC constraints distorted the native portrait aspect ratio")
  portraitOSC.updatePosition()
  portraitRoot.layoutSubtreeIfNeeded()
}}

print("PASS: production OSC follows pointer in native video coordinates, clamps actual geometry, and restores normalized position")
'''

swift = swift.replace("OSCFloatingMetrics.", "FloatingOSCHarness.")

with tempfile.TemporaryDirectory(prefix="yina-floating-osc-drag-") as directory:
    temp = Path(directory)
    swift_path = temp / "main.swift"
    binary_path = temp / "probe"
    swift_path.write_text(swift)
    subprocess.run([
        "xcrun", "swiftc", "-module-cache-path", str(temp / "modules"),
        str(swift_path), "-o", str(binary_path)
    ], check=True)
    subprocess.run([str(binary_path)], check=True)
