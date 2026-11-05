// Compile with yina/SubChooseViewController.swift; run sandboxed without display access.
import AppKit
class PlayerCore { func hideOnlineSubtitleWindow() {} }
class OnlineSubtitle {
  func getDescription() -> (name: String, left: String, right: String) { ("Fixture subtitle", "English", "S05E05") }
}
enum OSDType { case normal, withText(String) }
enum OSDMessage {
  case startFindingSub(String), downloadingSub(Int, String), foundSub(Int), networkError
  func titleAndType() -> (String, OSDType) {
    switch self {
    case .startFindingSub: return ("Searching for subtitles…", .normal)
    case .downloadingSub: return ("Downloading subtitles…", .normal)
    case .foundSub(let count): return ("Found \(count) subtitles", .normal)
    case .networkError: return ("Network error", .normal)
    }
  }
}

import AppKit
@main struct SubtitleWindowSmoke {
  static func main() {
    _ = NSApplication.shared
    let controller = OnlineSubtitleWindowController()
    controller.present(.startFindingSub("Fixture"), accessoryView: nil, chooser: nil)
    precondition(controller.window?.isVisible == true, "Search click must show a window")
    let chooser = SubChooseViewController()
    chooser.subtitles = [OnlineSubtitle(), OnlineSubtitle()]
    var canceled = false
    chooser.userCanceledAction = { canceled = true }
    controller.present(.foundSub(2), accessoryView: chooser.view, chooser: chooser)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    precondition(chooser.view.window === controller.window, "Results picker was not attached to the visible window")
    precondition(chooser.view.bounds.width > 0 && chooser.view.bounds.height > 0)
    controller.window?.performClose(nil)
    precondition(canceled, "Closing results must resolve cancellation")
    controller.present(.networkError, accessoryView: nil, chooser: nil)
    precondition(controller.window?.isVisible == true, "Errors must be visible")
    controller.dismiss()
    precondition(controller.window?.isVisible == false)
    print("PASS: visible search progress, attached result picker, close cancellation, visible error")
  }
}
