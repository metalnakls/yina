// Compile with SharedShowSession, SharedShowLAN, SharedShowStore, ShowEpisodeIndexReader, and PlayerState.
// This fixture covers archive persistence and explicit resume without a real mpv engine.
import AppKit

enum AppEnvironment {
  final class MemoryDefaults {
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
  }
  static let defaults = MemoryDefaults()
}
struct ShowFolder { let folderURL: URL }
enum ShowFolderSnapshotStore {
  static func loadCards() -> [ShowFolder] { [] }
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
  var sharedShow: SharedShowSession!
  func syncPositionIfNeeded() {}
  func seek(absoluteSecond: Double) { sharedShow.localControlChanged(); seeks.append(absoluteSecond); info.videoPosition?.second = absoluteSecond }
  func pause() { sharedShow.localControlChanged(); info.state = .paused }
  func resume() { sharedShow.localControlChanged(); info.state = .playing }
  func setSpeed(_ value: Double) { sharedShow.localControlChanged(); info.playSpeed = value }
  func openURLsAsync(_ urls: [URL], shouldAutoLoad: Bool = true, completion: ((Int?) -> Void)? = nil) {
    sharedShow.localMediaChangeRequested()
    info.currentURL = urls.first
    completion?(urls.count)
  }
  func cancelSharedShowMediaPreparation(for expectedURL: URL) {}
}

@main struct SharedShowSessionSmoke {
  @MainActor static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("yina-session-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let media = root.appendingPathComponent("Movie.mkv")
    try Data([1]).write(to: media)
    let store = try SharedShowStore(root: root)
    let descriptor = try store.enable()
    let player = PlayerCore()
    player.info.currentURL = media
    let session = SharedShowSession(player: player)
    player.sharedShow = session
    func wait(_ note: String, _ condition: () throws -> Bool) throws {
      let deadline = Date().addingTimeInterval(8)
      while try !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      }
      let settled = try condition()
      if !settled {
        print("timeout", note, "status", session.status ?? "nil", "show", session.showID?.uuidString ?? "nil",
              "records", try store.progress(showID: descriptor.showID).map { "\($0.writerID):\($0.position):\($0.activity)" })
        fflush(stdout)
      }
      precondition(settled, note)
    }
    session.start()
    try wait("enabled identity was not found") { session.showID == descriptor.showID }
    try wait("enabled media did not automatically host") { session.isHosting }
    try wait("progress was not archived") {
      try store.progress(showID: descriptor.showID).contains { $0.writerID == session.writerID && $0.position == 12 }
    }
    let peer = SharedShowStore.Progress(showID: descriptor.showID, participantID: UUID(), writerID: UUID(),
      revision: 1, updatedAt: Date(), relativePath: "Movie.mkv", position: 42, duration: 100,
      activity: .paused)
    try store.publish(peer)
    session.checkpoint()
    try wait("peer archive not found") { session.positions.contains { $0.writerID == peer.writerID } }
    precondition(player.seeks.isEmpty, "archive moved playback without explicit resume")
    session.resume(peer)
    precondition(player.seeks == [42], "explicit resume did not seek")
    player.info.videoPosition?.second = 47
    session.saveFinal(media: media, position: 47, duration: 100)
    try wait("final position was not archived") {
      guard let final = try store.progress(showID: descriptor.showID).first(where: { $0.writerID == session.writerID }) else { return false }
      return final.activity == .stopped && final.position == 47
    }
    session.shutdown()
    precondition(!session.isHosting, "closed player still advertises")
    print("PASS: automatic hosting, passive archive, explicit resume, final save, shutdown")
  }
}
