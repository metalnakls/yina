import Cocoa

/// Builds the same commands for the menu bar and the playlist sidebar from cached session state.
@MainActor
enum SharedShowMenuContent {
  static func populate(_ menu: NSMenu, session: SharedShowSession, target: AnyObject, canEnable: Bool) {
    menu.autoenablesItems = false
    if let watchStatus = session.watchStatus {
      let item = NSMenuItem(title: watchStatus, action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }
    if let status = session.status {
      let item = NSMenuItem(title: status, action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }
    let watchingTogether = session.isHosting || session.lanFollowingRoomID != nil
    // Leave remains available while the share or current episode is unavailable.
    if watchingTogether {
      let leave = NSMenuItem(title: "Leave Watch Together", action: NSSelectorFromString("leaveWatchTogether:"), keyEquivalent: "")
      leave.target = target
      menu.addItem(leave)
    }
    if session.showID == nil {
      if !watchingTogether {
        let enable = NSMenuItem(title: "Enable for This Show", action: NSSelectorFromString("enableSharedShow:"), keyEquivalent: "")
        enable.target = target
        enable.isEnabled = canEnable
        menu.addItem(enable)
      }
    } else {
      if !watchingTogether {
        let host = NSMenuItem(title: "Host Watch Together", action: NSSelectorFromString("hostWatchTogether:"), keyEquivalent: "")
        host.target = target
        host.isEnabled = canEnable
        menu.addItem(host)
      }
    }
    for room in SharedShowLAN.shared.rooms.prefix(12) where room.id != session.hostingRoomID {
      let follow = NSMenuItem(title: "Watch with \(room.hostName) · \(room.title)",
                              action: NSSelectorFromString("joinSharedRoom:"), keyEquivalent: "")
      follow.target = target
      follow.representedObject = room
      follow.state = session.lanFollowingRoomID == room.id ? .on : .off
      menu.addItem(follow)
    }
    if !session.hostQueueItems.isEmpty {
      let queueItem = NSMenuItem(title: "Shared Queue · \(session.hostQueueItems.count) episodes", action: nil, keyEquivalent: "")
      let queue = NSMenu()
      queue.autoenablesItems = false
      for path in session.hostQueueItems {
        let item = NSMenuItem(title: path, action: nil, keyEquivalent: "")
        item.state = path == session.hostQueueCurrent ? .on : .off
        item.isEnabled = false
        queue.addItem(item)
      }
      queueItem.submenu = queue
      menu.addItem(queueItem)
    }
    for record in session.positions.filter({ $0.relativePath == session.relativePath }).prefix(12) {
      let viewer = record.participantID == SharedShowSession.participantID ? "This profile" : "Viewer \(record.participantID.uuidString.prefix(6))"
      let position = VideoTime(record.position).stringRepresentation
      let date = DateFormatter.localizedString(from: record.updatedAt, dateStyle: .short, timeStyle: .short)
      let item = NSMenuItem(title: "Resume at \(position) · \(viewer) · \(date)", action: NSSelectorFromString("resumeSharedPosition:"), keyEquivalent: "")
      item.target = target
      item.representedObject = record
      menu.addItem(item)
    }
    addDownloadRequestActions(to: menu, session: session, target: target)
    if menu.items.isEmpty { menu.addItem(withTitle: "No saved positions yet", action: nil, keyEquivalent: "") }
  }

  static func addDownloadRequestActions(to menu: NSMenu, session: SharedShowSession, target: AnyObject) {
    guard let status = session.requestStatus else { return }
    menu.addItem(.separator())
    if let name = session.requestFileName {
      let file = NSMenuItem(title: "Request: \(name)", action: nil, keyEquivalent: "")
      file.isEnabled = false
      menu.addItem(file)
    }
    let info = NSMenuItem(title: status, action: nil, keyEquivalent: "")
    info.isEnabled = false
    menu.addItem(info)
    if session.canRetryRequest {
      let retry = NSMenuItem(title: "Retry Download Request", action: NSSelectorFromString("retryDownloadRequest:"), keyEquivalent: "")
      retry.target = target
      menu.addItem(retry)
    }
    if session.canWithdrawRequest {
      let withdraw = NSMenuItem(title: "Withdraw Download Request", action: NSSelectorFromString("withdrawDownloadRequest:"), keyEquivalent: "")
      withdraw.target = target
      menu.addItem(withdraw)
    }
  }
}

/// The menu bar is shared by all windows. Pin the player when the submenu opens.
@MainActor
final class SharedShowMenuController: NSObject, NSMenuDelegate {
  private weak var player: PlayerCore?
  private let activePlayer: @MainActor () -> PlayerCore?

  init(activePlayer: @escaping @MainActor () -> PlayerCore? = {
    (NSApp.mainWindow?.windowController as? PlayerWindowController)?.player
      ?? PlayerCore.playerCores.first
  }) {
    self.activePlayer = activePlayer
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    player = activePlayer()
    menu.removeAllItems()
    guard let player else {
      let item = NSMenuItem(title: "Open a local episode to share", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
      return
    }
    SharedShowMenuContent.populate(menu, session: player.sharedShow, target: self,
                                   canEnable: player.info.currentURL?.isFileURL == true && player.info.state.loaded)
  }

  @objc private func enableSharedShow(_ sender: NSMenuItem) {
    player?.sharedShow.enableSharing()
  }
  @objc private func hostWatchTogether(_ sender: NSMenuItem) { player?.sharedShow.hostWatchTogether() }
  @objc private func leaveWatchTogether(_ sender: NSMenuItem) { player?.sharedShow.leaveWatchTogether() }
  @objc private func joinSharedRoom(_ sender: NSMenuItem) {
    guard let room = sender.representedObject as? SharedShowLAN.Room,
          let player else { return }
    SharedShowLAN.shared.join(room, player: player)
  }
  @objc private func resumeSharedPosition(_ sender: NSMenuItem) {
    guard let record = sender.representedObject as? SharedShowStore.Progress else { return }
    player?.sharedShow.resume(record)
  }
  @objc private func retryDownloadRequest(_ sender: NSMenuItem) { player?.sharedShow.retryRequest() }
  @objc private func withdrawDownloadRequest(_ sender: NSMenuItem) { player?.sharedShow.withdrawRequest() }
}
