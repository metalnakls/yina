// xcrun swiftc -parse-as-library yina/OnlineSubtitleQuery.swift other/tests/online-subtitle-query-smoke.swift -o /tmp/yina-subtitle-query-smoke
import Foundation

@main struct SubtitleQuerySmoke {
  static func main() {
    let cases = [
      ("/TV/The Walking Dead/Season 5/S05E05.mkv", "The Walking Dead S05E05"),
      ("/TV/The Walking Dead/Season 5/S05E05_1080p.mkv", "The Walking Dead S05E05"),
      ("/TV/The Walking Dead - Season 5/S05E05.mkv", "The Walking Dead S05E05"),
      ("/TV/The Walking Dead/Season 4/Season 4 Episode 5.mkv", "The Walking Dead S04E05"),
      ("/TV/The Walking Dead/Season 5/5x05.mkv", "The Walking Dead S05E05"),
      ("/TV/The Walking Dead/Season 5/E05.mkv", "The Walking Dead S05E05"),
      ("/TV/The Walking Dead/Season 5/Episode 5.mkv", "The Walking Dead S05E05"),
      ("/TV/The Walking Dead Season 5/S05E05.mkv", "The Walking Dead S05E05"),
      ("/TV/The Walking Dead/Season 5/The.Walking.Dead.S05E05.1080p.mkv", "The.Walking.Dead.S05E05.1080p"),
      ("/Movies/Arrival.2016.mkv", "Arrival.2016"),
      ("/TV/Season 5/S05E05.mkv", "TV S05E05")
    ]
    for (path, expected) in cases {
      let actual = OnlineSubtitleQuery.searchString(for: URL(fileURLWithPath: path), mediaTitle: "Ignored")
      precondition(actual == expected, "\(path): expected \(expected), got \(actual)")
    }
    precondition(OnlineSubtitleQuery.searchString(for: URL(string: "https://example.com/video")!, mediaTitle: "Stream title") == "Stream title")
    print("Passed \(cases.count + 1) subtitle query cases")
  }
}
