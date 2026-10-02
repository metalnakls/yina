// xcrun swiftc -parse-as-library other/tests/file-open-architecture-smoke.swift -o /tmp/yina-file-open-architecture-smoke
// /tmp/yina-file-open-architecture-smoke
import Foundation

@main struct FileOpenArchitectureSmoke {
  static func main() throws {
    let playerCore = try String(contentsOfFile: "yina/PlayerCore.swift", encoding: .utf8)
    let mainWindow = try String(contentsOfFile: "yina/MainWindowController.swift", encoding: .utf8)

    precondition(playerCore.contains("pendingWindowLoadPath = path"))
    precondition(playerCore.contains("func startPendingWindowLoad()"))
    precondition(!mainWindow.contains("player.initVideo()\n    player.startPendingWindowLoad()"),
                 "mpv must not start while the player window is still being assembled")

    let openStart = playerCore.range(of: "private func openMainWindow")!.lowerBound
    let openBody = playerCore[openStart...]
    let pending = openBody.range(of: "pendingWindowLoadPath = path")!.lowerBound
    let loadWindow = openBody.range(of: "let _ = mainWindow.window")!.lowerBound
    precondition(pending < loadWindow,
                 "the pending media path must be available during windowDidLoad")

    let closeWelcome = openBody.range(of: "initialWindow.close()")!.lowerBound
    let startLoad = openBody.range(of: "startPendingWindowLoad()")!.lowerBound
    precondition(loadWindow < closeWelcome && closeWelcome < startLoad,
                 "finish the player window and close the welcome window before loading media")

    print("PASS: initial media loading starts after AppKit player-window setup.")
  }
}
