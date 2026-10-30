import Cocoa

// Keep app playback out of the test; the controller, AppKit host windows and
// superclass initializer all come from production or the system framework.
class PlayerWindowController: NSObject {
  class Video { func updateDisplayLink() {} }
  let videoView = Video()
  func forceDraw(_ reason: String) {}
}

class MainWindowController: PlayerWindowController, PIPViewControllerDelegate {
  var geometryChanges = 0
  var host: NSWindow?
  func pipHostGeometryChanged() { geometryChanges += 1 }
  func pipHostWindowDidChange(_ window: NSWindow?) { host = window }
}

enum Logger {
  enum Level { case error }
  static func log(_ message: String, level: Level) { print(message) }
}

extension NSScreen {
  static func log(_ message: String, _ screen: NSScreen?) {}
}

@main struct PiPLayoutSmoke {
  static func main() {
    NSApplication.shared.finishLaunching()
    // This is the initializer used by MainWindowController._pip. Calling
    // init(nibName:bundle:) here would hide the missing designated-init bridge.
    let controller = VideoPIPViewController()
    let delegate = MainWindowController()
    controller.delegate = delegate
    controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    let first = makeWindow()
    first.contentView = controller.view
    print("Running first PiP host layout")
    fflush(stdout)
    controller.viewDidLayout()
    precondition(delegate.host === first)
    controller.viewDidLayout()
    expectGeometryChange(delegate: delegate, window: first, count: 1)

    let second = makeWindow()
    second.contentView = controller.view
    controller.viewDidLayout()
    precondition(delegate.host === second)
    expectGeometryChange(delegate: delegate, window: first, count: 0)
    expectGeometryChange(delegate: delegate, window: second, count: 1)

    controller.viewDidDisappear()
    precondition(delegate.host == nil)
    expectGeometryChange(delegate: delegate, window: second, count: 0)
    controller.viewDidLayout()
    expectGeometryChange(delegate: delegate, window: second, count: 1)
    controller.viewDidDisappear()
    print("PASS: PiP default initialization, repeated layout, host replacement, exit and reentry")
    checkSystemPresentation()
  }

  static func makeWindow() -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                          styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
  }

  static func expectGeometryChange(delegate: MainWindowController, window: NSWindow, count: Int) {
    let previous = delegate.geometryChanges
    NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
    precondition(delegate.geometryChanges == previous + count,
                 "PiP must observe only its current host, once, until disappearance")
  }

  static func checkSystemPresentation() {
    let controller = VideoPIPViewController()
    let delegate = MainWindowController()
    controller.delegate = delegate
    let video = NSViewController()
    video.view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    controller.aspectRatio = video.view.frame.size
    controller.presentAsPicture(inPicture: video)
    waitUntil("PiP host visibility") { delegate.host?.isVisible == true }
    controller.dismiss(video)
    print("PASS: system PiP presentation and first layout with a blank video fixture")
  }

  static func waitUntil(_ description: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    if !condition() {
      fputs("FAIL: Timed out waiting for \(description)\n", stderr)
      exit(1)
    }
  }
}
