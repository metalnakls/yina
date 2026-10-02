// Compile with yina/PlaybackHistory.swift. All history storage is a fixture.
import Cocoa
struct VideoTime { let second: Double; init(_ value: Double) { second = value }; var stringRepresentation: String { "fixture" } }
enum Utility { static func playbackProgressFromWatchLater(_ value: String) -> VideoTime? { nil } }
enum ThumbnailCache { static func uniquelyRenamedVideo(forName: String, originalURL: URL) -> URL? { nil } }
final class LegacyHistory: NSObject, NSSecureCoding {
  static var supportsSecureCoding: Bool { true }
  var includesOptionalFields = true
  override init() { super.init() }
  required init?(coder: NSCoder) { super.init() }
  func encode(with coder: NSCoder) {
    coder.encode(URL(string: "https://example.invalid/fixture.mp4")!, forKey: "IINAPHUrl")
    coder.encode("fixture", forKey: "IINAPHNme")
    coder.encode("fixture-md5", forKey: "IINAPHMpvmd5")
    coder.encode(Date(timeIntervalSince1970: 123), forKey: "IINAPHDate")
    coder.encode(true, forKey: "IINAPHPlayed")
    coder.encode(42.0, forKey: "IINAPHDuration")
    if includesOptionalFields {
      coder.encode("fixture title", forKey: "IINAPHTitle")
      coder.encode(Data([1,2,3]), forKey: "IINAPHBookmark")
    }
  }
}
@main struct LegacyHistorySmoke {
 static func main() throws {
  let encoder = NSKeyedArchiver(requiringSecureCoding: true)
  encoder.setClassName("IINA.PlaybackHistory", for: LegacyHistory.self)
  encoder.encode([LegacyHistory()], forKey: NSKeyedArchiveRootObjectKey)
  encoder.finishEncoding()
  let entries = try PlaybackHistory.decodeArchive(encoder.encodedData)!
  precondition(entries.count == 1 && entries[0].name == "fixture")
  precondition(entries[0].duration.second == 42 && entries[0].played)
  precondition(entries[0].title == "fixture title")
  let modern = try NSKeyedArchiver.archivedData(withRootObject: entries, requiringSecureCoding: true)
  let roundTrip = try PlaybackHistory.decodeArchive(modern)!
  precondition(roundTrip.count == 1 && roundTrip[0].name == "fixture")
  let older = LegacyHistory()
  older.includesOptionalFields = false
  let oldEncoder = NSKeyedArchiver(requiringSecureCoding: true)
  oldEncoder.setClassName("IINA.PlaybackHistory", for: LegacyHistory.self)
  oldEncoder.encode([older], forKey: NSKeyedArchiveRootObjectKey)
  oldEncoder.finishEncoding()
  let oldEntries = try PlaybackHistory.decodeArchive(oldEncoder.encodedData)!
  precondition(oldEntries.count == 1 && oldEntries[0].title == nil)
  print("PASS: IINA class and field names import correctly; current yina history round-trips")
 }
}
