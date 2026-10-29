// xcrun swiftc -parse-as-library yina/SharedShowStore.swift yina/ShowEpisodeIndexReader.swift other/tests/shared-show-migration-smoke.swift -o /tmp/yina-shared-migration-smoke
import Foundation

@main
struct SharedShowMigrationSmoke {
  static func check(_ expression: @autoclosure () throws -> Bool) throws {
    let value = try expression()
    precondition(value)
  }
  static func main() throws {
    let files = FileManager.default
    let sandbox = files.temporaryDirectory.appendingPathComponent("yina-show-migration-\(UUID())")
    try files.createDirectory(at: sandbox, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: sandbox) }
    func folder(_ name: String) throws -> URL {
      let url = sandbox.appendingPathComponent(name)
      try files.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }
    func legacy(_ extra: [String: Any] = [:]) throws -> Data {
      let hash = String(repeating: "a", count: 40)
      var object: [String: Any] = [
        "schemaVersion": 1, "hashString": hash, "capturedAt": "2026-10-29T12:00:00Z",
        "episodes": [["id": ["hashString": hash, "fileIndex": 0],
                      "relativePath": "Season 1/Episode.mkv", "season": 1, "episode": 1,
                      "bytesCompleted": 12, "totalBytes": 100, "wanted": true]]
      ]
      object.merge(extra) { _, new in new }
      return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    let fresh = try folder("fresh")
    let freshStore = try SharedShowStore(root: fresh)
    let freshID = try freshStore.enable().showID
    try check(try freshStore.enable().showID == freshID)
    precondition(files.fileExists(atPath: fresh.appendingPathComponent(".yina/show.json").path))
    precondition(!files.fileExists(atPath: fresh.appendingPathComponent(".yina.json").path))

    let oldRoot = try folder("v1")
    let bytes = try legacy()
    try bytes.write(to: oldRoot.appendingPathComponent(".yina.json"))
    let oldStore = try SharedShowStore(root: oldRoot)
    let migrated = try oldStore.enable()
    precondition(migrated.showID == SharedShowStore.legacyShowID(hash: String(repeating: "a", count: 40)))
    try check(try Data(contentsOf: oldRoot.appendingPathComponent(".yina/legacy-index.json")) == bytes)
    precondition(!files.fileExists(atPath: oldRoot.appendingPathComponent(".yina.json").path))
    try check(try oldStore.catalog().episodes.first?.received == 12)
    try check(try oldStore.descriptor().showID == migrated.showID)

    let interrupted = try folder("interrupted")
    try files.createDirectory(at: interrupted.appendingPathComponent(".yina"), withIntermediateDirectories: true)
    try bytes.write(to: interrupted.appendingPathComponent(".yina/legacy-index.json"))
    let recovered = try SharedShowStore(root: interrupted)
    try check(try recovered.enable().showID == migrated.showID)
    try check(try Data(contentsOf: interrupted.appendingPathComponent(".yina/legacy-index.json")) == bytes)
    try check(try recovered.catalog().episodes.first?.received == 12)

    let quarantine = oldRoot.appendingPathComponent(".yina/.legacy-root-\(UUID()).pending")
    try bytes.write(to: quarantine)
    try check(try oldStore.descriptor().showID == migrated.showID)
    precondition(files.fileExists(atPath: quarantine.path), "Removed an active migrator's recent marker")
    try files.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: quarantine.path)
    try check(try oldStore.descriptor().showID == migrated.showID)
    precondition(!files.fileExists(atPath: quarantine.path), "Matching quarantine was not finalized")
    let conflictQuarantine = oldRoot.appendingPathComponent(".yina/.legacy-root-\(UUID()).pending")
    let unknownQuarantine = Data("{\"schemaVersion\":99}".utf8)
    try unknownQuarantine.write(to: conflictQuarantine)
    do { _ = try oldStore.descriptor(); fatalError("Silently ignored conflicting quarantine") } catch {}
    try check(try Data(contentsOf: conflictQuarantine) == unknownQuarantine)
    try files.removeItem(at: conflictQuarantine)

    let v2Root = try folder("v2")
    let v2Descriptor = SharedShowStore.Descriptor(showID: UUID(), createdAt: Date())
    let v2Bytes = try SharedShowStore.encoder().encode(v2Descriptor)
    try v2Bytes.write(to: v2Root.appendingPathComponent(".yina.json"))
    try check(try SharedShowStore(root: v2Root).enable().showID == v2Descriptor.showID)
    try check(try Data(contentsOf: v2Root.appendingPathComponent(".yina/show.json")) == v2Bytes)
    precondition(!files.fileExists(atPath: v2Root.appendingPathComponent(".yina.json").path))

