// xcrun swiftc -parse-as-library yina/SharedShowStore.swift yina/ShowEpisodeIndexReader.swift other/tests/shared-show-smoke.swift -o /tmp/yina-shared-show-smoke
import Foundation

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String = "Check failed") throws {
  let value = try condition()
  precondition(value, message)
}

@main
struct SharedShowSmoke {
  static func main() throws {
    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("yina-shared-show-\(UUID())", isDirectory: true)
    try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: sandbox) }
    let root = sandbox.appendingPathComponent("Show")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try SharedShowStore(root: root.resolvingSymlinksInPath())
    let descriptor = try store.enable()
    let descriptorData = try Data(contentsOf: root.appendingPathComponent(".yina/show.json"))
    try check(!fm.fileExists(atPath: root.appendingPathComponent(".yina.json").path),
              "New show creation wrote legacy root metadata")
    try check(try store.enable().showID == descriptor.showID)
    let media = root.appendingPathComponent("Episode.mkv")
    try Data(repeating: 0, count: 100).write(to: media)
    try check(try SharedShowStore.discover(for: media)?.descriptor().showID == descriptor.showID)

    let now = Date()
    let date = ISO8601DateFormatter().string(from: now.addingTimeInterval(-1))
    let hash = String(repeating: "a", count: 40)
    func episode(_ path: String = "Episode.mkv", index: Int = 0, received: Int = 100) -> [String: Any] {
      ["id": ["hashString": hash, "fileIndex": index], "relativePath": path, "season": 0,
       "episode": 1, "bytesCompleted": received, "totalBytes": 100, "wanted": false]
    }
    func manifest(_ episodes: [[String: Any]], timestamp: String? = nil) -> [String: Any] {
      ["schemaVersion": 1, "hashString": hash, "capturedAt": timestamp ?? date, "episodes": episodes]
    }
    func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    func fragment(_ object: [String: Any], writer: UUID) throws {
      let directory = root.appendingPathComponent(".yina/transfers/\(writer.uuidString.lowercased())")
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      try data(["schemaVersion": 1, "showID": descriptor.showID.uuidString, "writerID": writer.uuidString,
                "index": object]).write(to: directory.appendingPathComponent("\(hash).json"))
    }
    let writerA = UUID(), writerB = UUID(), participantA = UUID(), participantB = UUID()
    try fragment(manifest([episode()]), writer: writerA)
    let catalog = try store.catalog()
    try check(catalog.episodes.count == 1 && catalog.episodes[0].isFresh())
    try check(catalog.episodes[0].wanted == false && catalog.episodes[0].received == 100)
    try check(catalog.episodes[0].localSize == 100 && catalog.episodes[0].exists == true)
    try Data(repeating: 0, count: 10).write(to: media)
    try check(try store.catalog().episodes[0].localSize == 10, "Truncation mistaken for complete local media")
    try fragment(manifest([episode(received: 20)], timestamp: ISO8601DateFormatter().string(from: now.addingTimeInterval(100))), writer: writerB)
    try check(try store.catalog().episodes[0].received == 100, "Future writer displaced a usable snapshot")

    for invalid in [episode("../escape.mkv"), episode("/absolute.mkv"), episode("a//b.mkv"), episode(received: 101)] {
      try check(ShowEpisodeIndexReader.decode(try data(manifest([invalid]))) == nil)
    }
    try check(ShowEpisodeIndexReader.decode(try data(manifest([episode(), episode("episode.mkv", index: 1)]))) == nil)
    try check(ShowEpisodeIndexReader.decode(try data(manifest([episode(), episode("second.mkv")]))) == nil)
    var unknown = episode("Featurette.MKV")
    unknown["season"] = NSNull(); unknown["episode"] = NSNull(); unknown["wanted"] = NSNull()
    try check(ShowEpisodeIndexReader.decode(try data(manifest([unknown])))?.episodes.first?.path == "Featurette.MKV")
    var padded = manifest([episode()])
    padded["extension"] = String(repeating: " ", count: 5 * 1024 * 1024)
    try check(ShowEpisodeIndexReader.decode(try data(padded)) != nil, "Valid Glass exports over 4 MiB rejected")
    padded["extension"] = String(repeating: " ", count: 10 * 1024 * 1024)
    try check(ShowEpisodeIndexReader.decode(try data(padded)) == nil)

    func progress(_ participant: UUID, _ writer: UUID, revision: UInt64 = 1, time: Date = now, position: Double = 25) -> SharedShowStore.Progress {
      .init(showID: descriptor.showID, participantID: participant, writerID: writer, revision: revision,
            updatedAt: time, relativePath: "Episode.mkv", position: position, duration: 100, activity: .paused)
    }
    try store.publish(progress(participantA, writerA))
    try store.publish(progress(participantB, writerB))
    try check(try store.progress(showID: descriptor.showID).count == 2, "One writer erased another")
    try store.publish(progress(participantA, writerA, revision: 2, position: 10))
    let records = try store.progress(showID: descriptor.showID)
    try check(records.first { $0.writerID == writerA }?.position == 10, "Explicit rewind replaced by furthest progress")
    try check(try store.progress(showID: descriptor.showID, participantID: participantA,
                                 writerID: writerA)?.revision == 2, "Direct host read missed the latest revision")
    let malformedWriter = UUID()
    let malformedFolder = root.appendingPathComponent(".yina/progress/\(participantA.uuidString.lowercased())")
    try Data("{malformed".utf8).write(to: malformedFolder.appendingPathComponent("\(malformedWriter.uuidString.lowercased()).json"))
    try check(try store.progress(showID: descriptor.showID, participantID: participantA,
                                 writerID: malformedWriter) == nil, "Malformed direct host record was accepted")
    try check(try store.progress(showID: descriptor.showID).count == 2, "Malformed peer displaced valid records")
    do { try store.publish(progress(participantA, writerA)); fatalError("Accepted a decreasing revision") } catch {}
    do { try store.publish(progress(participantA, writerA, revision: 3, position: .infinity)); fatalError("Accepted infinite progress") } catch {}
    try store.publish(progress(participantA, UUID(), time: now.addingTimeInterval(100)))
    try check(try store.progress(showID: descriptor.showID).count == 2, "Future progress offered for resume")
    var host = progress(participantA, writerA)
    host.watchTogether = true
    host.playbackRate = 1.5
    try check(SharedPlaybackSync.target(for: host, at: now.addingTimeInterval(2))?.position == 25,
              "Paused host position advanced")
    let playing = SharedShowStore.Progress(showID: descriptor.showID, participantID: participantA,
      writerID: writerA, revision: 3, updatedAt: now, relativePath: "Episode.mkv", position: 25,
      duration: 100, activity: .playing, playbackRate: 1.5, watchTogether: true)
    try check(SharedPlaybackSync.target(for: playing, at: now.addingTimeInterval(2))?.position == 28)
    try check(SharedPlaybackSync.target(for: playing, at: now.addingTimeInterval(-1)) == nil)
    try check(SharedPlaybackSync.target(for: playing, at: now.addingTimeInterval(11)) == nil)
    host.watchTogether = false
    try check(SharedPlaybackSync.target(for: host, at: now) == nil)
    let ending = SharedShowStore.Progress(showID: descriptor.showID, participantID: participantA,
      writerID: writerA, revision: 4, updatedAt: now, relativePath: "Episode.mkv", position: 99,
      duration: 100, activity: .playing, playbackRate: 1.5, watchTogether: true)
    try check(SharedPlaybackSync.target(for: ending, at: now.addingTimeInterval(2))?.position == 99.5,
              "Host extrapolation sought to EOF")
    for command in [["cycle", "pause"], ["no-osd", "seek", "5"], ["multiply", "speed", "1.1"], ["frame-step"]] {
      try check(SharedPlaybackSync.isTransportCommand(command), "Transport shortcut missed")
    }
    for command in [["cycle", "sub-visibility"], ["add", "volume", "5"], ["screenshot"], ["show-text", "pause"]] {
      try check(!SharedPlaybackSync.isTransportCommand(command), "Unrelated shortcut took over playback")
    }
    let request = SharedShowStore.Demand(showID: descriptor.showID, requestID: UUID(), participantID: participantA,
      writerID: writerA, revision: 3, updatedAt: now, relativePath: "Episode.mkv", hashString: hash,
      fileIndex: 0, cancelled: false)
    try store.publish(request)
    let requestURL = root.appendingPathComponent(".yina/demand/\(writerA.uuidString.lowercased()).json")
    let requestJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: requestURL)) as! [String: Any]
    try check(requestJSON["updatedAt"] is String && requestJSON["relativePath"] as? String == "Episode.mkv")
    try check(try Data(contentsOf: root.appendingPathComponent(".yina/show.json")) == descriptorData, "Progress changed the descriptor")

    // A different selected show with a symlink inside .yina must never write outside it.
    let unsafe = sandbox.appendingPathComponent("Unsafe")
    let outside = sandbox.appendingPathComponent("Outside")
    try fm.createDirectory(at: unsafe, withIntermediateDirectories: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: root.appendingPathComponent("Escaped.mkv"), withDestinationURL: outside.appendingPathComponent("missing.mkv"))
    do { try store.validateRequestPath("Escaped.mkv"); fatalError("Requested a symlink target") } catch {}
    try fm.createSymbolicLink(at: root.appendingPathComponent("EscapedFolder"), withDestinationURL: outside)
    do { try store.validateRequestPath("EscapedFolder/missing.mkv"); fatalError("Requested through a symlink ancestor") } catch {}
    try store.validateRequestPath("Missing/Season/Episode.mkv")
    let unsafeStore = try SharedShowStore(root: unsafe.resolvingSymlinksInPath())
    let unsafeID = try unsafeStore.enable().showID
    try fm.moveItem(at: unsafe.appendingPathComponent(".yina"),
                    to: unsafe.appendingPathComponent(".yina.safe"))
    try fm.createSymbolicLink(at: unsafe.appendingPathComponent(".yina"), withDestinationURL: outside)
    let escaped = SharedShowStore.Progress(showID: unsafeID, participantID: participantA, writerID: writerA,
      revision: 1, updatedAt: now, relativePath: "Episode.mkv", position: 5, duration: 100, activity: .playing)
    do { try unsafeStore.publish(escaped); fatalError("Followed a metadata symlink") } catch {}
    try check(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)

    let legacyRoot = sandbox.appendingPathComponent("Legacy")
    try fm.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
    let legacyBytes = try data(manifest([episode()]))
    try legacyBytes.write(to: legacyRoot.appendingPathComponent(".yina.json"))
    let legacy = try SharedShowStore(root: legacyRoot.resolvingSymlinksInPath())
    try check(try legacy.enable().showID == SharedShowStore.legacyShowID(hash: hash))
    try check(try Data(contentsOf: legacyRoot.appendingPathComponent(".yina/legacy-index.json")) == legacyBytes,
              "Legacy inventory bytes changed during migration")
    try check(!fm.fileExists(atPath: legacyRoot.appendingPathComponent(".yina.json").path),
              "Recognized legacy file was not moved inside .yina")
    try check(try legacy.descriptor().showID == SharedShowStore.legacyShowID(hash: hash))
    try Data("{\"schemaVersion\":99}".utf8).write(to: legacyRoot.appendingPathComponent(".yina.json"))
    do { _ = try legacy.enable(); fatalError("Overwrote an unknown descriptor") } catch {}
    print("PASS: v1/v2 identity, Glass fragments, size caps, totals, duplicate/traversal validation, nullable fields, truncation, future snapshots, independent writers, revisions, demands, symlink containment, and unknown-schema preservation")
  }
}
