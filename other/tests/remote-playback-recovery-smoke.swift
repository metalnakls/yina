import Cocoa

enum YINAError: Error { case unsupportedMPVNodeFormat(UInt32) }
enum Logger { enum Level { case verbose } }
enum MPVProperty {
  static let playlist = "playlist", timePos = "time-pos", duration = "duration", eofReached = "eof-reached"
  static let timeRemainingFull = "time-remaining/full", playtimeRemainingFull = "playtime-remaining/full"
}
enum MPVOption {
  enum PlaybackControl { static let pause = "pause" }
  enum WatchLater { static let savePositionOnQuit = "save-position-on-quit" }
}
enum Preference { enum Key { case pauseWhenOpen }; static func bool(for key: Key) -> Bool { false } }
enum Notice { case yinaPlayerStopped }
struct VideoTime { var second: Double; init(_ s: Double) { second = s } }
final class Info {
  var state = PlayerState.loading
  var currentURL: URL? = URL(string: "nas-test://movie.wav")
  var isNetworkResource = true, isRemoteFile = false
  var isRemotePlayback: Bool { isNetworkResource || isRemoteFile }
  var videoPosition: VideoTime? = VideoTime(18), videoDuration: VideoTime? = VideoTime(30)
  var isSeeking = false, shouldAutoLoadFiles = false, justStartedFile = false
  var vid: Int? = 0, aid: Int? = 1, sid: Int? = 0, secondSid: Int? = 0
}
final class VideoView { func displayIdle() {}; func displayActive() {} }
final class Indicator {
  weak var player: PlayerCore?
  var isHidden = true
  func updateNetworkState() { isHidden = !(player?.isWaitingForRemoteMedia == true || player?.isWaitingForPlayback == true) }
}
final class Window { var isVisible = true }
final class Controller {
  let videoView = VideoView(), bufferIndicatorView = Indicator()
  var loaded = true, pendingShow = false, closed = false
  func close() { closed = true }
  func showWindow(_ sender: Any?) {}
}
final class Shared { func stop() {}; func fileEnded(dueToStopCommand: Bool) {} }
final class MemoryUsage { static let shared = MemoryUsage(); func logUsage(_ s: String) {} }
final class AppDelegate { static let shared = AppDelegate(); let openURLWindow = OpenURL() }
final class OpenURL { var window: Window?; func failedToLoadURL() {} }
enum Utility { static func showAlert(_ s: String) {} }
struct MPVHookValue {
  let block: (@escaping () -> Void) -> Void
  init(withBlock block: @escaping (@escaping () -> Void) -> Void) { self.block = block }
}

// RECOVERY_HELPER

final class PlayerCore {
  let info = Info(), mainWindow = Controller(), sharedShow = Shared()
  var currentController: Controller { mainWindow }
  var currentWindow: Window? = Window()
  var mpv: Engine!
  var remoteRecovery = RemotePlaybackRecovery(), remoteRecoveryRetry: DispatchWorkItem?
  var playbackResumeWait = PlaybackResumeWait(), playbackResumeIndicator: DispatchWorkItem?
  var transportGeneration: UInt64 = 0
  var isWaitingForPlayback: Bool { playbackResumeWait.visible(now: ProcessInfo.processInfo.systemUptime) }
  var isWaitingForRemoteMedia: Bool { remoteRecovery.waiting }
  var receivedEndFileWhileLoading = false, cachedEOF = false, cachedSavePositionOnQuit = true
  var requestedPause: Bool?, cachedRemaining: Double?, cachedScaledRemaining: Double?
  var pendingUrl: URL?, pendingKnownRemoteFile: Bool?, pendingAutoLoad = false
  var retired = false, completedCheckpoints = 0, savedPosition: Double?
  enum Sync { case time, playButton }
  func syncUI(_ s: Sync) {}; func syncUI(_ s: [Sync]) {}
  func syncPosition() { if cachedEOF { info.videoPosition = info.videoDuration } }
  func finishSubtitleDissolve() {}; func refreshSyncUITimer() {}; func refreshEdrMode() {}
  func checkpointPlaybackPosition(force: Bool = false) {}
  func clearCompletedPlaybackCheckpoint() { completedCheckpoints += 1 }
  func savePlaybackPosition() { savedPosition = info.videoPosition?.second }
  func scheduleIdleRetirement() { retired = true }
  func postNotification(_ n: Notice) {}
  func log(_ s: String) {}
  func open(_ u: URL, shouldAutoLoad: Bool, knownRemoteFile: Bool?) {}
  func retryNow() { remoteRecoveryRetry?.cancel(); remoteRecoveryRetry = nil; retryRemotePlayback() }
  func installHooks() { addRemotePlaybackRecoveryHooks() }
  func loaded() { info.state = .loaded; if remoteRecovery.retrying { finishRemotePlaybackRecovery() } }
  func cancel() { cancelRemotePlaybackRecovery() }
  func waitForResume() { startPlaybackResumeWait(generation: transportGeneration) }
// PRODUCTION_METHODS
}

