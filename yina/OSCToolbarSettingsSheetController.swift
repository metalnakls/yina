//
//  OSCToolbarSettingsSheetController.swift
//  yina
//
//  Created by Collider LI on 4/2/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Cocoa

extension NSPasteboard.PasteboardType {
  static let yinaOSCAvailableToolbarButtonType = NSPasteboard.PasteboardType("com.collider.yina.yinaOSCAvailableToolbarButtonType")
  static let yinaOSCCurrentToolbarButtonType = NSPasteboard.PasteboardType("com.collider.yina.yinaOSCCurrentToolbarButtonType")
}

class ToolbarSettingsSheetWindow: NSWindow {
  override var canBecomeKey: Bool { return true }
}

class OSCToolbarSettingsSheetController: NSWindowController, OSCToolbarCurrentItemsViewDelegate {
  var currentButtonTypes: [Preference.ToolBarButton] = []
  private var itemViewControllers: [OSCToolbarDraggingItemViewController] = []

  var availableItemsView: OSCToolbarAvailableItemsView!
  var currentItemsView: OSCToolbarCurrentItemsView!

  private enum LocalizedString {
    static let currentItemsHeading = "rNU-8V-iQt.title"
    static let currentItemsHint = "jlb-xc-k6x.title"
    static let availableItemsHeading = "DeE-Yj-Q4D.title"
    static let availableItemsHint = "VCG-VX-E3M.title"
    static let restoreDefault = "SmC-AI-FG6.title"
    static let cancel = "Jrf-II-Cfc.title"
    static let done = "0wJ-C7-Gds.title"

    static func value(_ key: String, fallback: String) -> String {
      NSLocalizedString(key,
                        tableName: "OSCToolbarSettingsSheetController",
                        bundle: .main,
                        value: fallback,
                        comment: "")
    }
  }

