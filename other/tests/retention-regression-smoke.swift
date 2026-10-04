import Cocoa
import JavaScriptCore

protocol InitializingFromKey { init?(key: Preference.Key) }
enum Preference {
  enum Key { case enableAdvancedSettings, enableLogging, logLevel }
  static func integer(for key: Key) -> Int { 0 }
  static func bool(for key: Key) -> Bool { true }
}
enum AppEnvironment {
  static let temporaryRoot: URL? = FileManager.default.temporaryDirectory.appendingPathComponent("yina-retention-tests-\(UUID())")
}
enum Utility {
  enum ShortCodeGenerator { static func getCode(length: Int) -> String { "smoke" } }
  static func showAlert(_ key: String, arguments: [String]) { fatalError(arguments.joined()) }
}
enum ObjcUtils { static func catchException(_ body: () -> Void) throws { body() } }
extension NSImage { static func sf(_ names: [String]) -> NSImage? { nil } }
extension Int { func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) } }
extension Notification.Name { static let yinaLogAppended = Notification.Name("yinaLogAppended") }
final class JavascriptPluginInstance {
  final class Plugin { let root = FileManager.default.temporaryDirectory }
  let plugin = Plugin()
  var currentFile: URL?
  func evaluateFile(_ url: URL, asModule: Bool) -> JSValue? { nil }
}
private final class WeakCallback { weak var value: JSValue?; init(_ value: JSValue) { self.value = value } }

@main enum RetentionRegressionSmoke {
  static func main() throws {
    // Logger's ordinary console output is deliberately noisy for this stress case.
    freopen("/dev/null", "w", stdout)
    defer { try? FileManager.default.removeItem(at: AppEnvironment.temporaryRoot!) }
    var notifications = 0
    let observer = NotificationCenter.default.addObserver(forName: .yinaLogAppended, object: nil, queue: nil) { _ in notifications += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }
    func until(_ condition: () -> Bool) {
      let deadline = Date(timeIntervalSinceNow: 3)
      while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
      }
      precondition(condition(), "timed out awaiting callback")
    }
    for index in 0..<20_000 { Logger.log("retention-test-\(index)") }
    precondition(Logger.buffer.count <= Logger.maximumLogCount, "closed log window must not grow without bounds")
    precondition(Logger.buffer.last?.message == "retention-test-19999", "newest message is retained")
    until { notifications > 0 }
    precondition(notifications == 1, "one notification per synchronous burst")
    let exported = AppEnvironment.temporaryRoot!.appendingPathComponent("export.log")
    try Logger.exportLog(to: exported)
    let completeLog = try String(contentsOf: exported, encoding: .utf8)
    precondition(completeLog.contains("retention-test-0\n") && completeLog.contains("retention-test-19999\n"), "full file export includes evicted UI messages")
    precondition(completeLog.split(separator: "\n").count == 20_000, "full export retains every message")
    DispatchQueue.concurrentPerform(iterations: 1_000) { Logger.log("concurrent-test-\($0)") }
    precondition(Logger.buffer.count <= Logger.maximumLogCount, "concurrent logging stays bounded")
    until { notifications > 1 }
    Logger.closeLogFile()

    let context = JSContext()!
    context.evaluateScript("var calls = 0")
    let plugin = JavascriptPluginInstance()
    let polyfill = JavascriptPolyfill(pluginInstance: plugin)
    var callbacks: [WeakCallback] = []
    autoreleasepool {
      for _ in 0..<200 {
        let callback = context.evaluateScript("(() => { calls++; })")!
        callbacks.append(WeakCallback(callback))
        _ = polyfill.createTimer(callback: callback, ms: 0, repeats: false)
      }
      let cancelled = polyfill.createTimer(callback: context.evaluateScript("(() => { calls += 10000; })")!, ms: 0, repeats: false)
      polyfill.removeTimer(identifier: cancelled)
    }
    until { context.objectForKeyedSubscript("calls").toInt32() == 200 }
    autoreleasepool { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
    precondition(callbacks.allSatisfy { $0.value == nil }, "completed timeout callbacks must be released")
    _ = polyfill.createTimer(callback: context.evaluateScript("(() => { calls += 10000; })")!, ms: 0, repeats: false)
    polyfill.removeAllTimers()
    let repeating = polyfill.createTimer(callback: context.evaluateScript("(() => { calls++; })")!, ms: 1, repeats: true)
    until { context.objectForKeyedSubscript("calls").toInt32() >= 203 }
    polyfill.removeTimer(identifier: repeating)
    let stoppedAt = context.objectForKeyedSubscript("calls").toInt32()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    precondition(context.objectForKeyedSubscript("calls").toInt32() == stoppedAt, "cleared timers stop firing")
    weak var unloaded: JavascriptPolyfill?
    autoreleasepool {
      let owner = JavascriptPolyfill(pluginInstance: plugin)
      unloaded = owner
      _ = owner.createTimer(callback: context.evaluateScript("(() => {})")!, ms: 0, repeats: false)
    }
    precondition(unloaded == nil, "queued timer creation must not retain an unloaded plugin")
    fputs("PASS: bounded logs, coalesced notifications, full export, completed callback release, pending cancellation, interval cancellation, unload\n", stderr)
  }
}
