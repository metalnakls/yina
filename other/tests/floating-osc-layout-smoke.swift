// xcrun swiftc yina/OSCFloatingTopView.swift other/tests/floating-osc-layout-smoke.swift -o /tmp/yina-osc-layout-smoke
// /tmp/yina-osc-layout-smoke
import Cocoa

@main struct FloatingOSCLayoutSmoke {
  static func main() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 120),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let root = window.contentView!
    let top = OSCFloatingTopView()
    root.addSubview(top)
    NSLayoutConstraint.activate([
      top.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      top.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      top.topAnchor.constraint(equalTo: root.topAnchor),
    ])
    func box(_ width: CGFloat) -> NSView {
      let view = NSView()
      view.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: width),
                                   view.heightAnchor.constraint(equalToConstant: 48)])
      return view
    }
    let back = box(32), play = box(48), forward = box(32)
    let middle = NSStackView(views: [back, play, forward])
    middle.spacing = 4
    middle.detachesHiddenViews = false
    let controls = NSStackView()
    controls.translatesAutoresizingMaskIntoConstraints = false
    controls.spacing = 0
    controls.detachesHiddenViews = false
    let speedLeft = box(30), speedRight = box(30)
    controls.addView(speedLeft, in: .center)
    controls.addView(middle, in: .center)
    controls.addView(speedRight, in: .center)
    controls.setVisibilityPriority(.notVisible, for: speedLeft)
    controls.setVisibilityPriority(.notVisible, for: speedRight)
    controls.setVisibilityPriority(.mustHold, for: middle)
    let volume = box(108)
    let toolbar = NSStackView(views: [box(24), box(24), box(24), box(24)])
    toolbar.translatesAutoresizingMaskIntoConstraints = false

    func install() { top.install(transport: controls, playButton: play, volume: volume, toolbar: toolbar) }
    func check(_ label: String) {
      root.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
      root.layoutSubtreeIfNeeded()
      let mid = play.convert(play.bounds, to: top).midX
      precondition(abs(mid - top.bounds.midX) < 0.5, "Off-center: \(label): \(mid) / \(top.bounds.midX)")
      precondition(abs(top.frame.height - 48) < 0.5, "Changed transport height")
      precondition(controls.superview === top, "Transport was detached")
    }
    install()
    for pass in 0..<3 {
      for direction in [NSUserInterfaceLayoutDirection.leftToRight, .rightToLeft] {
        top.userInterfaceLayoutDirection = direction
        controls.userInterfaceLayoutDirection = .leftToRight
        for hidden in [false, true] {
          volume.isHidden = hidden
          for width in [460.0, 200, 800, 260, 460] {
            window.setContentSize(NSSize(width: width, height: 120))
            check("pass \(pass), volume hidden \(hidden), width \(width), RTL \(direction.rawValue)")
            top.isHidden = true
            check("hidden")
            top.isHidden = false
            check("shown")
          }
        }
      }
      toolbar.views.forEach { toolbar.removeView($0) }
      check("empty toolbar")
      toolbar.addView(box(80), in: .trailing)
      check("toolbar rebuilt")
      top.uninstall()
      // Model floating -> docked -> floating reparenting.
      let docked = NSStackView(views: [controls, volume, toolbar])
      docked.views.forEach { docked.removeView($0) }
      install()
      check("reattached")
    }
    print("PASS: floating OSC centered across volume visibility, toolbar rebuilds, narrow/wide layouts, RTL, hide/show and reparenting.")
  }
}
