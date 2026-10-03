//
//  ThumbnailCache.swift
//  yina
//
//  Created by lhc on 14/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa
import ImageIO
import UniformTypeIdentifiers

fileprivate let subsystem = Logger.makeSubsystem("thumbcache", ["photo.stack"])

class ThumbnailCache {
  private typealias CacheVersion = UInt8
  private typealias FileSize = UInt64
  private typealias FileTimestamp = Int64

  private static let version: CacheVersion = 3
  
  private static let sizeofMetadata = MemoryLayout<CacheVersion>.size + MemoryLayout<FileSize>.size + MemoryLayout<FileTimestamp>.size

  private static let imageProperties: [NSBitmapImageRep.PropertyKey: Any] = [
    .compressionFactor: 0.75
  ]
  
  private static func log(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: subsystem)
  }

  static func fileExists(forName name: String) -> Bool {
    return FileManager.default.fileExists(atPath: urlFor(name).path)
  }

  static func fileIsCached(forName name: String, forVideo videoPath: URL?,
                           allowUnavailableVideo: Bool = false, requireCurrentFormat: Bool = false) -> Bool {
    if requireCurrentFormat {
      guard let file = try? FileHandle(forReadingFrom: urlFor(name)) else { return false }
      defer { file.closeFile() }
      guard file.read(type: CacheVersion.self) == version else { return false }
    }
    guard let videoPath, let cached = cachedMetadata(forName: name) else { return false }
    guard let videoMetadata = metadata(forVideo: videoPath) else {
      // Welcome snapshots remain useful when their network volume is disconnected.
      return allowUnavailableVideo
    }
    return cached == videoMetadata
  }

  /// Copy only a requested welcome preview, preserving existing yina cache entries.
  /// Call on the artwork queue: checking video metadata may touch a network volume.
  @discardableResult
  static func importLegacyPreview(forName name: String, forVideo videoURL: URL?,
                                  sourceDirectory: URL? = AppEnvironment.legacyThumbnailCacheURL,
                                  destinationDirectory: URL = Utility.thumbnailCacheURL) -> Bool {
    guard !AppEnvironment.isCleanStart, let sourceDirectory,
          !name.isEmpty, name != ".", name != "..", !name.contains("/"),
          let videoURL else { return false }
    let fm = FileManager.default
    let destination = destinationDirectory.appendingPathComponent(name)
    guard !fm.fileExists(atPath: destination.path) else { return false }
    let source = sourceDirectory.appendingPathComponent(name)
    guard let cached = cachedMetadata(at: source) else { return false }
    if let expected = metadata(forVideo: videoURL), cached != expected { return false }
    // The cache key comes from the saved card. Offline media cannot be restatted,
    // but its previously generated preview can still represent that same card.
    do {
      try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
      try fm.copyItem(at: source, to: destination)
      CacheManager.shared.needsRefresh = true
      return true
    } catch {
      log("Could not import a cached IINA preview: \(error.localizedDescription)", level: .warning)
      return false
    }
  }

  /// Recovers a pre-bookmark history entry after a Finder rename. Requiring one
  /// exact metadata match avoids redirecting a stale card to an unrelated file.
  static func uniquelyRenamedVideo(forName name: String, originalURL: URL) -> URL? {
    guard originalURL.isFileURL,
          let expected = cachedMetadata(forName: name),
          let siblings = try? FileManager.default.contentsOfDirectory(
            at: originalURL.deletingLastPathComponent(),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }

    let originalExtension = originalURL.pathExtension.lowercased()
    var match: URL?
    for candidate in siblings where candidate.pathExtension.lowercased() == originalExtension {
      guard metadata(forVideo: candidate) == expected else { continue }
      guard match == nil else { return nil }
      match = candidate
    }
    return match
  }

  private struct Metadata: Equatable {
    let size: FileSize
    let timestamp: FileTimestamp
  }

  private static func metadata(forVideo url: URL) -> Metadata? {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey,
                                                          .contentModificationDateKey]),
          values.isRegularFile == true,
          let size = values.fileSize,
          let modificationDate = values.contentModificationDate else { return nil }
    return Metadata(size: FileSize(size),
                    timestamp: FileTimestamp(modificationDate.timeIntervalSince1970))
  }

  private static func cachedMetadata(forName name: String) -> Metadata? {
    cachedMetadata(at: urlFor(name))
  }

  private static func cachedMetadata(at url: URL) -> Metadata? {
    guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { file.closeFile() }
    guard let cacheVersion = file.read(type: CacheVersion.self), [2, version].contains(cacheVersion),
          let size = file.read(type: FileSize.self),
          let timestamp = file.read(type: FileTimestamp.self) else { return nil }
    return Metadata(size: size, timestamp: timestamp)
  }

  /// Write thumbnail cache to file.
  /// This method is expected to be called when the file doesn't exist.
  static func write(_ thumbnails: [FFThumbnail], forName name: String, forVideo videoPath: URL?) {
    log("Writing thumbnail cache...")

    let maxCacheSize = Preference.integer(for: .maxThumbnailPreviewCacheSize) * FloatingPointByteCountFormatter.PrefixFactor.mi.rawValue
    if maxCacheSize == 0 {
      return
    } else if CacheManager.shared.getCacheSize() > maxCacheSize {
      CacheManager.shared.clearOldCache()
    }

    let pathURL = urlFor(name)
    guard FileManager.default.createFile(atPath: pathURL.path, contents: nil, attributes: nil) else {
      log("Cannot create file.", level: .error)
      return
    }
    guard let file = try? FileHandle(forWritingTo: pathURL) else {
      log("Cannot write to file.", level: .error)
      return
    }

    guard let fileAttr = try? FileManager.default.attributesOfItem(atPath: videoPath!.path) else {
      log("Cannot get video file attributes", level: .error)
      return
    }

    // file size
    guard let fileSize = fileAttr[.size] as? FileSize else {
      log("Cannot get video file size", level: .error)
      return
    }

    // modified date
    guard let fileModifiedDate = fileAttr[.modificationDate] as? Date else {
      log("Cannot get video file modification date", level: .error)
      return
    }
    let fileTimestamp = FileTimestamp(fileModifiedDate.timeIntervalSince1970)

    // Coalesce all data into a single write to reduce I/O syscalls
    var outputData = Data()

    // version
    outputData.append(Data(bytesOf: version))
    // file size
    outputData.append(Data(bytesOf: fileSize))
    // modified date
    outputData.append(Data(bytesOf: fileTimestamp))

    // data blocks
    for tb in thumbnails {
      let timestampData = Data(bytesOf: tb.realTime)
      guard let cgImage = tb.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        log("Cannot resolve thumbnail image.", level: .error)
        return
      }
      let isHDR = cgImage.contentHeadroom > 1 || cgImage.colorSpace.map { CGColorSpaceUsesITUR_2100TF($0) } == true
      let headroom = max(1, cgImage.contentHeadroom)
      let imageData: Data
      if isHDR {
        // PNG retains 16-bit samples and the PQ/HLG ICC profile; JPEG flattens HDR.
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        imageData = data as Data
      } else if let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: imageProperties) {
        imageData = data
      } else {
        log("Cannot encode thumbnail image.", level: .error)
        return
      }
      let headroomData = Data(bytesOf: headroom)
      let blockLength = Int64(timestampData.count + headroomData.count + imageData.count)
      outputData.append(Data(bytesOf: blockLength))
      outputData.append(timestampData)
      outputData.append(headroomData)
      outputData.append(imageData)
    }

    file.write(outputData)

    CacheManager.shared.needsRefresh = true
    log("Finished writing thumbnail cache.")
  }

  /// Read thumbnail cache to file.
  /// This method is expected to be called when the file exists.
  static func read(forName name: String) -> [FFThumbnail]? {
    log("Reading thumbnail cache...")

    let pathURL = urlFor(name)
    guard let file = try? FileHandle(forReadingFrom: pathURL) else {
      log("Cannot open file.", level: .error)
      return nil
    }
    log("Reading from \(pathURL.path)")

    var result: [FFThumbnail] = []

    // get file length
    file.seekToEndOfFile()
    let eof = file.offsetInFile

    file.seek(toFileOffset: 0)
    guard let cacheVersion = file.read(type: CacheVersion.self), [2, version].contains(cacheVersion) else {
      file.closeFile()
      return nil
    }
    // skip metadata
    file.seek(toFileOffset: UInt64(sizeofMetadata))

    // data blocks
    while file.offsetInFile != eof {
      // length and timestamp
      guard let blockLength = file.read(type: Int64.self),
            let timestamp = file.read(type: Double.self) else {
        log("Cannot read image header. Cache file will be deleted.", level: .warning)
        file.closeFile()
        deleteCacheFile(at: pathURL)
        return nil
      }
      let headroom: Float
      if cacheVersion >= 3 {
        guard let value = file.read(type: Float.self), value.isFinite, value >= 1 else {
          file.closeFile()
          deleteCacheFile(at: pathURL)
          return nil
        }
        headroom = value
      } else {
        headroom = 1
      }
      let headerSize = MemoryLayout<Double>.size + (cacheVersion >= 3 ? MemoryLayout<Float>.size : 0)
      guard blockLength > Int64(headerSize), UInt64(blockLength - Int64(headerSize)) <= eof - file.offsetInFile else {
        file.closeFile()
        deleteCacheFile(at: pathURL)
        return nil
      }
      let imageData = file.readData(ofLength: Int(blockLength) - headerSize)
      let options = [kCGImageSourceShouldAllowFloat: true,
                     kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary
      guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
            let decoded = CGImageSourceCreateImageAtIndex(source, 0, options) else {
        log("Cannot read image. Cache file will be deleted.", level: .warning)
        file.closeFile()
        deleteCacheFile(at: pathURL)
        return nil
      }
      let tagged = headroom > 1 ? CGImageCreateCopyWithContentHeadroom(headroom, decoded) ?? decoded : decoded
      let image = NSImage(cgImage: tagged, size: .zero)
      // construct
      let tb = FFThumbnail()
      tb.realTime = timestamp
      tb.image = image
      result.append(tb)
    }

    file.closeFile()
    log("Finished reading thumbnail cache, \(result.count) in total")
    return result
  }

  static func clearThumbnailCache() {
    try? FileManager.default.removeItem(atPath: Utility.thumbnailCacheURL.path)
    Utility.createDirIfNotExist(url: Utility.thumbnailCacheURL)
  }

  private static func deleteCacheFile(at pathURL: URL) {
    // try deleting corrupted cache
    do {
      try FileManager.default.removeItem(at: pathURL)
    } catch {
      log("Cannot delete corrupted cache.", level: .error)
    }
  }

  private static func urlFor(_ name: String) -> URL {
    return Utility.thumbnailCacheURL.appendingPathComponent(name)
  }

}
