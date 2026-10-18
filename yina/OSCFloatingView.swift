//
//  OSCFloatingView.swift
//  yina
//

import CoreImage
//  Created by Hechen Li on 2026-06-09.
//  Copyright © 2026 lhc. All rights reserved.
//

fileprivate extension LayoutValue {
  static let oscPaddingTop = LayoutValue(14, 10)
  static let oscPaddingBottom = LayoutValue(8, 5)
}

/// Button used by the floating OSC so AppKit keeps the native tracking path active.
class OSCButton: NSButton {
  enum Role {
    case standard
    case transport
    case primary

    var floatingSize: CGFloat {
      switch self {
      case .standard: 24
      case .transport: 32
      case .primary: 48
      }
    }
  }

  private var originalImageScaling: NSImageScaling?
  private var originalImagePosition: NSControl.ImagePosition?
  private var originalBezelStyle: NSButton.BezelStyle?
  private var originalIsBordered: Bool?
  private var originalContentTintColor: NSColor?
  private var originalConstraintSizes: [ObjectIdentifier: CGFloat] = [:]
  private var usesQuickTimeStyle = false
  var extendedDynamicRangeHeadroom: CGFloat = 1 {
    didSet {
      if usesQuickTimeStyle {
        contentTintColor = extendedDynamicRangeHeadroom > 1
          ? .hdrWhite(intensity: 0.84, headroom: extendedDynamicRangeHeadroom)
          : .white.withAlphaComponent(0.84)
      }
      needsDisplay = true
    }
  }
  private var isPressed = false
  @objc dynamic private var visualScale: CGFloat = 1 {
    didSet { needsDisplay = true }
  }

  override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
    if key == "visualScale" {
      return CABasicAnimation()
    }
    return super.defaultAnimation(forKey: key)
  }

  func setQuickTimeStyle(_ enabled: Bool, role: Role = .standard) {
    if originalImageScaling == nil {
      originalImageScaling = imageScaling
      originalImagePosition = imagePosition
      originalBezelStyle = bezelStyle
      originalIsBordered = isBordered
      originalContentTintColor = contentTintColor
    }

    usesQuickTimeStyle = enabled
    if enabled {
      imagePosition = .imageOnly
      imageScaling = .scaleProportionallyDown
      bezelStyle = .shadowlessSquare
      isBordered = false
      contentTintColor = extendedDynamicRangeHeadroom > 1
        ? .hdrWhite(intensity: 0.84, headroom: extendedDynamicRangeHeadroom)
        : .white.withAlphaComponent(0.84)
    } else {
      imagePosition = originalImagePosition!
      imageScaling = originalImageScaling!
      bezelStyle = originalBezelStyle!
      isBordered = originalIsBordered!
      contentTintColor = originalContentTintColor
      setPressed(false)
    }

    for constraint in constraints where (constraint.firstItem as? NSButton) === self {
      guard constraint.secondItem == nil,
            constraint.firstAttribute == .width || constraint.firstAttribute == .height else { continue }
      let key = ObjectIdentifier(constraint)
      if originalConstraintSizes[key] == nil {
        originalConstraintSizes[key] = constraint.constant
      }
      constraint.constant = enabled ? role.floatingSize : originalConstraintSizes[key]!
    }
  }

  override func mouseDown(with event: NSEvent) {
    if usesQuickTimeStyle {
      setPressed(true)
      super.mouseDown(with: event)
      setPressed(false)
      return
    }
    super.mouseDown(with: event)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard usesQuickTimeStyle else {
      super.draw(dirtyRect)
      return
    }
    NSGraphicsContext.saveGraphicsState()
    if visualScale != 1 {
      let transform = NSAffineTransform()
      transform.translateX(by: bounds.midX, yBy: bounds.midY)
      transform.scale(by: visualScale)
      transform.translateX(by: -bounds.midX, yBy: -bounds.midY)
      transform.concat()
    }
    if extendedDynamicRangeHeadroom > 1, let image {
      drawExtendedDynamicRangeImage(image)
    } else {
      super.draw(dirtyRect)
    }
    NSGraphicsContext.restoreGraphicsState()
  }

  private func drawExtendedDynamicRangeImage(_ image: NSImage) {
    let imageSize = image.size
    guard imageSize.width > 0, imageSize.height > 0 else { return }
    let scale = min(1, bounds.width / imageSize.width, bounds.height / imageSize.height)
    let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
    let imageRect = NSRect(x: bounds.midX - drawSize.width / 2,
                           y: bounds.midY - drawSize.height / 2,
                           width: drawSize.width, height: drawSize.height)
    image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1,
               respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    NSColor.hdrWhite(intensity: isPressed ? 1 : 0.84,
                     headroom: extendedDynamicRangeHeadroom).setFill()
    imageRect.fill(using: .sourceAtop)
  }

  private func setPressed(_ pressed: Bool) {
    guard isPressed != pressed else { return }
    isPressed = pressed
    highlight(pressed)
    let scale: CGFloat = pressed ? 0.94 : 1
    guard !Preference.bool(for: .disableAnimations) else {
      visualScale = scale
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = pressed ? 0.1 : 0.15
      context.timingFunction = CAMediaTimingFunction(name: pressed ? .easeInEaseOut : .easeOut)
      animator().visualScale = scale
    }
  }
}

