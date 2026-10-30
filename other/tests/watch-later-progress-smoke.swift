import Foundation

@main struct WatchLaterReaderSmoke {
  static func main() throws {
    func check(_ contents: String, _ expected: Double?) throws {
      try contents.write(to: Utility.watchLaterURL.appendingPathComponent("fixture"), atomically: true, encoding: .utf8)
      let result = Utility.playbackProgressFromWatchLater("fixture")?.second
      guard result == expected else {
        fputs("FAIL: watch-later progress was \(String(describing: result)), expected \(String(describing: expected))\n", stderr)
        exit(1)
      }
    }
    try check("start=18.250000\nvolume=50\n", 18.25)
    try check("# generated fixture.wav\nvolume=50\nstart=18.250000\n", 18.25)
    try check("# redirect entry\n", nil)
    try check("start=nan\n", nil)
    try check("start=-1\n", nil)
    precondition(Utility.playbackProgressFromWatchLater("missing") == nil)
    print("PASS: watch-later comments, option ordering, invalid values and missing progress")
  }
}
