import Cocoa

/// The Filters window's lists and toolbar, formerly constructed by its nib.
final class FilterWindowContentView: NSView {
  let splitView = NSSplitView()
  let currentFiltersTableView = NSTableView()
  let savedFiltersTableView = NSTableView()
  let removeButton: NSButton

  init(target: AnyObject, addAction: Selector, removeAction: Selector) {
    removeButton = FilterViewFactory.imageButton(NSImage.removeTemplateName, target: target, action: removeAction)
    super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 382))
    wantsLayer = true
    splitView.isVertical = false
    splitView.dividerStyle = .thin
    addSubview(splitView)
    FilterViewFactory.pin(splitView, to: self)

    let active = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 242))
    let saved = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 139))
    splitView.addArrangedSubview(active)
    splitView.addArrangedSubview(saved)
    splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
    splitView.setHoldingPriority(NSLayoutConstraint.Priority(300), forSubviewAt: 1)

    currentFiltersTableView.style = .fullWidth
    currentFiltersTableView.rowHeight = 24
    currentFiltersTableView.usesAlternatingRowBackgroundColors = true
    currentFiltersTableView.allowsColumnReordering = false
    currentFiltersTableView.autosaveName = "FilterTable"
    currentFiltersTableView.intercellSpacing = NSSize(width: 3, height: 2)
    for (id, title, width, minimum, maximum, editable) in [
      ("Key", "#", 40.0, 40.0, 40.0, false),
      ("Value", "Filter String", 527.5, 40.0, 2000.0, true),
      ("Save", "", 45.5, 45.0, 100.0, false)
    ] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
      column.title = title
      column.width = width
      column.minWidth = minimum
      column.maxWidth = maximum
      column.isEditable = editable
      currentFiltersTableView.addTableColumn(column)
    }
    let activeScroll = FilterViewFactory.scrollView(document: currentFiltersTableView)
    active.addSubview(activeScroll)
    let toolbar = NSView()
    active.addSubview(toolbar)
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    activeScroll.translatesAutoresizingMaskIntoConstraints = false
    let addButton = FilterViewFactory.imageButton(NSImage.addTemplateName, target: target, action: addAction)
    toolbar.addSubview(addButton)
    toolbar.addSubview(removeButton)
    NSLayoutConstraint.activate([
      activeScroll.leadingAnchor.constraint(equalTo: active.leadingAnchor),
      activeScroll.trailingAnchor.constraint(equalTo: active.trailingAnchor),
      activeScroll.topAnchor.constraint(equalTo: active.topAnchor),
      activeScroll.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
      toolbar.leadingAnchor.constraint(equalTo: active.leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: active.trailingAnchor),
      toolbar.bottomAnchor.constraint(equalTo: active.bottomAnchor),
      toolbar.heightAnchor.constraint(equalToConstant: 22),
      addButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 1),
      addButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
      removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor),
      removeButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
    ])

    savedFiltersTableView.style = .fullWidth
    savedFiltersTableView.rowHeight = 42
    savedFiltersTableView.usesAlternatingRowBackgroundColors = true
    savedFiltersTableView.allowsMultipleSelection = false
    savedFiltersTableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    savedFiltersTableView.headerView = nil
    savedFiltersTableView.intercellSpacing = NSSize(width: 3, height: 2)
    let savedColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Saved"))
    savedColumn.width = 628
    savedColumn.minWidth = 40
    savedColumn.maxWidth = 2000
    savedFiltersTableView.addTableColumn(savedColumn)
    let heading = NSTextField(labelWithString: "Saved filters")
    heading.translatesAutoresizingMaskIntoConstraints = false
    saved.addSubview(heading)
    let savedScroll = FilterViewFactory.scrollView(document: savedFiltersTableView)
    savedScroll.translatesAutoresizingMaskIntoConstraints = false
    saved.addSubview(savedScroll)
    NSLayoutConstraint.activate([
      heading.leadingAnchor.constraint(equalTo: saved.leadingAnchor, constant: 8),
      heading.topAnchor.constraint(equalTo: saved.topAnchor, constant: 2),
      heading.trailingAnchor.constraint(lessThanOrEqualTo: saved.trailingAnchor, constant: -8),
      savedScroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 2),
      savedScroll.leadingAnchor.constraint(equalTo: saved.leadingAnchor),
      savedScroll.trailingAnchor.constraint(equalTo: saved.trailingAnchor),
      savedScroll.bottomAnchor.constraint(equalTo: saved.bottomAnchor)
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

enum FilterViewFactory {
  static func pin(_ view: NSView, to parent: NSView) {
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
      view.topAnchor.constraint(equalTo: parent.topAnchor),
      view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
    ])
  }

  static func scrollView(document: NSView) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.borderType = .bezelBorder
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = document
    return scroll
  }

  static func imageButton(_ image: NSImage.Name, target: AnyObject, action: Selector) -> NSButton {
    let button = NSButton(image: NSImage(named: image)!, target: target, action: action)
    button.bezelStyle = .shadowlessSquare
    button.isBordered = false
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 20),
      button.heightAnchor.constraint(equalToConstant: 20)
    ])
    return button
  }

  static func textCell(editable: Bool = false, aligned: NSTextAlignment = .left) -> NSTableCellView {
    let cell = FilterTextCellView()
    let text = NSTextField(labelWithString: "")
    text.isEditable = editable
    text.isSelectable = editable
    text.alignment = aligned
    text.lineBreakMode = .byTruncatingTail
    text.cell?.isScrollable = true
    text.cell?.sendsActionOnEndEditing = true
    text.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(text)
    cell.textField = text
    if editable { text.delegate = cell }
    NSLayoutConstraint.activate([
      text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
      text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
      text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
    ])
    text.bind(.value, to: cell, withKeyPath: "objectValue", options: nil)
    return cell
  }

  static func saveCell(target: AnyObject, action: Selector) -> NSTableCellView {
    let cell = NSTableCellView()
    let button = NSButton(title: "Save", target: target, action: action)
    button.bezelStyle = .rounded
    button.controlSize = .small
    button.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(button)
    NSLayoutConstraint.activate([
      button.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
      button.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
    ])
    button.bind(.hidden, to: cell, withKeyPath: "objectValue", options: nil)
    return cell
  }
}

