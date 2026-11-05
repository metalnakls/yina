import Foundation

/// Builds a text query without reading or enumerating the media's parent folders.
/// Hash matching remains the provider's first source of exact release matches.
enum OnlineSubtitleQuery {
  static func searchString(for url: URL, mediaTitle: String) -> String {
    guard url.isFileURL else { return mediaTitle }
    let filename = url.deletingPathExtension().lastPathComponent
    // Only borrow a folder title when the filename starts with an episode marker.
    // A filename that already names the show or movie keeps its release details.
    let fullEpisode = #"(?i)^(?:s(?:eason)?[ ._-]*(\d+)[ ._-]*e(?:pisode)?[ ._-]*(\d+)|(\d+)x(\d+))(?=$|[\W_])"#
    let episodeOnly = #"(?i)^e(?:pisode)?[ ._-]*(\d+)(?=$|[\W_])"#
    var season: Int?
    let episode: Int
    if let groups = captures(fullEpisode, in: filename) {
      season = Int(groups[0].isEmpty ? groups[2] : groups[0])
      guard let number = Int(groups[1].isEmpty ? groups[3] : groups[1]) else { return filename }
      episode = number
    } else if let groups = captures(episodeOnly, in: filename), let number = Int(groups[0]) {
      episode = number
    } else {
      return filename
    }

    var folder = url.deletingLastPathComponent()
    for _ in 0..<3 {
      guard folder.path != "/", folder.path != "/Volumes" else { break }
      let name = folder.lastPathComponent
      let seasonSuffix = #"(?i)(?:^|[ ._-])s(?:eason)?[ ._-]*(\d+)$"#
      var title = name
      if let regex = try? NSRegularExpression(pattern: seasonSuffix),
         let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
         let numberRange = Range(match.range(at: 1), in: name),
         let suffixRange = Range(match.range, in: name) {
        if season == nil { season = Int(name[numberRange]) }
        title = String(name[..<suffixRange.lowerBound])
      }
      title = title.replacingOccurrences(of: #"[._]+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-")))
      if !title.isEmpty {
        guard let season else { return filename }
        return String(format: "%@ S%02dE%02d", title, season, episode)
      }
      folder.deleteLastPathComponent()
    }
    return filename
  }

  private static func captures(_ pattern: String, in text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    return (1..<match.numberOfRanges).map {
      Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? ""
    }
  }
}
