import AppKit

enum AppEnvironment {
  final class MemoryDefaults {
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
  }
  static let defaults = MemoryDefaults()
}
struct ShowFolder { let folderURL: URL }
enum ShowFolderSnapshotStore {
  static var root: URL = URL(fileURLWithPath: "/tmp")
  static func loadCards() -> [ShowFolder] { [ShowFolder(folderURL: root)] }
}
enum Utility {
  static func quickOpenPanel(title: String, chooseDir: Bool, dir: URL? = nil,
                            sheetWindow: NSWindow? = nil, callback: @escaping (URL) -> Void) {
    fatalError("No UI in the libmpv session fixture")
  }
}

@MainActor final class PlayerCore {
  final class Time { var second: Double; init(_ second: Double) { self.second = second } }
  final class PlaylistItem { let filename: String; init(_ filename: String) { self.filename = filename } }
  final class Info {
    var currentURL: URL?
    var state: PlayerState = .idle
    var videoPosition: Time?
    var videoDuration: Time?
    var playSpeed = 1.0
    var pausedForCache = false
    var isSeeking = false
    var playlist: [PlaylistItem] = []
  }
  let info = Info()
  let handle: OpaquePointer
  var session: SharedShowSession?
  var sharedShow: SharedShowSession { session! }
  private var pendingURL: URL?
  private var timer: Timer?
  private var canceledURL: URL?
  private var replacementInFlight = false
  var forcedCachePaused = false
  private(set) var seekEvents = 0

  init() {
    handle = mpv_create()!
    mpv_set_option_string(handle, "config", "no")
    mpv_set_option_string(handle, "load-scripts", "no")
    mpv_set_option_string(handle, "vo", "null")
    mpv_set_option_string(handle, "ao", "null")
    mpv_set_option_string(handle, "hwdec", "no")
    mpv_set_option_string(handle, "idle", "yes")
    precondition(mpv_initialize(handle) >= 0)
    timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.pump() }
    }
  }

  func close() {
    timer?.invalidate(); timer = nil
    mpv_terminate_destroy(handle)
  }

  private func pump() {
    while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {
      switch event.pointee.event_id {
      case MPV_EVENT_SEEK:
        seekEvents += 1
        info.isSeeking = true
        session?.playbackSeekingObserved()
      case MPV_EVENT_PLAYBACK_RESTART:
        info.isSeeking = false
        session?.playbackRestartObserved()
      case MPV_EVENT_FILE_LOADED:
        info.currentURL = pendingURL
        pendingURL = nil
        info.state = .playing
        var duration = 0.0
        if mpv_get_property(handle, "duration", MPV_FORMAT_DOUBLE, &duration) >= 0 {
          info.videoDuration = Time(duration)
        }
        info.videoPosition = Time(0)
        session?.start()
      case MPV_EVENT_END_FILE:
        let reason = event.pointee.data.load(as: mpv_end_file_reason.self)
        let replacing = replacementInFlight || info.state == .loading || info.state == .starting
        replacementInFlight = false
        session?.fileEnded(dueToStopCommand: reason == MPV_END_FILE_REASON_STOP && !replacing)
        if !replacing {
          info.state = .idle
          session?.stop()
        }
      default: break
      }
    }
    guard info.state.loaded else { return }
    var position = 0.0
    if mpv_get_property(handle, "time-pos", MPV_FORMAT_DOUBLE, &position) >= 0 {
      info.videoPosition = Time(position)
    }
    var duration = 0.0
    if mpv_get_property(handle, "duration", MPV_FORMAT_DOUBLE, &duration) >= 0 {
      info.videoDuration = Time(duration)
    }
    var speed = 1.0
    if mpv_get_property(handle, "speed", MPV_FORMAT_DOUBLE, &speed) >= 0 { info.playSpeed = speed }
    var paused: Int32 = 0
    if mpv_get_property(handle, "pause", MPV_FORMAT_FLAG, &paused) >= 0 {
      let previous = info.state
      info.state = paused != 0 ? .paused : .playing
      if previous != info.state { session?.playbackPauseObserved(paused != 0) }
    }
    var cachePaused: Int32 = 0
    if mpv_get_property(handle, "paused-for-cache", MPV_FORMAT_FLAG, &cachePaused) >= 0 {
      info.pausedForCache = cachePaused != 0 || forcedCachePaused
    }
    session?.playbackObservation(position: info.videoPosition?.second,
      observedAt: ProcessInfo.processInfo.systemUptime,
      cachePaused: info.pausedForCache, seeking: info.isSeeking)
  }

  func openURLsAsync(_ urls: [URL], shouldAutoLoad: Bool = true, completion: ((Int?) -> Void)? = nil) {
    guard let url = urls.first, canceledURL != url else { completion?(0); return }
    session?.localMediaChangeRequested()
    replacementInFlight = info.currentURL != nil
    pendingURL = url
    info.state = .loading
    let command = "loadfile \"\(url.path)\" replace"
    precondition(mpv_command_string(handle, command) >= 0)
    completion?(1)
  }
  func cancelSharedShowMediaPreparation(for expectedURL: URL) {
    if pendingURL == expectedURL { canceledURL = expectedURL }
  }
  func cancelSharedShowCommandOpen(for expectedURL: URL) {
    if pendingURL == expectedURL || info.currentURL == expectedURL {
      _ = mpv_command_string(handle, "stop")
    }
  }
  func syncPositionIfNeeded() {}
  func refreshSharedShowReadiness(generation: UInt64) {
    var position = 0.0
    var cachePaused: Int32 = 0
    var paused: Int32 = 0
    let hasPosition = mpv_get_property(handle, "time-pos", MPV_FORMAT_DOUBLE, &position) >= 0
    let hasCache = mpv_get_property(handle, "paused-for-cache", MPV_FORMAT_FLAG, &cachePaused) >= 0
    let hasPause = mpv_get_property(handle, "pause", MPV_FORMAT_FLAG, &paused) >= 0
    session?.playbackObservation(position: hasPosition ? position : nil,
      observedAt: ProcessInfo.processInfo.systemUptime,
      cachePaused: !hasCache || cachePaused != 0 || forcedCachePaused, seeking: info.isSeeking,
      barrierGeneration: generation, enginePaused: hasPause ? paused != 0 : nil)
  }
  func seek(absoluteSecond: Double) {
    session?.localControlChanged(.seek(absoluteSecond))
    _ = mpv_command_string(handle, "seek \(absoluteSecond) absolute exact")
  }
  func pause() {
    session?.localControlChanged(.pause(true))
    _ = mpv_set_property_string(handle, "pause", "yes")
  }
  func resume() {
    session?.localControlChanged(.pause(false))
    if session?.shouldDeferLocalResume == true { return }
    _ = mpv_set_property_string(handle, "pause", "no")
  }
  func setSpeed(_ value: Double) {
    session?.localControlChanged(.rate(value))
    _ = mpv_set_property_string(handle, "speed", "\(value)")
  }
  func setSharedShowCorrectionRate(_ value: Double) {
    _ = mpv_set_property_string(handle, "speed", "\(value)")
  }
}

