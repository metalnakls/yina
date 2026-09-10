//
//  SidebarLayoutPane.swift
//  iina
//
//  Created by Hechen Li on 2026-06-03.
//  Copyright © 2026 lhc. All rights reserved.
//


fileprivate extension LayoutValue {
  static let sidebarSettingsSpacing = LayoutValue(10, 6)
  static let liquidGlassSettingsSpacing = LayoutValue(6, 5)
}


fileprivate let ui = UIHelper.shared


class SidebarLayoutPane: SidebarScrollView {
  let prefObserver = Preference.Observer()
  weak var player: PlayerCore!

  private var videoSettingsStack: NSStackView!
  private var themeSettingStack: NSStackView!
  private var lockAspectSwitch: NSSwitch!
  private var lockWindowAspectStack: NSStackView!
  private var dockedUIStack: NSStackView!
  private var oscLayoutSelector: OSCLayoutSelector!
  private var removeBlackBarBtn: SideBarButton!

  init(player: PlayerCore) {
    self.player = player
    super.init(frame: .zero)

    let stack = ui.vStack(spacing: .sidebarStackViewSpacing)

    themeSettingStack = ui.vStack(
      spacing: .sidebarItemSpacing,
      ui.hStack(
        ui.image("circle.lefthalf.filled", "circle.lefthalf.fill", size: 20, config: .sidebarIconConfig),
        ui.label("settings.themeMaterial.desc"),
        ui.flexibleSpace(),
        ThemeSwitch(.themeMaterial),
      )
    )

    themeSettingStack.addArrangedSubview(ui.vStack(
        spacing: .sidebarItemSpacing,
        ui.hStack(
          ui.image("capsule.on.rectangle.liquid.glass", "liquid.glass", size: 20, config: .sidebarIconConfig),
          ui.label("sidebar.liquid_glass"),
          ui.flexibleSpace(),
        ),
        ui.vStack(
          spacing: .liquidGlassSettingsSpacing,
          ui.hStack(
            ui.space(),
            ui.image("osd", size: 16, config: .sidebarIconConfig),
            ui.label("settings.$OnScreenDisplay", isSmall: true),
            ui.flexibleSpace(),
            ui.toggleButton(bindTo: .useLiquidGlassOSD, size: .mini)
          ),
          ui.hStack(
            ui.space(),
            ui.image("osc.floating", size: 16, config: .sidebarIconConfig),
            ui.label("settings.$OnScreenController", isSmall: true),
            ui.flexibleSpace(),
            ui.toggleButton(bindTo: .useLiquidGlassOSC, size: .mini)
          ),
          ui.hStack(
            ui.space(),
            ui.image("sidebar.squares.trailing", size: 16, config: .sidebarIconConfig),
            ui.label("sidebar.sidebar", isSmall: true),
            ui.flexibleSpace(),
            ui.toggleButton(bindTo: .useLiquidGlassSidebar, size: .mini)
          ),
        )
    ))

    stack.addArrangedSubview(Container(themeSettingStack) {
      $0.padding(.all(.sidebarContainerPadding))
    })

    stack.addArrangedSubview(Container(ui.hStack(
      ui.image("rectangle.grid.3x2.fill", size: 20, config: .sidebarIconConfig),
      ui.label("sidebar.compact_interface"),
      ui.flexibleSpace(),
      ui.toggleButton(bindTo: .compactUI, size: .small)
    )) {
      $0.padding(.all(.sidebarContainerPadding))
    })

    videoSettingsStack = ui.vStack(spacing: .sidebarItemSpacing)

    videoSettingsStack.addArrangedSubview(ui.hStack(
      ui.image("custom.arrow.up.left.and.down.right.and.arrow.up.right.and.down.left.rectangle",
               size: 20, config: .sidebarIconConfig),
      ui.label("sidebar.edge_to_edge_video"),
      ui.flexibleSpace(),
      ui.toggleButton(bindTo: .edgeToEdgeVideo, size: .small)
    ))

    self.lockWindowAspectStack = ui.hStack(
      ui.image("custom.lock.rectangle", size: 20, config: .sidebarIconConfig),
      ui.label("sidebar.lock_window_aspect"),
      ui.flexibleSpace(),
      ui.toggleButton(bindTo: .unlockWindowAspectRatio, size: .small, inverted: true)
    )
    videoSettingsStack.addArrangedSubview(lockWindowAspectStack)

    self.dockedUIStack = ui.hStack(
      ui.image("dock.arrow.down.rectangle", size: 20, config: .sidebarIconConfig),
      ui.label("sidebar.docked"),
      ui.flexibleSpace(),
      ui.toggleButton(bindTo: .dockedControlBarAndTitlebar, size: .small)
    )
    videoSettingsStack.addArrangedSubview(dockedUIStack)

    self.removeBlackBarBtn = SideBarButton(ui.localized("sidebar.fit_window_to_video"), image: .removeBlackbars)
    removeBlackBarBtn.target = self
    removeBlackBarBtn.action = #selector(removeBlackBars)
    removeBlackBarBtn.size(height: 32)
    videoSettingsStack.addArrangedSubview(removeBlackBarBtn)
    removeBlackBarBtn.padding(.horizontal)

    updateVideoSettingsStack()

    stack.addArrangedSubview(Container(videoSettingsStack) {
      $0.padding(.all(.sidebarContainerPadding))
    })

    stack.addArrangedSubview(createOSCSettingsView())

    stack.addArrangedSubview(createSidebarSettingsView())

    prefObserver.addAll(
      .edgeToEdgeVideo,
      .unlockWindowAspectRatio,
      .dockedControlBarAndTitlebar,
    ) { [unowned self] _ in
      updateVideoSettingsStack()
    }

    documentView!.addSubview(stack)
    stack.padding(.horizontal(.sidebarMargin), .vertical(4))
  }
  
