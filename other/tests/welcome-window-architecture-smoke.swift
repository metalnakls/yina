// xcrun swiftc -parse-as-library other/tests/welcome-window-architecture-smoke.swift -o /tmp/iina-welcome-architecture-smoke
// /tmp/iina-welcome-architecture-smoke
import Foundation

@main struct WelcomeWindowArchitectureSmoke {
  static func main() throws {
    let welcome = try String(contentsOfFile: "iina/InitialWindowController.swift", encoding: .utf8)
    let ffmpeg = try String(contentsOfFile: "iina/FFmpegController.m", encoding: .utf8)
    let project = try String(contentsOfFile: "iina.xcodeproj/project.pbxproj", encoding: .utf8)

    precondition(!welcome.contains("windowNibName"))
    precondition(!welcome.contains("Timer.scheduledTimer"))
    precondition(welcome.contains("IINAWelcomeWindow"))
    precondition(welcome.contains("headerView = nil"))
    precondition(welcome.contains("lastColumnOnlyAutoresizingStyle"))
    precondition(welcome.contains("NSWorkspace.didMountNotification"))
    precondition(welcome.contains("@MainActor\nprivate final class WelcomeWindowCoordinator"))
    precondition(welcome.contains("welcome-artwork-480-"))
    precondition(welcome.contains("thumbWidth: 480"))
    precondition(welcome.contains("cancelArtworkRequests()"))
    precondition(welcome.contains("WelcomeFolderClassificationCache"))
    precondition(welcome.contains("ShowFolderSnapshotStore.load"))
    precondition(welcome.contains("ShowFolderSnapshotStore.save"))
    precondition(welcome.contains("case .unavailable where cachedFolderPaths.contains"))
    precondition(welcome.contains("if openLeftmostShowFolderCard()"))
    precondition(welcome.contains("guard let show = showFolders.first else { return false }"))
    let shelfAccessoryStart = welcome.range(of: "private func configureShelfAccessory()")!.lowerBound
    let shelfAccessoryEnd = welcome.range(of: "override func showWindow", range: shelfAccessoryStart..<welcome.endIndex)!.lowerBound
    let shelfAccessory = welcome[shelfAccessoryStart..<shelfAccessoryEnd]
    precondition(!shelfAccessory.contains("recentScrollView.leadingAnchor"))
    precondition(!shelfAccessory.contains("recentScrollView.trailingAnchor"))
    precondition(shelfAccessory.contains("showFolderHeader.widthAnchor.constraint(equalToConstant: 400)"))
    precondition(shelfAccessory.contains("recentFilesHeader.widthAnchor.constraint(equalToConstant: 400)"))
    precondition(welcome.contains("layoutAttribute = .bottom"))
    precondition(welcome.contains("automaticallyAdjustsSize = false"))
    precondition(!welcome.contains("layoutAttribute = .top"))
    precondition(welcome.contains("let recentRowsTop = accessoryHeight + recentHeaderHeight + 12"))
    precondition(welcome.contains("NSEdgeInsets(top: recentRowsTop"))
    precondition(ffmpeg.contains("atTime:(double)time"))
    precondition(ffmpeg.contains("hasRequestedTime"))
    precondition(ffmpeg.contains("cancelThumbnailGeneration"))
    precondition(ffmpeg.contains("operation.isCancelled"))
    precondition(!project.contains("InitialWindowController.xib in Resources"))
    print("PASS: welcome window is programmatic, event-driven, and uses a dedicated sharp FFmpeg artwork source.")
  }
}
