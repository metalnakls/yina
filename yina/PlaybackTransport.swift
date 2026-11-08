/// PlayerCore reduces inputs on main and executes at most one engine request at
/// a time. The engine adapter returns owned observations and command replies.
struct PlaybackTransport {
  struct Media: Equatable {
    let serial: UInt64
    let playlistEntry: Int64
  }

  enum Command: Equatable {
    case pause(Bool)
    case load(String)
    case playlist([String])
    case seek([String], replay: Bool)
    case frameStep(backwards: Bool)
    case stop
  }

  struct Request: Equatable {
    let id: UInt64
    let generation: UInt64
    let command: Command
    fileprivate let gate: Bool
    fileprivate let media: Media?
    fileprivate let restart: UInt64
  }

  enum Completion {
    case accepted, obsolete, loadFailed, seekFailed, pauseFailed, playlistFailed
  }

  enum Hold: Hashable {
    case slider, scroll
  }

  private enum Phase { case idle, loading, starting, loaded, ready, remoteWait, stopping, shuttingDown, shutDown }
  private var phase = Phase.idle
  private var latestStartSerial: UInt64 = 0
  private(set) var media: Media?
  private(set) var generation: UInt64 = 0
  private var pendingOpen: String?
  private(set) var requestedPause: Bool?
  private(set) var observedPause: Bool?
  private(set) var eof = false
  private var holds = Set<Hold>()
  private var loadIssued = false
  private var explicitLoadingPause: Bool?
  private var playlistAwaitingStart = false
  private var playlistPriorPause: Bool?
  private var retrying = false
  private var failedPauseTarget: Bool?
  private var stopNeedsPause = true
  private var seekObserved = false
  private var awaitingRestart = false
  private var restartSerial: UInt64 = 0
  private var nextID: UInt64 = 0
  private var queue: [Command] = []
  private var inFlight: Request?

  var state: PlayerState {
    switch phase {
    case .idle: return .idle
    case .loading: return .loading
    case .starting: return .starting
    case .loaded: return .loaded
    case .ready: return (observedPause ?? requestedPause ?? false) ? .paused : .playing
    case .remoteWait: return .paused
    case .stopping: return .stopping
    case .shuttingDown: return .shuttingDown
    case .shutDown: return .shutDown
    }
  }

  var effectivePaused: Bool { requestedPause ?? (observedPause ?? false) }
  var isSeeking: Bool {
    seekObserved || awaitingRestart ||
      (inFlight?.generation == generation && inFlight?.command.isSeek == true) ||
      queue.contains(where: \.isSeek)
  }

  var isOpening: Bool { phase == .loading || phase == .starting || phase == .loaded }
  var isReady: Bool { phase == .ready }

  @discardableResult
  mutating func beginOpen(path: String, pauseWhenOpen: Bool) -> Bool {
    guard phase != .stopping, phase != .shuttingDown, phase != .shutDown else { return false }
    invalidateMedia()
    phase = .loading
    pendingOpen = path
    requestedPause = pauseWhenOpen
    return true
  }

  mutating func submitOpen() {
    guard let path = pendingOpen else { return }
    pendingOpen = nil
    queue.append(.load(path))
  }

  @discardableResult
  mutating func fileStarted(_ identity: Media, pauseWhenOpen: Bool) -> Bool {
    guard state.active || phase == .idle, phase != .remoteWait,
          phase != .loading || loadIssued, identity.serial > latestStartSerial else { return false }
    latestStartSerial = identity.serial
    let appOpened = phase == .loading
    let manual = playlistAwaitingStart ||
      (inFlight?.generation == generation && inFlight?.command.isPlaylist == true)
    let wasReady = phase == .ready
    if !appOpened { generation &+= 1 }
    media = identity
    phase = .starting
    loadIssued = false
    playlistAwaitingStart = false
    playlistPriorPause = nil
    eof = false
    holds.removeAll()
    resetSeek()
    queue.removeAll(where: \.targetsCurrentMedia)
    if manual {
      requestedPause = explicitLoadingPause ?? pauseWhenOpen
    } else if !appOpened {
      // Preserve a deliberate pause on a file already starting, but do not
      // insert a pause between naturally advancing gapless entries.
      if wasReady { explicitLoadingPause = nil }
      requestedPause = explicitLoadingPause ?? (pauseWhenOpen ? true : nil)
    }
    return true
  }

