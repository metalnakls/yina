import Cocoa

enum YINAError: Error { case unsupportedMPVNodeFormat(UInt32) }
enum Logger { enum Level { case warning } }
enum MPVProperty {
  static let timePos = "time-pos", duration = "duration", eofReached = "eof-reached"
  static let timeRemainingFull = "time-remaining/full", playtimeRemainingFull = "playtime-remaining/full"
}
enum MPVOption { enum WatchLater { static let savePositionOnQuit = "save-position-on-quit" } }
struct VideoTime { var second: Double; init(_ second: Double) { self.second = second } }
final class Info {
  var state = PlayerState.paused
  var currentURL: URL?
  var videoPosition: VideoTime?
  var videoDuration: VideoTime?
  var isSeeking = false
  var justStartedFile = false
}
final class Engine { let asyncClient = MPVAsyncClient() }

// CHECKPOINT_HELPER

final class PlayerCore {
  let info = Info()
  let mpv = Engine()
  var cachedSavePositionOnQuit = true
  var cachedEOF = false
  var cachedRemaining: Double?, cachedScaledRemaining: Double?
  enum Sync { case time }
  func syncPosition() {}
  func syncUI(_ value: Sync) {}
  func log(_ message: String, level: Logger.Level) { fputs(message + "\n", stderr) }
  // CHECKPOINT_PROPERTY
  // PRODUCTION_METHODS
}

@main struct CrashRecoverySmoke {
  static func main() {
    let path = CommandLine.arguments[1]
    let mode = CommandLine.arguments[3]
    let handle = mpv_create()!
    let player = PlayerCore()
    player.info.currentURL = URL(fileURLWithPath: path)
    for (key, value) in ["config": "no", "load-scripts": "no", "vo": "null", "ao": "null",
                         "pause": "yes", "keep-open": "always", "save-position-on-quit": "yes",
                         "watch-later-dir": CommandLine.arguments[2]] {
      precondition(mpv_set_option_string(handle, key, value) >= 0)
    }
    precondition(mpv_initialize(handle) >= 0)
    player.mpv.asyncClient.activate(handle)
    let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    precondition(mpv_command_string(handle, "loadfile \"\(escaped)\"") >= 0)
    waitForRestart(handle, player)
    if mode == "verify" {
      let resumed = position(handle)
      guard abs(resumed - 18) < 0.1 else {
        fputs("FAIL: crash lost progress; reopened at \(resumed)s instead of 18s\n", stderr)
        exit(1)
      }
      print("PASS: SIGKILL recovery resumes the last checkpoint in a fresh mpv process")
      exit(0)
    }
    let target = mode == "seed" ? 6 : 18
    precondition(mpv_command_string(handle, "seek \(target) absolute+exact") >= 0)
    waitForRestart(handle, player)
    if mode == "seed" {
      precondition(mpv_command_string(handle, "write-watch-later-config") >= 0)
      exit(0)
    }
    player.updateObservedPlayback(["time-pos": position(handle), "duration": 30.0])
    print("READY")
    fflush(stdout)
    while true { pump(handle, player) }
  }

  static func position(_ handle: OpaquePointer) -> Double {
    var position = 0.0
    precondition(mpv_get_property(handle, "time-pos", MPV_FORMAT_DOUBLE, &position) >= 0)
    return position
  }

  static func waitForRestart(_ handle: OpaquePointer, _ player: PlayerCore) {
    let deadline = Date(timeIntervalSinceNow: 5)
    while Date() < deadline {
      if pump(handle, player) == MPV_EVENT_PLAYBACK_RESTART { return }
    }
    fatalError("No playback restart")
  }

  @discardableResult static func pump(_ handle: OpaquePointer, _ player: PlayerCore) -> mpv_event_id {
    let event = mpv_wait_event(handle, 0.01)!.pointee
    _ = player.mpv.asyncClient.consume(event)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
    return event.event_id
  }
}
