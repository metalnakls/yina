//
//  Titlebar.swift
//  yina
//
//  Created by Hechen Li on 2026-06-01.
//  Copyright © 2026 lhc. All rights reserved.
//

fileprivate let TitleBarHeightNormal: CGFloat = 32

fileprivate extension LayoutValue {
  static let titlebarHeight = LayoutValue(TitleBarHeightNormal + 8, TitleBarHeightNormal)
  static let oscBottomMargin = LayoutValue(10, 6)
}


class Titlebar: NSView {
  private let accessoryIconConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)

  weak var mainWindow: MainWindowController!

  // A registered native accessory lets NSScrollView provide the system's variable blur.
  private let edgeAccessory = NSTitlebarAccessoryViewController()
  private let titlebarAccessory = NSTitlebarAccessoryViewController()

  override var alphaValue: CGFloat {
    didSet {
      edgeAccessory.view.alphaValue = alphaValue
      titlebarAccessory.view.alphaValue = alphaValue
    }
  }

  override var isHidden: Bool {
    didSet {
      edgeAccessory.isHidden = isHidden
      titlebarAccessory.isHidden = isHidden
    }
  }

  private var onTopButton: NSButton

  private var container: NSStackView!
  private var titlebarContainer: NSView!
  private var titleHeightConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  private var topConstraint: NSLayoutConstraint!
  private var verticalConstraint: NSLayoutConstraint!

  var oscView: TimeLabelOverflowedStackView!
  private var oscContainer: NSView!
  private var oscLeadingConstraint: NSLayoutConstraint!

  init(mainWindow: MainWindowController) {
    self.mainWindow = mainWindow

    let window = mainWindow.window!

    self.onTopButton = NSButton(
      image: .sf("pin", withConfiguration: accessoryIconConfig)!,
      target: mainWindow,
      action: #selector(MainWindowController.ontopButtonAction)
    )

    super.init(frame: .zero)

    translatesAutoresizingMaskIntoConstraints = false

    edgeAccessory.layoutAttribute = .top
    edgeAccessory.automaticallyAdjustsSize = false
    edgeAccessory.preferredScrollEdgeEffectStyle = .soft
    edgeAccessory.view = NSView(frame: NSRect(x: 0, y: 0, width: window.frame.width,
                                             height: TitleBarHeightNormal))
    window.addTitlebarAccessoryViewController(edgeAccessory)

    onTopButton.size(height: 16)
    onTopButton.imageScaling = .scaleProportionallyDown
    onTopButton.translatesAutoresizingMaskIntoConstraints = false
    onTopButton.bezelStyle = .smallSquare
    onTopButton.isBordered = false
    updateOnTopIcon()

    titlebarAccessory.view = onTopButton
    titlebarAccessory.layoutAttribute = .right
    mainWindow.window!.addTitlebarAccessoryViewController(titlebarAccessory)
    window.titleVisibility = .visible

    // The top row reserves the titlebar's content height. AppKit draws the title,
    // proxy icon, and traffic lights in their native positions above this view.
    self.container = NSStackView()
    container.translatesAutoresizingMaskIntoConstraints = false
    addSubview(container)
    container.orientation = .vertical
    container.alignment = .centerX
    container.spacing = 0
    container.padding(.bottom, .leading)
    topConstraint = container.topAnchor.constraint(equalTo: topAnchor)
    topConstraint.isActive = true

    self.trailingConstraint = trailingAnchor
      .constraint(equalTo: container.trailingAnchor)
    trailingConstraint.isActive = true

    self.titlebarContainer = NativeTitlebarSpacerView()
    titlebarContainer.translatesAutoresizingMaskIntoConstraints = false
    container.addArrangedSubview(titlebarContainer)
    titlebarContainer.padding(.horizontal)
    titleHeightConstraint = titlebarContainer.heightAnchor.constraint(equalToConstant: 0)
    LayoutValue.titlebarHeight.use { [weak self] value in
      self?.titleHeightConstraint.constant = value
      self?.edgeAccessory.view.setFrameSize(NSSize(width: self?.bounds.width ?? 0, height: value))
    }
    titleHeightConstraint.isActive = true

    // osc

    self.oscContainer = TitlebarInnerView(titlebar: self)
    oscContainer.translatesAutoresizingMaskIntoConstraints = false
    container.addArrangedSubview(oscContainer)
    self.oscView = TimeLabelOverflowedStackView()
    oscView.translatesAutoresizingMaskIntoConstraints = false
    oscContainer.addSubview(oscView)
    oscView.padding(.trailing(6), .top, .bottom(.oscBottomMargin)).size(height: 24)

    oscLeadingConstraint = oscView.leadingAnchor
      .constraint(equalTo: oscContainer.leadingAnchor, constant: 6)
    oscLeadingConstraint.isActive = true

  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func updateVerticalConstraint(isDisplaying: Bool) {
    guard let superview else { return }
    if let verticalConstraint {
      superview.removeConstraint(verticalConstraint)
    }
    if isDisplaying {
      verticalConstraint = topAnchor.constraint(equalTo: superview.topAnchor)
    } else {
      verticalConstraint = bottomAnchor.constraint(equalTo: superview.topAnchor)
    }
    verticalConstraint.isActive = true
  }

  func update(hasOSC: Bool, inFullScreen: Bool) {
    // when in full screen, the OSC should have a top padding
    topConstraint.constant = inFullScreen ? 8 : 0
    // The title remains native. Only the custom time display follows the OSC state.
    container.setVisibilityPriority(.mustHold, for: titlebarContainer)
    if hasOSC {
      container.setVisibilityPriority(.mustHold, for: oscContainer)
      if inFullScreen {
        container.setVisibilityPriority(.notVisible, for: titlebarContainer)
      }
    } else {
      container.setVisibilityPriority(.notVisible, for: oscContainer)
    }
    window?.titleVisibility = .visible
    // update vertical constraint
    updateVerticalConstraint(isDisplaying: !inFullScreen || hasOSC)
  }

  func updateOnTopIcon() {
    let isOntop = mainWindow.isOntop
    onTopButton.isHidden = Preference.bool(for: .alwaysShowOnTopIcon) ? false : !isOntop
    onTopButton.image = isOntop ?
      .sf("pin.fill", withConfiguration: accessoryIconConfig) :
      .sf("pin", withConfiguration: accessoryIconConfig)
  }

  func setLeadingConstraint(_ constant: CGFloat, animated: Bool = true) {
    if animated {
      oscLeadingConstraint.animator().constant = constant + 6
    } else {
      oscLeadingConstraint.constant = constant + 6
    }
  }

  func setTrailingConstraint(_ constant: CGFloat, animated: Bool = true) {
    if animated {
      trailingConstraint.animator().constant = constant
    } else {
      trailingConstraint.constant = constant
    }
  }

  /// Inner edge (toward the video center) of the sidebar on the given side, in titlebar coords.
  /// Returns `0` for a hidden left sidebar and `w` for a hidden right sidebar so the lead/trail
  /// fade bands collapse to the bar edges.
  private func sidebarInnerEdge(for side: SidebarController.Side, in w: CGFloat) -> CGFloat {
    let panel = mainWindow.sidebars.sideBar(for: side)
    guard !panel.view.isHidden else {
      return side == .leading ? 0 : w
    }
    return side == .leading ? max(0, panel.view.frame.maxX) : min(w, panel.view.frame.minX)
  }
}


/// Keeps the titlebar in sync while the OSC lays out.
fileprivate class NativeTitlebarSpacerView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

fileprivate class TitlebarInnerView: NSView {
  weak var titlebar: Titlebar!

  init(titlebar: Titlebar) {
    self.titlebar = titlebar
    super.init(frame: .zero)
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func layout() {
    super.layout()
    titlebar.needsDisplay = true
  }
}