  @discardableResult
  mutating func fileLoaded(_ identity: Media) -> Bool {
    guard media == identity, phase == .starting else { return false }
    phase = .loaded
    return true
  }

  @discardableResult
  mutating func outputReady() -> Bool {
    guard phase == .loaded else { return false }
    phase = .ready
    explicitLoadingPause = nil
    return true
  }

  mutating func setPaused(_ paused: Bool) {
    guard state.active, phase != .remoteWait else { return }
    if isOpening || playlistPriorPause != nil { explicitLoadingPause = paused }
    failedPauseTarget = nil
    requestedPause = paused
    if paused { queue.removeAll(where: \.isReplay) }
    if !paused && eof && isReady &&
        inFlight?.command.isReplay != true && !queue.contains(where: \.isReplay) {
      queue.append(.seek(["seek", "0", "absolute+exact"], replay: true))
    }
  }

  mutating func observePause(_ paused: Bool, media identity: Media?) {
    // Pause is engine-global. An observation from the previously accepted
    // item must not settle a newer file once its START_FILE has arrived.
    guard media == nil || media == identity else { return }
    observedPause = paused
    if failedPauseTarget == paused { failedPauseTarget = nil }
    if isReady, !playlistAwaitingStart, playlistPriorPause == nil, holds.isEmpty,
       inFlight?.command.isPause != true, requestedPause == paused {
      requestedPause = nil
    }
  }

  mutating func setHold(_ reason: Hold, active: Bool) {
    guard isReady else { return }
    failedPauseTarget = nil
    if active {
      if holds.isEmpty && requestedPause == nil { requestedPause = effectivePaused }
      holds.insert(reason)
    } else {
      holds.remove(reason)
    }
  }

  mutating func step(_ arguments: [String]) {
    guard state.active, phase != .remoteWait else { return }
    failedPauseTarget = nil
    if playlistPriorPause == nil { playlistPriorPause = effectivePaused }
    queue.append(.playlist(arguments))
  }

  mutating func seek(_ arguments: [String]) {
    guard state.loaded, phase != .remoteWait else { return }
    queue.append(.seek(arguments, replay: false))
  }

  mutating func frameStep(backwards: Bool) {
    guard state.loaded, phase != .remoteWait else { return }
    queue.append(.frameStep(backwards: backwards))
  }

  @discardableResult
  mutating func observeSeek(_ identity: Media?) -> Bool {
    guard state.loaded, media == identity, media != nil else { return false }
    seekObserved = true
    return true
  }

  @discardableResult
  mutating func observeRestart(_ identity: Media?) -> Bool {
    guard state.loaded, media == identity, media != nil else { return false }
    restartSerial &+= 1
    resetSeek()
    return true
  }

  mutating func observeEOF(_ eof: Bool) {
    guard state.active else { return }
    self.eof = eof
  }

  mutating func waitForRemoteMedia() {
    invalidateMedia(keepIdentity: true)
    phase = .remoteWait
    requestedPause = true
  }

  mutating func retryRemoteMedia() {
    invalidateMedia()
    phase = .loading
    loadIssued = true
    retrying = true
    requestedPause = true
  }

  mutating func recoveredRemoteMedia() {
    retrying = false
    requestedPause = true
    failedPauseTarget = nil
  }

  mutating func cancelRemoteMedia() {
    retrying = false
    if phase == .remoteWait {
      phase = .ready
      requestedPause = true
    }
  }

  mutating func beginStop() {
    guard state.active else { return }
    invalidateMedia()
    phase = .stopping
    stopNeedsPause = true
  }

  mutating func submitStop() {
    guard phase == .stopping, inFlight?.command != .stop, !queue.contains(.stop) else { return }
    queue.append(.stop)
  }

  @discardableResult
  mutating func becameIdle() -> Bool {
    guard phase != .idle, phase != .loading, phase != .remoteWait,
          phase != .shuttingDown, phase != .shutDown else { return false }
    invalidateMedia()
    phase = .idle
    return true
  }

  mutating func shutDown(complete: Bool) {
    invalidateMedia()
    phase = complete ? .shutDown : .shuttingDown
  }

