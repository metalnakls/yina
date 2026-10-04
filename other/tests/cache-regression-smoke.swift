// Compile with ThumbnailCache.swift and CacheManager.swift; see optimization-smoke.sh.
import Cocoa

enum Logger {
  enum Level { case debug, warning, error }
  struct Subsystem {}
  static func makeSubsystem(_ name: String, _ symbols: [String]) -> Subsystem { Subsystem() }
  static func log(_ message: () -> String, level: Level, subsystem: Subsystem) {}
}
enum Utility {
  static let thumbnailCacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("yina-cache-tests-\(UUID())")
  static func createDirIfNotExist(url: URL) { try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
}
enum Preference {
  enum Key { case maxThumbnailPreviewCacheSize }
  static func integer(for key: Key) -> Int { 1 }
}
enum AppEnvironment {
  static let isCleanStart = true
  static let legacyThumbnailCacheURL: URL? = nil
}
enum FloatingPointByteCountFormatter {
  enum PrefixFactor { case mi; var rawValue: Int { 1_048_576 } }
}
final class FFThumbnail { var realTime = 0.0; var image: NSImage? }
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

@main enum CacheRegressionSmoke {
  static func main() throws {
    let directory = Utility.thumbnailCacheURL
    Utility.createDirIfNotExist(url: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
    func imageData(blue: Bool, width: Int = 32) -> Data {
      let context = CGContext(data: nil, width: width, height: width, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.setFillColor(red: blue ? 0 : 1, green: 0, blue: blue ? 1 : 0, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: width, height: width))
      return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    }
    let red = imageData(blue: false), blue = imageData(blue: true)
    func cache(version: UInt8 = 4, frames: [(Double, Data)], headroom: Float = 1) -> Data {
      var result = Data(bytesOf: version)
      result.append(Data(bytesOf: UInt64(42)))
      result.append(Data(bytesOf: Int64(1_700_000_000)))
      for (time, pixels) in frames {
        let headerLength = 8 + (version >= 3 ? 4 : 0)
        result.append(Data(bytesOf: Int64(headerLength + pixels.count)))
        result.append(Data(bytesOf: time))
        if version >= 3 { result.append(Data(bytesOf: headroom)) }
        result.append(pixels)
      }
      return result
    }
    func write(_ name: String, _ data: Data) throws { try data.write(to: directory.appendingPathComponent(name)) }
    func isBlue(_ image: NSImage?) -> Bool {
      guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let color = NSBitmapImageRep(cgImage: cg).colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else { return false }
      return color.blueComponent > 0.8 && color.redComponent < 0.2
    }

    // A realistic catalog for before/after benchmarking using the same reader API.
    let largeImage = imageData(blue: true, width: 240)
    try write("benchmark", cache(frames: (0..<101).map { (Double($0), largeImage) }))
    let start = ContinuousClock.now
    for _ in 0..<50 { autoreleasepool { check(ThumbnailCache.readOne(forName: "benchmark", nearest: 50) != nil, "benchmark frame") } }
    print("50 single-frame reads: \(start.duration(to: .now))")
    if CommandLine.arguments.contains("--benchmark-only") { return }

    for version in [UInt8(2), 4] {
      let name = "version-\(version)"
      try write(name, cache(version: version, frames: [(0, red), (10, blue)]))
      check(isBlue(ThumbnailCache.readOne(forName: name, nearest: 9)), "nearest frame for cache v\(version)")
      check(!isBlue(ThumbnailCache.readOne(forName: name, nearest: 5)), "ties select the earlier frame")
      check(ThumbnailCache.read(forName: name)?.count == 2, "full timeline catalog still loads")
    }
    // Invalid image payloads elsewhere prove the single-frame reader skips decoding them.
    try write("selected-only", cache(frames: [(0, Data([0])), (10, blue), (20, Data([0]))]))
    check(isBlue(ThumbnailCache.readOne(forName: "selected-only", nearest: 10)), "decode only the selected payload")
    try write("bad-length", cache(frames: [(0, red)]).dropLast())
    check(ThumbnailCache.readOne(forName: "bad-length") == nil, "truncated payload is rejected")
    check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("bad-length").path), "corrupt cache is removed")
    try write("bad-headroom", cache(frames: [(0, red)], headroom: .nan))
    _ = CacheManager.shared.getCacheSize()
    check(ThumbnailCache.readOne(forName: "bad-headroom") == nil, "non-finite headroom is rejected")
    check(CacheManager.shared.needsRefresh, "corrupt-file removal invalidates the cached directory")
    try write("valid", cache(frames: [(0, blue)]))
    check(ThumbnailCache.readOne(forName: "valid", nearest: .nan) == nil, "invalid caller timestamp is rejected")
    check(FileManager.default.fileExists(atPath: directory.appendingPathComponent("valid").path), "bad caller input preserves valid cache")

    // Failed image encoding must not truncate an existing cache.
    let video = directory.appendingPathComponent("video")
    try Data([1]).write(to: video)
    ThumbnailCache.write([FFThumbnail()], forName: "valid", forVideo: video)
    check(isBlue(ThumbnailCache.readOne(forName: "valid")), "failed replacement preserves existing preview")

    try FileManager.default.removeItem(at: directory)
    Utility.createDirIfNotExist(url: directory)
    CacheManager.shared.needsRefresh = true
    let item = Data(repeating: 1, count: 400_000)
    for index in 0..<6 { try CacheManager.shared.write(item, to: directory.appendingPathComponent("item-\(index)")) }
    check(CacheManager.shared.getCacheSize() <= 1_048_576, "successive evictions enforce the budget")
    check(!CacheManager.shared.needsRefresh, "successful enumeration clears refresh state")
    CacheManager.shared.clearOldCache()
    try CacheManager.shared.write(item, to: directory.appendingPathComponent("after-clear"))
    CacheManager.shared.clearOldCache()
    check(CacheManager.shared.getCacheSize() < item.count, "explicit eviction can run more than once")
    DispatchQueue.concurrentPerform(iterations: 40) { index in
      try! CacheManager.shared.write(Data(repeating: UInt8(index), count: 64_000), to: directory.appendingPathComponent("parallel-\(index)"))
    }
    check(CacheManager.shared.getCacheSize() <= 1_048_576, "concurrent writes share the budget")
    for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
      let data = try Data(contentsOf: file)
      check(data.count == 64_000 && data.allSatisfy { $0 == data.first }, "atomic writes leave complete files")
    }
    ThumbnailCache.clearThumbnailCache()
    check(CacheManager.shared.getCacheSize() == 0, "clearing the cache invalidates its directory snapshot")
    print("PASS: selected-frame decoding, v2/v4 compatibility, corruption, atomic replacement, repeated eviction, concurrent budget")
  }
}