  @MainActor required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func updateVideoSettingsStack() {
    if Preference.bool(for: .edgeToEdgeVideo) {
      videoSettingsStack.setVisibilityPriority(.mustHold, for: lockWindowAspectStack)
      videoSettingsStack.setVisibilityPriority(.notVisible, for: dockedUIStack)
    } else {
      videoSettingsStack.setVisibilityPriority(.notVisible, for: lockWindowAspectStack)
      videoSettingsStack.setVisibilityPriority(.mustHold, for: dockedUIStack)
    }
    // remove black bar button
    if Preference.unlockWindowAspectRatio {
      videoSettingsStack.setVisibilityPriority(.mustHold, for: removeBlackBarBtn)
    } else {
      videoSettingsStack.setVisibilityPriority(.notVisible, for: removeBlackBarBtn)
    }
  }

  @objc private func removeBlackBars(_ sender: AnyObject) {
    player.mainWindow.removeVideoViewBlackBars()
  }

  private func createOSCSettingsView() -> NSView {
    let container = NSView()
    container.setContentHuggingPriority(.init(200), for: .horizontal)

    self.oscLayoutSelector = OSCLayoutSelector()

    let label = createSectionTitle("settings.$OnScreenController")
    let stack = ui.hStack(oscLayoutSelector.views)
    stack.distribution = .fillEqually

    container.addSubview(label)
    container.addSubview(stack)
    let tuning = ui.vStack(spacing: 12, OSCDissolveTuningView(), SubtitleDissolveTuningView())
    container.addSubview(tuning)
    label.padding(.top, .leading, .trailing(greaterThan: 0))
    stack.padding(.horizontal(greaterThan: 0)).center(.x)
      .spacing(.top(.sidebarStackViewSpacing), to: label)
    tuning.padding(.bottom(8), .horizontal)
      .spacing(.top(.sidebarItemSpacing), to: stack)

    return container
  }

