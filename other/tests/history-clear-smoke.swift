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
    precondition(Utility.entered.wait(timeout: .now() + 3) == .success)
    controller.removeAll()
    precondition(controller.history.isEmpty, "clear updates in-memory history")
    let saved = try PlaybackHistory.decodeArchive(Data(contentsOf: url))!
    precondition(saved.isEmpty, "clear persists empty history")
    Utility.proceed.signal()
    func drain() {
      let deadline = Date(timeIntervalSinceNow: 3)
      while controller.tasksOutstanding != 0 && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005)) }
      precondition(controller.tasksOutstanding == 0)
    }
    drain()
    precondition(controller.history.isEmpty, "queued pre-clear additions stay discarded")
    controller.add(URL(fileURLWithPath: "/fixture/new.mp4"), duration: 1, title: nil, false)
    drain()
    precondition(controller.history.map(\.mpvMd5) == ["new.mp4"])
    let reopened = HistoryController(plistFileURL: url)
    precondition(reopened.history.map(\.mpvMd5) == ["new.mp4"], "later save does not resurrect cleared history")
    print("PASS: in-memory and disk clear, queued-add invalidation, post-clear additions and reload")
  }
}
