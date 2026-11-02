import Cocoa

enum Logger {
  enum Level { case debug, error, warning, verbose }
  struct Subsystem { let rawValue = "fixture" }
  static func log(_ message: () -> String, level: Level, subsystem: Subsystem) {}
}
enum MPVProperty {
  static let videoParamsGamma = "video-params/gamma"
  static let videoParamsPrimaries = "video-params/primaries"
  static let videoParamsSigPeak = "video-params/sig-peak"
}
enum MPVOption {
  enum GPURendererOptions { // GPU_OPTIONS
  }
  enum Video { static let displayFpsOverride = "display-fps-override" }
  enum Screenshot { static let screenshotTagColorspace = "screenshot-tag-colorspace" }
}
enum Preference {
  enum Key { case loadIccProfile, enableToneMapping, enableToneMappingTargetPeakOverride, toneMappingTargetPeakOverride, toneMappingAlgorithm }
  enum ToneMappingAlgorithmOption { case auto }
  static func bool(for key: Key) -> Bool { key == .enableToneMapping }
  static func integer(for key: Key) -> Int { 1000 }
  static func `enum`<T>(for key: Key) -> T { ToneMappingAlgorithmOption.auto as! T }
}
final class FakeScreen {
  var displayId: CGDirectDisplayID? = 1
  var maximumPotentialExtendedDynamicRangeColorComponentValue: CGFloat = 4
  var maximumExtendedDynamicRangeColorComponentValue: CGFloat = 4
  var maximumFramesPerSecond = 120
  var colorSpace: NSColorSpace? = .sRGB
}
extension NSScreen {
  static func logEDR(_ message: String, _ screen: FakeScreen, subsystem: Logger.Subsystem) {}
}
func CoreDisplay_DisplayCreateInfoDictionary(_ display: CGDirectDisplayID) -> Unmanaged<CFDictionary>? { nil }
extension Dictionary { func toStringForLog() -> String { "fixture" } }
final class FakeWindow { var screen: FakeScreen? = FakeScreen() }
enum Notice { case yinaHDRChanged }
final class FakeInfo {
  struct State { var loaded = true }
  var state = State()
  var currentURL = URL(fileURLWithPath: "/generated-a.mkv")
  var hdrAvailable = false
  var hdrEnabled = true
}
final class FakeMainWindow {
  var loaded = true
  var window: FakeWindow? = FakeWindow()
  func updateOSCExtendedDynamicRange() {}
}
final class FakeMPV {
  enum Value { case flag(Bool), double(Double), string(String) }
  var syncCalls = 0
  var callbacks: [([String: String]) -> Void] = []
  var writes: [String: Value] = [:]
  var writeCount = 0
  private func blocked() { syncCalls += 1; Thread.sleep(forTimeInterval: 0.1) }
  func getString(_ name: String) -> String? { blocked(); return nil }
  func getDouble(_ name: String) -> Double { blocked(); return 0 }
  func setFlag(_ name: String, _ value: Bool) { blocked() }
  func setDouble(_ name: String, _ value: Double) { blocked() }
  func setString(_ name: String, _ value: String) { blocked() }
  func setStringToDefault(_ name: String) { blocked() }
  func getStringsAsync(_ names: [String], completion: @escaping ([String: String]) -> Void) {
    callbacks.append(completion)
  }
  func setAsync(_ name: String, _ value: Value, coalescing: Bool = false) {
    writes[name] = value
    writeCount += 1
  }
}
final class FakePlayer {
  let subsystem = Logger.Subsystem()
  let mainWindow = FakeMainWindow()
  let info = FakeInfo()
  var mpv: FakeMPV! = FakeMPV()
  func postNotification(_ notice: Notice) {}
}
final class VideoView {
  var player: FakePlayer! = FakePlayer()
  let hdrSubsystem = Logger.Subsystem(), subsystem = Logger.Subsystem()
  var window: FakeWindow? = FakeWindow()
  var currentDisplay: CGDirectDisplayID? = 1
  var currentDisplaySupportsEDR: Bool? = true
  var edrRefreshGeneration: UInt64 = 0
  var edrSourceMetadata: [String: String] = [:]
  func currentICCProfilePath() -> String? { nil }
}

@main struct WakeDisplayRefreshSmoke {
  static func main() {
    let view = VideoView()
    let engine = view.player.mpv!
    let start = ProcessInfo.processInfo.systemUptime
    view.refreshEdrMode()
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    guard elapsed < 0.05 else {
      fputs("FAIL: wake HDR refresh blocked the UI for \(Int(elapsed * 1000))ms while the engine stalled\n", stderr)
      exit(1)
    }
    precondition(engine.callbacks.count == 1 && engine.writes.isEmpty)
    let hdr = [MPVProperty.videoParamsGamma: "pq", MPVProperty.videoParamsPrimaries: "bt.2020",
               "option-info/target-peak/default-value": "auto", "option-info/tone-mapping/default-value": "auto"]
    view.player.info.currentURL = URL(fileURLWithPath: "/generated-b.mkv")
    engine.callbacks[0](hdr)
    precondition(engine.writes.isEmpty, "Previous-file metadata must not change current output")
    view.refreshEdrMode()
    view.refreshEdrMode()
    engine.callbacks[1](hdr)
    precondition(engine.writes.isEmpty, "A superseded display refresh must not publish")
    engine.callbacks[2]([MPVProperty.videoParamsGamma: "bt.1886", MPVProperty.videoParamsPrimaries: "bt.709",
                         "option-info/target-peak/default-value": "auto", "option-info/tone-mapping/default-value": "auto"])
    guard case .flag(true)? = engine.writes[MPVOption.GPURendererOptions.inverseToneMapping] else {
      fatalError("SDR expansion policy changed")
    }
    view.refreshEdrMode()
    engine.callbacks[3](hdr)
    guard case .flag(false)? = engine.writes[MPVOption.GPURendererOptions.inverseToneMapping],
          case .string("pq")? = engine.writes[MPVOption.GPURendererOptions.targetTrc] else {
      fatalError("Native HDR must retain its transfer without SDR expansion")
    }
    view.window!.screen!.displayId = 2
    let displayStart = ProcessInfo.processInfo.systemUptime
    view.updateDisplayLink()
    precondition(ProcessInfo.processInfo.systemUptime - displayStart < 0.05)
    let writesBeforeClosing = engine.writeCount
    view.currentDisplay = 3
    engine.callbacks[4](hdr)
    precondition(engine.writeCount == writesBeforeClosing, "A previous display must reject a late refresh")
    view.refreshEdrMode()
    view.player.info.state.loaded = false
    engine.callbacks[5](hdr)
    precondition(engine.writeCount == writesBeforeClosing, "A stopped player must reject a late refresh")
    view.player.info.state.loaded = true
    view.refreshEdrMode()
    view.player = nil
    engine.callbacks[6](hdr)
    precondition(engine.writeCount == writesBeforeClosing, "A released player must reject a late refresh")
    precondition(engine.syncCalls == 0, "Display/HDR refresh must never wait on the media engine")
    print("PASS: delayed engine leaves wake/display refresh responsive; stale replies and HDR/SDR policy preserved")
  }
}
