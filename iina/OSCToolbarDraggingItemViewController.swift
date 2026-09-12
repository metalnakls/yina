//
//  OSCToolbarDraggingItemViewController.swift
//  iina
//
//  Created by Collider LI on 4/2/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Cocoa

class OSCToolbarDraggingItemViewController: NSViewController, NSPasteboardWriting {

  var availableItemsView: OSCToolbarAvailableItemsView?
  var buttonType: Preference.ToolBarButton

  @IBOutlet weak var toolbarButton: NSButton!
  @IBOutlet weak var descriptionLabel: NSTextField!


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
    itemView.heightAnchor.constraint(equalToConstant: 33).isActive = true

    let box = NSBox()
    box.translatesAutoresizingMaskIntoConstraints = false
    box.boxType = .primary
    box.titlePosition = .noTitle
    box.contentViewMargins = .zero

    let contentView = NSView()
    contentView.translatesAutoresizingMaskIntoConstraints = false
    box.contentView = contentView

    let button = NSButton()
    button.imagePosition = .imageOnly
    button.alignment = .center
    button.focusRingType = .none
    button.isEnabled = false

    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byClipping
    label.cell?.isScrollable = true
    label.font = .systemFont(ofSize: NSFont.systemFontSize)
    label.textColor = .labelColor
    label.backgroundColor = .controlColor

    contentView.addSubview(button)
    contentView.addSubview(label)
    itemView.addSubview(box)

    NSLayoutConstraint.activate([
      box.leadingAnchor.constraint(equalTo: itemView.leadingAnchor),
      box.trailingAnchor.constraint(equalTo: itemView.trailingAnchor),
      box.topAnchor.constraint(equalTo: itemView.topAnchor),
      box.bottomAnchor.constraint(equalTo: itemView.bottomAnchor),
      button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      button.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      label.leadingAnchor.constraint(equalTo: button.trailingAnchor),
      label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      label.centerYAnchor.constraint(equalTo: button.centerYAnchor)
    ])

    toolbarButton = button
    descriptionLabel = label
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
    return [.iinaOSCAvailableToolbarButtonType]
  }

  func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
    if type == .iinaOSCAvailableToolbarButtonType {
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
