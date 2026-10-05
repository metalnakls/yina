// xcrun swiftc -parse-as-library yina/InspectorWindowViews.swift yina/FlippedView.swift other/tests/inspector-window-smoke.swift -o /tmp/yina-inspector-window-smoke
// /tmp/yina-inspector-window-smoke (isolated views; does not launch yina)
import Cocoa

private final class InspectorActions: NSObject {
  weak var content: InspectorWindowContentView?
  var trackCalls = 0
  var watchCalls = 0
  @objc func tab(_ sender: NSSegmentedControl) { content!.tabView.selectTabViewItem(at: sender.selectedSegment) }
  @objc func track(_ sender: Any) { trackCalls += 1 }
  @objc func watch(_ sender: Any) { watchCalls += 1 }
}
private final class WatchSource: NSObject, NSTableViewDelegate, NSTableViewDataSource {
  var count = 2
  func numberOfRows(in tableView: NSTableView) -> Int { count }
  func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
    let cell = InspectorWindowContentView.watchCell(identifier: column!.identifier)
    cell.textField!.stringValue = column!.identifier.rawValue == "Key" ? "property-\(row)" : "value-\(row)"
    return cell
  }
}
@main struct InspectorSmoke {
  static func main() {
    _ = NSApplication.shared
    let actions = InspectorActions()
    let content = InspectorWindowContentView(target: actions,
      tabAction: #selector(InspectorActions.tab(_:)), trackAction: #selector(InspectorActions.track(_:)),
      addAction: #selector(InspectorActions.watch(_:)), removeAction: #selector(InspectorActions.watch(_:)))
    actions.content = content
    let panel = NSPanel(contentRect: content.frame, styleMask: [.titled, .resizable, .utilityWindow, .hudWindow],
                        backing: .buffered, defer: false)
    panel.contentView = content
    panel.toolbar = content.makeToolbar()
    precondition(panel.toolbar!.items.count == 1 && panel.toolbar!.items[0].view === content.tabButtonGroup)
    precondition(content.fields.count == 45)
    precondition(content.fields["trackDefaultField"]!.stringValue == "Default")
    precondition(content.fields["trackForcedField"]!.stringValue == "Forced")
    precondition(content.fields["trackSelectedField"]!.stringValue == "Selected")
    precondition(content.fields["trackExternalField"]!.stringValue == "External")
    let sample = String(repeating: "Long metadata ", count: 50)
    for field in content.fields.values {
      precondition(!field.isEditable && field.isSelectable)
      field.stringValue = sample
    }
    for size in [NSSize(width: 468, height: 481), NSSize(width: 850, height: 720)] {
      panel.setContentSize(size)
      for index in 0..<4 {
        content.tabButtonGroup.selectedSegment = index
        content.tabButtonGroup.sendAction(content.tabButtonGroup.action, to: actions)
        content.layoutSubtreeIfNeeded()
        precondition(content.tabView.selectedTabViewItem === content.tabView.tabViewItem(at: index))
        precondition(!content.hasAmbiguousLayout)
        for field in content.fields.values where field.isDescendant(of: content.tabView.selectedTabViewItem!.view!) {
          precondition(field.frame.width > 20 && field.frame.height > 0)
          precondition(!field.hasAmbiguousLayout)
        }
      }
    }
    content.trackPopup.addItems(withTitles: ["Video 1", "Audio 1"])
    content.trackPopup.selectItem(at: 1)
    content.trackPopup.sendAction(content.trackPopup.action, to: actions)
    precondition(actions.trackCalls == 1)
    content.deleteButton.performClick(nil)
    precondition(actions.watchCalls == 1)

    let source = WatchSource()
    let table = content.watchTableView
    table.dataSource = source
    table.delegate = source
    let minimum = content.watchTableContainerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
    minimum.isActive = true
    let statusScroll = content.tabView.tabViewItem(at: 3).view as! NSScrollView
    for rows in [2, 50, 0] {
      source.count = rows
      table.reloadData()
      minimum.constant = table.headerView!.frame.height + CGFloat(rows + 1) * (table.rowHeight + table.intercellSpacing.height)
      content.layoutSubtreeIfNeeded()
      statusScroll.layoutSubtreeIfNeeded()
      statusScroll.documentView!.layoutSubtreeIfNeeded()
      precondition(content.watchTableContainerView.frame.height >= minimum.constant)
      precondition(table.enclosingScrollView!.contentView.bounds.height >= CGFloat(rows) * 19)
      precondition(!statusScroll.documentView!.hasAmbiguousLayout)
      if rows == 50 {
        precondition(statusScroll.documentView!.frame.height > statusScroll.contentView.frame.height)
        statusScroll.documentView!.scroll(NSPoint(x: 0, y: 400))
        precondition(statusScroll.contentView.bounds.origin.y > 0, "Long watch lists must actually scroll")
        statusScroll.documentView!.scroll(.zero)
      }
      if rows > 0 {
        let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSTableCellView
        precondition(cell.textField!.stringValue == "property-0")
      }
    }
    precondition(table.tableColumns.map { $0.identifier.rawValue } == ["Key", "Value"])
    print("PASS: Inspector tabs, toolbar/actions, 45 fields, resizing, and short/long/empty watch lists.")
  }
}
