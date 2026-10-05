// xcrun swiftc -parse-as-library yina/ApplicationMenus.swift other/tests/main-menu-smoke.swift -o /tmp/yina-main-menu-smoke
// /tmp/yina-main-menu-smoke other/tests/main-menu-contract.json
import Cocoa

private final class MenuTarget: NSObject {
  var opens: [Int] = []
  var recentURL: URL?
  @objc func openFile(_ sender: NSMenuItem) { opens.append(sender.tag) }
  @objc func openRecent(_ sender: NSMenuItem) { recentURL = sender.representedObject as? URL }
}
private struct Contract: Decodable {
  let route: [Int]
  let title: String
  let key: String
  let flags: [String]
  let tag: Int
  let hidden: Bool
  let enabled: Bool
  let alternate: Bool
  let separator: Bool
  let action: String?
  let target: String
  let binding: String?
}
@main struct MenuSmoke {
  static func main() throws {
    let application = NSApplication.shared
    let delegate = MenuTarget(), updater = NSObject(), fonts = NSObject()
    let menus = ApplicationMenus(applicationDelegate: delegate, updater: updater, fontManager: fonts)
    let contract = try JSONDecoder().decode([Contract].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    precondition(contract.count == 193)
    var actualCount = 0
    func count(_ menu: NSMenu) {
      actualCount += menu.numberOfItems
      menu.items.forEach { if let submenu = $0.submenu { count(submenu) } }
    }
    count(menus.mainMenu); count(menus.dockMenu)
    precondition(actualCount == contract.count)
    let flags: [String: NSEvent.ModifierFlags] = ["command": .command, "option": .option, "shift": .shift, "control": .control]
    for entry in contract {
      var menu = entry.route[0] == 0 ? menus.mainMenu! : menus.dockMenu!
      let route = Array(entry.route.dropFirst())
      for index in route.dropLast() { menu = menu.item(at: index)!.submenu! }
      let item = menu.item(at: route.last!)!
      let label = "Menu contract mismatch: \(entry.title) at \(entry.route)"
      precondition(item.title == entry.title && item.keyEquivalent == entry.key, label)
      precondition(item.tag == entry.tag && item.isHidden == entry.hidden && item.isAlternate == entry.alternate, label)
      precondition(item.isSeparatorItem == entry.separator, label)
      if !entry.separator { precondition(item.isEnabled == entry.enabled, label) }
      precondition(item.keyEquivalentModifierMask == entry.flags.reduce([]) { $0.union(flags[$1]!) }, label)
      // AppKit supplies its own submenu-opening action when a submenu is assigned.
      if item.submenu == nil || entry.action != nil {
        precondition(item.action.map(NSStringFromSelector) == entry.action, label)
      }
      switch entry.target {
      case "applicationDelegate": precondition(item.target === delegate, label)
      case "updater": precondition(item.target === updater, label)
      case "fontManager": precondition(item.target === fonts, label)
      default: if item.submenu == nil { precondition(item.target == nil, label) }
      }
      if let binding = entry.binding { precondition(menus.item(binding) === item, label) }
    }
    menus.install(in: application)
    precondition(application.mainMenu === menus.mainMenu)
    precondition(application.servicesMenu === menus.menu("servicesMenu"))
    precondition(application.windowsMenu === menus.menu("windowsMenu"))
    precondition(application.helpMenu === menus.menu("helpMenu"))
    for modifiers: NSEvent.ModifierFlags in [[.command], [.command, .option]] {
      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: 0, windowNumber: 0, context: nil, characters: "o", charactersIgnoringModifiers: "o",
        isARepeat: false, keyCode: 31)!
      precondition(menus.mainMenu.performKeyEquivalent(with: event))
    }
    menus.dockMenu.performActionForItem(at: 0)
    precondition(delegate.opens == [0, 1, 0])

    // Exercise native-list adaptation without reading or modifying the user's recent documents.
    var urls = [URL(fileURLWithPath: "/tmp/first/movie.mkv"), URL(fileURLWithPath: "/tmp/second/movie.mkv")]
    var clears = 0
    menus.configureRecentDocuments(target: delegate, openAction: #selector(MenuTarget.openRecent(_:)),
                                   urls: { urls }, clear: { urls = []; clears += 1 })
    let recent = menus.menu("recentDocumentsMenu")
    precondition(recent.numberOfItems == 4)
    precondition(recent.items[0].toolTip != recent.items[1].toolTip)
    recent.performActionForItem(at: 1)
    precondition(delegate.recentURL == urls[1])
    recent.performActionForItem(at: 3)
    precondition(clears == 1 && recent.numberOfItems == 1 && !recent.items[0].isEnabled)
    print("PASS: All 193 original menu entries, targets, shortcuts, bindings, system menus, Dock actions, and recents.")
  }
}