@main struct SharedShowMPVSmoke {
  @MainActor static func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    ShowFolderSnapshotStore.root = root
    let role = CommandLine.arguments[2]
    let a = root.appendingPathComponent("A.mkv")
    let b = root.appendingPathComponent("B.mkv")
    let store = try SharedShowStore(root: root)
    let descriptor = try store.enable()
    let player = PlayerCore()
    defer { player.session?.shutdown(); player.close() }
    let session = SharedShowSession(player: player)
    player.session = session
    SharedShowLAN.shared.startDiscovery()
    func flag(_ name: String) -> URL { root.appendingPathComponent("test-" + name) }
    func signal(_ name: String) { FileManager.default.createFile(atPath: flag(name).path, contents: Data()) }
    func wait(_ note: String, timeout: TimeInterval = 20, _ condition: () throws -> Bool) throws {
      let deadline = Date(timeIntervalSinceNow: timeout)
      while try !condition() && Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
      }
      let settled = try condition()
      if !settled {
        print("boundary timeout:", role, note, "media", player.info.currentURL?.lastPathComponent ?? "nil",
              "state", player.info.state, "path", session.relativePath ?? "nil",
              "watch", session.watchStatus ?? "nil", "rooms", SharedShowLAN.shared.rooms.count,
              "readiness", session.lanReadinessDiagnostic)
        fflush(stdout)
      }
      precondition(settled, note)
    }
    player.openURLsAsync([a])
    try wait("initial media") { player.info.state.loaded && session.showID == descriptor.showID }
    if role == "host" {
      try wait("automatic LAN host") { session.isHosting && session.hostingRoomID != nil }
      try session.hostingRoomID!.uuidString.write(to: flag("room-id"), atomically: true, encoding: .utf8)
      signal("host-ready")
      try wait("client joined") { FileManager.default.fileExists(atPath: flag("client-joined").path) }
      try wait("client playing before buffer") {
        FileManager.default.fileExists(atPath: flag("client-ready-for-buffer").path) &&
          session.lanReadyForSharedPlayback
      }
      signal("host-armed-for-buffer")
      let seeksBeforeBuffer = player.seekEvents
      try wait("host held for guest buffer") { player.info.state == .paused }
      signal("host-held-for-buffer")
      player.pause()
      signal("host-user-paused")
      try wait("guest buffer cleared") { FileManager.default.fileExists(atPath: flag("client-buffer-cleared").path) }
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.7))
      precondition(player.info.state == .paused, "User pause was overwritten by buffer recovery")
      player.resume()
      try wait("host scheduled restart") { player.info.state == .playing }
      signal("host-resumed-after-buffer")
      try wait("guest scheduled restart") { FileManager.default.fileExists(atPath: flag("client-resumed-after-buffer").path) }
      precondition(player.seekEvents == seeksBeforeBuffer, "Buffer recovery issued a corrective seek")
      player.pause(); player.seek(absoluteSecond: 4); player.setSpeed(1.5)
      try wait("client received host transport") { FileManager.default.fileExists(atPath: flag("client-saw-host").path) }
      try wait("client command reached host") {
        player.info.state == .playing && player.info.playSpeed > 1.24 && player.info.playSpeed < 1.26 &&
          (player.info.videoPosition?.second ?? 0) > 7.5
      }
      signal("host-saw-client")
      player.openURLsAsync([b])
      try wait("host advanced episode") { player.info.currentURL == b && session.relativePath == "B.mkv" }
      try wait("client advanced episode") { FileManager.default.fileExists(atPath: flag("client-saw-b").path) }
      try wait("client switched host episode") {
        player.info.currentURL?.lastPathComponent == "A.mkv" && session.relativePath == "A.mkv"
      }
      signal("host-saw-client-switch")
      try wait("guest stayed joined after switch") {
        FileManager.default.fileExists(atPath: flag("client-checked-switch").path)
      }
      session.localStopRequested()
      precondition(mpv_command_string(player.handle, "stop") >= 0)
      try wait("client disconnected") { FileManager.default.fileExists(atPath: flag("client-disconnected").path) }
      precondition(!session.isHosting, "Stopped host still advertises")
      session.saveFinal(media: player.info.currentURL, position: player.info.videoPosition?.second ?? 0,
                        duration: player.info.videoDuration?.second ?? 30)
      try wait("host final archive") {
        try store.progress(showID: descriptor.showID).first { $0.writerID == session.writerID }?.activity == .stopped
      }
      print("PASS host: cache-stall hold, user pause, scheduled resume, no corrective seek, commands, episode, disconnect")
    } else {
      let id = try String(contentsOf: flag("room-id"), encoding: .utf8)
      let roomID = UUID(uuidString: id)!
      try wait("Bonjour discovery") { SharedShowLAN.shared.rooms.contains { $0.id == roomID } }
      let room = SharedShowLAN.shared.rooms.first { $0.id == roomID }!
      precondition(SharedShowLAN.shared.join(room, player: player))
      try wait("joined") { session.lanFollowingRoomID == roomID }
      signal("client-joined")
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
      try wait("guest playing before buffer") {
        session.lanReadyForSharedPlayback
      }
      let seeksBeforeBuffer = player.seekEvents
      signal("client-ready-for-buffer")
      try wait("host armed for buffer") { FileManager.default.fileExists(atPath: flag("host-armed-for-buffer").path) }
      player.forcedCachePaused = true
      session.playbackObservation(position: player.info.videoPosition?.second,
        observedAt: ProcessInfo.processInfo.systemUptime,
        cachePaused: true, seeking: player.info.isSeeking)
      try wait("host paused for guest buffer") { FileManager.default.fileExists(atPath: flag("host-held-for-buffer").path) }
      precondition(player.info.state == .paused, "Guest continued through simulated buffer")
      try wait("host user pause") { FileManager.default.fileExists(atPath: flag("host-user-paused").path) }
      player.forcedCachePaused = false
      session.playbackObservation(position: player.info.videoPosition?.second,
        observedAt: ProcessInfo.processInfo.systemUptime,
        cachePaused: false, seeking: player.info.isSeeking)
      signal("client-buffer-cleared")
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.7))
      precondition(player.info.state == .paused, "Guest auto-resumed over host user pause")
      try wait("host resumed after buffer") { FileManager.default.fileExists(atPath: flag("host-resumed-after-buffer").path) }
      try wait("guest resumed with host") { player.info.state == .playing }
      signal("client-resumed-after-buffer")
      precondition(player.seekEvents == seeksBeforeBuffer, "Guest buffer recovery issued corrective seek")
      try wait("host pause/seek/rate") {
        player.info.state == .paused && player.info.playSpeed > 1.49 &&
          (player.info.videoPosition?.second ?? 0) > 3.5
      }
      signal("client-saw-host")
      player.resume(); player.seek(absoluteSecond: 8); player.setSpeed(1.25)
      try wait("host accepted client command") { FileManager.default.fileExists(atPath: flag("host-saw-client").path) }
      precondition(session.lanFollowingRoomID == roomID, "Client detached after local transport")
      try wait("host episode switch") {
        player.info.currentURL?.lastPathComponent == "B.mkv" && player.info.state.loaded
      }
      signal("client-saw-b")
      player.openURLsAsync([a])
      try wait("guest initiated episode switch") {
        FileManager.default.fileExists(atPath: flag("host-saw-client-switch").path)
      }
      precondition(session.lanFollowingRoomID == roomID, "Guest episode switch detached room")
      signal("client-checked-switch")
      try wait("host gone") { session.lanFollowingRoomID == nil }
      let finalPosition = player.info.videoPosition?.second ?? 0
      session.saveFinal(media: player.info.currentURL, position: finalPosition,
                        duration: player.info.videoDuration?.second)
      try wait("client final archive") {
        guard let progress = try store.progress(showID: descriptor.showID).first(where: { $0.writerID == session.writerID }) else { return false }
        return progress.activity == .stopped && abs(progress.position - finalPosition) < 0.5
      }
      signal("client-disconnected")
      print("PASS client: simulated cache stall, shared pause/resume, no corrective seek, commands, episode, host gone")
    }
  }
}