  override init(window: NSWindow?) {
    let sheetWindow = window ?? ToolbarSettingsSheetWindow(
      contentRect: NSRect(x: 0, y: 0, width: 425, height: 355),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    availableItemsView = OSCToolbarAvailableItemsView()
    currentItemsView = OSCToolbarCurrentItemsView()
    super.init(window: sheetWindow)
    configureWindow(sheetWindow)
  }

  convenience init() {
    self.init(window: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func configureWindow(_ window: NSWindow) {
    window.title = "Toolbar Settings"
    window.isReleasedWhenClosed = false
    window.titlebarSeparatorStyle = .none

    let contentView = NSView()
    contentView.wantsLayer = true
    window.contentView = contentView

    let currentItemsHeading = NSTextField(labelWithString: LocalizedString.value(
      LocalizedString.currentItemsHeading,
      fallback: "Current Items:"
    ))
    let currentItemsHint = NSTextField(labelWithString: LocalizedString.value(
      LocalizedString.currentItemsHint,
      fallback: "Drag an item out of the box to delete it."
    ))
    let availableItemsHeading = NSTextField(labelWithString: LocalizedString.value(
      LocalizedString.availableItemsHeading,
      fallback: "Available Items:"
    ))
    let availableItemsHint = NSTextField(labelWithString: LocalizedString.value(
      LocalizedString.availableItemsHint,
      fallback: "Drag an item and drop it to the box above to add it."
    ))

    for label in [currentItemsHeading, availableItemsHeading] {
      label.translatesAutoresizingMaskIntoConstraints = false
    }
    for hint in [currentItemsHint, availableItemsHint] {
      hint.translatesAutoresizingMaskIntoConstraints = false
      hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      hint.textColor = .secondaryLabelColor
      hint.lineBreakMode = .byClipping
    }

    let currentItemsBox = NSBox()
    currentItemsBox.translatesAutoresizingMaskIntoConstraints = false
    currentItemsBox.boxType = .primary
    currentItemsBox.titlePosition = .noTitle
    currentItemsBox.contentViewMargins = .zero

    let currentItemsContentView = NSView()
    currentItemsContentView.translatesAutoresizingMaskIntoConstraints = false
    currentItemsBox.contentView = currentItemsContentView
    currentItemsView.translatesAutoresizingMaskIntoConstraints = false
    currentItemsContentView.addSubview(currentItemsView)
    let currentItemsHeightConstraint = currentItemsView.heightAnchor.constraint(equalTo: currentItemsContentView.heightAnchor)
    currentItemsHeightConstraint.priority = .init(900)

    availableItemsView.translatesAutoresizingMaskIntoConstraints = false
    availableItemsView.orientation = .vertical
    availableItemsView.alignment = .leading
    availableItemsView.spacing = 4

    let restoreDefaultButton = NSButton(
      title: LocalizedString.value(LocalizedString.restoreDefault, fallback: "Restore Default"),
      target: self,
      action: #selector(restoreDefaultButtonAction(_:))
    )
    let cancelButton = NSButton(
      title: LocalizedString.value(LocalizedString.cancel, fallback: "Cancel"),
      target: self,
      action: #selector(cancelButtonAction(_:))
    )
    let doneButton = NSButton(
      title: LocalizedString.value(LocalizedString.done, fallback: "Done"),
      target: self,
      action: #selector(okButtonAction(_:))
    )
    restoreDefaultButton.translatesAutoresizingMaskIntoConstraints = false
    cancelButton.translatesAutoresizingMaskIntoConstraints = false
    doneButton.translatesAutoresizingMaskIntoConstraints = false
    cancelButton.keyEquivalent = "\u{1b}"
    doneButton.keyEquivalent = "\r"

    for view in [currentItemsHeading, currentItemsHint, currentItemsBox,
                 availableItemsHeading, availableItemsHint, availableItemsView!,
                 restoreDefaultButton, cancelButton, doneButton] {
      contentView.addSubview(view)
    }

    NSLayoutConstraint.activate([
      currentItemsHeading.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      currentItemsHeading.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
      currentItemsHint.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      currentItemsHint.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      currentItemsHint.topAnchor.constraint(equalTo: currentItemsHeading.bottomAnchor, constant: 4),

      currentItemsBox.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      currentItemsBox.topAnchor.constraint(equalTo: currentItemsHint.bottomAnchor, constant: 10),
      currentItemsBox.widthAnchor.constraint(equalTo: currentItemsBox.heightAnchor, multiplier: 5),
      currentItemsBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),

      currentItemsView.centerXAnchor.constraint(equalTo: currentItemsContentView.centerXAnchor),
      currentItemsView.centerYAnchor.constraint(equalTo: currentItemsContentView.centerYAnchor),
      currentItemsView.widthAnchor.constraint(equalTo: currentItemsView.heightAnchor, multiplier: 5),
      currentItemsView.heightAnchor.constraint(lessThanOrEqualTo: currentItemsContentView.heightAnchor),
      currentItemsHeightConstraint,

      availableItemsHeading.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      availableItemsHeading.topAnchor.constraint(equalTo: currentItemsBox.bottomAnchor, constant: 20),
      availableItemsHint.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      availableItemsHint.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      availableItemsHint.topAnchor.constraint(equalTo: availableItemsHeading.bottomAnchor, constant: 4),
      availableItemsView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      availableItemsView.topAnchor.constraint(equalTo: availableItemsHint.bottomAnchor, constant: 10),
      availableItemsView.widthAnchor.constraint(equalToConstant: 240),

      restoreDefaultButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      restoreDefaultButton.topAnchor.constraint(equalTo: availableItemsView.bottomAnchor, constant: 20),
      restoreDefaultButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
      cancelButton.leadingAnchor.constraint(greaterThanOrEqualTo: restoreDefaultButton.trailingAnchor, constant: 8),
      cancelButton.firstBaselineAnchor.constraint(equalTo: restoreDefaultButton.firstBaselineAnchor),
      doneButton.leadingAnchor.constraint(equalTo: cancelButton.trailingAnchor, constant: 12),
      doneButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      doneButton.firstBaselineAnchor.constraint(equalTo: restoreDefaultButton.firstBaselineAnchor),
      doneButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
    ])

    currentItemsView.registerForDraggedTypes([.yinaOSCAvailableToolbarButtonType, .yinaOSCCurrentToolbarButtonType])
    currentItemsView.currentItemsViewDelegate = self
    currentItemsView.initItems(fromItems: OSCToolbarConfiguration.items)

    var allButtonTypes: [Preference.ToolBarButton] = [.volume, .settings, .playlist, .pip, .fullScreen, .musicMode, .subTrack, .screenshot, .plugins]
    allButtonTypes.append(.liveText)
    for type in allButtonTypes {
      let itemViewController = OSCToolbarDraggingItemViewController(buttonType: type)
      itemViewController.availableItemsView = availableItemsView
      itemViewControllers.append(itemViewController)
      itemViewController.view.translatesAutoresizingMaskIntoConstraints = false
      availableItemsView.addView(itemViewController.view, in: .top)
    }
  }

  func currentItemsView(_ view: OSCToolbarCurrentItemsView, updatedItems items: [Preference.ToolBarButton]) {
    currentButtonTypes = items
  }

  @objc func okButtonAction(_ sender: Any) {
    endSheet(with: .OK)
  }

  @objc func cancelButtonAction(_ sender: Any) {
    endSheet(with: .cancel)
  }

  @objc func restoreDefaultButtonAction(_ sender: Any) {
    currentButtonTypes = [.volume] + (Preference.defaultPreference[.controlBarToolbarButtons] as! [Int]).compactMap(Preference.ToolBarButton.init(rawValue:))
    currentItemsView.initItems(fromItems: currentButtonTypes)
  }

  private func endSheet(with returnCode: NSApplication.ModalResponse) {
    guard let window, let sheetParent = window.sheetParent else { return }
    sheetParent.endSheet(window, returnCode: returnCode)
  }
}


class OSCToolbarCurrentItem: NSButton, NSPasteboardWriting {

  var currentItemsView: OSCToolbarCurrentItemsView
  var buttonType: Preference.ToolBarButton

  init(buttonType: Preference.ToolBarButton, superView: OSCToolbarCurrentItemsView) {
    self.buttonType = buttonType
    self.currentItemsView = superView
    super.init(frame: .zero)

    OSCToolbarButton.setStyle(of: self, buttonType: buttonType)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
    return [.yinaOSCCurrentToolbarButtonType]
  }

  func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
    if type == .yinaOSCCurrentToolbarButtonType {
      return buttonType.rawValue
    }
    return nil
  }

  override func mouseDown(with event: NSEvent) {
    guard let dragItem = OSCToolbarButton.buildDragItem(from: self, pasteboardWriter: self, buttonType: buttonType) else { return }

    currentItemsView.itemBeingDragged = self
    beginDraggingSession(with: [dragItem], event: event, source: currentItemsView)
  }

}


protocol OSCToolbarCurrentItemsViewDelegate {