  private func createSectionTitle(_ text: String) -> NSView {
    func separator() -> NSBox {
      let box = NSBox()
      box.boxType = .separator
      box.size(height: 1)
      return box
    }

    let a = separator()
    let b = separator()

    let label = ui.hStack(
      a,
      ui.label(text, font: .boldSystemFont(ofSize: 12), isSecondary: true),
      b,
    )
    a.widthAnchor.constraint(equalTo: b.widthAnchor).isActive = true
    return label
  }

  private func createSidebarSettingsView() -> NSView {
    let container = NSView()
    container.setContentHuggingPriority(.init(200), for: .horizontal)

    let label = createSectionTitle("sidebar.sidebar_position")
    let config = [
      ("gearshape.fill", "sidebar.settings", Preference.Key.sidebarSettingsDisplayAtLeading),
      ("list.bullet.rectangle.fill", "sidebar.playlist_and_chapters", Preference.Key.sidebarPlaylistDisplayAtLeading),
      ("puzzlepiece.extension.fill", "sidebar.plugins", Preference.Key.sidebarPluginsDisplayAtLeading),
    ]
    let stack = Container(ui.vStack(
      spacing: .sidebarSettingsSpacing,
      config.map { img, text, key in
        ui.hStack(
          ui.image(img, config: .sidebarIconConfig),
          ui.label(text),
          ui.flexibleSpace(),
          SidebarPosSwitch(key),
        )
      }
    )) {
      $0.padding(.all(.sidebarContainerPadding))
    }

    container.addSubview(label)
    container.addSubview(stack)
    label.padding(.top, .leading, .trailing(greaterThan: 0))
    stack.padding(.bottom(8), .horizontal)
      .spacing(.top(.sidebarStackViewSpacing), to: label)

    return container
  }
}


