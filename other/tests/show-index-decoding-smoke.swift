import Foundation

@main
struct ShowIndexDecodingSmoke {
  static func main() throws {
    let record: [String: Any] = ["id": ["hashString": "0123456789abcdef0123456789abcdef01234567", "fileIndex": 0],
                               "relativePath": "Season 1/episode.mkv", "bytesCompleted": 10,
                               "totalBytes": 10, "wanted": false]
    func data(_ records: [[String: Any]], version: Int = 1, date: String = "2026-10-28T20:00:00Z") -> Data {
      try! JSONSerialization.data(withJSONObject: ["schemaVersion": version, "hashString": "0123456789abcdef0123456789abcdef01234567",
                                                  "capturedAt": date, "episodes": records])
    }
    let snapshot = ShowEpisodeIndexReader.decode(data([record]))
    precondition(snapshot?.episodes.first?.received == 10)
    precondition(snapshot?.episodes.first?.wanted == false)
    precondition(ShowEpisodeIndexReader.decode(data([record, record])) == nil)
    precondition(ShowEpisodeIndexReader.decode(data([record], version: 2)) == nil)
    precondition(ShowEpisodeIndexReader.decode(data([record], date: "invalid")) == nil)
    precondition(ShowEpisodeIndexReader.decode(data([record], date: "2026-10-28T20:00:00.123Z")) != nil)
    for path in ["../escape.mkv", "/escape.mkv", "a/../escape.mkv", "a//b.mkv", "a\\b.mkv", "a/./b.mkv"] {
      var unsafe = record
      unsafe["relativePath"] = path
      precondition(ShowEpisodeIndexReader.decode(data([unsafe])) == nil, "Accepted unsafe path: \(path)")
    }
    var mismatched = record
    mismatched["id"] = ["hashString": "ffffffffffffffffffffffffffffffffffffffff", "fileIndex": 0]
    precondition(ShowEpisodeIndexReader.decode(data([mismatched])) == nil)
    var negative = record
    negative["bytesCompleted"] = -1
    precondition(ShowEpisodeIndexReader.decode(data([negative])) == nil)
    precondition(ShowEpisodeIndexReader.decode(Data(repeating: 32, count: ShowEpisodeIndexReader.maximumBytes + 1)) == nil)
    let date = snapshot!.capturedAt
    precondition(snapshot!.isFresh(at: date.addingTimeInterval(1)))
    precondition(!snapshot!.isFresh(at: date.addingTimeInterval(-1)))
    precondition(!snapshot!.isFresh(at: date.addingTimeInterval(ShowEpisodeIndexReader.freshnessLimit)))
    print("PASS: show inventory decoding, bounds, identities, paths, and freshness")
  }
}