  func currentItemsView(_ view: OSCToolbarCurrentItemsView, updatedItems items: [Preference.ToolBarButton])

}


class OSCToolbarCurrentItemsView: NSStackView, NSDraggingSource {

  var currentItemsViewDelegate: OSCToolbarCurrentItemsViewDelegate?

  var itemBeingDragged: OSCToolbarCurrentItem?

  private var items: [Preference.ToolBarButton] = []

  private let placeholderView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()
  private var dragDestIndex: Int = 0

  func initItems(fromItems items: [Preference.ToolBarButton]) {
    self.items = items
    views.forEach { self.removeView($0) }
    for buttonType in items {
      let button = OSCToolbarCurrentItem(buttonType: buttonType, superView: self)
      self.addView(button, in: .trailing)
    }
  }

  private func updateItems() {
    items = views.compactMap { ($0 as? OSCToolbarCurrentItem)?.buttonType }

    if let delegate = currentItemsViewDelegate {
      delegate.currentItemsView(self, updatedItems: items)
    }
  }

  // Dragging source

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    return [.delete, .move]
  }

  func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
    if let itemBeingDragged {
      // remove the dragged view and insert a placeholder at its position.
      let index = views.firstIndex(of: itemBeingDragged)!
      removeView(itemBeingDragged)
      Utility.quickConstraints(["H:[v(\(Preference.ToolBarButton.frameSize))]", "V:[v(\(Preference.ToolBarButton.frameSize))]"], ["v": placeholderView])
      insertView(placeholderView, at: index, in: .trailing)
    }
  }

  func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
    guard let window else { return }
    let windowPoint = window.convertFromScreen(NSRect(origin: screenPoint, size: .zero)).origin
    let inView = frame.contains(windowPoint)
    session.animatesToStartingPositionsOnCancelOrFail = inView
  }

  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    if operation == [] || operation == .delete {
      let diameter = Preference.ToolBarButton.frameSize
      // Do "poof" animation on item remove
      NSAnimationEffect.disappearingItemDefault.show(centeredAt: screenPoint, size: NSSize(width: diameter, height: diameter), completionHandler: {
        self.updateItems()
      })
    }
  }

  // Dragging destination

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    let pboard = sender.draggingPasteboard

    if let _ = pboard.availableType(from: [.yinaOSCAvailableToolbarButtonType]) {
      // dragging available item in:
      // don't accept existing items, don't accept new items when already have 5 icons
      guard let rawButtonType = sender.draggingPasteboard.propertyList(forType: .yinaOSCAvailableToolbarButtonType) as? Int,
        let buttonType = Preference.ToolBarButton(rawValue: rawButtonType),
        !items.contains(buttonType),
        items.count < 5 else {
        return []
      }
      return .copy
    } else if let _ = pboard.availableType(from: [.yinaOSCCurrentToolbarButtonType]) {
      // rearranging current items
      return .move
    }

    return []
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    let pboard = sender.draggingPasteboard

    let isAvailableItem = pboard.availableType(from: [.yinaOSCAvailableToolbarButtonType]) != nil
    let isCurrentItem = pboard.availableType(from: [.yinaOSCCurrentToolbarButtonType]) != nil
    guard isAvailableItem || isCurrentItem else { return [] }

    if isAvailableItem {
      // dragging available item in:
      // don't accept existing items, don't accept new items when already have 5 icons
      guard let rawButtonType = sender.draggingPasteboard.propertyList(forType: .yinaOSCAvailableToolbarButtonType) as? Int,
        let buttonType = Preference.ToolBarButton(rawValue: rawButtonType),
        !items.contains(buttonType),
        items.count < 5 else {
          return []
      }
    }

    // get the expected drag destination position and index
    let pos = convert(sender.draggingLocation, from: nil)
    let phWidth = Preference.ToolBarButton.frameSize
    let phHeight = phWidth
    var index = views.count - Int(floor((frame.width - pos.x) / phWidth)) - 1
    if index < 0 { index = 0 }
    dragDestIndex = index

    // add placeholder view at expected index
    if views.contains(placeholderView) {
      removeView(placeholderView)
    }
    Utility.quickConstraints(["H:[v(\(phWidth))]", "V:[v(\(phHeight))]"], ["v": placeholderView])
    insertView(placeholderView, at: index, in: .trailing)
    // animate frames
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.25
      context.allowsImplicitAnimation = true
      self.layoutSubtreeIfNeeded()
    }, completionHandler: nil)

    return isAvailableItem ? .copy : .move
  }

  override func draggingEnded(_ sender: NSDraggingInfo) {
    // remove the placeholder view
    if views.contains(placeholderView) {
      removeView(placeholderView)
    }
    itemBeingDragged = nil
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let pboard = sender.draggingPasteboard

    if views.contains(placeholderView) {
      removeView(placeholderView)
    }

    if let _ = pboard.availableType(from: [.yinaOSCAvailableToolbarButtonType]) {
      // dragging available item in; don't accept existing items
      if let rawButtonType = sender.draggingPasteboard.propertyList(forType: .yinaOSCAvailableToolbarButtonType) as? Int,
          let buttonType = Preference.ToolBarButton(rawValue: rawButtonType),
          items.count < 5,
          dragDestIndex >= 0,
          dragDestIndex <= views.count {
        let item = OSCToolbarCurrentItem(buttonType: buttonType, superView: self)
        insertView(item, at: dragDestIndex, in: .trailing)
        updateItems()
        return true
      }
      return false
    } else if let _ = pboard.availableType(from: [.yinaOSCCurrentToolbarButtonType]) {
      // rearranging current items
      insertView(itemBeingDragged!, at: dragDestIndex, in: .trailing)
      updateItems()
      return true
    }

    return false
  }

}


class OSCToolbarAvailableItemsView: NSStackView, NSDraggingSource {

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    return .copy
  }

}
