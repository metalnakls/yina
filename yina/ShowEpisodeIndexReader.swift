import Foundation

/// Read-only availability inventory; shared identity and per-writer records live
/// in SharedShowStore. Download state is always a dated snapshot.
enum ShowEpisodeIndexReader {
  static let freshnessLimit: TimeInterval = 15 * 60
  static let maximumBytes = 10 * 1024 * 1024

  struct Episode: Sendable {
    let path: String
    let season: Int?
    let episode: Int?
    let received: UInt64
    let size: UInt64
    let wanted: Bool?
    var exists: Bool?
    var localSize: UInt64?
    var hashString = ""
    var fileIndex = 0
    var capturedAt = Date.distantPast
    var ambiguous = false

    func isFresh(at now: Date = Date()) -> Bool {
      let age = now.timeIntervalSince(capturedAt)
      return age >= 0 && age < ShowEpisodeIndexReader.freshnessLimit
    }
  }

  struct Snapshot: Sendable {
    let capturedAt: Date
    var episodes: [Episode]
    var root: URL?
    var showID: UUID?
    func isFresh(at now: Date = Date()) -> Bool {
      let age = now.timeIntervalSince(capturedAt)
      return age >= 0 && age < ShowEpisodeIndexReader.freshnessLimit
    }
  }

  struct Manifest: Codable {
    struct Record: Codable {
      struct Identity: Codable { let hashString: String; let fileIndex: Int }
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
    guard let store = try? SharedShowStore.discover(for: media) else { return nil }
    return try? store.catalog()
  }

  /// Separate decoding from filesystem discovery for deterministic validation.
  static func decode(_ data: Data) -> Snapshot? {
    guard data.count <= maximumBytes,
          let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
          manifest.schemaVersion == 1, SharedShowStore.validHash(manifest.hashString),
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
      guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
            record.id.hashString.caseInsensitiveCompare(manifest.hashString) == .orderedSame,
            record.id.fileIndex >= 0, ids.insert(record.id.fileIndex).inserted,
            paths.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
            record.bytesCompleted <= record.totalBytes,
            (record.season == nil && record.episode == nil) ||
              (record.season != nil && record.episode != nil && record.season! >= 0 && record.episode! > 0)
      else { return nil }
      episodes.append(Episode(path: path, season: record.season, episode: record.episode,
                              received: record.bytesCompleted, size: record.totalBytes,
                              wanted: record.wanted, exists: nil, localSize: nil,
                              hashString: manifest.hashString.lowercased(), fileIndex: record.id.fileIndex,
                              capturedAt: captured))
    }
    return Snapshot(capturedAt: captured, episodes: episodes)
  }
}
