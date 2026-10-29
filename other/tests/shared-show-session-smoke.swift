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
  final class Time { var second: Double; init(_ value: Double) { second = value } }
  final class Info {
    var currentURL: URL?
    var state = PlayerState.playing
    var videoPosition: Time? = Time(12)
    var videoDuration: Time? = Time(100)
    var playSpeed = 1.0
  }
  let info = Info()
  var seeks: [Double] = []
  var onControl: () -> Void = {}
  func syncPositionIfNeeded() {}
  func seek(absoluteSecond: Double) { onControl(); seeks.append(absoluteSecond); info.videoPosition?.second = absoluteSecond }
  func pause() { onControl(); info.state = .paused }
  func resume() { onControl(); info.state = .playing }
  func setSpeed(_ value: Double) { onControl(); info.playSpeed = value }
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
    func wait(_ predicate: () throws -> Bool) throws {
      let deadline = Date().addingTimeInterval(5)
      while try !predicate() {
        precondition(Date() < deadline, "Session did not settle")
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
    }
    session.start()
    try wait { session.showID == descriptor.showID }
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
    try store.publish(host)
    session.checkpoint()
    try wait { session.positions.contains { $0.writerID == host.writerID && $0.revision == 2 } }
    session.follow(host)
    precondition(session.followingWriter == host.writerID)
    precondition(player.info.state == .paused && player.info.playSpeed == 1.5 && player.seeks.last == 30)
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
    try store.publish(host)
    session.checkpoint()
    try wait { session.positions.contains { $0.writerID == host.writerID && $0.revision == 5 } }
    precondition(player.seeks == beforeStaleHost && player.info.state == .playing,
                 "Host's different episode controlled this episode")
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
    let beforeOtherFile = player.seeks
    player.info.currentURL = a
    session.resume(peer)
    precondition(player.seeks == beforeOtherFile, "Resume applied to a different current file")
    session.saveFinal(media: b, position: 64, duration: 100)
    try wait {
      try store.progress(showID: descriptor.showID).contains {
        $0.writerID == session.writerID && $0.activity == .stopped && $0.position == 64
      }
    }
    print("PASS: checkpoint queue, rapid file changes, final position, explicit resume, host pause/play/seek/rate, no control echo, local takeover, stale/ended hosts, host episode changes, host publication, and current-file isolation")
  }
}
