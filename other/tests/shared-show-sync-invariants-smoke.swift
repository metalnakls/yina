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
  static var root = URL(fileURLWithPath: "/tmp")
  static func loadCards() -> [ShowFolder] { [ShowFolder(folderURL: root)] }
}
enum Utility {
  static func quickOpenPanel(title: String, chooseDir: Bool, dir: URL? = nil,
                             sheetWindow: NSWindow? = nil, callback: @escaping (URL) -> Void) {
    fatalError("No UI in the sync fixture")
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
  var session: SharedShowSession?
  var sharedShow: SharedShowSession { session! }
  var seeks: [Double] = []
  var pauses = 0
  var resumes = 0
  var speedWrites: [Double] = []
  var pendingCorrection: Double?
  var readinessRefreshes = 0

  func openURLsAsync(_ urls: [URL], shouldAutoLoad: Bool = true, completion: ((Int?) -> Void)? = nil) {
    guard let url = urls.first else { completion?(0); return }
    session?.localMediaChangeRequested()
    info.currentURL = url
    info.state = .paused
    info.videoPosition = Time(0)
    info.videoDuration = Time(60)
    session?.start()
    completion?(1)
  }
  func cancelSharedShowMediaPreparation(for expectedURL: URL) {}
  func cancelSharedShowCommandOpen(for expectedURL: URL) {}
  func syncPositionIfNeeded() {}
  func refreshSharedShowReadiness(generation: UInt64) {
    readinessRefreshes += 1
    session?.playbackObservation(position: info.videoPosition?.second,
                                 observedAt: ProcessInfo.processInfo.systemUptime,
                                 cachePaused: info.pausedForCache, seeking: info.isSeeking,
                                 barrierGeneration: generation,
                                 enginePaused: info.state == .paused)
  }
  func seek(absoluteSecond: Double) {
    session?.localControlChanged(.seek(absoluteSecond))
    seeks.append(absoluteSecond)
    info.isSeeking = true
  }
  func pause() {
    session?.localControlChanged(.pause(true))
    pauses += 1
    info.state = .paused
    session?.playbackPauseObserved(true)
  }
  func resume() {
    session?.localControlChanged(.pause(false))
    if session?.shouldDeferLocalResume == true { return }
    resumes += 1
    info.state = .playing
    session?.playbackPauseObserved(false)
  }
  func setSpeed(_ value: Double) {
    session?.localControlChanged(.rate(value))
    speedWrites.append(value)
    pendingCorrection = nil
    info.playSpeed = value
  }
  func setSharedShowCorrectionRate(_ value: Double) {
    speedWrites.append(value)
    pendingCorrection = value
  }
}

@main struct SharedShowSyncInvariantsSmoke {
  @MainActor static func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    ShowFolderSnapshotStore.root = root
    let media = root.appendingPathComponent("A.mkv")
    let store = try SharedShowStore(root: root)
    let descriptor = try store.enable()
    let player = PlayerCore()
    let archiveQueue = OperationQueue()
    archiveQueue.maxConcurrentOperationCount = 1
    let archiveScheduler = SharedShowSession.RequestWorkScheduler(
      reserve: { _ in (archiveQueue, "fixture") }, release: { _ in })
    let session = SharedShowSession(player: player, sharingWorkScheduler: archiveScheduler)
    player.session = session
    defer { session.shutdown() }

    func until(_ label: String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
      let deadline = Date(timeIntervalSinceNow: timeout)
      while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
      }
      precondition(condition(), label)
    }
    player.openURLsAsync([media])
    until("media membership") { session.showID == descriptor.showID && session.relativePath == "A.mkv" }
    player.info.state = .playing
    session.hostWatchTogether()
    precondition(session.isHosting)

