// Compile with yina/PlaybackHistory.swift. All history storage is a fixture.
import Cocoa
struct VideoTime { let second: Double; init(_ value: Double) { second = value }; var stringRepresentation: String { "fixture" } }
enum Utility { static func playbackProgressFromWatchLater(_ value: String) -> VideoTime? { nil } }
enum ThumbnailCache { static func uniquelyRenamedVideo(forName: String, originalURL: URL) -> URL? { nil } }
final class LegacyHistory: NSObject, NSSecureCoding {
  static var supportsSecureCoding: Bool { true }
  var includesOptionalFields = true
  var fieldPrefix = "IINAPH"
  override init() { super.init() }
  required init?(coder: NSCoder) { super.init() }
  func encode(with coder: NSCoder) {
    coder.encode(URL(string: "https://example.invalid/fixture.mp4")!, forKey: "\(fieldPrefix)Url")
    coder.encode("fixture", forKey: "\(fieldPrefix)Nme")
    coder.encode("fixture-md5", forKey: "\(fieldPrefix)Mpvmd5")
    coder.encode(Date(timeIntervalSince1970: 123), forKey: "\(fieldPrefix)Date")
    coder.encode(true, forKey: "\(fieldPrefix)Played")
    coder.encode(42.0, forKey: "\(fieldPrefix)Duration")
    if includesOptionalFields {
      coder.encode("fixture title", forKey: "\(fieldPrefix)Title")
      coder.encode(Data([1,2,3]), forKey: "\(fieldPrefix)Bookmark")
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
  let modern = try PlaybackHistory.encodeArchive(entries)
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
  let interim = LegacyHistory()
  interim.fieldPrefix = "YINAPH"
  let interimEncoder = NSKeyedArchiver(requiringSecureCoding: true)
  interimEncoder.setClassName("YINA.PlaybackHistory", for: LegacyHistory.self)
  interimEncoder.encode([interim], forKey: NSKeyedArchiveRootObjectKey)
  interimEncoder.finishEncoding()
  let interimEntries = try PlaybackHistory.decodeArchive(interimEncoder.encodedData)!
  precondition(interimEntries.count == 1 && interimEntries[0].name == "fixture")
  let archive = try PropertyListSerialization.propertyList(from: modern, format: nil) as! [String: Any]
  let objects = archive["$objects"] as! [Any]
  precondition(objects.contains { ($0 as? [String: Any])?["$classname"] as? String == "IINA.PlaybackHistory" })
  precondition(objects.contains { ($0 as? [String: Any])?["IINAPHUrl"] != nil })
  precondition(!objects.contains { ($0 as? [String: Any])?["YINAPHUrl"] != nil })
  print("PASS: upstream IINA archives, interim yina aliases, missing optional fields, and upstream-compatible writes")
 }
}
