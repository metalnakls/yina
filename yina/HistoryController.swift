//
//  HistoryController.swift
//  yina
//
//  Created by lhc on 25/4/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

class HistoryController: NSObject {

  static let shared = HistoryController(plistFileURL: Utility.playbackHistoryURL)

#if DEBUG
  /// As logging of all history entries can produce a huge number of log messages this feature is only included in debug builds and
  /// must be enabled by setting this property to `true` when you need investigate history file contents.
  private static let logAllHistoryEntries = false
#endif

  /// Cached copy of the playback history stored in the history file.
  ///
  /// This is accessed by both the main thread and a background thread and must be referenced under a lock.
  @Atomic var history: [PlaybackHistory] = []
  // Protected by the history lock; invalidates additions queued before a clear.
  private var historyGeneration = 0

  /// Number of tasks currently in the queue.
  @Atomic var tasksOutstanding = 0

  private let plistURL: URL
  private let queue = DispatchQueue(label: "YINAHistoryController", qos: .background)
  private let persistenceLock = NSLock()
  private var saveQueued = false
  private var saveDirty = false

  init(plistFileURL: URL) {
    self.plistURL = plistFileURL
    super.init()
    read()
  }

  private func read() {
    // Avoid logging a scary error if the file does not exist.
    guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
    do {
      MemoryUsage.shared.logUsage("before reading history")
      let data = try Data(contentsOf: plistURL)
      guard let history = try PlaybackHistory.decodeArchive(data) else {
        // Secure coding should ensure that this never occurs.
        log("Unable to convert object read from playback history file to [PlaybackHistory]", level: .error)
        return
      }
      self.history = history
      log("Read \(history.count) playback history entries")
      MemoryUsage.shared.logUsage("after reading history")

      // As logging of all history entries can produce a huge number of log messages this feature is
      // only included in debug builds.
#if DEBUG
      // YINA must be built with the property logAllHistoryEntries set to true when you want the
      // history file contents to be logged when it is read.
      guard HistoryController.logAllHistoryEntries, !history.isEmpty,
            Logger.isEmitting(.verbose) else { return }
      log("Playback history:", level: .verbose)
      var index = 0
      for entry in history {
        log("History[\(index)] \(String(describing: entry))", level: .verbose)
        index += 1
      }
#endif
    } catch {
      log("Failed to read playback history file \(plistURL.path): \(error)", level: .error)
    }
  }

  private func requestSave() {
    let shouldQueue = persistenceLock.withLock { () -> Bool in
      saveDirty = true
      if saveQueued { return false }
      saveQueued = true
      $tasksOutstanding.withLock { $0 += 1 }
      return true
    }
    guard shouldQueue else { return }
    queue.async { [self] in
      while true {
        let shouldSave = persistenceLock.withLock { () -> Bool in
          if !saveDirty { saveQueued = false; return false }
          saveDirty = false
          return true
        }
        guard shouldSave else { break }
        // Entries can refresh their bookmarks while encoding. Neither that nor
        // archive replacement may run while a UI reader holds the history lock.
        let snapshot = $history.withLock { $0.map { $0.detachedCopy() } }
        do {
          let data = try PlaybackHistory.encodeArchive(snapshot)
          try data.write(to: plistURL, options: [.atomic])
          log("Saved \(snapshot.count) playback history entries")
        } catch {
          log("Failed to save playback history to file \(plistURL.path): \(error)", level: .error)
        }
        NotificationCenter.default.post(Notification(name: .yinaHistoryUpdated))
      }
      taskFinished()
    }
  }

  private func taskFinished() {
    $tasksOutstanding.withLock { $0 -= 1 }
    NotificationCenter.default.post(Notification(name: .yinaHistoryTaskFinished))
  }

  /// Add an entry to playback history.
  /// - Note: The entry is added asynchronously by a background thread.
  /// - Parameters:
  ///   - url: URL of the media being played.
  ///   - duration: Total duration of the media.
  ///   - title: Title of the media (if available).
  ///   - ignorePath: When `true`, only the URL's filename will be used for the sum if the URL does not contain a scheme.
  func add(_ url: URL, duration: Double, title: String?, _ ignorePath: Bool) {
    guard Preference.bool(for: .recordPlaybackHistory) else { return }
    let generation = $history.withLock { _ in historyGeneration }
    $tasksOutstanding.withLock { $0 += 1 }
    queue.async { [self] in
      let mpvMd5 = Utility.mpvWatchLaterMd5(url, ignorePath)
      let entry = PlaybackHistory(url: url, duration: duration, title: title, mpvMd5: mpvMd5)
      let added = $history.withLock { history in
        guard generation == historyGeneration else { return false }
        if let existingItem = history.first(where: { $0.mpvMd5 == mpvMd5 }),
           let index = history.firstIndex(of: existingItem) {
          history.remove(at: index)
        }
        history.insert(entry, at: 0)
        return true
      }
      if added {
        log("Adding to history: \(String(describing: entry))", level: .verbose)
        NotificationCenter.default.post(Notification(name: .yinaHistoryUpdated))
        requestSave()
      }
      taskFinished()
    }
  }

  func remove(_ entries: [PlaybackHistory]) {
    $history.withLock { history in
      log("Removing \(entries.count) playback history entries")
      let identifiers = Set(entries.map(\.mpvMd5))
      history.removeAll { identifiers.contains($0.mpvMd5) }
    }
    NotificationCenter.default.post(Notification(name: .yinaHistoryUpdated))
    requestSave()
  }

  func removeAll() {
    $history.withLock { history in
      log("Removing all playback history entries")
      historyGeneration += 1
      history = []
    }
    NotificationCenter.default.post(Notification(name: .yinaHistoryUpdated))
    requestSave()
  }

  private func log(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: Logger.Sub.history)
  }
}

extension Logger.Sub {
  static let history = Logger.makeSubsystem("history", ["clock"])
}
