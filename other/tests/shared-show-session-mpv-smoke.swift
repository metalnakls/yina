import AppKit

enum AppEnvironment {
  final class MemoryDefaults {
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String, forKey key: String) { values[key] = value }
  }
  static let defaults = MemoryDefaults()
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
    var playlist: [PlaylistItem] = []
  }
  let info = Info()
  let handle: OpaquePointer
  var session: SharedShowSession?
  private var pendingURL: URL?
  private var timer: Timer?
  private var canceledURL: URL?

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
        let replacing = info.state == .loading || info.state == .starting
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
      info.state = paused != 0 ? .paused : .playing
    }
  }

  func openURLsAsync(_ urls: [URL], shouldAutoLoad: Bool = true, completion: ((Int?) -> Void)? = nil) {
    guard let url = urls.first, canceledURL != url else { completion?(0); return }
    session?.localMediaChangeRequested()
    pendingURL = url
    info.state = .loading
    let command = "loadfile \"\(url.path)\" replace"
    precondition(mpv_command_string(handle, command) >= 0)
    completion?(1)
  }
  func cancelSharedShowMediaPreparation(for expectedURL: URL) {
    if pendingURL == expectedURL { canceledURL = expectedURL }
  }
  func syncPositionIfNeeded() {}
  func seek(absoluteSecond: Double) {
    session?.localControlChanged()
    _ = mpv_command_string(handle, "seek \(absoluteSecond) absolute exact")
  }
  func pause() {
    session?.localControlChanged()
    _ = mpv_set_property_string(handle, "pause", "yes")
  }
  func resume() {
    session?.localControlChanged()
    _ = mpv_set_property_string(handle, "pause", "no")
  }
  func setSpeed(_ value: Double) {
    session?.localControlChanged()
    _ = mpv_set_property_string(handle, "speed", "\(value)")
  }
}

@main struct SharedShowMPVSmoke {
  @MainActor static func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let a = root.appendingPathComponent("A.mkv")
    let b = root.appendingPathComponent("B.mkv")
    let store = try SharedShowStore(root: root)
    let descriptor = try store.enable()
    let host = PlayerCore(), follower = PlayerCore()
    defer { host.close(); follower.close() }
    let hosting = SharedShowSession(player: host)
    let following = SharedShowSession(player: follower)
    host.session = hosting; follower.session = following
    host.info.playlist = [.init(a.path), .init(b.path)]
    host.openURLsAsync([a]); follower.openURLsAsync([a])
    func wait(_ note: String, _ condition: () throws -> Bool) throws {
      let deadline = Date(timeIntervalSinceNow: 12)
      while try !condition() && Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
      }
      let settled = try condition()
      if !settled {
        print("boundary timeout:", note, "host", host.info.currentURL?.lastPathComponent ?? "nil",
              hosting.watchStatus ?? "nil", "follower", follower.info.currentURL?.lastPathComponent ?? "nil",
              following.watchStatus ?? "nil", "path", following.relativePath ?? "nil",
              "queue", following.hostQueueCurrent ?? "nil", "writer", following.followingWriter?.uuidString ?? "nil")
        fflush(stdout)
      }
      precondition(settled, note)
    }
    try wait("Both generated files did not load") { host.info.state.loaded && follower.info.state.loaded }
    try wait("Shared show not discovered") { hosting.showID == descriptor.showID && following.showID == descriptor.showID }
    hosting.hostWatchTogether()
    try wait("Host queue did not publish") {
      try store.queue(showID: descriptor.showID, participantID: SharedShowSession.participantID,
                      writerID: hosting.writerID)?.current == "A.mkv"
    }
    let record = try store.progress(showID: descriptor.showID).first { $0.writerID == hosting.writerID }!
    following.follow(record)
    host.pause(); host.seek(absoluteSecond: 4); host.setSpeed(1.5); hosting.checkpoint()
    try wait("Pause/seek/rate did not reach real follower mpv") {
      following.checkpoint()
      return follower.info.state == .paused && follower.info.playSpeed > 1.49 &&
        (follower.info.videoPosition?.second ?? 0) > 3.5
    }
    host.openURLsAsync([b]); hosting.checkpoint()
    try wait("Host did not switch to next real file") { host.info.currentURL == b && hosting.relativePath == "B.mkv" }
    try wait("Follower did not load host's next real file") {
      following.checkpoint()
      return follower.info.currentURL?.lastPathComponent == "B.mkv" && follower.info.state.loaded
    }
    follower.pause()
    precondition(following.followingWriter == nil, "Local real mpv control did not take over")
    try wait("Host did not publish next episode before rejoin") {
      try store.progress(showID: descriptor.showID).first { $0.writerID == hosting.writerID }?.relativePath == "B.mkv"
    }
    let nextRecord = try store.progress(showID: descriptor.showID).first { $0.writerID == hosting.writerID }!
    following.follow(nextRecord)
    try wait("Could not rejoin host on the next episode") { following.followingWriter == hosting.writerID }
    precondition(mpv_command_string(host.handle, "stop") >= 0)
    try wait("Explicit host stop did not end real follower session") {
      following.checkpoint()
      return following.followingWriter == nil
    }
    print("PASS: two real libmpv cores follow generated pause/seek/rate and next episode; local takeover and host stop")
  }
}