final class Fault {
  static let shared = Fault()
  let lock = NSLock()
  var data = Data(), offline = false
  var opened: [String] = []
  func setOffline(_ v: Bool) { lock.lock(); offline = v; lock.unlock() }
}
final class Stream { var offset = 0 }
let openStream: mpv_stream_cb_open_ro_fn = { _, uri, info in
  let fault = Fault.shared
  fault.lock.lock(); defer { fault.lock.unlock() }
  fault.opened.append(String(cString: uri!))
  if fault.offline { return MPV_ERROR_LOADING_FAILED.rawValue }
  info!.pointee.cookie = Unmanaged.passRetained(Stream()).toOpaque()
  info!.pointee.read_fn = { cookie, bytes, count in
    let fault = Fault.shared
    fault.lock.lock(); defer { fault.lock.unlock() }
    if fault.offline { return -1 }
    let stream = Unmanaged<Stream>.fromOpaque(cookie!).takeUnretainedValue()
    let n = min(Int(count), fault.data.count - stream.offset)
    fault.data.withUnsafeBytes { data in
      if n > 0 { memcpy(bytes!, data.baseAddress!.advanced(by: stream.offset), n) }
    }
    stream.offset += n
    return Int64(n)
  }
  info!.pointee.seek_fn = { cookie, offset in
    let fault = Fault.shared
    fault.lock.lock(); defer { fault.lock.unlock() }
    if fault.offline || offset < 0 || offset > fault.data.count { return -1 }
    Unmanaged<Stream>.fromOpaque(cookie!).takeUnretainedValue().offset = Int(offset)
    return offset
  }
  info!.pointee.size_fn = { _ in Int64(Fault.shared.data.count) }
  info!.pointee.close_fn = { cookie in Unmanaged<Stream>.fromOpaque(cookie!).release() }
  return 0
}

final class Engine {
  let handle: OpaquePointer
  let asyncClient = MPVAsyncClient()
  unowned let player: PlayerCore
  var hooks: [UInt64: MPVHookValue] = [:]
  var loads = 0, ends = 0
  init(_ player: PlayerCore) {
    self.player = player
    handle = mpv_create()!
    for (k, v) in ["config": "no", "load-scripts": "no", "vo": "null", "ao": "null", "idle": "yes",
                   "cache": "no", "pause": "yes", "keep-open": "no", "terminal": "no",
                   "demuxer-readahead-secs": "0.2", "stream-buffer-size": "4KiB", "save-position-on-quit": "no"] {
      precondition(mpv_set_option_string(handle, k, v) >= 0)
    }
    precondition(mpv_stream_cb_add_ro(handle, "nas-test", nil, openStream) >= 0)
    precondition(mpv_initialize(handle) >= 0)
    asyncClient.activate(handle)
  }
  func setAsync(_ n: String, _ v: MPVAsyncClient.Value) { asyncClient.set(n, v) }
  func setFlag(_ n: String, _ v: Bool, level: Logger.Level) { setAsync(n, .flag(v)) }
  func log(_ s: String) {}
  func getPropertiesAsync(_ n: [String], completion: @escaping ([String: Any]) -> Void) { asyncClient.get(n, completion: completion) }
  func addHook(_ n: MPVHook, hook: MPVHookValue) {
    let id = UInt64(hooks.count + 1); hooks[id] = hook
    precondition(mpv_hook_add(handle, id, n.rawValue, 0) >= 0)
  }
  func number(_ n: String) -> Double? {
    var d = 0.0
    return mpv_get_property(handle, n, MPV_FORMAT_DOUBLE, &d) >= 0 ? d : nil
  }
  func flag(_ n: String) -> Bool {
    var f: Int32 = 0; _ = mpv_get_property(handle, n, MPV_FORMAT_FLAG, &f); return f != 0
  }
  func pump() {
    while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {
      if asyncClient.consume(event.pointee) { continue }
      switch event.pointee.event_id {
      case MPV_EVENT_HOOK:
        let h = event.pointee.data.load(as: mpv_event_hook.self)
        hooks[event.pointee.reply_userdata]!.block { mpv_hook_continue(self.handle, h.id) }
      case MPV_EVENT_FILE_LOADED:
        loads += 1; player.loaded()
      case MPV_EVENT_START_FILE:
        player.info.state = .starting
      case MPV_EVENT_PLAYBACK_RESTART:
        player.info.justStartedFile = false
      // END_EVENT
      default: break
      }
      if event.pointee.event_id == MPV_EVENT_END_FILE { ends += 1 }
    }
    if flag("idle-active") { player.idleActiveChanged() }
    if let pos = number("time-pos") {
      player.updateObservedPlayback(["time-pos": pos, "duration": 30.0, "eof-reached": flag("eof-reached")])
    }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
  }
}

