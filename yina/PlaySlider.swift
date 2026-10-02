//
//  PlaySlider.swift
//  yina
//
//  Created by low-batt on 10/11/21.
//  Copyright © 2021 lhc. All rights reserved.
//

import Cocoa

/// Chapter markers are independent of the system slider's drawing and tracking machinery.
private final class SliderChapterMarks: NSView {
  weak var slider: PlaySlider?

  override var isFlipped: Bool { slider?.isFlipped ?? false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    guard let slider, slider.usesSystemAppearance, slider.drawChapters,
          let controller = slider.window?.windowController as? PlayerWindowController,
          let duration = controller.player.info.videoDuration?.second, duration > 0 else { return }
    let bar = slider.sliderCell.barRect(flipped: slider.isFlipped)
    let knob = slider.sliderCell.knobRect(flipped: slider.isFlipped)
    let travel = max(0, bar.width - knob.width)
    NSColor.black.withAlphaComponent(0.3).setFill()
    for chapter in controller.player.info.chapters.dropFirst() {
      let fraction = chapter.time.second / duration
      guard fraction > 0, fraction < 1 else { continue }
      let x = bar.minX + knob.width / 2 + CGFloat(fraction) * travel
      let mark = NSRect(x: round(x) - 0.5, y: bar.minY, width: 1, height: bar.height)
      // Never paint over the native thumb (including its expanded tracking appearance).
      if !mark.intersects(knob.insetBy(dx: -4, dy: -4)) {
        NSBezierPath(rect: mark).fill()
      }
    }
  }
}

private final class FloatingPlaySliderCell: NSSliderCell {
  var extendedDynamicRangeHeadroom: CGFloat = 1

  private var usesExtendedDynamicRange: Bool { extendedDynamicRangeHeadroom > 1 }

  override func drawKnob(_ knobRect: NSRect) {
    guard usesExtendedDynamicRange else {
      super.drawKnob(knobRect)
      return
    }
    NSColor.hdrWhite(headroom: extendedDynamicRangeHeadroom).setFill()
    let diameter = min(knobRect.width, knobRect.height)
    let circle = NSRect(x: knobRect.midX - diameter / 2, y: knobRect.midY - diameter / 2,
                        width: diameter, height: diameter)
    NSBezierPath(ovalIn: circle).fill()
  }

  override func drawBar(inside rect: NSRect, flipped: Bool) {
    guard usesExtendedDynamicRange else {
      super.drawBar(inside: rect, flipped: flipped)
      return
    }
    let knob = knobRect(flipped: flipped)
    let progress = min(max(knob.midX, rect.minX), rect.maxX)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)

    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY,
                              width: progress - rect.minX, height: rect.height)).addClip()
    NSColor.hdrWhite(intensity: 0.45, headroom: extendedDynamicRangeHeadroom).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: NSRect(x: progress, y: rect.minY,
                              width: rect.maxX - progress, height: rect.height)).addClip()
    NSColor.hdrWhite(intensity: 0.18, headroom: extendedDynamicRangeHeadroom).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
  }
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
/// - Note: Floating OSCs use an unmodified system cell; chapter markers are a noninteractive overlay.
final class PlaySlider: NSSlider {

  private(set) var usesSystemAppearance = false
  private var originalTrackFillColor: NSColor?
  private var legacyCell: PlaySliderCell!
  private var floatingCell: FloatingPlaySliderCell!
  private var chapterMarks: SliderChapterMarks!
  private(set) var isDraggingPlaybackThumb = false
  private var resumeAfterTracking = false

  /// Knob representing the A loop point for the mpv A-B loop feature.
  var abLoopA: PlaySliderLoopKnob { abLoopAKnob }

  /// Knob representing the B loop point for the mpv A-B loop feature.
  var abLoopB: PlaySliderLoopKnob { abLoopBKnob }

  var sliderCell: NSSliderCell { cell as! NSSliderCell }
  var sliderKnobWidth: CGFloat { usesSystemAppearance ? floatingCell.knobRect(flipped: isFlipped).width : legacyCell.knobWidth }
  var sliderKnobHeight: CGFloat { usesSystemAppearance ? floatingCell.knobRect(flipped: isFlipped).height : legacyCell.knobHeight }
  var sliderKnobRadius: CGFloat { usesSystemAppearance ? sliderKnobHeight / 2 : legacyCell.knobRadius }