final class SavedFilterCellView: NSTableCellView {
  let enabledButton: NSButton
  let filterText = NSTextField(labelWithString: "")
  let shortcutText = NSTextField(labelWithString: "")

  init(target: AnyObject, toggleAction: Selector, editAction: Selector, deleteAction: Selector) {
    enabledButton = NSButton(checkboxWithTitle: "", target: target, action: toggleAction)
    super.init(frame: .zero)
    let name = NSTextField(labelWithString: "")
    textField = name
    let edit = FilterViewFactory.imageButton(NSImage.actionTemplateName, target: target, action: editAction)
    let delete = FilterViewFactory.imageButton(NSImage.stopProgressFreestandingTemplateName, target: target, action: deleteAction)
    filterText.textColor = .secondaryLabelColor
    filterText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    filterText.lineBreakMode = .byTruncatingMiddle
    shortcutText.textColor = .secondaryLabelColor
    shortcutText.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    name.lineBreakMode = .byTruncatingTail
    for view in [enabledButton, name, filterText, shortcutText, edit, delete] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      enabledButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      enabledButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      name.leadingAnchor.constraint(equalTo: enabledButton.trailingAnchor, constant: 6),
      name.topAnchor.constraint(equalTo: topAnchor, constant: 3),
      name.trailingAnchor.constraint(lessThanOrEqualTo: shortcutText.leadingAnchor, constant: -6),
      filterText.leadingAnchor.constraint(equalTo: name.leadingAnchor),
      filterText.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
      filterText.trailingAnchor.constraint(lessThanOrEqualTo: shortcutText.leadingAnchor, constant: -6),
      filterText.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -3),
      shortcutText.centerYAnchor.constraint(equalTo: centerYAnchor),
      shortcutText.trailingAnchor.constraint(equalTo: edit.leadingAnchor, constant: -6),
      edit.centerYAnchor.constraint(equalTo: centerYAnchor),
      edit.trailingAnchor.constraint(equalTo: delete.leadingAnchor, constant: -4),
      delete.centerYAnchor.constraint(equalTo: centerYAnchor),
      delete.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
    ])
    name.bind(.value, to: self, withKeyPath: "objectValue.name", options: nil)
    filterText.bind(.value, to: self, withKeyPath: "objectValue.filterString", options: nil)
    shortcutText.bind(.value, to: self, withKeyPath: "objectValue.readableShortCutKey", options: nil)
    enabledButton.bind(.value, to: self, withKeyPath: "objectValue.isEnabled", options: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Preset list and parameter area; the controller supplies the existing preset logic.
final class FilterPresetContentView: NSView {
  let tableView = NSTableView()
  let scrollContentView = FlippedView(frame: .zero)
  let addButton: NSButton
  let presetsWidthConstraint: NSLayoutConstraint

  init(target: AnyObject, addAction: Selector, cancelAction: Selector) {
    addButton = NSButton(title: "Add", target: target, action: addAction)
    let left = FilterViewFactory.scrollView(document: tableView)
    presetsWidthConstraint = left.widthAnchor.constraint(equalToConstant: 160)
    super.init(frame: NSRect(x: 0, y: 0, width: 620, height: 400))
    tableView.style = .fullWidth
    tableView.headerView = nil
    tableView.allowsMultipleSelection = false
    tableView.allowsEmptySelection = false
    tableView.allowsColumnReordering = false
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Preset"))
    column.isEditable = false
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)
    let right = FilterViewFactory.scrollView(document: scrollContentView)
    scrollContentView.translatesAutoresizingMaskIntoConstraints = false
    scrollContentView.widthAnchor.constraint(equalTo: right.contentView.widthAnchor).isActive = true
    let cancel = NSButton(title: "Cancel", target: target, action: cancelAction)
    addButton.bezelStyle = .rounded
    cancel.bezelStyle = .rounded
    addButton.keyEquivalent = "\r"
    cancel.keyEquivalent = "\u{1b}"
    for view in [left, right, addButton, cancel] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      left.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      presetsWidthConstraint,
      left.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8),
      right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 8),
      right.topAnchor.constraint(equalTo: left.topAnchor),
      right.bottomAnchor.constraint(equalTo: left.bottomAnchor),
      right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      right.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
      addButton.trailingAnchor.constraint(equalTo: right.trailingAnchor),
      addButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
      cancel.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -12),
      cancel.centerYAnchor.constraint(equalTo: addButton.centerYAnchor)
    ])
    tableView.nextKeyView = addButton
    addButton.nextKeyView = cancel
    cancel.nextKeyView = tableView
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// View-based table bindings update the cell; explicitly commit edits to the controller.
private final class FilterTextCellView: NSTableCellView, NSTextFieldDelegate {
  func controlTextDidEndEditing(_ notification: Notification) {
    guard let text = notification.object as? NSTextField else { return }
    var ancestor = superview
    while let view = ancestor, !(view is NSTableView) { ancestor = view.superview }
    guard let table = ancestor as? NSTableView else { return }
    let row = table.row(for: self)
    let column = table.column(for: self)
    guard row >= 0, column >= 0 else { return }
    table.dataSource?.tableView?(table, setObjectValue: text.stringValue,
                                for: table.tableColumns[column], row: row)
  }
}