  /// A successful pause reply is the barrier before a load/playlist command.
  /// A media action already submitted remains in flight through replacement so
  /// a newer action cannot overtake it on libmpv's asynchronous command queue.
  mutating func nextRequest() -> Request? {
    // A queued seek still belongs to the old entry until START_FILE.
    guard inFlight == nil, !playlistAwaitingStart else { return nil }
    if let command = queue.first {
      if command.requiresPause && (command != .stop || stopNeedsPause), observedPause != true {
        return start(.pause(true), gate: true)
      }
      queue.removeFirst()
      if case .load = command { loadIssued = true }
      return start(command)
    }
    let target: Bool?
    if !holds.isEmpty || retrying || phase == .remoteWait { target = true }
    else if isReady { target = requestedPause }
    else { target = nil }
    guard let target, target != failedPauseTarget else { return nil }
    if observedPause == target {
      if holds.isEmpty && !retrying && isReady { requestedPause = nil }
      return nil
    }
    return start(.pause(target))
  }

  mutating func complete(_ request: Request, success: Bool) -> Completion {
    guard inFlight == request else { return .obsolete }
    inFlight = nil
    guard request.generation == generation else { return .obsolete }
    switch request.command {
    case .pause(let paused):
      if success {
        // The property may already have had this value, in which case libmpv
        // sends no change event. The successful set is also an observation.
        observedPause = paused
        return .accepted
      }
      if request.gate, let blocked = queue.first {
        queue.removeFirst()
        if case .load = blocked { return failOpen() }
        if blocked.isPlaylist { return failPlaylist() }
        if blocked == .stop {
          queue.insert(.stop, at: 0)
          stopNeedsPause = false
        }
      } else {
        failedPauseTarget = paused
        if requestedPause == paused { requestedPause = nil }
      }
      return .pauseFailed
    case .load:
      return success || request.media != media ? .accepted : failOpen()
    case .playlist:
      if request.media != media { return .accepted }
      if !success { return failPlaylist() }
      playlistAwaitingStart = true
      return .accepted
    case .seek(_, let replay):
      guard request.media == media else { return .obsolete }
      if success {
        awaitingRestart = request.restart == restartSerial
        if replay { eof = false }
        return .accepted
      }
      if replay && requestedPause == false { requestedPause = nil }
      return .seekFailed
    case .frameStep, .stop:
      return .accepted
    }
  }

  private mutating func start(_ command: Command, gate: Bool = false) -> Request {
    nextID &+= 1
    let request = Request(id: nextID, generation: generation, command: command,
                          gate: gate, media: media, restart: restartSerial)
    inFlight = request
    return request
  }

  private mutating func failOpen() -> Completion {
    invalidateMedia()
    phase = .idle
    return .loadFailed
  }

  private mutating func failPlaylist() -> Completion {
    if !playlistAwaitingStart && !queue.contains(where: \.isPlaylist) {
      requestedPause = explicitLoadingPause ?? playlistPriorPause
      explicitLoadingPause = nil
      playlistPriorPause = nil
    }
    return .playlistFailed
  }

  private mutating func invalidateMedia(keepIdentity: Bool = false) {
    generation &+= 1
    if !keepIdentity { media = nil }
    queue.removeAll()
    pendingOpen = nil
    requestedPause = nil
    explicitLoadingPause = nil
    loadIssued = false
    playlistAwaitingStart = false
    playlistPriorPause = nil
    retrying = false
    failedPauseTarget = nil
    holds.removeAll()
    eof = false
    resetSeek()
  }

  private mutating func resetSeek() {
    seekObserved = false
    awaitingRestart = false
  }
}

private extension PlaybackTransport.Command {
  var isPause: Bool {
    if case .pause = self { return true }
    return false
  }

  var isSeek: Bool {
    if case .seek = self { return true }
    return false
  }

  var targetsCurrentMedia: Bool {
    if case .frameStep = self { return true }
    return isSeek
  }

  var isReplay: Bool {
    if case .seek(_, true) = self { return true }
    return false
  }

  var isPlaylist: Bool {
    if case .playlist = self { return true }
    return false
  }
  var requiresPause: Bool {
    switch self {
    case .load, .playlist, .stop: return true
    default: return false
    }
  }
}
