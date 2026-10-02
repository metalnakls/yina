//
//  OSCToolbarDraggingItemViewController.swift
//  yina
//
//  Created by Collider LI on 4/2/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Cocoa

fileprivate let ui = UIHelper.shared


class OSCToolbarDraggingItemViewController: NSViewController, NSPasteboardWriting {

  weak var availableItemsView: OSCToolbarAvailableItemsView?

  private let buttonType: Preference.ToolBarButton
  private let toolbarButton: NSButton = {
    let button = ui.button("")
    button.imagePosition = .imageOnly
    button.alignment = .center
    button.focusRingType = .none
    button.isEnabled = false
    return button
  }()
  private let descriptionLabel: NSTextField = {
    let label = ui.label("", canCompress: false)
    label.lineBreakMode = .byClipping
    label.cell?.isScrollable = true
    label.font = .systemFont(ofSize: NSFont.systemFontSize)
    label.textColor = .labelColor
    label.backgroundColor = .controlColor
    return label
  }()


  init(buttonType: Preference.ToolBarButton) {
    self.buttonType = buttonType
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let itemView = NSView(frame: NSRect(x: 0, y: 0, width: 332, height: 33))
    itemView.translatesAutoresizingMaskIntoConstraints = false
    itemView.size(height: 33)

    let box = NSBox()
    box.translatesAutoresizingMaskIntoConstraints = false
    box.boxType = .primary
    box.titlePosition = .noTitle
    box.contentViewMargins = .zero

    let contentView = NSView()
    contentView.translatesAutoresizingMaskIntoConstraints = false
    box.contentView = contentView

    contentView.addSubview(toolbarButton)
    contentView.addSubview(descriptionLabel)
    itemView.addSubview(box)

    box.padding(.all, from: itemView)
    toolbarButton.padding(.leading, from: contentView)
    toolbarButton.center(.y, with: contentView)
    descriptionLabel.spacing(.leading, to: toolbarButton)
    descriptionLabel.padding(.trailing, from: contentView)
    descriptionLabel.center(.y, with: toolbarButton)

    view = itemView
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    OSCToolbarButton.setStyle(of: toolbarButton, buttonType: buttonType)
    // Button is actually disabled so that its mouseDown goes to its superview instead. But don't gray it out.
    (toolbarButton.cell! as! NSButtonCell).imageDimsWhenDisabled = false

    descriptionLabel.stringValue = buttonType.localizedDescription()
  }

  func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
    return [.yinaOSCAvailableToolbarButtonType]
  }

  func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
    if type == .yinaOSCAvailableToolbarButtonType {
      return buttonType.rawValue
    }
    return nil
  }

  override func mouseDown(with event: NSEvent) {
    guard let availableItemsView else { return }

    guard let dragItem = OSCToolbarButton.buildDragItem(from: toolbarButton, pasteboardWriter: self, buttonType: buttonType) else { return }
    view.beginDraggingSession(with: [dragItem], event: event, source: availableItemsView)
  }

}
