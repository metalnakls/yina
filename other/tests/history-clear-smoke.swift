import Cocoa

enum Preference {
  enum Key { case recordPlaybackHistory }
  static func bool(for key: Key) -> Bool { true }
}
enum Utility {
  static let playbackHistoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("yina-history-fixture-\(UUID()).json")
  static let entered = DispatchSemaphore(value: 0)
  static let proceed = DispatchSemaphore(value: 0)
  static func mpvWatchLaterMd5(_ url: URL, _ ignorePath: Bool) -> String {
    if url.lastPathComponent == "queued.mp4" {
      entered.signal(); proceed.wait()
    }
    return url.lastPathComponent
  }
}
final class PlaybackHistory: NSObject {
  let mpvMd5: String
  init(url: URL, duration: Double, title: String?, mpvMd5: String) { self.mpvMd5 = mpvMd5 }
  func detachedCopy() -> PlaybackHistory { PlaybackHistory(url: URL(fileURLWithPath: mpvMd5), duration: 0, title: nil, mpvMd5: mpvMd5) }
  static func encodeArchive(_ entries: [PlaybackHistory]) throws -> Data {
    try JSONSerialization.data(withJSONObject: entries.map(\.mpvMd5))
  }
  static func decodeArchive(_ data: Data) throws -> [PlaybackHistory]? {
    let names = try JSONSerialization.jsonObject(with: data) as! [String]
    return names.map { PlaybackHistory(url: URL(fileURLWithPath: $0), duration: 0, title: nil, mpvMd5: $0) }
  }
}
enum Logger {
  enum Sub {}
  enum Level { case debug, error, verbose }
  static func makeSubsystem(_ name: String, _ icons: [String]) -> String { name }
  static func log(_ message: () -> String, level: Level, subsystem: String) {}
  static func isEmitting(_ level: Level) -> Bool { false }
}
final class MemoryUsage {
  static let shared = MemoryUsage()
  func logUsage(_ message: String) {}
}
extension Notification.Name {
  static let yinaHistoryUpdated = Notification.Name("fixture.updated")
  static let yinaHistoryTaskFinished = Notification.Name("fixture.finished")
}
@main enum HistoryClearSmoke {
  static func main() throws {
    let url = Utility.playbackHistoryURL
    defer { try? FileManager.default.removeItem(at: url) }
    let controller = HistoryController(plistFileURL: url)
    controller.history = [PlaybackHistory(url: url, duration: 0, title: nil, mpvMd5: "old")]
    controller.add(URL(fileURLWithPath: "/fixture/queued.mp4"), duration: 1, title: nil, false)
    precondition(Utility.entered.wait(timeout: .now() + 30) == .success)
    controller.removeAll()
    precondition(controller.history.isEmpty, "clear updates in-memory history")
    Utility.proceed.signal()
    func drain() {
      let deadline = Date(timeIntervalSinceNow: 30)
      while controller.tasksOutstanding != 0 && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005)) }
      precondition(controller.tasksOutstanding == 0, "History tasks remain: \(controller.tasksOutstanding)")
    }
    drain()
    precondition(controller.history.isEmpty, "queued pre-clear additions stay discarded")
    let saved = try PlaybackHistory.decodeArchive(Data(contentsOf: url))!
    precondition(saved.isEmpty, "clear persists empty history")
    controller.add(URL(fileURLWithPath: "/fixture/new.mp4"), duration: 1, title: nil, false)
    drain()
    precondition(controller.history.map(\.mpvMd5) == ["new.mp4"])
    let reopened = HistoryController(plistFileURL: url)
    precondition(reopened.history.map(\.mpvMd5) == ["new.mp4"], "later save does not resurrect cleared history")
    controller.history = (0..<5_000).map { PlaybackHistory(url: url, duration: 0, title: nil, mpvMd5: "entry-\($0)") }
    controller.remove([controller.history[1_000].detachedCopy()])
    drain()
    let large = HistoryController(plistFileURL: url).history
    precondition(large.count == 4_999 && !large.contains { $0.mpvMd5 == "entry-1000" },
                 "detached row removal and large archive persisted")
    print("PASS: in-memory and disk clear, queued-add invalidation, post-clear additions, detached removal, and large archive reload")
  }
}
