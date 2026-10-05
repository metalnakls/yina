// xcrun swiftc -parse-as-library yina/FilterWindowViews.swift yina/NewFilterSheetViewController.swift yina/FlippedView.swift yina/FilterPresets.swift yina/MPVFilter.swift other/tests/filter-window-smoke.swift -o /tmp/yina-filter-window-smoke
// /tmp/yina-filter-window-smoke (isolated AppKit views; no yina launch)
import Cocoa

// Domain dependencies are isolated; view construction and preset logic use production code.
final class FilterWindowController {
  let filterType: String
  let window: NSWindow? = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
                        styleMask: [.titled], backing: .buffered, defer: false)
  var newFilterSheet: NSWindow { window! }
  init(_ type: String) { filterType = type }
  func addFilter(_ filter: MPVFilter) -> Bool { true }
}
enum MPVProperty { static let vf = "vf"; static let af = "af" }
enum Logger {
  enum Level { case warning }
  static func log(_ message: String, level: Level) {}
}
enum Utility {
  static func showAlert(_ key: String, sheetWindow: NSWindow?) {}
  static func quickConstraints(_ formats: [String], _ views: [String: NSView]) {
    formats.forEach { NSLayoutConstraint.activate(NSLayoutConstraint.constraints(
      withVisualFormat: $0, options: [], metrics: nil, views: views)) }
  }
}
enum OSDMessage { case addFilter(String) }
final class PlayerCore {
  static let lastActive = PlayerCore()
  func sendOSD(_ message: OSDMessage) {}
}
extension Collection {
  subscript(at index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
extension String {
  var mpvFixedLengthQuoted: String { "%\(utf8.count)%\(self)" }
}
final class Actions: NSObject {
  var calls = 0
  @objc func action(_ sender: Any) { calls += 1 }
}
final class SavedModel: NSObject {
  @objc dynamic var name = "Test"
  @objc dynamic var filterString = "volume=2"
  @objc dynamic var readableShortCutKey = "⌘K"
  @objc dynamic var isEnabled = true
}
final class TableSource: NSObject, NSTableViewDelegate, NSTableViewDataSource {
  var value = "volume=2"
  func numberOfRows(in tableView: NSTableView) -> Int { 1 }
  func tableView(_ tableView: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
    column?.identifier.rawValue == "Key" ? "0" : value
  }
  func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
    FilterViewFactory.textCell(editable: column?.identifier.rawValue == "Value")
  }
  func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for column: NSTableColumn?, row: Int) {
    if column?.identifier.rawValue == "Value", let text = object as? String { value = text }
  }
}

@main struct FilterWindowSmoke {
  static func main() {
    _ = NSApplication.shared
    let actions = Actions()
    let selector = #selector(Actions.action(_:))
    let content = FilterWindowContentView(target: actions, addAction: selector, removeAction: selector)
    let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
    window.contentView = content
    for size in [NSSize(width: 640, height: 382), NSSize(width: 240, height: 278), NSSize(width: 1000, height: 600)] {
      window.setContentSize(size)
      content.layoutSubtreeIfNeeded()
      content.splitView.adjustSubviews()
      content.layoutSubtreeIfNeeded()
      precondition(content.splitView.frame.size == size)
      precondition(!content.hasAmbiguousLayout)
      precondition(content.currentFiltersTableView.enclosingScrollView!.frame.height > 0)
      precondition(content.savedFiltersTableView.enclosingScrollView!.frame.height > 0)
    }
    precondition(content.currentFiltersTableView.tableColumns.map { $0.identifier.rawValue } == ["Key", "Value", "Save"])
    precondition(content.currentFiltersTableView.rowHeight == 24 && content.savedFiltersTableView.rowHeight == 42)
    content.removeButton.performClick(nil)
    precondition(actions.calls == 1)

    // Real AppKit editing must send the changed string back to the table data source.
    let source = TableSource()
    let table = content.currentFiltersTableView
    table.delegate = source
    table.dataSource = source
    table.reloadData()
    table.layoutSubtreeIfNeeded()
    table.editColumn(1, row: 0, with: nil, select: true)
    guard let editor = window.firstResponder as? NSTextView else { preconditionFailure("Filter string editor missing") }
    editor.string = "volume=3"
    window.makeFirstResponder(table)
    precondition(source.value == "volume=3", "Filter string editing must commit through the table data source")

    // Preserve the nib's model bindings, including checkbox writes and cell reuse.
    let cell = SavedFilterCellView(target: actions, toggleAction: selector, editAction: selector, deleteAction: selector)
    cell.frame = NSRect(x: 0, y: 0, width: 600, height: 42)
    let model = SavedModel()
    cell.objectValue = model
    cell.layoutSubtreeIfNeeded()
    precondition(cell.textField!.stringValue == model.name && cell.filterText.stringValue == model.filterString)
    precondition(cell.shortcutText.stringValue == model.readableShortCutKey && cell.enabledButton.state == .on)
    cell.enabledButton.performClick(nil)
    precondition(!model.isEnabled && actions.calls == 2)
    let replacement = SavedModel()
    replacement.name = "Replacement"
    cell.objectValue = replacement
    precondition(cell.textField!.stringValue == "Replacement" && cell.enabledButton.state == .on)
    let saveCell = FilterViewFactory.saveCell(target: actions, action: selector)
    let save = saveCell.subviews[0] as! NSButton
    saveCell.objectValue = true
    precondition(save.isHidden)
    saveCell.objectValue = false
    precondition(!save.isHidden)

    for type in [MPVProperty.vf, MPVProperty.af] {
      let parent = FilterWindowController(type)
      let controller = NewFilterSheetViewController(filterWindow: parent)
      let form = controller.view as! FilterPresetContentView
      parent.window!.contentViewController = controller
      form.layoutSubtreeIfNeeded()
      let presets = type == MPVProperty.vf ? FilterPreset.vfPresets : FilterPreset.afPresets
      precondition(form.tableView.numberOfRows == presets.count && form.tableView.selectedRow == 0)
      for (row, preset) in presets.enumerated() {
        form.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        form.layoutSubtreeIfNeeded()
        precondition(!form.scrollContentView.subviews.isEmpty)
        let stack = form.scrollContentView.subviews[0] as! NSStackView
        precondition(form.scrollContentView.frame.width > 100)
        for input in stack.arrangedSubviews {
          precondition(input.frame.width > 100, "Preset controls must fill the settings column")
        }
        let custom = preset.name.starts(with: "custom_")
        if custom { precondition(!form.addButton.isEnabled, "Empty custom names must remain blocked") }
      }
      precondition(form.addButton.keyEquivalent == "\r")
      let cancel = form.subviews.compactMap { $0 as? NSButton }.first { $0.keyEquivalent == "\u{1b}" }
      precondition(cancel != nil)
      precondition(form.presetsWidthConstraint.constant > 20)
    }
    print("PASS: Filters layout, table edits, saved bindings/reuse, and audio/video preset selection.")
  }
}