private final class OSCFloatingContentView: NSView {
  private weak var mainWindow: MainWindowController?
  weak var dragSurface: NSView?

  init(mainWindow: MainWindowController) {
    self.mainWindow = mainWindow
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard bounds.contains(point), let mainWindow else { return nil }

    var controls: [NSView] = mainWindow.oscToolbarView?.subviews ?? []
    controls.append(contentsOf: [mainWindow.volumeSlider, mainWindow.muteButton,
                                 mainWindow.playButton,
                                 mainWindow.leftLabel,
                                 mainWindow.rightLabel, mainWindow.playSlider].compactMap { $0 })
    for control in controls.reversed()
      where control.isDescendant(of: self) && !control.isHiddenOrHasHiddenAncestor {
      let localPoint = control.convert(point, from: self)
      if control.bounds.contains(localPoint) {
        return control.hitTest(localPoint) ?? control
      }
    }

    return dragSurface
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }
}

private final class OSCFloatingDragSurface: NSView {
  weak var owner: OSCFloatingView?

  override var mouseDownCanMoveWindow: Bool { false }

  override func mouseDown(with event: NSEvent) {
    owner?.mouseDown(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    owner?.mouseDragged(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    owner?.mouseUp(with: event)
  }
}


class OSCFloatingView: TranslucentView {
  /// Padding kept between the bar and the edges of the video. The bar spans nearly the whole
  /// width in the manner of the picture in picture controls, but never touches the edges.
  static let horizontalInset: CGFloat = 96
  /// Distance kept between the bar and the bottom of the video.
  static let verticalMargin: CGFloat = 25
  /// Fallback height used for clamping before the bar has been laid out.
  private static let assumedHeight: CGFloat = 67

  static var hiddenBlurRadius: CGFloat {
    CGFloat(min(max(Preference.float(for: .oscDissolveBlurRadius), 0), 48))
  }
  private static let dissolveAnimationKey = "oscDissolveBlur"
  private static let dissolveFilterName = "oscDissolve"
  private static let dissolveRadiusKeyPath = "filters.\(dissolveFilterName).inputRadius"
  weak var mainWindow: MainWindowController!
  private let dissolveBlur = CIFilter(name: "CIGaussianBlur")!
  private var prefersUnfilteredVisibleAppearance = false
  private var dissolveAnimationInProgress = false

  var oscTopView: OSCFloatingTopView!
  var oscBottomView: TimeLabelOverflowedStackView!

  private var widthConstraint: NSLayoutConstraint!
  private var yConstraint: NSLayoutConstraint!

  var mousePosRelatedToView: CGPoint?

  var isDragging: Bool = false
  private var didDrag = false

  @discardableResult
  func routeMouseDown(_ event: NSEvent) -> Bool {
    let point = convert(event.locationInWindow, from: nil)
    guard bounds.contains(point), let content else { return false }
    let contentPoint = content.convert(point, from: self)
    guard let targetView = content.hitTest(contentPoint) else { return false }
    if targetView === content {
      mouseDown(with: event)
    } else {
      targetView.mouseDown(with: event)
    }
    return true
  }

  init(mainWindow: MainWindowController) {
    self.mainWindow = mainWindow

    let container = OSCFloatingContentView(mainWindow: mainWindow)
    container.translatesAutoresizingMaskIntoConstraints = false

    super.init(liquidGlassCornerRadius: 24, vevCornerRadius: 20, padding: (0, 0),
               contentPlacement: .aboveMaterial)

    wantsLayer = true
    dissolveBlur.name = Self.dissolveFilterName
    dissolveBlur.setDefaults()
    dissolveBlur.setValue(0, forKey: kCIInputRadiusKey)
    contentFilters = [dissolveBlur]

    let dragSurface = OSCFloatingDragSurface()
    dragSurface.translatesAutoresizingMaskIntoConstraints = false
    dragSurface.owner = self
    container.addSubview(dragSurface, positioned: .below, relativeTo: nil)
    dragSurface.padding(.all)
    container.dragSurface = dragSurface

    self.oscTopView = OSCFloatingTopView()
    oscTopView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(oscTopView)
    oscTopView.padding(.top(.oscPaddingTop), .horizontal(12))

    self.oscBottomView = TimeLabelOverflowedStackView()
    oscBottomView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(oscBottomView)
    oscBottomView.padding(.bottom(.oscPaddingBottom), .horizontal(8))
      .spacing(.top(8), to: oscTopView)

    let widthConstraint = widthAnchor.constraint(equalToConstant: 0)
    widthConstraint.priority = .init(300)
    widthConstraint.isActive = true
    self.widthConstraint = widthConstraint

    setContent(container)

    NotificationCenter.default
      .addObserver(forName: .yinaSidebarStatusChanged, object: nil, queue: .main) { [weak self] _ in
      self?.initPosition()
    }
  }

  /// The control bar is always plain glass, matching the picture in picture overlay.

  ///
  /// The previous implementation forced a `hudWindow` material and a dark appearance, which is
  /// what made the bar read as a light or dark slab rather than as glass over the video.
  override func setStyle(_ newStyle: TranslucentView.Style, force: Bool = false) {
    super.setStyle(.visualEffect, force: force)
    guard let visualEffectView = container as? NSVisualEffectView else { return }
    visualEffectView.blendingMode = .behindWindow
    visualEffectView.material = .underWindowBackground
    visualEffectView.state = .followsWindowActiveState
    visualEffectView.appearance = nil
  }

  /// Sets the starting blur without animation. Used only while the OSC is fully transparent.
  func prepareDissolveBlur(_ radius: CGFloat) {
    ensureDissolveFilterAttached()
    layer?.removeAnimation(forKey: Self.dissolveAnimationKey)
    dissolveAnimationInProgress = false
    dissolveBlur.setValue(radius, forKey: kCIInputRadiusKey)
    layer?.setValue(radius, forKeyPath: Self.dissolveRadiusKeyPath)
  }

  /// Animates the attached Core Image filter directly on the backing layer instead of rebuilding
  /// the filter graph on every animation frame.
  func animateDissolveBlur(to radius: CGFloat, duration: TimeInterval,
                           startingAt preparedRadius: CGFloat? = nil) {
    ensureDissolveFilterAttached()
    guard duration > 0, let layer else {
      prepareDissolveBlur(radius)
      return
    }
    let keyPath = Self.dissolveRadiusKeyPath
    let currentRadius = preparedRadius.map(Double.init) ??
      (layer.presentation()?.value(forKeyPath: keyPath) as? NSNumber)?.doubleValue ??
      (dissolveBlur.value(forKey: kCIInputRadiusKey) as? NSNumber)?.doubleValue ?? 0
    layer.setValue(radius, forKeyPath: keyPath)

    let easing = DissolveEasing(rawValue: Preference.integer(for: .oscDissolveEasing)) ?? .easeInOut
    let overshoot = Double(Preference.float(for: .oscDissolveOvershoot))
    let animation = CAKeyframeAnimation(keyPath: keyPath)
    animation.values = (0...120).map { index in
      let progress = easing.value(at: Double(index) / 120, overshoot: overshoot)
      return max(0, currentRadius + (Double(radius) - currentRadius) * progress)
    }
    animation.duration = duration
    animation.calculationMode = .linear
    dissolveAnimationInProgress = true
    layer.add(animation, forKey: Self.dissolveAnimationKey)
  }

  func finishDissolveAppearance() {
    layer?.removeAnimation(forKey: Self.dissolveAnimationKey)
    dissolveAnimationInProgress = false
    dissolveBlur.setValue(0, forKey: kCIInputRadiusKey)
    layer?.setValue(0, forKeyPath: Self.dissolveRadiusKeyPath)
    if prefersUnfilteredVisibleAppearance {
      contentFilters = []
    }
  }

  /// EDR content should not remain behind a Core Image filter while the OSC is fully visible.
  /// The dissolve temporarily reattaches the Gaussian filter, then removes it after fading in.
  func setPrefersUnfilteredVisibleAppearance(_ enabled: Bool) {
    guard enabled != prefersUnfilteredVisibleAppearance else { return }
    prefersUnfilteredVisibleAppearance = enabled
    if enabled, !dissolveAnimationInProgress {
      finishDissolveAppearance()
    } else if !enabled {
      ensureDissolveFilterAttached()
    }
  }

  private func ensureDissolveFilterAttached() {
    guard !contentFilters.contains(where: { $0 === dissolveBlur }) else { return }
    contentFilters = [dissolveBlur]
  }

  func setupConstraints() {
    let videoView = mainWindow.videoViewContainer!

    // The bar spans nearly the whole video in the manner of the picture in picture controls, but
    // never touches the edges. It is always centred horizontally; only the vertical position is
    // the user's to tune.
    widthConstraint = widthAnchor.constraint(equalTo: videoView.widthAnchor,
                                              constant: -2 * Self.horizontalInset)
    widthConstraint.priority = .defaultHigh
    widthConstraint.isActive = true

    centerXAnchor.constraint(equalTo: videoView.centerXAnchor).isActive = true

    // Keep the bar inside the video no matter how wide it grows.
    leadingAnchor.constraint(greaterThanOrEqualTo: videoView.leadingAnchor,
                             constant: Self.horizontalInset / 2).isActive = true
    trailingAnchor.constraint(lessThanOrEqualTo: videoView.trailingAnchor,
                              constant: -Self.horizontalInset / 2).isActive = true

    yConstraint = videoView.bottomAnchor.constraint(equalTo: bottomAnchor)
    yConstraint.priority = .defaultHigh
    yConstraint.isActive = true
  }

  func initPosition() {
    let videoView = mainWindow.videoViewContainer!
    let cpv = Preference.float(for: .controlBarPositionVertical)
    yConstraint.constant = videoView.frame.height * CGFloat(cpv)
  }

  func updatePosition() {
    let videoView = mainWindow.videoViewContainer!
    let windowHeight = videoView.frame.height
    let cpv = Preference.float(for: .controlBarPositionVertical)
    yConstraint.constant = clampedY(windowHeight * CGFloat(cpv), inHeight: windowHeight)
  }

  /// Keeps the bar fully on screen with the bottom margin intact.
  private func clampedY(_ proposed: CGFloat, inHeight windowHeight: CGFloat) -> CGFloat {
    let height = fittingSize.height > 0 ? fittingSize.height : Self.assumedHeight
    let maximum = max(windowHeight - height - Self.verticalMargin, 0)
    return proposed.clamped(to: 0...maximum)
  }

  override func mouseDown(with event: NSEvent) {
    mousePosRelatedToView = NSEvent.mouseLocation
    mousePosRelatedToView!.y -= frame.origin.y
    didDrag = false
    isDragging = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard let mousePos = mousePosRelatedToView else { return }
    didDrag = true
    let windowFrame = mainWindow.videoViewContainer.frame
    let proposed = NSEvent.mouseLocation.y - mousePos.y
    yConstraint.constant = clampedY(proposed, inHeight: windowFrame.height)
  }

  override func mouseUp(with event: NSEvent) {
    isDragging = false
    guard didDrag else { return }
    let windowHeight = mainWindow.videoViewContainer.frame.height
    guard windowHeight > 0 else { return }
    // Only the vertical position is remembered. The bar is always centred.
    Preference.set(yConstraint.constant / windowHeight, for: .controlBarPositionVertical)
  }

  @MainActor required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