    // A stale restart from an earlier seek cannot satisfy a newer seek barrier.
    player.info.videoPosition?.second = 2
    session.localControlChanged(.seek(12))
    session.playbackRestartObserved()
    session.playbackObservation(position: 2, observedAt: ProcessInfo.processInfo.systemUptime,
                                cachePaused: false, seeking: false,
                                barrierGeneration: 1, enginePaused: true)
    let resumesBeforeTarget = player.resumes
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.65))
    precondition(player.resumes == resumesBeforeTarget, "stale frame marked latest seek ready")
    player.info.videoPosition?.second = 12
    session.playbackObservation(position: 12, observedAt: ProcessInfo.processInfo.systemUptime,
                                cachePaused: false, seeking: false,
                                barrierGeneration: 1, enginePaused: true)
    until("host resumed after target observed", timeout: 2) { player.resumes > resumesBeforeTarget }

    // A delayed readiness query from the first barrier cannot release the next.
    session.localControlChanged(.seek(14))
    session.playbackRestartObserved()
    let resumesBeforeOldGeneration = player.resumes
    session.playbackObservation(position: 14, observedAt: ProcessInfo.processInfo.systemUptime,
                                cachePaused: false, seeking: false, barrierGeneration: 1,
                                enginePaused: true)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.65))
    precondition(player.resumes == resumesBeforeOldGeneration,
                 "old-generation readiness released new barrier")
    player.info.videoPosition?.second = 14
    session.playbackObservation(position: 14, observedAt: ProcessInfo.processInfo.systemUptime,
                                cachePaused: false, seeking: false, barrierGeneration: 2,
                                enginePaused: true)
    until("new generation resumed", timeout: 2) { player.resumes > resumesBeforeOldGeneration }

    // A later explicit pause must cancel an already scheduled group resume.
    session.localControlChanged(.pause(false))
    let resumesBeforePause = player.resumes
    let archiveStarted = DispatchSemaphore(value: 0)
    let releaseArchive = DispatchSemaphore(value: 0)
    archiveQueue.addOperation {
      archiveStarted.signal()
      _ = releaseArchive.wait(timeout: .now() + 3)
    }
    precondition(archiveStarted.wait(timeout: .now() + 1) == .success,
                 "archive stall fixture did not start")
    let controlStarted = ProcessInfo.processInfo.systemUptime
    session.localControlChanged(.pause(true))
    precondition(ProcessInfo.processInfo.systemUptime - controlStarted < 0.15,
                 "live pause waited for archive I/O")
    releaseArchive.signal()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.65))
    precondition(player.resumes == resumesBeforePause, "explicit pause lost to scheduled resume")
    session.leaveWatchTogether()

    // Ordinary local transport outside a room must not enter a group barrier.
    player.info.state = .playing
    let unsharedPauseCount = player.pauses
    session.localControlChanged(.seek(7))
    precondition(!session.shouldDeferLocalResume && player.pauses == unsharedPauseCount,
                 "unshared seek entered room barrier")
    session.localControlChanged(.pause(false))
    precondition(!session.shouldDeferLocalResume, "unshared resume entered room barrier")

    // The same path and seek generation must never trigger a corrective seek.
    let room = SharedShowLAN.Room(id: UUID(), showID: descriptor.showID, hostName: "host",
                                  title: "A", relativePath: "A.mkv", position: 12,
                                  duration: 60, paused: true, rate: 1)
    player.info.state = .playing
    session.beginLANFollow(room)
    precondition(player.info.state == .paused,
                 "joining room left unrelated local playback running")
    func state(revision: UInt64, position: Double, seekGeneration: UInt64 = 1) -> SharedShowLAN.State {
      SharedShowLAN.State(roomID: room.id, showID: room.showID, hostName: room.hostName,
        title: "A", relativePath: "A.mkv", position: position, duration: 60,
        paused: true, rate: 1, revision: revision, emittedAt: Date(),
        awaitingNextEpisode: false, epoch: room.id, seekGeneration: seekGeneration,
        waitingForReady: true, userPaused: true)
    }
    session.applyLANState(state(revision: 1, position: 12))
    let firstSeekCount = player.seeks.count
    precondition(firstSeekCount > 0, "initial alignment seek missing")
    for revision in 2...8 {
      session.applyLANState(state(revision: UInt64(revision), position: 12 + Double(revision) * 0.03))
    }
    precondition(player.seeks.count == firstSeekCount, "heartbeat caused corrective seek")

    // A queued trim must be superseded even if mpv has not reported it yet.
    player.info.playSpeed = 1
    player.setSharedShowCorrectionRate(1.005)
    let writesBeforeLeave = player.speedWrites.count
    session.leaveWatchTogether()
    precondition(player.speedWrites.count > writesBeforeLeave &&
                 abs(player.speedWrites.last! - 1) < 0.0001 &&
                 player.pendingCorrection == nil,
                 "pending room speed trim leaked after leave")
    print("PASS sync invariants: stale seek and generation, pause cancellation, archive stall, unshared transport, join hold, stable seek generation, rate restoration")
  }
}
