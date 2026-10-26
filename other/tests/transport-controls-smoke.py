#!/usr/bin/env python3
"""Exercise production transport reparenting and floating hit routing in isolated AppKit."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
controller_source = (ROOT / "yina/MainWindowController.swift").read_text()
osc_source = (ROOT / "yina/OSCFloatingView.swift").read_text()
stack_source = (ROOT / "yina/TimeLabelOverflowedStackView.swift").read_text()
metrics_source = (ROOT / "yina/OSCBottomView.swift").read_text()


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


transport_method = extract_method(controller_source, "private func configureTransportHierarchy")
reset_method = extract_method(controller_source, "private func resetTransportHierarchyForLayoutChange")
attach_method = extract_method(controller_source, "private func attachTransportToFloatingView")
content_start = osc_source.index("private final class OSCFloatingContentView")
content_end = osc_source.index("private final class OSCFloatingDragSurface", content_start)
content_source = osc_source[content_start:content_end]
hit_test_method = extract_method(content_source, "override func hitTest(_ point: NSPoint)")
owner_start = osc_source.index("class OSCFloatingView: TranslucentView")
owner_source = osc_source[owner_start:]
route_method = extract_method(owner_source, "func routeMouseDown(_ event: NSEvent)")
stack_class = stack_source[stack_source.index("class TimeLabelOverflowedStackView"):]
inset_match = re.search(r"static let floatingHorizontalInset: CGFloat = ([0-9.]+)", metrics_source)
assert inset_match, "Floating OSC inset constant not found in production source"
floating_inset = inset_match.group(1)
swift = r'''import Cocoa

final class ProbeButton: NSButton {
  var mouseDownCount = 0
  override func mouseDown(with event: NSEvent) { mouseDownCount += 1 }
}
final class ProbeSlider: NSSlider {
  var mouseDownCount = 0
  override func mouseDown(with event: NSEvent) { mouseDownCount += 1 }
}
final class ProbeTimeLabel: NSTextField {
  var mouseDownCount = 0
  override func mouseDown(with event: NSEvent) { mouseDownCount += 1 }
}

enum OSCDesignMetrics { static let floatingHorizontalInset: CGFloat = @@FLOATING_INSET@@ }
@@STACK_CLASS@@

final class TransportHarness {
  let leftArrowButton = ProbeButton(frame: .zero)
  let playButton = ProbeButton(frame: .zero)
  let rightArrowButton = ProbeButton(frame: .zero)
  let leftLabel = ProbeTimeLabel(frame: .zero)
  let playSlider = ProbeSlider(frame: .zero)
  let rightLabel = ProbeTimeLabel(frame: .zero)
  let oscPlayControlMiddleView: NSStackView
  let oscTransportView: NSStackView! = NSStackView()
  let oscSliderView: NSView! = NSView()
  let oscPlayControlView: NSView! = NSView()
  let floatingHost = TimeLabelOverflowedStackView()
  let dockHost = NSStackView()

  init() {
    leftArrowButton.title = ""
    playButton.title = ""
    rightArrowButton.title = ""
    [leftArrowButton, playButton, rightArrowButton].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      $0.widthAnchor.constraint(equalToConstant: 24).isActive = true
      $0.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    oscPlayControlMiddleView = NSStackView(views: [leftArrowButton, playButton, rightArrowButton])
    oscPlayControlMiddleView.spacing = 16
    oscPlayControlView.addSubview(oscPlayControlMiddleView)
    oscTransportView.orientation = .horizontal
    oscTransportView.alignment = .centerY
    oscTransportView.detachesHiddenViews = false

    oscSliderView.translatesAutoresizingMaskIntoConstraints = false
    leftLabel.translatesAutoresizingMaskIntoConstraints = false
    playSlider.translatesAutoresizingMaskIntoConstraints = false
    rightLabel.translatesAutoresizingMaskIntoConstraints = false
    oscSliderView.addSubview(leftLabel)
    oscSliderView.addSubview(playSlider)
    oscSliderView.addSubview(rightLabel)
    playSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
    playSlider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    leftLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    rightLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    NSLayoutConstraint.activate([
      leftLabel.widthAnchor.constraint(equalTo: rightLabel.widthAnchor),
      leftLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 46),
      rightLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 46),
      playSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
      leftLabel.leadingAnchor.constraint(equalTo: oscSliderView.leadingAnchor, constant: 2),
      playSlider.leadingAnchor.constraint(equalTo: leftLabel.trailingAnchor, constant: 2),
      playSlider.centerYAnchor.constraint(equalTo: oscSliderView.centerYAnchor),
      rightLabel.leadingAnchor.constraint(equalTo: playSlider.trailingAnchor, constant: 2),
      rightLabel.trailingAnchor.constraint(equalTo: oscSliderView.trailingAnchor, constant: -2),
      leftLabel.centerYAnchor.constraint(equalTo: playSlider.centerYAnchor),
      rightLabel.centerYAnchor.constraint(equalTo: oscSliderView.centerYAnchor),
      playSlider.topAnchor.constraint(equalTo: oscSliderView.topAnchor, constant: 6),
      oscSliderView.bottomAnchor.constraint(equalTo: playSlider.bottomAnchor, constant: 6),
    ])
  }

@@TRANSPORT_METHOD@@
@@RESET_METHOD@@
@@ATTACH_METHOD@@
  func switchTransport(_ isFloating: Bool) {
    configureTransportHierarchy(isFloating)
  }
  func resetForLayoutChange() {
    resetTransportHierarchyForLayoutChange()
  }
  func attachFloatingTransport() {
    attachTransportToFloatingView(floatingHost)
  }
}

final class OSCFloatingViewHarness: NSView {
  var content: NSView?
  var dragDownCount = 0
  override func mouseDown(with event: NSEvent) { dragDownCount += 1 }
@@ROUTE_METHOD@@
}

final class DragSurfaceHarness: NSView {
  weak var owner: OSCFloatingViewHarness?
  var mouseDownCount = 0
  override func mouseDown(with event: NSEvent) {
    mouseDownCount += 1
    owner?.mouseDown(with: event)
  }
}

final class FloatingContentHarness: NSView {
  weak var dragSurface: NSView?
@@HIT_TEST_METHOD@@
}

@main
struct TransportSmoke {
static func main() {
NSApplication.shared.setActivationPolicy(.prohibited)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 260),
  styleMask: [.borderless], backing: .buffered, defer: false)
precondition(!window.isVisible, "Fixture must remain unshown")
let root = window.contentView!
let owner = OSCFloatingViewHarness(frame: NSRect(x: 37, y: 29, width: 960, height: 100))
root.addSubview(owner)
let wrapper = NSView(frame: NSRect(x: 23, y: 17, width: 390, height: 72))
owner.addSubview(wrapper)
let content = FloatingContentHarness(frame: NSRect(x: 13, y: 9, width: 360, height: 48))
wrapper.addSubview(content)
owner.content = content
let dragSurface = DragSurfaceHarness(frame: .zero)
dragSurface.translatesAutoresizingMaskIntoConstraints = false
dragSurface.owner = owner
content.dragSurface = dragSurface
content.addSubview(dragSurface)
NSLayoutConstraint.activate([
  dragSurface.leadingAnchor.constraint(equalTo: content.leadingAnchor),
  dragSurface.trailingAnchor.constraint(equalTo: content.trailingAnchor),
  dragSurface.topAnchor.constraint(equalTo: content.topAnchor),
  dragSurface.bottomAnchor.constraint(equalTo: content.bottomAnchor),
])

let transport = TransportHarness()
transport.oscPlayControlMiddleView.spacing = 4
transport.resetForLayoutChange()
transport.switchTransport(true)
transport.attachFloatingTransport()
precondition(transport.oscPlayControlMiddleView.arrangedSubviews.count == 2)
precondition(transport.oscPlayControlMiddleView.arrangedSubviews[0] === transport.leftArrowButton)
precondition(transport.oscPlayControlMiddleView.arrangedSubviews[1] === transport.rightArrowButton)
precondition(transport.oscTransportView.arrangedSubviews.count == 2)
precondition(transport.oscTransportView.arrangedSubviews[0] === transport.playButton)
precondition(transport.oscTransportView.arrangedSubviews[1] === transport.oscSliderView)
precondition(transport.playButton.superview === transport.oscTransportView)
precondition(transport.oscSliderView.superview === transport.oscTransportView)

let floating = transport.floatingHost
floating.translatesAutoresizingMaskIntoConstraints = false
content.addSubview(floating)
NSLayoutConstraint.activate([
  floating.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
  floating.centerYAnchor.constraint(equalTo: content.centerYAnchor),
])

func verifyControlHit(_ control: NSControl, index: Int) {
  let localPoint = NSPoint(x: control.bounds.midX, y: control.bounds.midY)
  let pointInWindow = control.convert(localPoint, to: nil)
  let event = NSEvent.mouseEvent(with: .leftMouseDown, location: pointInWindow,
    modifierFlags: [], timestamp: Double(index), windowNumber: window.windowNumber,
    context: nil, eventNumber: index, clickCount: 1, pressure: 1)!
  precondition(owner.routeMouseDown(event), "Production route must accept control hit \(index)")
}

for width in [285.0, 640.0, 900.0] {
  content.setFrameSize(NSSize(width: width, height: 48))
  wrapper.setFrameSize(NSSize(width: width + 30, height: 72))
  root.layoutSubtreeIfNeeded()
  content.layoutSubtreeIfNeeded()
  precondition(transport.playButton.frame.maxX < transport.oscSliderView.frame.minX,
    "Play/pause must remain left of the floating timeline at width \(width)")
  verifyControlHit(transport.playButton, index: Int(width))
  verifyControlHit(transport.playSlider, index: Int(width) + 1)
  verifyControlHit(transport.rightLabel, index: Int(width) + 2)
}
precondition(transport.playButton.mouseDownCount == 3, "Floating play/pause must receive native hits")
precondition(transport.playSlider.mouseDownCount == 3, "Timeline slider must receive native hits")
precondition(transport.rightLabel.mouseDownCount == 3, "Right time label must receive native hits")

let blankPoint = NSPoint(x: content.bounds.maxX - 2, y: content.bounds.midY)
let blankEvent = NSEvent.mouseEvent(with: .leftMouseDown,
  location: content.convert(blankPoint, to: nil), modifierFlags: [], timestamp: 99,
  windowNumber: window.windowNumber, context: nil, eventNumber: 99, clickCount: 1, pressure: 1)!
precondition(owner.routeMouseDown(blankEvent), "Blank floating surface must route to drag")
precondition(owner.dragDownCount == 1, "Blank surface must start dragging")
precondition(dragSurface.mouseDownCount == 1,
  "Blank surface should use the existing drag surface")

for index in 0..<10 {
  transport.resetForLayoutChange()
  precondition(transport.floatingHost.arrangedSubviews.isEmpty,
    "Layout teardown must detach the old floating host arrangement")
  precondition(transport.oscTransportView.arrangedSubviews.isEmpty,
    "Layout teardown must clear the old floating transport row")

  if index % 3 != 0 {
    transport.dockHost.addArrangedSubview(transport.oscPlayControlView)
    transport.dockHost.addArrangedSubview(transport.oscSliderView)
    precondition(transport.dockHost.arrangedSubviews.count == 2,
      "Top/bottom hosts must install the docked controls once")
  }

  transport.oscPlayControlMiddleView.spacing = 16
  precondition(transport.oscPlayControlMiddleView.arrangedSubviews.count == 3,
    "Docked transport must keep back/play/forward")
  precondition(transport.oscPlayControlMiddleView.arrangedSubviews[0] === transport.leftArrowButton)
  precondition(transport.oscPlayControlMiddleView.arrangedSubviews[1] === transport.playButton)
  precondition(transport.oscPlayControlMiddleView.arrangedSubviews[2] === transport.rightArrowButton)
  if index % 3 != 0 {
    precondition(transport.dockHost.arrangedSubviews.count == 2,
      "Repeated top/bottom installation must not duplicate controls")
    transport.resetForLayoutChange()
    precondition(transport.dockHost.arrangedSubviews.isEmpty,
      "Layout teardown must release docked arranged views")
  }
  transport.oscPlayControlMiddleView.spacing = 4
  transport.switchTransport(true)
  transport.attachFloatingTransport()
  precondition(transport.oscPlayControlMiddleView.arrangedSubviews.count == 2)
  precondition(transport.oscTransportView.arrangedSubviews.count == 2,
    "Repeated mode changes must not duplicate arranged views")
}
print("PASS: production transport reparenting and floating native hit routing across nested offsets, widths, and repeated mode changes")
}
}
'''

swift = (swift.replace("@@TRANSPORT_METHOD@@", transport_method)
         .replace("@@RESET_METHOD@@", reset_method)
         .replace("@@ATTACH_METHOD@@", attach_method)
         .replace("@@STACK_CLASS@@", stack_class)
         .replace("@@FLOATING_INSET@@", floating_inset)
         .replace("@@ROUTE_METHOD@@", route_method)
         .replace("@@HIT_TEST_METHOD@@", hit_test_method))

with tempfile.TemporaryDirectory(prefix="yina-transport-controls-") as temp_dir:
    temp = Path(temp_dir)
    source_path = temp / "transport-controls-smoke.swift"
    binary_path = temp / "transport-controls-smoke"
    source_path.write_text(swift)
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library",
        "-module-cache-path", str(temp / "module-cache"),
        str(source_path), "-o", str(binary_path),
    ], check=True, cwd=ROOT)
    subprocess.run([str(binary_path)], check=True, cwd=ROOT)
