// xcrun swiftc -parse-as-library yina/SharedShowStore.swift yina/ShowEpisodeIndexReader.swift other/tests/shared-show-queue-smoke.swift -o /tmp/yina-shared-queue-smoke
import Foundation

@main
struct SharedShowQueueSmoke {
  static func check(_ expression: @autoclosure () throws -> Bool, _ message: String = "Check failed") throws {
    let value = try expression()
    precondition(value, message)
  }

  static func main() throws {
    let files = FileManager.default
    let sandbox = files.temporaryDirectory.appendingPathComponent("yina-show-queue-\(UUID())")
    let root = sandbox.appendingPathComponent("Show")
    let outside = sandbox.appendingPathComponent("Outside")
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    try files.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: sandbox) }
    let store = try SharedShowStore(root: root)
    let showID = try store.enable().showID
    let participant = UUID(), writerA = UUID(), writerB = UUID()
    let unmanaged = root.appendingPathComponent("Local.mkv")
    let managed = root.appendingPathComponent("Season/Episode.mkv")
    try files.createDirectory(at: managed.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: 100).write(to: unmanaged)
    try Data(repeating: 8, count: 100).write(to: managed)
    let localPath = "Local.mkv", episodePath = "Season/Episode.mkv"
    try check(try store.resolvePlayable(path: localPath, showID: showID)?.resolvingSymlinksInPath() == unmanaged.resolvingSymlinksInPath())
    try check(try store.resolvePlayable(path: "Missing.mkv", showID: showID) == nil)

    let hash = String(repeating: "b", count: 40)
    func fragment(received: Int, capturedAt: Date = Date()) throws {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let value: [String: Any] = [
        "schemaVersion": 1, "showID": showID.uuidString, "writerID": writerA.uuidString,
        "index": ["schemaVersion": 1, "hashString": hash,
                  "capturedAt": formatter.string(from: capturedAt),
                  "episodes": [["id": ["hashString": hash, "fileIndex": 0],
                                "relativePath": episodePath, "season": 1, "episode": 1,
                                "bytesCompleted": received, "totalBytes": 100, "wanted": true]]]
      ]
      let directory = root.appendingPathComponent(".yina/transfers/\(writerA.uuidString.lowercased())")
      try files.createDirectory(at: directory, withIntermediateDirectories: true)
      let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
      try data.write(to: directory.appendingPathComponent("\(hash).json"), options: .atomic)
    }
    try fragment(received: 40)
    try check(try store.resolvePlayable(path: episodePath, showID: showID) == nil,
              "A partial managed file was playable")
    // Case-insensitive volumes must not turn a known partial file into an
    // apparently unmanaged path merely because queue capitalization differs.
    if files.fileExists(atPath: root.appendingPathComponent("season/episode.mkv").path) {
      try check(try store.resolvePlayable(path: "season/episode.mkv", showID: showID) == nil,
                "A case variant bypassed the managed completion check")
    }
    try fragment(received: 100)
    try check(try store.resolvePlayable(path: episodePath, showID: showID)?.resolvingSymlinksInPath() == managed.resolvingSymlinksInPath())
    try Data(repeating: 8, count: 10).write(to: managed)
    try check(try store.resolvePlayable(path: episodePath, showID: showID) == nil,
              "A truncated managed file was playable")
    try Data(repeating: 8, count: 100).write(to: managed)
    try fragment(received: 100, capturedAt: Date().addingTimeInterval(-20 * 60))
    try check(try store.resolvePlayable(path: episodePath, showID: showID) == nil,
              "A stale managed snapshot authorized playback")
    try fragment(received: 100)

    func record(_ writer: UUID, revision: UInt64 = 1, items: [String] = [localPath, episodePath],
                current: String? = episodePath) -> SharedShowStore.QueueRecord {
      .init(showID: showID, participantID: participant, writerID: writer, revision: revision,
            updatedAt: Date(), items: items, current: current)
    }
    try store.publishQueue(record(writerA))
    try store.publishQueue(record(writerB))
    try check(try store.queue(showID: showID, participantID: participant, writerID: writerA)?.current == episodePath)
    try check(try store.queue(showID: showID, participantID: participant, writerID: writerB)?.items.count == 2)
    try store.publishQueue(record(writerA, revision: 2, current: localPath))
    try check(try store.queue(showID: showID, participantID: participant, writerID: writerA)?.revision == 2)
    do { try store.publishQueue(record(writerA, revision: 1)); fatalError("Accepted stale queue revision") } catch {}
    do { try store.publishQueue(record(writerA, revision: 3, items: [localPath, "local.mkv"]));
      fatalError("Accepted casefold duplicate") } catch {}
    for path in ["../outside.mkv", "/absolute.mkv", ".yina/show.json", "Season//Episode.mkv"] {
      do { try store.publishQueue(record(writerA, revision: 3, items: [path], current: path));
        fatalError("Accepted unsafe queue path") } catch {}
      do { _ = try store.resolvePlayable(path: path, showID: showID);
        fatalError("Resolved unsafe queue path") } catch {}
    }
    do { try store.publishQueue(record(writerA, revision: 3, items: [localPath], current: episodePath));
      fatalError("Accepted current path outside queue") } catch {}

    try files.createSymbolicLink(at: root.appendingPathComponent("Escape.mkv"),
                                 withDestinationURL: outside.appendingPathComponent("Escape.mkv"))
    do { _ = try store.resolvePlayable(path: "Escape.mkv", showID: showID);
      fatalError("Resolved symlink outside show") } catch {}
    try files.createSymbolicLink(at: root.appendingPathComponent("EscapeFolder"), withDestinationURL: outside)
    do { _ = try store.resolvePlayable(path: "EscapeFolder/Episode.mkv", showID: showID);
      fatalError("Resolved symlink ancestor") } catch {}
    print("PASS: independent queues, revisions, path bounds, unmanaged playback, partial/stale/truncated managed refusal, and symlink containment")
  }
}