@main struct RemoteRecoverySmoke {
  static func wait(_ engine: Engine, _ condition: () -> Bool, _ message: String) {
    let until = Date(timeIntervalSinceNow: 8)
    while !condition(), Date() < until { engine.pump() }
    precondition(condition(), message)
  }
  static func main() throws {
    var policy = RemotePlaybackRecovery()
    let nas = URL(fileURLWithPath: "/Volumes/GeneratedNAS/movie.mkv")
    policy.record(url: nas, position: 18, duration: 30, eof: false)
    precondition(!policy.begin(url: nas, remote: false, failed: true, completed: false, playlistEntryID: 1, tracks: [:]))
    precondition(policy.begin(url: nas, remote: true, failed: false, completed: true, playlistEntryID: 1, tracks: [:]))
    policy.record(url: nas, position: 0, duration: 30, eof: false)
    precondition(policy.target!.position == 18, "An offline retry replaced the saved position")
    let oldGeneration = policy.beginRetry()!
    precondition(policy.beginRetry() == nil, "Overlapping retries are forbidden")
    policy.cancel()
    precondition(policy.generation != oldGeneration && policy.target == nil)
    policy.record(url: nas, position: 29.9, duration: 30, eof: false)
    precondition(!policy.begin(url: nas, remote: true, failed: false, completed: true, playlistEntryID: 1, tracks: [:]), "Normal EOF became a reconnect")
    var resume = PlaybackResumeWait()
    resume.begin(position: 18, now: 10)
    precondition(!resume.visible(now: 10.24) && resume.visible(now: 10.25))
    precondition(!resume.observe(position: 18, playing: true))
    precondition(!resume.observe(position: 19, playing: false), "A paused seek is not a resumed video")
    precondition(resume.observe(position: 18.1, playing: true) && !resume.pending)
    Fault.shared.data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let player = PlayerCore(), url = URL(string: "nas-test://movie.wav")!
    let engine = Engine(player); player.mpv = engine
    player.mainWindow.bufferIndicatorView.player = player
    player.installHooks()
    engine.asyncClient.command(["loadfile", url.absoluteString])
    wait(engine, { engine.loads == 1 }, "Initial media did not load")
    engine.asyncClient.command(["loadfile", "nas-test://next.wav", "append"])
    engine.asyncClient.command(["seek", "18", "absolute+exact"])
    wait(engine, { abs((engine.number("time-pos") ?? 0) - 18) < 0.1 }, "Initial seek failed")
    player.info.state = .paused
    player.updateObservedPlayback(["time-pos": 18.0, "duration": 30.0])
    player.waitForResume()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    precondition(!player.mainWindow.bufferIndicatorView.isHidden, "A stalled Play request needs a spinner")
    player.info.state = .playing
    player.updateObservedPlayback(["time-pos": 18.1])
    precondition(player.mainWindow.bufferIndicatorView.isHidden, "Playback progress must clear the spinner")
    player.info.state = .paused
    Fault.shared.setOffline(true)
    engine.setAsync("pause", .flag(false))
    wait(engine, { player.isWaitingForRemoteMedia && engine.flag("idle-active") }, "Read failure did not enter recovery")
    let position = player.remoteRecovery.target!.position
    precondition(position >= 18 && position < 25, "Lost the last playable position")
    precondition(player.savedPosition == position && player.completedCheckpoints == 0)
    precondition(!player.mainWindow.closed && !player.retired && !player.mainWindow.bufferIndicatorView.isHidden)
    let firstEnds = engine.ends
    player.retryNow()
    wait(engine, { engine.ends > firstEnds && !player.remoteRecovery.retrying }, "Offline retry did not remain recoverable")
    precondition(player.remoteRecovery.target!.position == position, "Failed retry overwrote progress")
    precondition(!player.mainWindow.closed && !player.retired)
    wait(engine, { engine.flag("idle-active") }, "Offline retry did not return idle")
    Fault.shared.setOffline(false)
    player.retryNow()
    wait(engine, { !player.isWaitingForRemoteMedia && engine.loads >= 2 }, "Reconnection did not restore the session")
    precondition(engine.flag("pause") && player.info.state == .paused, "Reconnection unexpectedly autoplayed")
    precondition(abs((engine.number("time-pos") ?? -1) - position) < 0.1, "Resume position changed")
    precondition(engine.number("playlist-count") == 2, "Reconnect discarded the playlist")
    precondition(!Fault.shared.opened.contains("nas-test://next.wav"), "Failure advanced the playlist")
    precondition(player.mainWindow.bufferIndicatorView.isHidden && !player.mainWindow.closed)
    var restoredTimeline = player.remoteRecovery
    precondition(restoredTimeline.begin(url: url, remote: true, failed: false, completed: true,
      playlistEntryID: 1, tracks: [:]), "Reconnected playback lost its position/duration snapshot")
    let loadsBeforeCancel = engine.loads
    player.fileEnded(false, failed: true, playlistEntryID: 1)
    player.retryNow()
    player.cancel()
    for _ in 0..<20 { engine.pump() }
    precondition(!player.remoteRecovery.waiting && !player.remoteRecovery.retrying)
    precondition(engine.loads == loadsBeforeCancel, "An old retry resurrected canceled media")
    print("PASS: real read failure, failed reconnect, same-window paused resume, exact position and playlist retention")
  }
}
