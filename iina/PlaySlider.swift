//
//  PlaySlider.swift
//  iina
//
//  Created by low-batt on 10/11/21.
//  Copyright © 2021 lhc. All rights reserved.
//

import Cocoa

/// Draws the QuickTime-style floating timeline while preserving IINA's neutral colors and chapter marks.
private final class FloatingPlaySliderCell: PlaySliderCell {
  let idleKnobSize = NSSize(width: 20, height: 8)
  let activeKnobSize = NSSize(width: 30, height: 18)

  override var knobThickness: CGFloat { idleKnobSize.width }

  override func drawBar(inside rect: NSRect, flipped: Bool) {
    let timelineRect = NSRect(x: rect.minX, y: round(rect.midY - 2), width: rect.width, height: 4)
    super.drawBar(inside: timelineRect, flipped: flipped)
  }

  override func drawKnob(_ knobRect: NSRect) {
    guard (controlView as? PlaySlider)?.isTrackingFloatingKnob != true else { return }
    let rect = NSRect(x: round(knobRect.midX - idleKnobSize.width / 2),
                      y: round(knobRect.midY - idleKnobSize.height / 2),
                      width: idleKnobSize.width,
                      height: idleKnobSize.height)
    let path = NSBezierPath(roundedRect: rect,
                            xRadius: idleKnobSize.height / 2,
                            yRadius: idleKnobSize.height / 2)
    (usesExtendedDynamicRange ? NSColor.hdrWhite(alpha: 0.96) : .mainSliderKnob).setFill()
    path.fill()
  }

  override func knobRect(flipped: Bool) -> NSRect {
    let slider = controlView as! NSSlider
    let bar = barRect(flipped: flipped)
    let span = slider.maxValue - slider.minValue
    let percentage = span == 0 ? 0 : (slider.doubleValue - slider.minValue) / span
    let x = bar.minX + CGFloat(percentage) * (bar.width - idleKnobSize.width)
    let nativeRect = super.knobRect(flipped: flipped)
    return NSRect(x: x,
                  y: nativeRect.midY - idleKnobSize.height / 2,
                  width: idleKnobSize.width,
                  height: idleKnobSize.height)
  }

  override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool {
    let started = super.startTracking(at: startPoint, in: controlView)
    if started {
      (controlView as? PlaySlider)?.setFloatingKnobTracking(true)
    }
    return started
  }

  override func stopTracking(last lastPoint: NSPoint, current stopPoint: NSPoint,
                             in controlView: NSView, mouseIsUp flag: Bool) {
    super.stopTracking(last: lastPoint, current: stopPoint, in: controlView, mouseIsUp: flag)
    (controlView as? PlaySlider)?.setFloatingKnobTracking(false)
  }
}

private final class SliderKnobIndicatorView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    let indicator = NSRect(x: round(bounds.midX - 8), y: round(bounds.midY - 2), width: 16, height: 4)
    NSColor.white.withAlphaComponent(0.96).setFill()
    NSBezierPath(roundedRect: indicator, xRadius: 2, yRadius: 2).fill()
  }
}

/// The public AppKit glass surface used while the timeline is being tracked.
private final class SliderGlassKnobView: NSGlassEffectView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension NSSlider {
  func replaceCellPreservingConfiguration(with replacement: NSSliderCell) {
    let currentValue = doubleValue
    let currentMinValue = minValue
    let currentMaxValue = maxValue
    let currentAltIncrementValue = altIncrementValue
    let currentSliderType = sliderType
    let currentNumberOfTickMarks = numberOfTickMarks
    let currentTickMarkPosition = tickMarkPosition
    let currentAllowsTickMarkValuesOnly = allowsTickMarkValuesOnly
    let currentIsContinuous = isContinuous
    let currentIsEnabled = isEnabled
    let currentTarget = target
    let currentAction = action
    let currentTag = tag
    let currentNeutralValue = neutralValue

    cell = replacement
    minValue = currentMinValue
    maxValue = currentMaxValue
    doubleValue = currentValue
    altIncrementValue = currentAltIncrementValue
    sliderType = currentSliderType
    numberOfTickMarks = currentNumberOfTickMarks
    tickMarkPosition = currentTickMarkPosition
    allowsTickMarkValuesOnly = currentAllowsTickMarkValuesOnly
    isContinuous = currentIsContinuous
    isEnabled = currentIsEnabled
    target = currentTarget
    action = currentAction
    tag = currentTag
    neutralValue = currentNeutralValue
  }
}

