// Compile the production entry point with an isolated delegate, not the yina app:
// xcrun swiftc -parse-as-library yina/ApplicationMain.swift yina/ApplicationMenus.swift other/tests/application-startup-smoke.swift -o /tmp/yina-application-startup-smoke
// /tmp/yina-application-startup-smoke
import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var menus: ApplicationMenus!
  private let updater = NSObject()
  private var installed = false
  private var willFinish = false

  override init() {
    super.init()
    precondition(NSApp == nil, "Delegate preparation must precede AppKit initialization")
    UserDefaults.standard.setVolatileDomain(["NSApplicationIgnorePersistentState": true],
                                           forName: UserDefaults.argumentDomain)
  }

  func installApplicationMenus(in application: NSApplication) {
    // This standalone test process has no windows, Dock presence, player, or persisted yina state.
    application.setActivationPolicy(.prohibited)
    menus = ApplicationMenus(applicationDelegate: self, updater: updater, fontManager: NSFontManager.shared)
    menus.install(in: application)
    installed = true
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    precondition(installed && NSApp.delegate === self)
    precondition(NSApp.mainMenu === menus.mainMenu)
    precondition(NSApp.windowsMenu === menus.menu("windowsMenu"))
    willFinish = true
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    precondition(willFinish && NSApp.delegate === self)
    DispatchQueue.main.async {
      precondition(NSApp.delegate === self, "Production entry point must retain its weak application delegate")
      print("PASS: Production entry point installs menus before launch callbacks and retains the delegate.")
      NSApp.stop(nil)
      let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!
      NSApp.postEvent(wake, atStart: true)
    }
  }
}
