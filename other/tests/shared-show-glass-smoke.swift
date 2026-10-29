// Compile alongside Glass's real Models, TorrentNameCleaner, ShowEpisodeIndex,
// and YinaShowStore sources. This verifies the two applications' wire formats.
import Foundation

@main struct SharedShowGlassSmoke {
  static func main() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("yina-glass-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let yina = try SharedShowStore(root: root)
    let identity = try yina.enable()
    let glass = YinaShowStore(rootURL: root)
    let fromGlass = try await glass.readDescriptor()
    precondition(fromGlass?.showID == identity.showID)
    let hash = "0123456789abcdef0123456789abcdef01234567"
    precondition(SharedShowStore.legacyShowID(hash: hash) == YinaShowStore.deterministicShowID(for: hash))
    let object: [String: Any] = ["schemaVersion": 1, "hashString": hash,
      "capturedAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-1)),
      "episodes": [["id": ["hashString": hash, "fileIndex": 4], "relativePath": "Special.MKV",
                     "bytesCompleted": 20, "totalBytes": 100, "season": NSNull(), "episode": NSNull(), "wanted": true]]]
    let index = try JSONDecoder().decode(ShowEpisodeIndex.self, from: JSONSerialization.data(withJSONObject: object))
    try await glass.publishTransferSnapshot(index, showID: identity.showID, writerID: UUID())
    let catalog = try yina.catalog()
    precondition(catalog.episodes.first?.fileIndex == 4 && catalog.episodes.first?.received == 20)
    let writer = UUID(), participant = UUID()
    try yina.publish(SharedShowStore.Progress(showID: identity.showID, participantID: participant, writerID: writer,
      revision: 1, updatedAt: Date(), relativePath: "Special.MKV", position: 25, duration: 100, activity: .paused,
      playbackRate: 1.25, watchTogether: true))
    let received = try await glass.readProgress(showID: identity.showID)
    precondition(received.count == 1 && received[0].position == 25 && received[0].coverage.isEmpty)
    try await glass.publishProgress(YinaProgressSnapshot(showID: identity.showID, participantID: UUID(), writerID: UUID(),
      revision: 1, relativePath: "Special.MKV", position: 35, duration: 100, activity: .stopped,
      coverage: [YinaCoverageInterval(start: 0, end: 20)]))
    let peers = try yina.progress(showID: identity.showID)
    precondition(peers.count == 2 && peers.contains { $0.position == 35 })
    let requestID = UUID()
    try yina.publish(SharedShowStore.Demand(showID: identity.showID, requestID: requestID, participantID: participant,
      writerID: writer, revision: 2, updatedAt: Date(), relativePath: "Special.MKV", hashString: hash, fileIndex: 4, cancelled: false))
    let demand = try await glass.readDemand(showID: identity.showID)
    precondition(demand.count == 1 && demand[0].requestID == requestID && demand[0].fileIndex == 4)
    print("PASS: Glass publishes → YINA reads; YINA progress/demand → Glass reads; Glass progress → YINA reads; identical legacy show IDs")
  }
}