/// A custom [slider](https://developer.apple.com/design/human-interface-guidelines/macos/selectors/sliders/)
/// for the onscreen controller.
///
/// This slider adds two thumbs (referred to as knobs in code) to the progress bar slider to show the A and B loop points of the
/// [mpv](https://mpv.io/manual/stable/) A-B loop feature and allow the loop points to be adjusted. When the feature is
/// disabled the additional thumbs are hidden.
/// - Note: Floating OSCs use a chapter-aware neutral cell with an interactive AppKit glass thumb; other layouts retain `PlaySliderCell`.
/// - Note: Unlike `NSSlider` the `draw` method of this class will do nothing if the view is hidden.
final class PlaySlider: NSSlider {

  private(set) var usesSystemAppearance = false
  private var originalTrackFillColor: NSColor?
  private var legacyCell: PlaySliderCell!
  private var floatingCell: FloatingPlaySliderCell!
  private var floatingKnob: SliderGlassKnobView!
  private var floatingKnobAnimationGeneration = 0

  fileprivate private(set) var isTrackingFloatingKnob = false

  /// Knob representing the A loop point for the mpv A-B loop feature.
  var abLoopA: PlaySliderLoopKnob { abLoopAKnob }

  /// Knob representing the B loop point for the mpv A-B loop feature.
  var abLoopB: PlaySliderLoopKnob { abLoopBKnob }

  var sliderCell: NSSliderCell { cell as! NSSliderCell }
  var sliderKnobWidth: CGFloat { usesSystemAppearance ? floatingCell.idleKnobSize.width : legacyCell.knobWidth }
  var sliderKnobHeight: CGFloat { usesSystemAppearance ? floatingCell.idleKnobSize.height : legacyCell.knobHeight }
  var sliderKnobRadius: CGFloat { usesSystemAppearance ? floatingCell.idleKnobSize.height / 2 : legacyCell.knobRadius }

  var drawChapters: Bool {
    get { legacyCell.drawChapters }
    set {
      legacyCell.drawChapters = newValue
      floatingCell.drawChapters = newValue
      needsDisplay = true
    }
  }

  /// Range of values the slider is configured to return.
  var range: ClosedRange<Double> { minValue...maxValue }

  /// Span of the range of values the slider is configured to return.
  var span: Double { maxValue - minValue }

  var usesExtendedDynamicRange: Bool {
    get { legacyCell.usesExtendedDynamicRange }
    set {
      legacyCell.usesExtendedDynamicRange = newValue
      floatingCell.usesExtendedDynamicRange = newValue
      needsDisplay = true
      abLoopA.needsDisplay = true
      abLoopB.needsDisplay = true
    }
  }

  // MARK:- Private Properties

  private var abLoopAKnob: PlaySliderLoopKnob!

  private var abLoopBKnob: PlaySliderLoopKnob!

