import Cocoa
import Foundation

private let fixtureTimestamp: Int64 = 1_700_000_000

enum Logger {
  enum Subsystem { case thumbnailCache }
  enum Level { case debug, warning, error }
  static func makeSubsystem(_ name: String, _ categories: [String]) -> Subsystem { .thumbnailCache }
  static func log(_ message: () -> String, level: Level, subsystem: Subsystem) {}
}

enum Utility {
  static let thumbnailCacheURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("yina-preview-cache-import-unused-\(UUID().uuidString)", isDirectory: true)
  static func createDirIfNotExist(url: URL) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }
}

enum Preference {
  enum Key { case maxThumbnailPreviewCacheSize }
  static func integer(for key: Key) -> Int { 0 }
}

enum FloatingPointByteCountFormatter {
  enum PrefixFactor { case mi; var rawValue: Int { 1_048_576 } }
}

final class CacheManager {
  static let shared = CacheManager()
  var needsRefresh = false
  func getCacheSize() -> Int { 0 }
  func clearOldCache() {}
}

final class FFThumbnail {
  var realTime: Double = 0
  var image: NSImage?
}

extension Data {
  init<T>(bytesOf value: T) {
    var value = value
    self = Swift.withUnsafeBytes(of: &value) { Data($0) }
  }
}

extension FileHandle {
  func read<T>(type: T.Type) -> T? {
    let data = readData(ofLength: MemoryLayout<T>.size)
    guard data.count == MemoryLayout<T>.size else { return nil }
    return data.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
  }
}

@main
enum PreviewCacheImportSmoke {
  static func main() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("yina-preview-cache-import-smoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appendingPathComponent("legacy", isDirectory: true)
    let destination = root.appendingPathComponent("yina", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let video = root.appendingPathComponent("video.mp4")
    try Data("temporary video fixture".utf8).write(to: video)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(fixtureTimestamp))], ofItemAtPath: video.path)
    let videoSize = UInt64(try FileManager.default.attributesOfItem(atPath: video.path)[.size] as! Int)

    func cache(_ version: UInt8 = 2, size: UInt64? = nil, modified: Int64 = fixtureTimestamp, payload: [UInt8] = [7, 8, 9]) -> Data {
      var data = Data()
      data.append(Data(bytesOf: version))
      data.append(Data(bytesOf: size ?? videoSize))
      data.append(Data(bytesOf: modified))
      data.append(contentsOf: payload)
      return data
    }
    func writeSource(_ name: String, _ data: Data) throws {
      try data.write(to: source.appendingPathComponent(name))
    }
    func contents(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    func check(_ condition: Bool, _ message: String) {
      if !condition { fatalError("FAIL: \(message)") }
    }

    if AppEnvironment.isCleanStart {
      try writeSource("requested", cache())
      let copied = ThumbnailCache.importLegacyPreview(forName: "requested", forVideo: video,
        sourceDirectory: source, destinationDirectory: destination)
      check(!copied, "clean start must skip legacy import")
      check(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("requested").path),
            "clean start must not create a destination cache")
      print("PASS: --clean-start skipped legacy preview import")
      return
    }

    let requested = cache(payload: [1, 2, 3, 4])
    let untouched = cache(payload: [5, 6, 7])
    try writeSource("requested", requested)
    try writeSource("unrequested", untouched)
    check(ThumbnailCache.importLegacyPreview(forName: "requested", forVideo: video,
      sourceDirectory: source, destinationDirectory: destination), "matching cache should import")
    check(try contents(destination.appendingPathComponent("requested")) == requested, "requested cache bytes should copy")
    check(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("unrequested").path),
          "unrequested cache must remain uncopied")
    check(try contents(source.appendingPathComponent("unrequested")) == untouched, "unrequested source cache must remain untouched")
    check(CacheManager.shared.needsRefresh, "successful import should mark cache manager for refresh")

    let existing = cache(payload: [42])
    try existing.write(to: destination.appendingPathComponent("existing"))
    try writeSource("existing", cache(payload: [43]))
    check(!ThumbnailCache.importLegacyPreview(forName: "existing", forVideo: video,
      sourceDirectory: source, destinationDirectory: destination), "existing destination must prevent import")
    check(try contents(destination.appendingPathComponent("existing")) == existing, "existing cache must not be overwritten")

    try writeSource("stale", cache(size: videoSize + 1))
    check(!ThumbnailCache.importLegacyPreview(forName: "stale", forVideo: video,
      sourceDirectory: source, destinationDirectory: destination), "stale metadata must be rejected")

    try writeSource("wrong-version", cache(3))
    check(!ThumbnailCache.importLegacyPreview(forName: "wrong-version", forVideo: video,
      sourceDirectory: source, destinationDirectory: destination), "incompatible version must be rejected")
    try writeSource("corrupt", Data([2, 1, 2]))
    check(!ThumbnailCache.importLegacyPreview(forName: "corrupt", forVideo: video,
      sourceDirectory: source, destinationDirectory: destination), "truncated header must be rejected")

    check(!ThumbnailCache.importLegacyPreview(forName: "absent", forVideo: video,
      sourceDirectory: source, destinationDirectory: destination), "absent source must be rejected")
    check(!ThumbnailCache.importLegacyPreview(forName: "../escape", forVideo: video,
      sourceDirectory: source, destinationDirectory: destination), "traversal name must be rejected")

    print("PASS: requested-only copy, preserved existing cache, metadata/header rejection, absent source, traversal")
  }
}