fileprivate final class OSCDissolveTuningView: NSStackView {
  private struct Setting {
    let title: String
    let key: Preference.Key
    let range: ClosedRange<Double>
    let step: Double
    let valueText: (Double) -> String
  }

  private let settings: [Setting] = [
    Setting(title: "sidebar.osc_appear_speed", key: .oscDissolveAppearDuration,
            range: 0.05...0.75, step: 0.01,
            valueText: { "\(Int(($0 * 1000).rounded())) ms" }),
    Setting(title: "sidebar.osc_disappear_speed", key: .oscDissolveDisappearDuration,
            range: 0.05...1.0, step: 0.01,
            valueText: { "\(Int(($0 * 1000).rounded())) ms" }),
    Setting(title: "sidebar.osc_blur_radius", key: .oscDissolveBlurRadius,
            range: 0...48, step: 1,
            valueText: { "\(Int($0.rounded())) pt" }),
  ]

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    orientation = .vertical
    alignment = .leading
    spacing = 8

    addArrangedSubview(ui.label("sidebar.osc_tuning", font: .boldSystemFont(ofSize: 11), isSecondary: true))

    for (index, setting) in settings.enumerated() {
      let slider = NSSlider(value: Double(Preference.float(for: setting.key)),
                            minValue: setting.range.lowerBound,
                            maxValue: setting.range.upperBound,
                            target: self,
                            action: #selector(sliderChanged(_:)))
      slider.controlSize = .small
      slider.isContinuous = true
      slider.tag = index
      slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
      slider.setContentHuggingPriority(.defaultLow, for: .horizontal)

      let value = ui.label(setting.valueText(slider.doubleValue), isSmall: true,
                           isSecondary: true, canCompress: false)
      value.identifier = NSUserInterfaceItemIdentifier("oscDissolveTuningValue")
      value.alignment = .right
      value.widthAnchor.constraint(equalToConstant: 52).isActive = true

      let row = ui.hStack(
        ui.label(setting.title, isSmall: true),
        ui.flexibleSpace(4),
        slider,
        value
      )
      addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    let curve = DissolveCurveTuningView(easingKey: .oscDissolveEasing, overshootKey: .oscDissolveOvershoot)
    addArrangedSubview(curve)
    curve.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
  }

  @objc private func sliderChanged(_ sender: NSSlider) {
    let setting = settings[sender.tag]
    let steppedValue = (sender.doubleValue / setting.step).rounded() * setting.step
    sender.doubleValue = steppedValue
    Preference.set(Float(steppedValue), for: setting.key)

    guard let row = sender.superview as? NSStackView,
          let value = row.arrangedSubviews.compactMap({ $0 as? NSTextField }).last else { return }
    value.stringValue = setting.valueText(steppedValue)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}


fileprivate final class SubtitleDissolveTuningView: NSStackView, NSTextFieldDelegate {
  private struct Setting {
    let title: String
    let key: Preference.Key
    let scale: Double
    let maximum: Double
    let unit: String
  }

  private let settings = [
    Setting(title: "sidebar.sub_fade_in", key: .subDissolveAppearDuration,
            scale: 1000, maximum: 60000, unit: "ms"),
    Setting(title: "sidebar.sub_fade_out", key: .subDissolveDisappearDuration,
            scale: 1000, maximum: 60000, unit: "ms"),
    Setting(title: "sidebar.sub_extra_blur", key: .subDissolveBlurRadius,
            scale: 1, maximum: 20, unit: ""),
  ]
  private var sliders: [NSSlider] = []
  private var fields: [NSTextField] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    orientation = .vertical
    alignment = .leading
    spacing = 8
    addArrangedSubview(ui.label("sidebar.sub_tuning", font: .boldSystemFont(ofSize: 11), isSecondary: true))

    for (index, setting) in settings.enumerated() {
      let stored = Double(Preference.float(for: setting.key)) * setting.scale
      let initial = stored.isFinite ? min(max(stored, 0), setting.maximum) : 0
      let slider = NSSlider(value: initial, minValue: 0,
                            maxValue: setting.scale == 1 ? setting.maximum : max(2000, initial),
                            target: self, action: #selector(sliderChanged(_:)))
      slider.controlSize = .small
      slider.isContinuous = true
      slider.tag = index
      slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
      slider.setContentHuggingPriority(.defaultLow, for: .horizontal)

      let formatter = NumberFormatter()
      formatter.numberStyle = .decimal
      formatter.usesGroupingSeparator = false
      formatter.minimum = 0
      formatter.maximum = NSNumber(value: setting.maximum)
      formatter.maximumFractionDigits = setting.scale == 1 ? 2 : 0
      let field = NSTextField()
      field.formatter = formatter
      field.doubleValue = initial
      field.controlSize = .small
      field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      field.alignment = .right
      field.tag = index
      field.delegate = self
      field.target = self
      field.action = #selector(valueChanged(_:))
      field.widthAnchor.constraint(equalToConstant: 60).isActive = true
      let title = NSLocalizedString(setting.title, comment: "")
      field.setAccessibilityLabel("\(title) \(setting.unit)")
      slider.setAccessibilityLabel(title)
      fields.append(field)
      sliders.append(slider)

      let row = ui.hStack(ui.label(setting.title, isSmall: true), ui.flexibleSpace(4),
                         slider, field, ui.label(setting.unit, isSmall: true, isSecondary: true))
      addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    let curve = DissolveCurveTuningView(easingKey: .subDissolveEasing, overshootKey: .subDissolveOvershoot)
    addArrangedSubview(curve)
    curve.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
  }

  @objc private func sliderChanged(_ sender: NSSlider) {
    let precision = settings[sender.tag].scale == 1 ? 100.0 : 1.0
    let value = (sender.doubleValue * precision).rounded() / precision
    fields[sender.tag].doubleValue = value
    save(value, at: sender.tag)
  }

  @objc private func valueChanged(_ sender: NSTextField) {
    save(sender.doubleValue, at: sender.tag)
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    guard let field = notification.object as? NSTextField else { return }
    valueChanged(field)
  }

  private func save(_ value: Double, at index: Int) {
    let setting = settings[index]
    guard value.isFinite else { return }
    let clamped = min(max(value, 0), setting.maximum)
    fields[index].doubleValue = clamped
    sliders[index].maxValue = setting.scale == 1 ? setting.maximum : max(2000, clamped)
    sliders[index].doubleValue = clamped
    Preference.set(Float(clamped / setting.scale), for: setting.key)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}


fileprivate final class DissolveCurveTuningView: NSStackView, NSTextFieldDelegate {
  private let easingKey: Preference.Key
  private let overshootKey: Preference.Key

  init(easingKey: Preference.Key, overshootKey: Preference.Key) {
    self.easingKey = easingKey
    self.overshootKey = overshootKey
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    orientation = .vertical
    alignment = .leading
    spacing = 8

    let picker = NSPopUpButton()
    picker.controlSize = .small
    for easing in DissolveEasing.allCases {
      picker.addItem(withTitle: NSLocalizedString(easing.titleKey, comment: ""))
      picker.lastItem?.tag = easing.rawValue
    }
    picker.selectItem(withTag: Preference.integer(for: easingKey))
    picker.target = self
    picker.action = #selector(easingChanged(_:))
    picker.setAccessibilityLabel(NSLocalizedString("sidebar.blur_easing", comment: ""))

    let field = NSTextField()
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimum = 0
    formatter.maximum = 100
    formatter.maximumFractionDigits = 1
    field.formatter = formatter
    field.doubleValue = Double(Preference.float(for: overshootKey)) * 100
    field.controlSize = .small
    field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    field.alignment = .right
    field.widthAnchor.constraint(equalToConstant: 60).isActive = true
    field.target = self
    field.action = #selector(overshootChanged(_:))
    field.delegate = self
    field.setAccessibilityLabel(NSLocalizedString("sidebar.blur_overshoot", comment: "") + " %")

    for row in [ui.hStack(ui.label("sidebar.blur_easing", isSmall: true), ui.flexibleSpace(), picker),
                ui.hStack(ui.label("sidebar.blur_overshoot", isSmall: true), ui.flexibleSpace(),
                          field, ui.label("%", isSmall: true, isSecondary: true))] {
      addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
  }

  @objc private func easingChanged(_ sender: NSPopUpButton) {
    guard let item = sender.selectedItem else { return }
    Preference.set(item.tag, for: easingKey)
  }

  @objc private func overshootChanged(_ sender: NSTextField) {
    guard sender.doubleValue.isFinite else { return }
    let value = min(max(sender.doubleValue, 0), 100)
    sender.doubleValue = value
    Preference.set(Float(value / 100), for: overshootKey)
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    guard let field = notification.object as? NSTextField else { return }
    overshootChanged(field)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}


fileprivate class SideBarButton: NSView {
  weak var target: AnyObject?
  var action: Selector?

  var isHighlighted = false {
    didSet {
      (layer as? CAGradientLayer)?.colors = [
        NSColor.gray.withAlphaComponent(isHighlighted ? 0.15 : 0.1).cgColor,
        NSColor.gray.withAlphaComponent(isHighlighted ? 0.2 : 0.15).cgColor
      ]
    }
  }

  init(_ text: String, image: NSImage? = nil) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    let background = CAGradientLayer()
    background.borderColor = NSColor.sidebarContainerBorder.cgColor
    background.borderWidth = 1
    background.cornerRadius = 8
    background.colors = [
      NSColor.gray.withAlphaComponent(0.1).cgColor,
      NSColor.gray.withAlphaComponent(0.15).cgColor
    ]
    background.locations = [0, 1]
    background.startPoint = .zero
    background.endPoint = .init(x: 0, y: 1)
    layer = background

    let container = NSStackView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.orientation = .horizontal
    container.spacing = 8
    container.alignment = .firstBaseline
    if let image {
      let imageView = NSImageView(image: image)
      container.addArrangedSubview(imageView)
    }
    let label = NSTextField(labelWithString: text)
    container.addArrangedSubview(label)

    addSubview(container)
    container.center()
  }

  override func mouseDown(with event: NSEvent) {
    isHighlighted = true
  }

  override func mouseUp(with event: NSEvent) {
    isHighlighted = false
    let pt = convert(event.locationInWindow, from: nil)
    guard bounds.contains(pt), let target, let action else { return }
    NSApp.sendAction(action, to: target, from: self)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}


fileprivate class OSCLayoutSelector: NSBox {
  class Item: NSBox {
    let position: Preference.OSCPosition

    init(_ position: Preference.OSCPosition) {
      self.position = position
      super.init(frame: .zero)
      translatesAutoresizingMaskIntoConstraints = false
      boxType = .custom
      cornerRadius = 8
    }
    
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }
    
    var isActive: Bool = false {
      didSet {
        animator().borderColor = isActive ? .controlAccentColor : .sidebarContainerBorder
        animator().borderWidth = isActive ? 2 : 1
        animator().fillColor = isActive ? .controlAccentColor.withAlphaComponent(0.1) :
          .gray.withAlphaComponent(0.1)
      }
    }

    override func mouseDown(with event: NSEvent) {
      Preference.set(position.rawValue, for: .oscPosition)
    }
  }

  var views: [Item]!
  private let prefObserver = Preference.Observer()

  init() {
    super.init(frame: .zero)

    self.views = Preference.OSCPosition.allCases.map(createView)

    prefObserver.add(.oscPosition, runNow: true) { [unowned self] _ in updateItems() }
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func updateItems() {
    guard let position = Preference.OSCPosition(key: .oscPosition) else { return }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.1
      views.forEach {
        $0.isActive = $0.position == position
      }
    }
  }

  private func createView(_ position: Preference.OSCPosition) -> Item {
    let content = ui.vStack(
      align: .centerX,
      ui.image("osc.\(position.description)", width: 40, height: 28, scaleUp: true),
      ui.label(NSLocalizedString("osc_pos.\(position.description)", comment: ""), isSmall: true)
    )
    content.distribution = .fillEqually
    let item = Item(position)
    item.contentView = content
    content.padding(.all(12))
    return item
  }
}


fileprivate class ThemeSwitch: NSSegmentedControl {
  private let key: Preference.Key
  let prefObserver = Preference.Observer()

  init(_ key: Preference.Key) {
    self.key = key
    super.init(frame: .zero)

    segmentCount = 3
    setTag(0, forSegment: 0)
    setTag(2, forSegment: 1)
    setTag(4, forSegment: 2)
    setLabel(ui.localized("settings.themeMaterial.items.0"), forSegment: 0)
    setLabel(ui.localized("settings.themeMaterial.items.2"), forSegment: 1)
    setLabel(ui.localized("general.auto"), forSegment: 2)

    prefObserver.add(key, runNow: true) { [unowned self] _ in
      selectSegment(withTag: Preference.integer(for: key))
    }
  }

  override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
    Preference.set(selectedTag(), for: key)
    return true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}


fileprivate class SidebarPosSwitch: NSSegmentedControl {
  private let key: Preference.Key
  let prefObserver = Preference.Observer()

  init(_ key: Preference.Key) {
    self.key = key
    super.init(frame: .zero)

    segmentCount = 2
    setTag(0, forSegment: 0)
    setTag(1, forSegment: 1)
    setImage(.sf("sidebar.leading"), forSegment: 0)
    setImage(.sf("sidebar.trailing"), forSegment: 1)

    prefObserver.add(key, runNow: true) { [unowned self] _ in
      selectSegment(withTag: Preference.bool(for: key) ? 0 : 1)
    }
  }

  override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
    let isLeading = (selectedTag() == 0)
    Preference.set(isLeading, for: key)
    return true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
