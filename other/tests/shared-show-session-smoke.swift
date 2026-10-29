// Compile with SharedShowSession, SharedShowStore, ShowEpisodeIndexReader and PlayerState.
// Only the mpv/UI boundary is replaced; the queue, lifecycle, and disk protocol are production code.
import AppKit

enum AppEnvironment {
  final class MemoryDefaults {
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
  }
  static let defaults = MemoryDefaults()
}
@MainActor final class PlayerCore {
  final class PlaylistItem { let filename: String; init(_ filename: String) { self.filename = filename } }
  final class Time { var second: Double; init(_ value: Double) { second = value } }
  final class Info {
    var currentURL: URL?
    var state = PlayerState.playing
    var videoPosition: Time? = Time(12)
    var videoDuration: Time? = Time(100)
    var playSpeed = 1.0
    var playlist: [PlaylistItem] = []
  }
  let info = Info()
  var seeks: [Double] = []
  var opened: [URL] = []
  var delayOpen = false
  var cancelled: [URL] = []
  var pendingOpen: (URL, ((Int?) -> Void)?)?
  var onControl: () -> Void = {}
  func syncPositionIfNeeded() {}
  func seek(absoluteSecond: Double) { onControl(); seeks.append(absoluteSecond); info.videoPosition?.second = absoluteSecond }
  func pause() { onControl(); info.state = .paused }
  func resume() { onControl(); info.state = .playing }
  func setSpeed(_ value: Double) { onControl(); info.playSpeed = value }
  func openURLsAsync(_ urls: [URL], shouldAutoLoad: Bool = true, completion: ((Int?) -> Void)? = nil) {
    onControl()
    if delayOpen, let first = urls.first { pendingOpen = (first, completion); return }
    opened.append(contentsOf: urls)
    completion?(urls.count)
  }
  func cancelSharedShowMediaPreparation(for expectedURL: URL) {
    if pendingOpen?.0 == expectedURL { pendingOpen = nil; cancelled.append(expectedURL) }
  }
  func finishPendingOpen() {
    guard let pendingOpen else { return }
    self.pendingOpen = nil
    opened.append(pendingOpen.0)
    pendingOpen.1?(1)
  }
}
enum Utility {
  static func quickOpenPanel(title: String, chooseDir: Bool, dir: URL? = nil,
                            sheetWindow: NSWindow? = nil, callback: @escaping (URL) -> Void) {
    fatalError("A session checkpoint opened a panel")
  }
}

