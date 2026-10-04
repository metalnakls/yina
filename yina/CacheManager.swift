//
//  CacheManager.swift
//  yina
//
//  Created by lhc on 28/9/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

class CacheManager {

  static let shared = CacheManager()

  private let lock = NSLock()
  private var cacheNeedsRefresh = true
  var needsRefresh: Bool {
    get { lock.withLock { cacheNeedsRefresh } }
    set { lock.withLock { cacheNeedsRefresh = newValue } }
  }

  private var cachedContents: [URL]?

  private func cacheFolderContents() -> [URL]? {
    if cacheNeedsRefresh {
      cachedContents = try? FileManager.default.contentsOfDirectory(at: Utility.thumbnailCacheURL,
                                                                    includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey],
                                                                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
      cacheNeedsRefresh = cachedContents == nil
    }
    return cachedContents
  }

  func getCacheSize() -> Int {
    lock.withLock { cacheSize() }
  }

  private func cacheSize() -> Int {
    return cacheFolderContents()?.reduce(0 as Int) { totalSize, url in
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
      return totalSize + size
    } ?? 0
  }

  func clearOldCache() {
    lock.withLock {
      clearOldCache(bytesToDelete: maximumCacheSize / 2)
    }
  }

  /// Serialize budget checks and atomic replacement across thumbnail workers.
  func write(_ data: Data, to url: URL) throws {
    try lock.withLock {
      let limit = maximumCacheSize
      guard limit > 0, data.count <= limit else { return }
      let replacedSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      let projectedSize = cacheSize() - replacedSize + data.count
      if projectedSize > limit {
        clearOldCache(bytesToDelete: max(limit / 2, projectedSize - limit), excluding: url)
      }
      try data.write(to: url, options: .atomic)
      cacheNeedsRefresh = true
    }
  }

  private var maximumCacheSize: Int {
    max(0, Preference.integer(for: .maxThumbnailPreviewCacheSize)) * FloatingPointByteCountFormatter.PrefixFactor.mi.rawValue
  }

  private func clearOldCache(bytesToDelete: Int, excluding: URL? = nil) {
    guard bytesToDelete > 0 else { return }
    defer { cacheNeedsRefresh = true }

    // Load each file's metadata once before sorting.
    guard let contents = cacheFolderContents()?.filter({ $0 != excluding }).map({ url in
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey])
      return (url: url, size: values?.fileSize ?? 0, date: values?.contentAccessDate ?? Date.distantPast)
    }).sorted(by: { $0.date < $1.date }) else { return }

    // delete old cache
    var clearedCacheSize = 0
    for entry in contents {
      guard clearedCacheSize < bytesToDelete else { break }
      do {
        try FileManager.default.removeItem(at: entry.url)
        clearedCacheSize += entry.size
      } catch {
        // A failed removal must not count toward the space reclaimed.
      }
    }
  }

}