  var drawChapters: Bool {
    get { legacyCell.drawChapters }
    set {
      legacyCell.drawChapters = newValue
      needsDisplay = true
    }
  }

  /// Range of values the slider is configured to return.
  var range: ClosedRange<Double> { minValue...maxValue }

  /// Span of the range of values the slider is configured to return.
  var span: Double { maxValue - minValue }

  var extendedDynamicRangeHeadroom: CGFloat {
    get { legacyCell.extendedDynamicRangeHeadroom }
    set {
      legacyCell.extendedDynamicRangeHeadroom = newValue
      floatingCell.extendedDynamicRangeHeadroom = newValue
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
    chapterMarks = SliderChapterMarks(frame: bounds)
    chapterMarks.slider = self
    chapterMarks.autoresizingMask = [.width, .height]
    addSubview(chapterMarks, positioned: .below, relativeTo: abLoopAKnob)

    addTarget(self, action: #selector(trackingBegan), for: .trackingBegan)
    addTarget(self, action: #selector(trackingEnded),
              for: [.trackingEndedInside, .trackingEndedOutside, .trackingCancelled])
  }

  func setQuickTimeStyle(_ enabled: Bool) {
    let desiredCell: NSSliderCell = enabled ? floatingCell : legacyCell
    guard usesSystemAppearance != enabled || cell !== desiredCell else { return }
    if cell !== desiredCell {
      replaceCellPreservingConfiguration(with: desiredCell)
    }
    usesSystemAppearance = enabled
    controlSize = enabled ? .regular : .small
    trackFillColor = enabled ? .white : originalTrackFillColor
    tintProminence = .automatic
    chapterMarks.isHidden = !enabled
    abLoopA.updateGeometry()
    abLoopB.updateGeometry()
    needsDisplay = true
  }

  // MARK: - Drawing

  // Leave NSSlider.draw untouched so AppKit owns the complete interactive appearance.
  override var needsDisplay: Bool {
    get { super.needsDisplay }
    set {
      super.needsDisplay = newValue
      guard newValue else { return }
      chapterMarks?.needsDisplay = true
      abLoopAKnob?.needsDisplay = true
      abLoopBKnob?.needsDisplay = true
    }
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    // When YINA is not the application being used and the onscreen controller is hidden if the
    // mouse is moved over a YINA window the YINA will unhide the controller. If the slider is
    // not marked as needing display the controller will show without the slider. I would have
    // thought the NSView method would do this. The current Apple documentation does not say what
    // the NSView method does or even if it needs to be called by subclasses.
    needsDisplay = true
  }

  // MARK: - Mouse / Trackpad events

  /// Track the control lifecycle, not the duration of a mouseDown call. AppKit can track
  /// asynchronously; returning from mouseDown does not mean the user has released the thumb.
  @objc private func trackingBegan() {
    guard !isDraggingPlaybackThumb else { return }
    isDraggingPlaybackThumb = true
    let player = playerCore
    resumeAfterTracking = player.info.state == .playing
    player.mainWindow.liveText.clearAnalysis()
    player.pause()
    player.mainWindow.thumbnailPeekView.isHidden = true
  }

  @objc private func trackingEnded() {
    guard isDraggingPlaybackThumb else { return }
    isDraggingPlaybackThumb = false
    if resumeAfterTracking { playerCore.resume() }
    resumeAfterTracking = false
    chapterMarks.needsDisplay = true
  }

  /// The user is scrolling while the cursor is within the slider.
  ///
  /// With certain kinds of input devices, such as a mouse with a scroll wheel that spins freely, it is easy to accidentally move the cursor
  /// over the slider and unintentionally change the playback position. For users that dislike this behavior YINA provides a setting to
  /// disable scrolling the slider. When this setting is enabled the user must grab and drag the slider's thumb to change the playback
  /// position or click on a position within the slider.
  /// - Parameter event: Event indicating the scroll wheel position changed.
  override func scrollWheel(with event: NSEvent) {
    guard !Preference.bool(for: .disablePlaySliderScrolling) else { return }
    super.scrollWheel(with: event)
  }

  private var playerCore: PlayerCore {
    (window!.windowController as! PlayerWindowController).player
  }
}