    for (name, content) in [("unknown-top", try legacy(["private": "keep"])),
                            ("unknown-schema", Data("{\"schemaVersion\":99}".utf8))] {
      let root = try folder(name)
      try content.write(to: root.appendingPathComponent(".yina.json"))
      do { _ = try SharedShowStore(root: root).enable(); fatalError("Accepted unknown metadata") } catch {}
      try check(try Data(contentsOf: root.appendingPathComponent(".yina.json")) == content)
    }
    let nested = try folder("unknown-nested")
    var nestedObject = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    var episodes = nestedObject["episodes"] as! [[String: Any]]
    episodes[0]["foreign"] = "keep"
    nestedObject["episodes"] = episodes
    let nestedBytes = try JSONSerialization.data(withJSONObject: nestedObject)
    try nestedBytes.write(to: nested.appendingPathComponent(".yina.json"))
    do { _ = try SharedShowStore(root: nested).enable(); fatalError("Accepted unknown episode field") } catch {}
    try check(try Data(contentsOf: nested.appendingPathComponent(".yina.json")) == nestedBytes)

    let conflict = try folder("conflict")
    try bytes.write(to: conflict.appendingPathComponent(".yina.json"))
    try files.createDirectory(at: conflict.appendingPathComponent(".yina"), withIntermediateDirectories: true)
    let unrelated = try SharedShowStore.encoder().encode(SharedShowStore.Descriptor(showID: UUID(), createdAt: Date()))
    try unrelated.write(to: conflict.appendingPathComponent(".yina/show.json"))
    do { _ = try SharedShowStore(root: conflict).enable(); fatalError("Overwrote conflicting descriptor") } catch {}
    try check(try Data(contentsOf: conflict.appendingPathComponent(".yina/show.json")) == unrelated)
    try check(try Data(contentsOf: conflict.appendingPathComponent(".yina.json")) == bytes)

    let outside = try folder("outside")
    let symlink = try folder("symlink")
    try files.createSymbolicLink(at: symlink.appendingPathComponent(".yina"), withDestinationURL: outside)
    do { _ = try SharedShowStore(root: symlink).enable(); fatalError("Followed metadata symlink") } catch {}
    try check(try files.contentsOfDirectory(atPath: outside.path).isEmpty)
    let rootLink = try folder("root-link")
    let outsideMetadata = outside.appendingPathComponent("metadata.json")
    try bytes.write(to: outsideMetadata)
    try files.createSymbolicLink(at: rootLink.appendingPathComponent(".yina.json"),
                                 withDestinationURL: outsideMetadata)
    do { _ = try SharedShowStore(root: rootLink).enable(); fatalError("Followed legacy root symlink") } catch {}
    try check(try Data(contentsOf: outsideMetadata) == bytes)
    let descriptorLink = try folder("descriptor-link")
    try files.createDirectory(at: descriptorLink.appendingPathComponent(".yina"), withIntermediateDirectories: true)
    try files.createSymbolicLink(at: descriptorLink.appendingPathComponent(".yina/show.json"),
                                 withDestinationURL: outsideMetadata)
    do { _ = try SharedShowStore(root: descriptorLink).enable(); fatalError("Followed descriptor symlink") } catch {}
    try check(try Data(contentsOf: outsideMetadata) == bytes)

    let race = try folder("race")
    let lock = NSLock()
    var ids: [UUID] = []
    var errors = 0
    DispatchQueue.concurrentPerform(iterations: 12) { _ in
      do {
        let id = try SharedShowStore(root: race).enable().showID
        lock.lock(); ids.append(id); lock.unlock()
      } catch {
        lock.lock(); errors += 1; lock.unlock()
      }
    }
    precondition(errors == 0 && ids.count == 12 && Set(ids).count == 1,
                 "Concurrent creators disagreed or failed")
    let migrationRace = try folder("migration-race")
    try bytes.write(to: migrationRace.appendingPathComponent(".yina.json"))
    ids.removeAll()
    errors = 0
    DispatchQueue.concurrentPerform(iterations: 12) { _ in
      do {
        let id = try SharedShowStore(root: migrationRace).enable().showID
        lock.lock(); ids.append(id); lock.unlock()
      } catch {
        lock.lock(); errors += 1; lock.unlock()
      }
    }
    precondition(errors == 0 && ids.count == 12 && Set(ids) == [migrated.showID],
                 "Concurrent migrators disagreed or failed")
    try check(try Data(contentsOf: migrationRace.appendingPathComponent(".yina/legacy-index.json")) == bytes)
    precondition(!files.fileExists(atPath: migrationRace.appendingPathComponent(".yina.json").path))
    print("PASS: canonical creation, byte-preserving v1/v2 migration, interrupted recovery, quarantine conflicts, strict fields, symlinks, and creator race")
  }
}
