//
//  PlaybackHistory.swift
//  yina
//
//  Created by lhc on 28/4/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

fileprivate let KeyUrl = "YINAPHUrl"
fileprivate let KeyName = "YINAPHNme"
fileprivate let KeyMpvMd5 = "YINAPHMpvmd5"
fileprivate let KeyPlayed = "YINAPHPlayed"
fileprivate let KeyAddedDate = "YINAPHDate"
fileprivate let KeyDuration = "YINAPHDuration"
fileprivate let KeyTitle = "YINAPHTitle"
fileprivate let KeyBookmark = "YINAPHBookmark"

/// An entry in the playback history file.
/// - Important: This class conforms to [NSSecureCoding](https://developer.apple.com/documentation/foundation/nssecurecoding).
///     When making changes be certain the requirements for secure coding are not violated by the changes.
class PlaybackHistory: NSObject, NSSecureCoding {

  /// Indicate this class supports secure coding.
  static var supportsSecureCoding: Bool { true }

  /// Keep IINA and earlier yina archives readable after the Swift module rename.
  static func decodeArchive(_ data: Data) throws -> [PlaybackHistory]? {
    let decoder = try NSKeyedUnarchiver(forReadingFrom: data)
    decoder.requiresSecureCoding = true
    for name in ["IINA.PlaybackHistory", "iina.PlaybackHistory", "YINA.PlaybackHistory"] {
      decoder.setClass(PlaybackHistory.self, forClassName: name)
    }
    let entries = decoder.decodeObject(of: [NSArray.self, PlaybackHistory.self],
                                       forKey: NSKeyedArchiveRootObjectKey) as? [PlaybackHistory]
    decoder.finishDecoding()
    if let error = decoder.error { throw error }
    return entries
  }

  private static let dateFormatter: DateFormatter = {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "MM/dd/yyyy HH:mm:ss"
    return dateFormatter
  }()

  var url: URL
  var name: String
  var mpvMd5: String

  var played: Bool
  var addedDate: Date

  var duration: VideoTime
  var mpvProgress: VideoTime? {
    Utility.playbackProgressFromWatchLater(mpvMd5)
  }

  var title: String?
  private var bookmarkData: Data?

  /// A description of this playback history entry suitable to include in a log message.
  override var description: String {
    var description = """
      added: \(PlaybackHistory.dateFormatter.string(from: addedDate)) \
      duration: \(duration.stringRepresentation)
      """
    if let mpvProgress { description += " progress: \(mpvProgress.stringRepresentation)" }
    description += "\n  \(url)"
    if let title { description += "\n  \(title)" }
    description += "\n  MD5: \(mpvMd5)"
    return description
  }

  required init?(coder aDecoder: NSCoder) {
    func archiveKey(_ current: String) -> String {
      aDecoder.containsValue(forKey: current) ? current : current.replacingOccurrences(of: "YINAPH", with: "IINAPH")
    }
    guard
      let url = aDecoder.decodeObject(of: NSURL.self, forKey: archiveKey(KeyUrl)),
      let name = aDecoder.decodeObject(of: NSString.self, forKey: archiveKey(KeyName)),
      let md5 = aDecoder.decodeObject(of: NSString.self, forKey: archiveKey(KeyMpvMd5)),
      let date = aDecoder.decodeObject(of: NSDate.self, forKey: archiveKey(KeyAddedDate))
    else {
      return nil
    }

    let played = aDecoder.decodeBool(forKey: archiveKey(KeyPlayed))
    let duration = aDecoder.decodeDouble(forKey: archiveKey(KeyDuration))
    let title = aDecoder.containsValue(forKey: archiveKey(KeyTitle))
      ? aDecoder.decodeObject(of: NSString.self, forKey: archiveKey(KeyTitle)) : nil
    let bookmarkData = aDecoder.containsValue(forKey: archiveKey(KeyBookmark))
      ? aDecoder.decodeObject(of: NSData.self, forKey: archiveKey(KeyBookmark)) as Data? : nil

    self.url = url as URL
    self.name = name as String
    self.mpvMd5 = md5 as String
    self.played = played
    self.addedDate = date as Date
    self.duration = VideoTime(duration)
    self.title = title as String?
    self.bookmarkData = bookmarkData

    super.init()
  }

  init(url: URL, duration: Double, name: String? = nil, title: String?, mpvMd5: String) {
    self.url = url
    self.name = name ?? url.lastPathComponent
    self.mpvMd5 = mpvMd5
    self.played = true
    self.addedDate = Date()
    self.duration = VideoTime(duration)
    self.title = title
    self.bookmarkData = Self.makeBookmark(for: url)
    super.init()
  }

  /// Returns the current location of a local file after Finder moves or renames it.
  /// Existing history archives did not contain bookmarks, so use thumbnail metadata
  /// as a conservative one-time migration when exactly one sibling still matches.
  func resolvedURL() -> URL {
    guard url.isFileURL else { return url }

    if let bookmarkData {
      var isStale = false
      if let resolved = try? URL(resolvingBookmarkData: bookmarkData,
                                 options: [.withoutMounting, .withoutUI],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale),
         FileManager.default.fileExists(atPath: resolved.path) {
        updateFileURL(resolved, refreshBookmark: isStale)
        return url
      }
    }

    if FileManager.default.fileExists(atPath: url.path) {
      if bookmarkData == nil {
        bookmarkData = Self.makeBookmark(for: url)
      }
      return url
    }

    if bookmarkData == nil,
       let recovered = ThumbnailCache.uniquelyRenamedVideo(forName: mpvMd5, originalURL: url) {
      updateFileURL(recovered, refreshBookmark: true)
    }
    return url
  }

  private func updateFileURL(_ newURL: URL, refreshBookmark: Bool) {
    let standardizedURL = newURL.standardizedFileURL
    url = standardizedURL
    name = standardizedURL.lastPathComponent
    if refreshBookmark || bookmarkData == nil {
      bookmarkData = Self.makeBookmark(for: standardizedURL)
    }
  }

  private static func makeBookmark(for url: URL) -> Data? {
    guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
  }

  func encode(with aCoder: NSCoder) {
    aCoder.encode(url, forKey: KeyUrl)
    aCoder.encode(name, forKey: KeyName)
    aCoder.encode(mpvMd5, forKey: KeyMpvMd5)
    aCoder.encode(played, forKey: KeyPlayed)
    aCoder.encode(addedDate, forKey: KeyAddedDate)
    aCoder.encode(duration.second, forKey: KeyDuration)
    aCoder.encode(title, forKey: KeyTitle)
    aCoder.encode(bookmarkData ?? Self.makeBookmark(for: url), forKey: KeyBookmark)
  }
}
