import Cocoa

/// The transport is a direct child, not a gravity-area item. Only the optional side groups
/// may detach as available space changes; their layout never owns the transport's position.
final class OSCFloatingTopView: NSView {
  private let leadingStack = NSStackView()
  private let trailingStack = NSStackView()
  private var transportConstraints: [NSLayoutConstraint] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    for stack in [leadingStack, trailingStack] {
      stack.translatesAutoresizingMaskIntoConstraints = false
      stack.orientation = .horizontal
      stack.alignment = .centerY
      stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
      addSubview(stack)
      stack.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
    }
  }

  func install(transport: NSView, playButton: NSView, volume: NSView, toolbar: NSView) {
    uninstall()
    addSubview(transport)
    leadingStack.addView(volume, in: .leading)
    trailingStack.addView(toolbar, in: .trailing)
    leadingStack.setVisibilityPriority(.detachOnlyIfNecessary, for: volume)
    trailingStack.setVisibilityPriority(.detachOnlyIfNecessary, for: toolbar)
    transportConstraints = [
      playButton.centerXAnchor.constraint(equalTo: centerXAnchor),
      transport.topAnchor.constraint(equalTo: topAnchor),
      transport.bottomAnchor.constraint(equalTo: bottomAnchor),
      leadingStack.leadingAnchor.constraint(equalTo: leadingAnchor),
      leadingStack.trailingAnchor.constraint(equalTo: transport.leadingAnchor, constant: -8),
      trailingStack.leadingAnchor.constraint(equalTo: transport.trailingAnchor, constant: 8),
      trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor),
    ]
    transportConstraints[0].identifier = "FloatingOSC.PlayButton.CenterX"
    NSLayoutConstraint.activate(transportConstraints)
  }

  func uninstall() {
    NSLayoutConstraint.deactivate(transportConstraints)
    transportConstraints.removeAll()
    for stack in [leadingStack, trailingStack] {
      stack.views.forEach { stack.removeView($0) }
    }
    subviews.filter { $0 !== leadingStack && $0 !== trailingStack }.forEach { $0.removeFromSuperview() }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
