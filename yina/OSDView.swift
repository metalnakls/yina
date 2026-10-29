//
//  OSDView.swift
//  yina
//
//  Created by Hechen Li on 2026-05-27.
//  Copyright © 2026 lhc. All rights reserved.
//

import Mustache

class OSDView: TranslucentView {
  var stackView: NSStackView
  var iconView: NSImageView
  var titleStack: NSStackView
  var label: NSTextField
  var secondaryLabel: NSTextField
  var progressBar: FixedProgressBar

  weak var mainWindow: MainWindowController!

  private var accessoryView: NSView?
  private var uiHeadroom: CGFloat = 1
  private var sourceTitle: NSAttributedString?

  init(mainWindow: MainWindowController) {
    self.mainWindow = mainWindow

    self.stackView = NSStackView()
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.orientation = .vertical
    stackView.alignment = .leading
    stackView.spacing = 0

    self.iconView = NSImageView()

    self.label = NSTextField(labelWithString: "")
    label.lineBreakMode = .byTruncatingMiddle
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.init(499), for: .horizontal)

    self.titleStack = NSStackView(views: [iconView, label])
    titleStack.orientation = .horizontal
    titleStack.spacing = 6
    titleStack.alignment = .centerY

    self.secondaryLabel = NSTextField(labelWithString: "")
    secondaryLabel.lineBreakMode = .byTruncatingMiddle
    secondaryLabel.translatesAutoresizingMaskIntoConstraints = false
    secondaryLabel.textColor = .secondaryLabelColor
    secondaryLabel.setContentCompressionResistancePriority(.init(499), for: .horizontal)

    self.progressBar = FixedProgressBar()
    progressBar.translatesAutoresizingMaskIntoConstraints = false
    progressBar.heightAnchor.constraint(equalToConstant: 12).isActive = true
    progressBar.setContentHuggingPriority(.defaultHigh, for: .horizontal)

    super.init(liquidGlassCornerRadius: 16, vevCornerRadius: 10, padding: (16, 8), contentPlacement: .aboveMaterial)

    stackView.addArrangedSubview(titleStack)
    stackView.addArrangedSubview(secondaryLabel)
    stackView.addArrangedSubview(progressBar)
    setContent(stackView)
  }
  
  @MainActor required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func updateViews(fromMessage message: OSDMessage, player: PlayerCore) {
    let textSize = CGFloat(Preference.float(for: .osdTextSize))
    let iconSize = textSize * 0.8
    let smallTextSize = (textSize * 0.9).clamped(to: 11...25)
    let secondaryTextSize = (textSize * 0.5).clamped(to: 11...25)

    // data for mustache rendering
    let duration = player.info.videoDuration
    let position = player.info.videoPosition
    let osdData: [String: String] = [
      "duration": duration?.stringRepresentation ?? Constants.String.videoTimePlaceholder,
      "preciseDuration": duration?.stringRepresentationWithPrecision(3) ?? Constants.String.videoTimePlaceholder,
      "position": position?.stringRepresentation ?? Constants.String.videoTimePlaceholder,
      "precisePosition": position?.stringRepresentationWithPrecision(3) ?? Constants.String.videoTimePlaceholder,
      "currChapter": (player.mpv.getInt(MPVProperty.chapter) + 1).description,
      "chapterCount": player.info.chapters.count.description
    ]

    label.font = NSFont.monospacedDigitSystemFont(ofSize: textSize, weight: .regular)
    secondaryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: secondaryTextSize, weight: .regular)

    let (osdString, osdType) = message.titleAndType()
    let renderedLabel = try! (try! Template(string: osdString)).render(osdData)
    if let attrString = message.attributedTitle(renderedLabel, fontSize: textSize, smallFontSize: smallTextSize) {
      sourceTitle = attrString
      label.attributedStringValue = attrString
    } else {
      sourceTitle = nil
      label.attributedStringValue = NSAttributedString(string: "")
      label.stringValue = renderedLabel
    }

    if let image = message.image(),
       let imageWithConfig = image.withSymbolConfiguration(.init(pointSize: iconSize, weight: .regular)) {
      iconView.image = imageWithConfig
      titleStack.setVisibilityPriority(.mustHold, for: iconView)
    } else {
      titleStack.setVisibilityPriority(.notVisible, for: iconView)
    }

    // Most OSD messages are displayed based on the configured language direction.
    progressBar.userInterfaceLayoutDirection = stackView.userInterfaceLayoutDirection
    secondaryLabel.baseWritingDirection = .natural
    label.baseWritingDirection = .natural

    [secondaryLabel, progressBar].forEach {
      stackView.setVisibilityPriority(.notVisible, for: $0)
    }

    switch osdType {
    case .normal:
      break
    case .withPosition(let value):
      // OSD messages displaying the playback position must always be displayed left to right.
      progressBar.userInterfaceLayoutDirection = .leftToRight
      label.baseWritingDirection = .leftToRight
      fallthrough
    case .withProgress(let value):
      stackView.setVisibilityPriority(.mustHold, for: progressBar)
      progressBar.doubleValue = value
    case .withLeftToRightText(let text):
      // OSD messages displaying the playback position must always be displayed left to right.
      secondaryLabel.baseWritingDirection = .leftToRight
      fallthrough
    case .withText(let text):
      stackView.setVisibilityPriority(.mustHold, for: secondaryLabel)
      secondaryLabel.stringValue = try! (try! Template(string: text)).render(osdData)
    }
    updateHDRColors()
  }

  override func setContentExtendedDynamicRange(_ enabled: Bool, headroom: CGFloat) {
    uiHeadroom = enabled ? headroom : 1
    super.setContentExtendedDynamicRange(enabled, headroom: headroom)
    updateHDRColors()
  }

  private func updateHDRColors() {
    label.textColor = OSCExtendedDynamicRange.color(.labelColor, headroom: uiHeadroom)
    secondaryLabel.textColor = OSCExtendedDynamicRange.color(.secondaryLabelColor, headroom: uiHeadroom)
    iconView.contentTintColor = OSCExtendedDynamicRange.color(.labelColor, headroom: uiHeadroom)
    progressBar.fillColor = OSCExtendedDynamicRange.color(.controlAccentColor, headroom: uiHeadroom)
    if let sourceTitle {
      let title = NSMutableAttributedString(attributedString: sourceTitle)
      sourceTitle.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: sourceTitle.length)) { color, range, _ in
        title.addAttribute(.foregroundColor, value: OSCExtendedDynamicRange.color(color as? NSColor ?? .labelColor,
                                                                                headroom: uiHeadroom), range: range)
      }
      label.attributedStringValue = title
    }
  }

  func addAccessoryView(_ view: NSView) {
    removeAccessoryView()
    stackView.addArrangedSubview(view)
    view.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
    accessoryView = view
  }

  func removeAccessoryView() {
    guard let accessoryView else { return }
    if stackView.subviews.contains(accessoryView) {
      stackView.removeArrangedSubview(accessoryView)
      accessoryView.removeFromSuperview()
    }
  }
}
