//
//  SidebarSubtitlesPane.swift
//  yina
//
//  Created by Hechen Li on 2026-06-15.
//  Copyright © 2026 lhc. All rights reserved.
//

fileprivate let ui = UIHelper.shared


class SidebarSubtitlesPane: SidebarScrollView {
  weak var player: PlayerCore!

  init(player: PlayerCore) {
    self.player = player
    super.init(frame: .zero)

    drawsBackground = false

    let stack = ui.vStack(spacing: .sidebarStackViewSpacing)

    stack.addArrangedSubview(ui.vStack(
      spacing: .sidebarItemSpacing,
      wantsToGrow: true,
      ui.hStack(
        spacing: 8,
        ui.image("1.square.fill", size: 16, config: .sidebarIconConfig),
        ui.label("sidebar.primary", font: .boldSystemFont(ofSize: 12)),
        ui.flexibleSpace(),
        VisibilitySwitch(player: player, isPrimary: true),
      ),
      Container(TrackSelector(
        .sub,
        player: player,
        observedKeys: [.yinaSIDChanged]
      )) {
        $0.padding(.all)
      }
    ))

    stack.addArrangedSubview(ui.vStack(
      spacing: .sidebarItemSpacing,
      wantsToGrow: true,
      ui.hStack(
        spacing: 8,
        ui.image("2.square.fill", size: 16, config: .sidebarIconConfig),
        ui.label("sidebar.secondary", font: .boldSystemFont(ofSize: 12)),
        ui.flexibleSpace(),
        VisibilitySwitch(player: player, isPrimary: false),
      ),
      Container(TrackSelector(
        .secondSub,
        player: player,
        observedKeys: [.yinaSIDChanged]
      )) {
        $0.padding(.all)
      }
    ))

    stack.addArrangedSubview(Container(LoadSubtitleView(player: player)) {
      $0.padding(.all(.sidebarContainerPadding))
    })

    stack.addArrangedSubview(Container(SubPositionDelayView(player: player)) {
      $0.padding(.all(.sidebarContainerPadding))
    })

    let textStyleView = Container(SubStyleView(player: player)) {
      $0.padding(.all(.sidebarContainerPadding))
    }
    stack.addArrangedSubview(textStyleView)

    let imageWarning = Container(ui.label(
      "sidebar.sub_settings_not_available", wrapping: true, isSmall: true, isSecondary: true)) {
        $0.padding(
          .vertical(.sidebarContainerPadding),
          .leading(.sidebarContainerPadding),
          .trailing(greaterThan: .sidebarContainerPadding)
        )
      }
    stack.addArrangedSubview(imageWarning)

    let assWarning = Container(ui.label(
      "sidebar.sub_style_warning", wrapping: true, isSmall: true, isSecondary: true)) {
        $0.padding(
          .vertical(.sidebarContainerPadding),
          .leading(.sidebarContainerPadding),
          .trailing(greaterThan: .sidebarContainerPadding)
        )
      }
    stack.addArrangedSubview(assWarning)

    documentView!.addSubview(stack)
    stack.padding(.horizontal(.sidebarMargin), .top(4), .bottom(.sidebarMargin))

    let block = { (_: Notification) in
      let tracks = ([.sub, .secondSub] as [MPVTrack.TrackType]).compactMap {
        player.info.currentTrack($0)
      }
      let hasText = tracks.isEmpty || tracks.map { !$0.isImageSub }.reduce(false) { $0 || $1 }
      let isASS = tracks.map { $0.isAssSub }.reduce(false) { $0 || $1 }

      stack.setVisibilityPriority(hasText ? .mustHold : .notVisible, for: textStyleView)
      stack.setVisibilityPriority(hasText ? .notVisible : .mustHold, for: imageWarning)
      stack.setVisibilityPriority(isASS ? .mustHold : .notVisible, for: assWarning)
    }

    block(.init(name: .init("")))
    player.observe(.yinaSIDChanged, block: block)
    player.observe(.yinaTracklistChanged, block: block)
  }

  @MainActor required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}


