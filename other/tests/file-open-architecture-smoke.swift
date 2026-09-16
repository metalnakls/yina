// xcrun swiftc -parse-as-library other/tests/file-open-architecture-smoke.swift -o /tmp/iina-file-open-architecture-smoke
// /tmp/iina-file-open-architecture-smoke
import Foundation

@main struct FileOpenArchitectureSmoke {
  static func main() throws {
    let playerCore = try String(contentsOfFile: "iina/PlayerCore.swift", encoding: .utf8)
    let mainWindow = try String(contentsOfFile: "iina/MainWindowController.swift", encoding: .utf8)

    precondition(playerCore.contains("pendingWindowLoadPath = path"))
    precondition(playerCore.contains("func startPendingWindowLoad()"))
    precondition(mainWindow.contains("player.initVideo()\n    player.startPendingWindowLoad()"),
                 "mpv should start opening media as soon as the render context is ready")

    let openStart = playerCore.range(of: "private func openMainWindow")!.lowerBound
    let openBody = playerCore[openStart...]
    let pending = openBody.range(of: "pendingWindowLoadPath = path")!.lowerBound
    let loadWindow = openBody.range(of: "let _ = mainWindow.window")!.lowerBound
    precondition(pending < loadWindow,
                 "the pending media path must be available during windowDidLoad")

    print("PASS: initial media loading overlaps the tail of AppKit player-window setup.")
  }
}
