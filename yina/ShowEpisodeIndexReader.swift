import Foundation

/// Read-only compatibility with Glass's version-one show inventory.
enum ShowEpisodeIndexReader {
  static let freshnessLimit: TimeInterval = 15 * 60
  static let maximumBytes = 4 * 1024 * 1024

  struct Episode: Sendable {
    let path: String
    let season: Int?
    let episode: Int?
    let received: UInt64
    let size: UInt64
    let wanted: Bool?
    var exists: Bool?
    var localSize: UInt64?
  }

  struct Snapshot: Sendable {
    let capturedAt: Date
    var episodes: [Episode]
    func isFresh(at now: Date = Date()) -> Bool {
      let age = now.timeIntervalSince(capturedAt)
      return age >= 0 && age < ShowEpisodeIndexReader.freshnessLimit
    }
  }

  private struct Manifest: Decodable {
    struct Record: Decodable {
      struct Identity: Decodable { let hashString: String; let fileIndex: Int }
      let id: Identity
      let relativePath: String
      let season: Int?
      let episode: Int?
      let bytesCompleted: UInt64
      let totalBytes: UInt64
      let wanted: Bool?
    }
    let schemaVersion: Int
    let hashString: String
    let capturedAt: String
    let episodes: [Record]
  }

  static func read(for media: URL) -> Snapshot? {
    precondition(!Thread.isMainThread, "Show inventory must be read off the UI thread")
    guard media.isFileURL else { return nil }
    let file = media.standardizedFileURL.resolvingSymlinksInPath()
    var folder = file.deletingLastPathComponent()
    let volume = try? folder.resourceValues(forKeys: [.volumeURLKey]).volume
    for _ in 0..<12 {
      let inventory = folder.appendingPathComponent(".yina.json")
      if FileManager.default.fileExists(atPath: inventory.path) {
        guard inventory.resolvingSymlinksInPath().deletingLastPathComponent() == folder,
              let handle = try? FileHandle(forReadingFrom: inventory) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes,
              var result = decode(data) else { return nil }
        // Only bounded local checks; the inventory is not permission to scan a share.
        for index in result.episodes.indices.prefix(16) {
          let local = folder.appendingPathComponent(result.episodes[index].path).resolvingSymlinksInPath()
          guard local.path.hasPrefix(folder.path == "/" ? "/" : folder.path + "/") else { return nil }
          let attributes = try? FileManager.default.attributesOfItem(atPath: local.path)
          result.episodes[index].exists = attributes != nil
          result.episodes[index].localSize = (attributes?[.size] as? NSNumber)?.uint64Value
        }
        return result
      }
      let parent = folder.deletingLastPathComponent()
      if parent == folder || folder == volume { break }
      folder = parent
    }
    return nil
  }

  /// Separate decoding from filesystem discovery for deterministic validation.
  static func decode(_ data: Data) -> Snapshot? {
    guard data.count <= maximumBytes,
          let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
          manifest.schemaVersion == 1, !manifest.hashString.isEmpty,
          manifest.episodes.count <= 20_000 else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fractional = formatter.date(from: manifest.capturedAt)
    formatter.formatOptions = [.withInternetDateTime]
    guard let captured = fractional ?? formatter.date(from: manifest.capturedAt) else { return nil }
    var ids = Set<Int>()
    var paths = Set<String>()
    var episodes: [Episode] = []
    for record in manifest.episodes {
      let path = record.relativePath
      let components = path.split(separator: "/", omittingEmptySubsequences: false)
      guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
            record.id.hashString.caseInsensitiveCompare(manifest.hashString) == .orderedSame,
            record.id.fileIndex >= 0, ids.insert(record.id.fileIndex).inserted,
            paths.insert(path).inserted else { return nil }
      episodes.append(Episode(path: path, season: record.season, episode: record.episode,
                              received: record.bytesCompleted, size: record.totalBytes,
                              wanted: record.wanted, exists: nil, localSize: nil))
    }
    return Snapshot(capturedAt: captured, episodes: episodes)
  }
}