fileprivate class VisibilitySwitch: NSSwitch {
  private unowned let player: PlayerCore
  private let isPrimary: Bool

  init(player: PlayerCore, isPrimary: Bool) {
    self.player = player
    self.isPrimary = isPrimary
    super.init(frame: .zero)

    controlSize = .mini
    target = self
    action = #selector(switchAction)
    update()

    player.observe(.yinaSubVisibilityChanged) { [unowned self] _ in
      update()
    }
    player.observe(.yinaSIDChanged) { [unowned self] _ in
      update()
    }
  }

  private func update() {
    let trackType: MPVTrack.TrackType = isPrimary ? .sub : .secondSub
    let hasSelectedTrack = player.info.currentTrack(trackType) != nil
    let isVisible = isPrimary ?
      player.info.isSubVisible : player.info.isSecondSubVisible
    isEnabled = hasSelectedTrack
    state = hasSelectedTrack && isVisible ? .on : .off
  }

  @objc private func switchAction(_ sender: AnyObject) {
    if isPrimary {
      player.toggleSubVisibility()
    } else {
      player.toggleSecondSubVisibility()
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}


fileprivate class LoadSubtitleView: NSView {
  private unowned let player: PlayerCore

  init(player: PlayerCore) {
    self.player = player
    super.init(frame: .zero)

    translatesAutoresizingMaskIntoConstraints = false

    let loadSubSegment = NSSegmentedControl(
      labels: [NSLocalizedString("sidebar.load_subtitle", comment: ""), ""],
      trackingMode: .momentary,
      target: self,
      action: #selector(loadExternalSubAction)
    )
    loadSubSegment.trackingMode = .momentary
    loadSubSegment.target = self
    loadSubSegment.action = #selector(loadExternalSubAction)
    loadSubSegment.setImage(.sf("chevron.down"), forSegment: 1)

    let searchOnlineButton = ui.button(
      "sidebar.search_online", target: self, action: #selector(searchOnlineAction)
    )

    let stack = ui.hStack(
      spacing: 8,
      loadSubSegment,
      searchOnlineButton,
    )
    addSubview(stack)
    stack.padding(.all)
  }

  @objc func loadExternalSubAction(_ sender: NSSegmentedControl) {
    if sender.selectedSegment == 0 {
      let currentDir = player.info.currentURL?.deletingLastPathComponent()
      Utility.quickOpenPanel(title: "Load external subtitle", chooseDir: false, dir: currentDir,
                             sheetWindow: player.currentWindow,
                             allowedFileTypes: Utility.containsSubExt) { url in
        self.player.loadExternalSubFile(url, delay: true)
      }
    } else if sender.selectedSegment == 1 {
      player.mainWindow.showSubChooseMenu(forView: sender)
    }
  }

  @objc func searchOnlineAction(_ sender: AnyObject) {
    player.mainWindow.menuActionHandler.menuFindOnlineSub(.dummy)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}


fileprivate class SubDelayView: SidebarSliderView {
  var isPrimary: Bool = true

  override var titleImage: NSImage? {
    .sf("clock.arrow.trianglehead.counterclockwise.rotate.90", "clock.arrow.circlepath",
        withConfiguration: .sidebarIconConfig)
  }
  override var titleKey: String { "sidebar.delay" }
  override var tickMarkLabels: [String] {
    ["-5s", "0s", "+5s"]
  }
  override var notificationKey: Notification.Name {
    .yinaSubDelayChanged
  }

  override func setup() {
    slider.minValue = -5
    slider.maxValue = 5
    slider.numberOfTickMarks = 21
    slider.neutralValue = 0

    let fmt = NumberFormatter()
    fmt.numberStyle = .decimal
    fmt.maximumSignificantDigits = 3
    input.formatter = fmt
  }

  override func indicatorLabel() -> String {
    "\(input.stringValue)s"
  }

  override func update() {
    let delayOption = isPrimary ? MPVOption.Subtitles.subDelay : MPVOption.Subtitles.secondarySubDelay
    let subDelay = player.mpv.getDouble(delayOption)
    slider.doubleValue = subDelay
    input.doubleValue = subDelay
    resetButton.isHidden = slider.doubleValue == 0
    updateIndicator()
  }

  override func sliderAction() {
    let eventType = NSApp.currentEvent!.type
    if eventType == .leftMouseDown {
      slider.allowsTickMarkValuesOnly = true
    }
    if eventType == .leftMouseUp {
      slider.allowsTickMarkValuesOnly = false
    }
    let sliderValue = slider.doubleValue
    input.doubleValue = sliderValue
    updateIndicator()
    if let event = NSApp.currentEvent {
      if event.type == .leftMouseUp {
        player.setSubDelay(sliderValue, forPrimary: isPrimary)
      }
    }
  }

  override func customEditFinishedAction() {
    if input.stringValue.isEmpty {
      input.stringValue = "0"
    }
    let value = input.doubleValue
    player.setSubDelay(value, forPrimary: isPrimary)
    slider.doubleValue = value
    if let window = input.window {
      window.makeFirstResponder(window.contentView)
    }
  }

  override func resetButtonAction() {
    player.setAudioDelay(0)
  }
}


fileprivate class SubPositionDelayView: NSView {
  private unowned let player: PlayerCore
  private let prefObserver = Preference.Observer()
  private var isPrimary = true
  private var isDefaultSnapLatched = false

  private var primarySwitch: NSSegmentedControl!
  private var positionSlider: NSSlider!
  private var delayView: SubDelayView!

  init(player: PlayerCore) {
    self.player = player
    super.init(frame: .zero)

    translatesAutoresizingMaskIntoConstraints = false

    self.primarySwitch = NSSegmentedControl()
    primarySwitch.controlSize = .small
    primarySwitch.segmentCount = 2
    primarySwitch.setLabel(NSLocalizedString("sidebar.primary", comment: ""), forSegment: 0)
    primarySwitch.setLabel(NSLocalizedString("sidebar.secondary", comment: ""), forSegment: 1)
    primarySwitch.selectedSegment = 0
    primarySwitch.target = self
    primarySwitch.action = #selector(switchAction)
    primarySwitch.setContentHuggingPriority(.init(100), for: .horizontal)
    primarySwitch.segmentDistribution = .fillEqually

    self.positionSlider = NSSlider()
    positionSlider.minValue = 0
    positionSlider.maxValue = 150
    positionSlider.numberOfTickMarks = 4
    positionSlider.tickMarkPosition = .below
    positionSlider.allowsTickMarkValuesOnly = false
    positionSlider.controlSize = .small
    positionSlider.target = self
    positionSlider.action = #selector(positionAction)

    positionSlider.tintProminence = .none

    self.delayView = SubDelayView(player: player)

    let stack = ui.vStack(
      spacing: .sidebarItemSpacing,
      wantsToGrow: true,
      primarySwitch,
      ui.space(),
      delayView,
      ui.hStack(
        spacing: 8,
        ui.image("arrow.up.and.down", size: 16, config: .sidebarIconConfig),
        ui.label("sidebar.position", font: .boldSystemFont(ofSize: 12)),
        ui.flexibleSpace(),
      ),
      positionSlider,
    )
    addSubview(stack)
    stack.padding(.all)

    update()
    prefObserver.addAll([.subPos, .secondarySubPos]) { [unowned self] _ in
      updatePosition()
    }
  }

  private func update() {
    updatePosition()
    delayView.update()
  }

  private func updatePosition() {
    let key: Preference.Key = isPrimary ? .subPos : .secondarySubPos
    positionSlider.floatValue = Preference.float(for: key)
  }

  @objc private func switchAction(_ sender: AnyObject) {
    isPrimary = primarySwitch.selectedSegment == 0
    isDefaultSnapLatched = false
    update()
  }

  @objc private func positionAction(_ sender: AnyObject) {
    let canonicalPosition = isPrimary ? 100 : 0
    var position = Int(positionSlider.intValue)
    let distance = abs(position - canonicalPosition)
    if distance <= 2 {
      position = canonicalPosition
      positionSlider.intValue = Int32(position)
      if !isDefaultSnapLatched {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        isDefaultSnapLatched = true
      }
    } else if distance >= 4 {
      isDefaultSnapLatched = false
    }

    player.previewSubPos(position, forPrimary: isPrimary)
    if isInteractionEnding {
      player.setSubPos(position, forPrimary: isPrimary)
      isDefaultSnapLatched = false
    }
  }

  private var isInteractionEnding: Bool {
    guard let eventType = NSApp.currentEvent?.type else { return true }
    return eventType != .leftMouseDown && eventType != .leftMouseDragged
  }
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}


fileprivate class SubStyleView: NSView {
  private unowned let player: PlayerCore
  private let prefObserver = Preference.Observer()

  private var stylePopUp: NSPopUpButton!
  private var stylePreview: SubtitleStylePreviewView!
  private var scaleSlider: NSSlider!
  private var fontChooser: NSButton!
  private var borderSizePicker: NSPopUpButton!
  private var textColorWell: NSColorWell!
  private var backgroundColorWell: NSColorWell!
  private var borderColorWell: NSColorWell!

  init(player: PlayerCore) {
    self.player = player
    super.init(frame: .zero)

    translatesAutoresizingMaskIntoConstraints = false

    self.stylePopUp = NSPopUpButton()
    stylePopUp.controlSize = .small
    stylePopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    stylePopUp.target = self
    stylePopUp.action = #selector(chooseSubStyleAction)
    for style in SubtitleStyleID.allCases {
      let item = NSMenuItem(title: style.localizedName, action: nil, keyEquivalent: "")
      item.tag = style.rawValue
      stylePopUp.menu?.addItem(item)
    }

    self.stylePreview = SubtitleStylePreviewView()
    stylePreview.translatesAutoresizingMaskIntoConstraints = false

    self.scaleSlider = NSSlider()
    scaleSlider.minValue = -2
    scaleSlider.maxValue = 2
    scaleSlider.numberOfTickMarks = 5
    scaleSlider.tickMarkPosition = .below
    scaleSlider.allowsTickMarkValuesOnly = false
    scaleSlider.controlSize = .small
    scaleSlider.target = self
    scaleSlider.action = #selector(scaleAction)
    scaleSlider.neutralValue = 0

    let scaleResetButton = NSButton(
      image: .sf("arrow.counterclockwise.circle.fill")!,
      target: self, action: #selector(scaleResetButtonAction)
    )
    scaleResetButton.bezelStyle = .smallSquare
    scaleResetButton.isBordered = false

    self.fontChooser = NSButton()
    fontChooser.bezelStyle = .push
    fontChooser.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
    fontChooser.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    fontChooser.target = self
    fontChooser.action = #selector(chooseSubFontAction)

    self.borderSizePicker = NSPopUpButton()
    borderSizePicker.addItems(withTitles: [
      "0", "0.25", "0.5", "1", "1.5", "2", "2.5", "3", "4", "5"
    ])
    borderSizePicker.size(width: 60)
    borderSizePicker.target = self
    borderSizePicker.action = #selector(chooseSubBorderSizeAction)

    let scaleStack = ui.hStack(
      spacing: 8,
      ui.image("plus.magnifyingglass", size: 16, config: .sidebarIconConfig),
      ui.label("sidebar.scale", font: .boldSystemFont(ofSize: 12)),
      scaleSlider,
      scaleResetButton,
    )
    scaleStack.size(height: 30)

    let styleStack = ui.hStack(
      spacing: 8,
      ui.image("paintbrush.pointed.fill", size: 16, config: .sidebarIconConfig),
      ui.label("sidebar.style", font: .boldSystemFont(ofSize: 12)),
      ui.flexibleSpace(),
      stylePopUp,
    )
    styleStack.size(height: 24)

    let stack = ui.vStack(
      spacing: .sidebarItemSpacing,
      styleStack,
      stylePreview,
      scaleStack,
      {
        let label = ui.label("sidebar.font", font: .boldSystemFont(ofSize: 12))
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return ui.hStack(
          spacing: 8,
          ui.image("textformat", size: 16, config: .sidebarIconConfig),
          label,
          ui.flexibleSpace(),
          fontChooser,
        )
      }(),
      ui.hStack(
        spacing: 8,
        ui.image("paintpalette.fill", size: 16, config: .sidebarIconConfig),
        ui.label("sidebar.color", font: .boldSystemFont(ofSize: 12)),
        ui.flexibleSpace(),
        createColorWell(\.textColorWell, tag: 1),
      ),
      ui.hStack(
        spacing: 8,
        ui.image("inset.filled.circle.dashed", "circle.dashed.inset.filled", "circle.dashed.inset.fill", size: 16, config: .sidebarIconConfig),
        ui.label("sidebar.border", font: .boldSystemFont(ofSize: 12)),
        ui.flexibleSpace(),
        borderSizePicker,
        createColorWell(\.borderColorWell, tag: 3),
      ),
      ui.hStack(
        spacing: 8,
        ui.image("shadow", size: 16, config: .sidebarIconConfig),
        ui.label("sidebar.shadow", font: .boldSystemFont(ofSize: 12)),
        ui.flexibleSpace(),
        createColorWell(\.backgroundColorWell, tag: 2),
      )
    )

    addSubview(stack)
    stack.padding(.all)

    updateSelectedStyle()
    updateScale()
    updateTextStyle()
    prefObserver.addAll([
      .subTextFont,
      .subTextColorString,
      .subShadowColorString,
      .subBorderSize,
      .subBorderColorString,
      .subBorderStyle,
      .subBold,
      .subItalic,
      .subTextSize,
    ]) { [unowned self] _ in
      self.updateTextStyle()
    }
    prefObserver.add(.subStyle) { [unowned self] _ in
      self.updateSelectedStyle()
    }
    prefObserver.add(.subScale) { [unowned self] _ in
      updateScale()
    }
    player.observe(.yinaSubScaleChanged) { [unowned self] _ in
      updateScale()
    }
  }

  private func createColorWell(_ keyPath: ReferenceWritableKeyPath<SubStyleView, NSColorWell?>, tag: Int) -> NSColorWell {
    let colorWell = NSColorWell()
    colorWell.tag = tag
    colorWell.translatesAutoresizingMaskIntoConstraints = false
    colorWell.colorWellStyle = .expanded
    colorWell.size(height: 24)
    colorWell.target = self
    colorWell.action = #selector(colorAction)
    self[keyPath: keyPath] = colorWell
    return colorWell
  }

  private func updateScale() {
    let currSubScale = player.mpv.getDouble(MPVOption.Subtitles.subScale).clamped(to: 0.1...10)
    scaleSlider.doubleValue = SubtitleScale.sliderValue(for: currSubScale)
  }

  private func updateSelectedStyle() {
    let selected = SubtitleStyleID(rawValue: Preference.integer(for: .subStyle)) ?? .none
    stylePopUp.selectItem(withTag: selected.rawValue)
    updateTextStyle()
  }

  private func updateTextStyle() {
    fontChooser.title = Preference.string(for: .subTextFont) ?? "sans-serif"

    let borderWidth = Preference.float(for: .subBorderSize)
    borderSizePicker.selectItem(at: -1)
    borderSizePicker.itemArray.forEach { item in
      if Double(borderWidth) == Double(item.title) {
        borderSizePicker.select(item)
      }
    }

    for (key, colorWell) in [
      (Preference.Key.subTextColorString, textColorWell),
      (Preference.Key.subBorderColorString, borderColorWell),
      (Preference.Key.subShadowColorString, backgroundColorWell),
    ] {
      if let colorString = Preference.string(for: key),
         let color = NSColor(mpvColorString: colorString) {
        colorWell?.color = color
      }
    }

    stylePreview.preview = SubtitleStyles.Preview.current()
  }

  @objc private func chooseSubStyleAction(_ sender: NSPopUpButton) {
    guard let style = SubtitleStyleID(rawValue: sender.selectedTag()) else { return }
    SubtitleStyles.apply(style)
  }

  @objc private func scaleResetButtonAction(_ sender: AnyObject) {
    player.setSubScale(1)
    scaleSlider.doubleValue = 0
  }

  @objc private func scaleAction(_ sender: AnyObject) {
    let scale = SubtitleScale.scale(for: scaleSlider.doubleValue)
    player.previewSubScale(scale)
    if isInteractionEnding {
      player.setSubScale(scale)
    }
  }

  private var isInteractionEnding: Bool {
    guard let eventType = NSApp.currentEvent?.type else { return true }
    return eventType != .leftMouseDown && eventType != .leftMouseDragged
  }

  @objc func chooseSubFontAction(_ sender: AnyObject) {
    player.chooseSubFont()
  }

  @objc func chooseSubBorderSizeAction(_ sender: AnyObject) {
    guard let title = borderSizePicker.selectedItem?.title, let value = Double(title) else { return }
    player.setSubTextBorderSize(value)
  }

  @objc func colorAction(_ sender: NSColorWell) {
    let color = sender.color.mpvColorString
    switch sender.tag {
    case 1: player.setSubTextColor(color)
    case 2: player.setSubTextBgColor(color)
    case 3: player.setSubTextBorderColor(color)
    default: break
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}


/// A miniature rendering of the current subtitle appearance.
///
/// Picking between "white on black" and "white with an outline" by name alone is hopeless, so the
/// style picker shows the actual result. It reads live preferences rather than the selected
/// profile, which keeps it honest when a profile leaves a knob alone — and makes it double as a
/// live preview of the font, colour, border and shadow controls underneath it.
fileprivate class SubtitleStylePreviewView: NSView {
  var preview: SubtitleStyles.Preview? {
    didSet { needsDisplay = true }
  }

  /// mpv's outline and shadow offsets are in subtitle units; scale them into preview points.
  private static let strokeScale: CGFloat = 1.5
  private static let boxPadding: CGFloat = 8

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: 44)
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = false
  }

  override func draw(_ dirtyRect: NSRect) {
    let bounds = self.bounds
    drawCheckerboard(in: bounds)

    guard let preview else { return }

    let text = NSLocalizedString("sidebar.sub_style_preview", comment: "")
    let strokeWidth = preview.outlineSize * SubtitleStylePreviewView.strokeScale
    let inset = strokeWidth + (preview.isBox ? SubtitleStylePreviewView.boxPadding : 0)

    let textSize = (text as NSString).size(withAttributes: [.font: preview.font])
    let contentWidth = textSize.width + inset * 2
    let contentHeight = textSize.height + inset * 2
    let origin = NSPoint(x: bounds.midX - contentWidth / 2, y: bounds.midY - contentHeight / 2)
    let textRect = NSRect(x: origin.x + inset, y: origin.y + inset,
                          width: textSize.width, height: textSize.height)

    if preview.isBox {
      let boxRect = NSRect(x: origin.x, y: origin.y, width: contentWidth, height: contentHeight)
      // A neutral base first so a translucent box still reads as a box over the checkerboard.
      let box = NSBezierPath(roundedRect: boxRect, xRadius: 5, yRadius: 5)
      NSColor(calibratedWhite: 0.5, alpha: 1).setFill()
      box.fill()
      preview.shadowColor.setFill()
      box.fill()
    }

    // libass layers shadow, then outline, then fill. Match that order so the preview looks like
    // the video does.
    let shadowOffset = preview.shadowSize * SubtitleStylePreviewView.strokeScale
    if shadowOffset > 0, preview.shadowColor.alphaComponent > 0 {
      draw(text, at: textRect.offsetBy(dx: shadowOffset, dy: -shadowOffset), font: preview.font,
           fill: preview.shadowColor, stroke: nil, strokeWidth: 0)
    }
    if strokeWidth > 0 {
      draw(text, at: textRect, font: preview.font, fill: preview.outlineColor,
           stroke: preview.outlineColor, strokeWidth: strokeWidth)
    }
    draw(text, at: textRect, font: preview.font, fill: preview.textColor, stroke: nil,
         strokeWidth: 0)
  }

  private func draw(_ text: String, at rect: NSRect, font: NSFont, fill: NSColor, stroke: NSColor?,
                    strokeWidth: CGFloat) {
    var attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: fill,
      // A negative width makes AppKit fill instead of stroke.
      .strokeWidth: stroke != nil && strokeWidth > 0 ? strokeWidth : -1,
    ]
    if let stroke {
      attributes[.strokeColor] = stroke
    }
    NSAttributedString(string: text, attributes: attributes).draw(in: rect)
  }

  private func drawCheckerboard(in rect: NSRect) {
    let clip = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
    clip.addClip()

    let square: CGFloat = 10
    var row = 0
    var y = rect.minY
    while y < rect.maxY {
      var column = 0
      var x = rect.minX
      while x < rect.maxX {
        if (row + column).isMultiple(of: 2) {
          NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
          NSBezierPath(rect: NSRect(x: x, y: y, width: square, height: square)).fill()
        }
        x += square
        column += 1
      }
      y += square
      row += 1
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