@main struct SharedShowSessionSmoke {
  @MainActor static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("yina-session-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let a = root.appendingPathComponent("A.mkv"), b = root.appendingPathComponent("B.mkv")
    try Data([1]).write(to: a); try Data([1]).write(to: b)
    let store = try SharedShowStore(root: root)
    let descriptor = try store.enable()
    let player = PlayerCore()
    player.info.currentURL = a
    let session = SharedShowSession(player: player)
    player.onControl = { session.localControlChanged() }
    var waitNumber = 0
    func wait(_ predicate: () throws -> Bool) throws {
      waitNumber += 1
      let deadline = Date().addingTimeInterval(5)
      while try !predicate() {
        if Date() >= deadline { print("wait", waitNumber, "status", session.status ?? "nil", "watch", session.watchStatus ?? "nil", "show", session.showID?.uuidString ?? "nil", "queue", session.hostQueueItems, "opened", player.opened, "seeks", player.seeks); fflush(stdout) }
        precondition(Date() < deadline, "Session wait \(waitNumber) did not settle")
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
    }
    session.start()
    try wait { session.showID == descriptor.showID }
    var changes = 0
    let observer = NotificationCenter.default.addObserver(forName: .yinaSharedShowChanged, object: player,
                                                          queue: .main) { _ in changes += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }
    player.info.state = .paused
    let beforePause = changes
    session.checkpoint()
    try wait {
      guard changes > beforePause else { return false }
      return try store.progress(showID: descriptor.showID).first { $0.writerID == session.writerID }?.activity == .paused
    }
    let pausedRevision = try store.progress(showID: descriptor.showID).first { $0.writerID == session.writerID }!.revision
    let beforeRepeat = changes
    session.checkpoint()
    try wait { changes > beforeRepeat }
    let repeatedRevision = try store.progress(showID: descriptor.showID).first { $0.writerID == session.writerID }!.revision
    precondition(repeatedRevision == pausedRevision,
                 "Unchanged paused non-host checkpoint wrote a new revision")
    player.info.state = .playing
    player.info.videoPosition?.second = 37
    session.checkpoint()
    session.saveFinal(media: a, position: 38, duration: 100)
    player.info.currentURL = b
    player.info.videoPosition?.second = 4
    session.start()
    try wait { session.relativePath == "B.mkv" }
    let records = try store.progress(showID: descriptor.showID)
    let current = records.first { $0.writerID == session.writerID }!
    precondition(current.relativePath == "B.mkv" && current.position == 4, "Old completion displaced the new episode")
    let peer = SharedShowStore.Progress(showID: descriptor.showID, participantID: UUID(), writerID: UUID(),
      revision: 1, updatedAt: Date().addingTimeInterval(-1), relativePath: "B.mkv",
      position: 62, duration: 100, activity: .paused)
    try store.publish(peer)
    session.checkpoint()
    try wait { !session.positions.isEmpty }
    precondition(player.seeks.isEmpty, "Peer progress sought automatically")
    session.resume(peer)
    precondition(player.seeks == [62])
    var host = SharedShowStore.Progress(showID: descriptor.showID, participantID: peer.participantID,
      writerID: peer.writerID, revision: 2, updatedAt: Date(), relativePath: "B.mkv",
      position: 30, duration: 100, activity: .paused, playbackRate: 1.5, watchTogether: true)
    try store.publishQueue(.init(showID: descriptor.showID, participantID: peer.participantID,
      writerID: peer.writerID, revision: 2, updatedAt: Date(), items: ["A.mkv", "B.mkv"], current: "B.mkv"))
    try store.publish(host)
    session.checkpoint()
    try wait { session.positions.contains { $0.writerID == host.writerID && $0.revision == 2 } }
    session.follow(host)
    precondition(session.followingWriter == host.writerID)
    try wait { player.info.state == .paused && player.info.playSpeed == 1.5 && player.seeks.last == 30 }
    // Remote commands re-enter PlayerCore without detaching or echoing host control.
    precondition(session.followingWriter != nil)
    host = .init(showID: descriptor.showID, participantID: peer.participantID,
      writerID: peer.writerID, revision: 3, updatedAt: Date(), relativePath: "B.mkv",
      position: 40, duration: 100, activity: .playing, playbackRate: 1.5, watchTogether: true)
    try store.publish(host)
    session.checkpoint()
    try wait { player.info.state == .playing && (player.seeks.last ?? 0) >= 40 }
    precondition(session.followingWriter != nil)
    player.pause()
    precondition(session.followingWriter == nil, "Local pause failed to take control back")
    session.follow(host)
    try wait { player.info.state == .playing && (player.seeks.last ?? 0) >= 40 }
    let beforeStaleHost = player.seeks
    host = .init(showID: descriptor.showID, participantID: peer.participantID,
      writerID: peer.writerID, revision: 4, updatedAt: Date().addingTimeInterval(-30), relativePath: "B.mkv",
      position: 80, duration: 100, activity: .paused, playbackRate: 2, watchTogether: true)
    try store.publish(host)
    session.checkpoint()
    try wait { session.positions.contains { $0.writerID == host.writerID && $0.revision == 4 } }
    precondition(player.seeks == beforeStaleHost && player.info.state == .playing && player.info.playSpeed == 1.5,
                 "A stale host controlled local playback")
    host = .init(showID: descriptor.showID, participantID: peer.participantID,
      writerID: peer.writerID, revision: 5, updatedAt: Date(), relativePath: "A.mkv",
      position: 80, duration: 100, activity: .paused, playbackRate: 2, watchTogether: true)
    try store.publishQueue(.init(showID: descriptor.showID, participantID: peer.participantID,
      writerID: peer.writerID, revision: 5, updatedAt: Date(), items: ["A.mkv", "B.mkv"], current: "A.mkv"))
    try store.publish(host)
    session.checkpoint()
    try wait { session.positions.contains { $0.writerID == host.writerID && $0.revision == 5 } }
    try wait { player.opened.last.map { store.relativePath(for: $0) == "A.mkv" } == true }
    precondition(session.followingWriter == host.writerID && player.seeks == beforeStaleHost,
                 "Explicit follow did not switch episodes safely")
    host = .init(showID: descriptor.showID, participantID: peer.participantID,
      writerID: peer.writerID, revision: 6, updatedAt: Date(), relativePath: "B.mkv",
      position: 80, duration: 100, activity: .stopped, playbackRate: 2, watchTogether: false)
    try store.publish(host)
    session.checkpoint()
    try wait { session.followingWriter == nil }
    precondition(player.seeks == beforeStaleHost, "Ending the host session changed local position")
    session.hostWatchTogether()
    try wait {
      try store.progress(showID: descriptor.showID).contains { $0.writerID == session.writerID && $0.watchTogether == true }
    }
    session.leaveWatchTogether()
    try wait {
      try store.progress(showID: descriptor.showID).contains { $0.writerID == session.writerID && $0.watchTogether == false }
    }
    session.saveFinal(media: b, position: 64, duration: 100)
    try wait {
      try store.progress(showID: descriptor.showID).contains {
        $0.writerID == session.writerID && $0.activity == .stopped && $0.position == 64
      }
    }
    let beforeOtherFile = player.seeks
    player.info.currentURL = a
    session.resume(peer)
    precondition(player.seeks == beforeOtherFile, "Resume applied to a different current file")

    // A second follower exercises delayed preparation, rapid episode changes,
    // missing and partial media, and a copied old host record.
    let c = root.appendingPathComponent("C.mkv")
    let d = root.appendingPathComponent("D.mkv")
    let e = root.appendingPathComponent("E.mkv")
    try Data([1]).write(to: c)
    let follower = PlayerCore()
    follower.info.currentURL = a
    let following = SharedShowSession(player: follower)
    follower.onControl = { following.localControlChanged() }
    following.start()
    try wait { following.showID == descriptor.showID }
    let hostParticipant = UUID(), hostWriter = UUID()
    func publishHost(_ revision: UInt64, path: String, activity: SharedShowStore.Progress.Activity = .playing,
                     together: Bool = true) throws -> SharedShowStore.Progress {
      let record = SharedShowStore.Progress(showID: descriptor.showID, participantID: hostParticipant,
        writerID: hostWriter, revision: revision, updatedAt: Date(), relativePath: path,
        position: 12, duration: 100, activity: activity, playbackRate: 1, watchTogether: together)
      try store.publishQueue(.init(showID: descriptor.showID, participantID: hostParticipant,
        writerID: hostWriter, revision: revision, updatedAt: Date(),
        items: ["A.mkv", "B.mkv", "C.mkv", "D.mkv", "E.mkv"], current: path))
      try store.publish(record)
      return record
    }
    let firstHost = try publishHost(1, path: "B.mkv")
    follower.delayOpen = true
    following.follow(firstHost)
    try wait { follower.pendingOpen?.0.lastPathComponent == "B.mkv" }
    following.leaveWatchTogether()
    precondition(follower.pendingOpen == nil && follower.cancelled.last?.lastPathComponent == "B.mkv",
                 "Leaving did not cancel a delayed remote preparation")
    follower.finishPendingOpen()
    precondition(follower.opened.isEmpty, "Late remote preparation displaced local playback")
    follower.delayOpen = false
    follower.openURLsAsync([a])
    precondition(follower.opened.last == a, "Local open lost to canceled remote preparation")

    following.follow(firstHost)
    try wait { follower.opened.last?.lastPathComponent == "B.mkv" }
    follower.info.currentURL = follower.opened.last
    following.start()
    try wait { following.relativePath == "B.mkv" && following.followingWriter == hostWriter }
    _ = try publishHost(2, path: "C.mkv")
    following.checkpoint()
    try wait { follower.opened.last?.lastPathComponent == "C.mkv" }
    _ = try publishHost(3, path: "A.mkv")
    following.checkpoint()
    try wait { follower.opened.last?.lastPathComponent == "A.mkv" }
    // A late C load was still remotely requested, so it must not end following;
    // the latest A target remains authoritative.
    follower.info.currentURL = follower.opened.first { $0.lastPathComponent == "C.mkv" }
    following.start()
    try wait { following.followingWriter == hostWriter }
    follower.info.currentURL = follower.opened.last { $0.lastPathComponent == "A.mkv" }
    following.start()
    try wait { following.relativePath == "A.mkv" && following.followingWriter == hostWriter }

    _ = try publishHost(4, path: "D.mkv")
    let beforeMissing = follower.opened.count
    following.checkpoint()
    try wait { following.watchStatus?.contains("finish downloading") == true }
    precondition(follower.opened.count == beforeMissing, "Missing episode entered playback")
    try Data([1]).write(to: d)
    following.checkpoint()
    try wait { follower.opened.last?.lastPathComponent == "D.mkv" }

    try Data([1]).write(to: e)
    let transferWriter = UUID()
    let transferDir = root.appendingPathComponent(".yina/transfers/\(transferWriter.uuidString.lowercased())")
    try fm.createDirectory(at: transferDir, withIntermediateDirectories: true)
    let fragment = transferDir.appendingPathComponent("aa.json")
    func writeTransfer(_ received: Int) throws {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let json: [String: Any] = ["schemaVersion": 1, "showID": descriptor.showID.uuidString,
        "writerID": transferWriter.uuidString, "index": ["schemaVersion": 1, "hashString": "aa",
          "capturedAt": formatter.string(from: Date()), "episodes": [["id": ["hashString": "aa", "fileIndex": 0],
            "relativePath": "E.mkv", "season": 1, "episode": 5,
            "bytesCompleted": received, "totalBytes": 1, "wanted": true]]]]
      try JSONSerialization.data(withJSONObject: json).write(to: fragment, options: .atomic)
    }
    try writeTransfer(0)
    _ = try publishHost(5, path: "E.mkv")
    let beforePartial = follower.opened.count
    following.checkpoint()
    try wait { following.watchStatus?.contains("finish downloading") == true }
    precondition(follower.opened.count == beforePartial, "Partial managed episode entered playback")
    try writeTransfer(1)
    following.checkpoint()
    try wait { follower.opened.last?.lastPathComponent == "E.mkv" }

    let old = SharedShowStore.Progress(showID: descriptor.showID, participantID: hostParticipant,
      writerID: hostWriter, revision: 2, updatedAt: Date(), relativePath: "B.mkv",
      position: 85, duration: 100, activity: .playing, playbackRate: 2, watchTogether: true)
    let progressFile = root.appendingPathComponent(".yina/progress/\(hostParticipant.uuidString.lowercased())/\(hostWriter.uuidString.lowercased()).json")
    try SharedShowStore.encoder().encode(old).write(to: progressFile, options: .atomic)
    let beforeReplay = follower.opened.count
    following.checkpoint()
    try wait { following.positions.contains { $0.writerID == hostWriter && $0.revision == 2 } }
    precondition(follower.opened.count == beforeReplay && following.followingWriter == hostWriter,
                 "Copied old host record replayed a file change")

    let hostPlayer = PlayerCore()
    hostPlayer.info.currentURL = a
    hostPlayer.info.playlist = [.init(a.path), .init(b.path)]
    let hosting = SharedShowSession(player: hostPlayer)
    hostPlayer.onControl = { hosting.localControlChanged() }
    hosting.start()
    try wait { hosting.showID == descriptor.showID }
    hosting.hostWatchTogether()
    try wait { try store.queue(showID: descriptor.showID, participantID: SharedShowSession.participantID,
                               writerID: hosting.writerID)?.items == ["A.mkv", "B.mkv"] }
    hostPlayer.info.playlist = [.init(b.path), .init(a.path)]
    hosting.playlistChanged()
    try wait { try store.queue(showID: descriptor.showID, participantID: SharedShowSession.participantID,
                               writerID: hosting.writerID)?.items == ["B.mkv", "A.mkv"] }
    hosting.fileEnded(dueToStopCommand: false)
    hostPlayer.info.state = .idle
    hosting.stop()
    precondition(hosting.isHosting, "Natural EOF ended the host session before auto-next")
    try wait { try store.queue(showID: descriptor.showID, participantID: SharedShowSession.participantID,
                               writerID: hosting.writerID)?.current == nil }
    let waitingHost = try store.progress(showID: descriptor.showID).first { $0.writerID == hosting.writerID }!
    let beforeEOF = follower.opened.count
    following.follow(waitingHost)
    try wait { following.watchStatus?.contains("next episode") == true }
    precondition(follower.opened.count == beforeEOF, "Follower reopened finished episode at host EOF")
    hostPlayer.info.currentURL = b
    hostPlayer.info.state = .playing
    hosting.start()
    try wait { try store.progress(showID: descriptor.showID).contains {
      $0.writerID == hosting.writerID && $0.relativePath == "B.mkv" && $0.watchTogether == true
    } }
    following.checkpoint()
    try wait { follower.opened.last?.lastPathComponent == "B.mkv" }
    hosting.fileEnded(dueToStopCommand: true)
    hostPlayer.info.state = .idle
    hosting.stop()
    try wait { try store.progress(showID: descriptor.showID).contains {
      $0.writerID == hosting.writerID && $0.activity == .stopped && $0.watchTogether == false
    } }
    let racePlayer = PlayerCore()
    racePlayer.info.currentURL = a
    let raced = SharedShowSession(player: racePlayer)
    raced.start()
    try wait { raced.relativePath == "A.mkv" }
    let oldGeneration = raced.generationToken
    racePlayer.info.currentURL = b
    raced.start()
    try wait { raced.relativePath == "B.mkv" }
    raced.saveFinal(media: a, position: 90, duration: 100, sourceGeneration: oldGeneration)
    raced.checkpoint()
    try wait { try store.progress(showID: descriptor.showID).contains {
      $0.writerID == raced.writerID && $0.relativePath == "B.mkv"
    } }
    precondition(raced.relativePath == "B.mkv", "Late old-file final replaced the new context")

    print("PASS: shared queue/follow safety, EOF transition, and final-save generation")
  }
}