  // MARK: - Initialization

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    initializeCells()
    originalTrackFillColor = trackFillColor
    commonInit()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    initializeCells()
    originalTrackFillColor = trackFillColor
    commonInit()
  }

  private func initializeCells() {
    legacyCell = PlaySliderCell()
    floatingCell = FloatingPlaySliderCell()
    [legacyCell, floatingCell].forEach {
      $0.refusesFirstResponder = true
      $0.minValue = 0
      $0.maxValue = 100
    }
  }

  private func commonInit() {
    // Apple increased the height of sliders in Big Sur. Until we have time to restructure the
    // on screen controller to accommodate a larger slider reduce the size of the slider from
    // regular to small. This makes the slider match the behavior seen under Catalina. This MUST
    // be set before creating the loop knobs as it changes the height of knobs which is referenced
    // during loop knob initialization.
    controlSize = .small

    abLoopAKnob = PlaySliderLoopKnob(slider: self, toolTip: "A-B loop A")
    abLoopBKnob = PlaySliderLoopKnob(slider: self, toolTip: "A-B loop B")

    floatingKnob = SliderGlassKnobView()
    floatingKnob.translatesAutoresizingMaskIntoConstraints = true
    floatingKnob.style = .regular
    floatingKnob.effectIsInteractive = true
    floatingKnob.cornerRadius = floatingCell.activeKnobSize.height / 2
    floatingKnob.contentView = SliderKnobIndicatorView()
    floatingKnob.isHidden = true
    addSubview(floatingKnob)
  }

  func setQuickTimeStyle(_ enabled: Bool) {
    let desiredCell: NSSliderCell = enabled ? floatingCell : legacyCell
    guard usesSystemAppearance != enabled || cell !== desiredCell else { return }
    if cell !== desiredCell {
      replaceCellPreservingConfiguration(with: desiredCell)
    }
    usesSystemAppearance = enabled
    controlSize = .small
    trackFillColor = originalTrackFillColor
    tintProminence = .automatic
    isTrackingFloatingKnob = false
    floatingKnob.isHidden = true
    abLoopA.updateGeometry()
    abLoopB.updateGeometry()
    needsDisplay = true
  }

  // MARK: - Drawing

  /// Draw the slider.
  ///
  /// The [NSSlider](https://developer.apple.com/documentation/appkit/nsslider) method is being overridden
  /// for two reasons.
  ///
  /// With the onscreen controller hidden and a movie playing spindumps showed time being spent drawing the slider even though it
  /// was not visible. Apparently `NSSlider.draw` is not calling
  /// [hiddenOrHasHiddenAncestor](https://developer.apple.com/documentation/appkit/nsview/1483473-hiddenorhashiddenancestor)
  /// to see if drawing can be avoided.  This was noticed under macOS Monterey.  Unknown if Apple addressed this in later macOS
  /// releases.
  ///
  /// The loop knobs are added as subviews to the slider. That should have resulted in the `PlaySliderLoopKnob.draw` method
  /// being called when the slider was being drawn. Prior to macOS Sonoma that did not occur. The assumption is that the
  /// [NSSlider](https://developer.apple.com/documentation/appkit/nsslider) `draw` method was not calling
  /// `super.draw` and that has now been corrected. As a workaround on earlier versions of macOS the loop knob `draw` method
  /// is called directly.
  override func draw(_ dirtyRect: NSRect) {
    guard !isHiddenOrHasHiddenAncestor else { return }
    super.draw(dirtyRect)
    if usesSystemAppearance, isTrackingFloatingKnob {
      let target = floatingKnobFrame(size: floatingKnob.frame.size)
      floatingKnob.setFrameOrigin(target.origin)
    }
    abLoopA.needsDisplay = true
    abLoopB.needsDisplay = true
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    // When IINA is not the application being used and the onscreen controller is hidden if the
    // mouse is moved over an IINA window the IINA will unhide the controller. If the slider is
    // not marked as needing display the controller will show without the slider. I would have
    // thought the NSView method would do this. The current Apple documentation does not say what
    // the NSView method does or even if it needs to be called by subclasses.
    needsDisplay = true
  }

  // MARK: - Mouse / Trackpad events

  /// Informs the receiver that the user has pressed the left mouse button.
  ///
  /// This is a workaround for IINA issue #5768 where starting with macOS Tahoe AppKit is miss-handling mouse events in certain
  /// circumstances. Merely adding this function solved the problem. Maybe the presence of this function prevents the use of some sort
  /// of faulty optimization?
  /// - Important: _DO NOT REMOVE_ this function thinking it is not needed. Read issue #5768.
  /// - Parameter event: An object encapsulating information about the mouse-down event.
  override func mouseDown(with event: NSEvent) {
    let player = playerCore
    let shouldResume = player.info.state != .paused
    player.mainWindow.liveText.clearAnalysis()
    player.pause()
    player.mainWindow.thumbnailPeekView.isHidden = true
    super.mouseDown(with: event)
    if shouldResume {
      player.resume()
    }
  }

  /// The user is scrolling while the cursor is within the slider.
  ///
  /// With certain kinds of input devices, such as a mouse with a scroll wheel that spins freely, it is easy to accidentally move the cursor
  /// over the slider and unintentionally change the playback position. For users that dislike this behavior IINA provides a setting to
  /// disable scrolling the slider. When this setting is enabled the user must grab and drag the slider's thumb to change the playback
  /// position or click on a position within the slider.
  /// - Parameter event: Event indicating the scroll wheel position changed.
  override func scrollWheel(with event: NSEvent) {
    guard !Preference.bool(for: .disablePlaySliderScrolling) else { return }
    super.scrollWheel(with: event)
  }

  fileprivate func setFloatingKnobTracking(_ tracking: Bool) {
    guard usesSystemAppearance, tracking != isTrackingFloatingKnob else { return }
    isTrackingFloatingKnob = tracking
    floatingKnobAnimationGeneration += 1
    let generation = floatingKnobAnimationGeneration
    let duration = AccessibilityPreferences.motionReductionEnabled ? 0 :
      AccessibilityPreferences.adjustedDuration(tracking ? 0.10 : 0.12)

    if tracking {
      floatingKnob.frame = floatingKnobFrame(size: floatingCell.idleKnobSize)
      floatingKnob.isHidden = false
    }
    needsDisplay = true

    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      let size = tracking ? floatingCell.activeKnobSize : floatingCell.idleKnobSize
      floatingKnob.animator().frame = floatingKnobFrame(size: size)
    } completionHandler: { [weak self] in
      guard let self, self.floatingKnobAnimationGeneration == generation, !tracking else { return }
      self.floatingKnob.isHidden = true
      self.needsDisplay = true
    }
  }

  private func floatingKnobFrame(size: NSSize) -> NSRect {
    let knobRect = floatingCell.knobRect(flipped: isFlipped)
    return NSRect(x: round(knobRect.midX - size.width / 2),
                  y: round(knobRect.midY - size.height / 2),
                  width: size.width,
                  height: size.height)
  }

  private var playerCore: PlayerCore {
    (window!.windowController as! PlayerWindowController).player
  }
}
