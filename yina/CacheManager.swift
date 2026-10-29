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

  private struct Entry {
    let size: Int
    let accessed: Date
  }

  private let stateLock = NSLock()
  private let writer = DispatchQueue(label: "YINACacheManager", qos: .utility)
  private var contents: [URL: Entry] = [:]
  private var totalSize = 0
  private var cacheNeedsRefresh = true
  private var refreshQueued = false
  private var lastReconciled = Date.distantPast
  private var invalidationGeneration = 0

  var needsRefresh: Bool {
    get { stateLock.withLock { cacheNeedsRefresh } }
    set {
      stateLock.withLock {
        cacheNeedsRefresh = newValue
        if newValue { invalidationGeneration += 1 }
      }
      if newValue { scheduleRefresh() }
    }
  }

  /// The settings view reads a snapshot. Directory enumeration always happens
  /// on the writer queue and never holds the state lock across filesystem I/O.
  func getCacheSize() -> Int {
    stateLock.withLock {
      if Date().timeIntervalSince(lastReconciled) >= 30 { cacheNeedsRefresh = true }
    }
    scheduleRefresh()
    return stateLock.withLock { totalSize }
  }

  func getCacheSizeAsync(_ completion: @escaping (Int?) -> Void) {
    writer.async { [self] in
      let refreshed = reconcile(force: true)
      let size = stateLock.withLock { totalSize }
      DispatchQueue.main.async { completion(refreshed ? size : nil) }
    }
  }

  private func scheduleRefresh() {
    let shouldQueue = stateLock.withLock { () -> Bool in
      guard cacheNeedsRefresh && !refreshQueued else { return false }
      refreshQueued = true
      return true
    }
    guard shouldQueue else { return }
    writer.async { [self] in
      let refreshed = reconcile(force: true)
      stateLock.withLock { refreshQueued = false }
      if refreshed && needsRefresh { scheduleRefresh() }
    }
  }

  @discardableResult
  private func reconcile(force: Bool = false) -> Bool {
    let (dirty, generation) = stateLock.withLock { (cacheNeedsRefresh, invalidationGeneration) }
    guard force || dirty || Date().timeIntervalSince(lastReconciled) >= 30 else { return true }
    guard let files = try? FileManager.default.contentsOfDirectory(at: Utility.thumbnailCacheURL,
      includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey],
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return false }
    var found: [URL: Entry] = [:]
    var bytes = 0
    for url in files {
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey]),
            let size = values.fileSize, size >= 0 else { continue }
      found[url] = Entry(size: size, accessed: values.contentAccessDate ?? .distantPast)
      bytes += size
    }
    stateLock.withLock {
      contents = found
      totalSize = bytes
      if invalidationGeneration == generation { cacheNeedsRefresh = false }
      lastReconciled = Date()
    }
    return true
  }

  func clearOldCache() {
    writer.async { [self] in
      reconcile()
      clearOldCache(bytesToDelete: maximumCacheSize / 2)
    }
  }

  /// Budget checks, eviction, and replacement share one writer lane.
  func write(_ data: Data, to url: URL) throws {
    try writer.sync {
      reconcile()
      let limit = maximumCacheSize
      guard limit > 0, data.count <= limit else { return }
      // Account for a file changed by another process even before the next
      // broad reconciliation.
      let oldSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      let projected = stateLock.withLock { () -> Int in
        totalSize += oldSize - (contents[url]?.size ?? 0)
        if oldSize == 0 { contents.removeValue(forKey: url) }
        else { contents[url] = Entry(size: oldSize, accessed: contents[url]?.accessed ?? .distantPast) }
        return totalSize - oldSize + data.count
      }
      if projected > limit {
        clearOldCache(bytesToDelete: max(limit / 2, projected - limit), excluding: url)
      }
      try data.write(to: url, options: .atomic)
      stateLock.withLock {
        totalSize += data.count - oldSize
        contents[url] = Entry(size: data.count, accessed: Date())
      }
    }
  }

  private var maximumCacheSize: Int {
    max(0, Preference.integer(for: .maxThumbnailPreviewCacheSize)) * FloatingPointByteCountFormatter.PrefixFactor.mi.rawValue
  }

  private func clearOldCache(bytesToDelete: Int, excluding: URL? = nil) {
    guard bytesToDelete > 0 else { return }
    let candidates = stateLock.withLock {
      contents.filter { $0.key != excluding }.sorted { $0.value.accessed < $1.value.accessed }
    }
    var reclaimed = 0
    for (url, entry) in candidates where reclaimed < bytesToDelete {
      do {
        try FileManager.default.removeItem(at: url)
        reclaimed += entry.size
        stateLock.withLock {
          totalSize -= contents.removeValue(forKey: url)?.size ?? 0
        }
      } catch {
        // Preserve the failed file in the accounting and try another one.
      }
    }
  }
}
