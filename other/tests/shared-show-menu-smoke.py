#!/usr/bin/env python3
"""Compile production sidebar menu methods into a small native AppKit fixture."""

from pathlib import Path
import os
import subprocess
import tempfile


repo = Path(__file__).resolve().parents[2]
source = (repo / "yina/SidebarPlaylistPane.swift").read_text()


def method(name: str) -> str:
    marker = f"  private func {name}("
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    raise AssertionError(f"unterminated production method: {name}")


methods = "\n\n".join(
    method(name)
    for name in ("updateSharedShowButton", "buildSharedShowMenu", "addDownloadRequestActions")
)
rounding_source = (repo / "yina/Extensions.swift").read_text()
rounding_start = rounding_source.index("  func roundedHalfDown() -> Double {")
rounding_end = rounding_source.index("\n  }", rounding_start) + len("\n  }")
rounding_method = rounding_source[rounding_start:rounding_end]
infinite_line = next(
    line.strip()
    for line in (repo / "yina/AppData.swift").read_text().splitlines()
    if "static let infinite = VideoTime(999, 0, 0)" in line
)

fixture = r'''import AppKit
import Foundation

// The production store and playback target implementation are compiled beside
// this fixture. These doubles supply only the PlayerCore/session/view boundary.
final class SharedShowSession {
  static let participantID = UUID()
  var requestStatus: String?
  var requestFileName: String?
  var canRetryRequest = false
  var canWithdrawRequest = false
  var isHosting = false
  var followingWriter: UUID?
  var showID: UUID?
  var watchStatus: String?
  var status: String?
  var positions: [SharedShowStore.Progress] = []
  var relativePath: String?
  var hostQueueItems: [String] = []
  var hostQueueCurrent: String?
}

final class PlayerCore {
  final class State { var loaded = false }
  final class Info {
    var currentURL: URL?
    let state = State()
  }
  let info = Info()
  let sharedShow = SharedShowSession()
}

enum Constants { enum Time { INFINITE_LINE } }
extension Double {
ROUNDING_METHOD
}

final class SidebarPlaylistPane: NSView {
  let player: PlayerCore
  private let sharedShowButton = NSPopUpButton(frame: .zero, pullsDown: true)

  init(player: PlayerCore) {
    self.player = player
    super.init(frame: .zero)
    sharedShowButton.menu = NSMenu()
    sharedShowButton.addItem(withTitle: "Shared Show")
  }
  required init?(coder: NSCoder) { fatalError("unused") }

  @objc private func leaveWatchTogether(_ sender: NSMenuItem) {}
  @objc private func enableSharedShow(_ sender: NSMenuItem) {}
  @objc private func hostWatchTogether(_ sender: NSMenuItem) {}
  @objc private func followSharedViewer(_ sender: NSMenuItem) {}
  @objc private func resumeSharedPosition(_ sender: NSMenuItem) {}
  @objc private func retryDownloadRequest(_ sender: NSMenuItem) {}
  @objc private func withdrawDownloadRequest(_ sender: NSMenuItem) {}

PRODUCTION_METHODS

  func buttonEnabled() -> Bool { updateSharedShowButton(); return sharedShowButton.isEnabled }
  func menu() -> NSMenu { let value = NSMenu(); buildSharedShowMenu(value); return value }
}

func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
  menu.items.first { $0.title == title }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  precondition(condition(), message)
}

@main enum Smoke {
  static func main() {
    _ = NSApplication.shared
    let player = PlayerCore()
    let pane = SidebarPlaylistPane(player: player)

    // A follower can leave even when the show descriptor and episode are gone.
    player.sharedShow.followingWriter = UUID()
    player.sharedShow.watchStatus = "Disconnected from host"
    require(pane.buttonEnabled(), "disconnected follower button disabled")
    var menu = pane.menu()
    require(item(menu, "Leave Watch Together")?.isEnabled == true, "disconnected follower cannot leave")
    require(item(menu, "Enable for This Show…") == nil, "follower offered conflicting enable action")
    require(item(menu, "Disconnected from host")?.isEnabled == false, "status should be read-only")

    // EOF clears the loaded state, while the Watch Together membership remains.
    player.info.currentURL = URL(fileURLWithPath: "/tmp/ended.mkv")
    player.info.state.loaded = false
    require(pane.buttonEnabled(), "EOF footer disabled while following")
    require(item(pane.menu(), "Leave Watch Together")?.isEnabled == true, "EOF hid Leave")

    player.sharedShow.followingWriter = nil
    player.sharedShow.watchStatus = nil
    player.sharedShow.showID = UUID()
    player.sharedShow.relativePath = "Season 1/Now.mkv"
    let freshWriter = UUID()
    let now = Date()
    let fresh = SharedShowStore.Progress(showID: player.sharedShow.showID!, participantID: UUID(),
      writerID: freshWriter, revision: 1, updatedAt: now,
      relativePath: "Season 2/Next.mkv", position: 15, duration: 90, activity: .playing,
      playbackRate: 1, watchTogether: true)
    let stale = SharedShowStore.Progress(showID: player.sharedShow.showID!, participantID: UUID(),
      writerID: UUID(), revision: 1, updatedAt: now.addingTimeInterval(-60),
      relativePath: "Season 3/Old.mkv", position: 15, duration: 90, activity: .playing,
      playbackRate: 1, watchTogether: true)
    player.sharedShow.positions = [fresh, stale]
    menu = pane.menu()
    require(item(menu, "Host Watch Together")?.isEnabled == true, "fresh local episode cannot host")
    let follow = menu.items.first { $0.title.contains("Next.mkv") }
    require(follow?.isEnabled == true && follow?.representedObject is SharedShowStore.Progress,
            "fresh cross-episode host unavailable")
    require(!menu.items.contains { $0.title.contains("Old.mkv") }, "stale host offered")

    player.sharedShow.hostQueueItems = ["Season 1/Now.mkv", "Season 2/Next.mkv", "Season 3/Last.mkv"]
    player.sharedShow.hostQueueCurrent = "Season 2/Next.mkv"
    menu = pane.menu()
    let queue = item(menu, "Shared Queue · 3 episodes")?.submenu
    require(queue?.items.map(\.title) == player.sharedShow.hostQueueItems, "shared queue changed order")
    require(queue?.items.map(\.isEnabled) == [false, false, false], "shared queue should be read-only")
    require(queue?.items.map(\.state) == [.off, .on, .off], "shared queue current marker wrong")

    player.sharedShow.requestStatus = "Download request failed"
    player.sharedShow.requestFileName = "Requested Episode.mkv"
    player.sharedShow.canRetryRequest = true
    player.sharedShow.canWithdrawRequest = true
    menu = pane.menu()
    require(item(menu, "Download request failed")?.isEnabled == false, "request status should be read-only")
    require(item(menu, "Retry Download Request")?.isEnabled == true, "Retry missing")
    require(item(menu, "Withdraw Download Request")?.isEnabled == true, "Withdraw missing")
    require(menu.items.contains { $0.title.contains("Requested Episode.mkv") }, "requested filename missing")

    player.sharedShow.canRetryRequest = false
    player.sharedShow.canWithdrawRequest = false
    menu = pane.menu()
    require(item(menu, "Retry Download Request") == nil, "Retry offered when unavailable")
    require(item(menu, "Withdraw Download Request") == nil, "Withdraw offered when unavailable")
    print("PASS: production sidebar button/menu methods, follower, EOF, host, queue, and request actions")
  }
}
'''.replace("PRODUCTION_METHODS", methods).replace("ROUNDING_METHOD", rounding_method).replace(
    "INFINITE_LINE", infinite_line
)

with tempfile.TemporaryDirectory(prefix="yina-shared-menu-") as directory:
    root = Path(directory)
    swift = root / "menu.swift"
    swift.write_text(fixture)
    cache = root / "module-cache"
    cache.mkdir()
    env = {**os.environ, "CLANG_MODULE_CACHE_PATH": str(cache), "SWIFT_MODULE_CACHE_PATH": str(cache)}
    binary = root / "menu"
    subprocess.run(
        ["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(cache),
         str(repo / "yina/SharedShowStore.swift"), str(repo / "yina/ShowEpisodeIndexReader.swift"),
         str(repo / "yina/VideoTime.swift"),
         str(swift), "-o", str(binary)],
        check=True, env=env,
    )
    subprocess.run([str(binary)], check=True, timeout=20, env=env)
