import AppKit

extension Notification.Name {
  static let yinaSharedShowChanged = Notification.Name("yinaSharedShowChanged")
}

/// One player owns one writer file. Bounded lanes keep a stalled share from
/// blocking every other session while each session retains its write order.
@MainActor
final class SharedShowSession {
  enum ControlIntent {
    case pause(Bool)
    case seek(Double)
    case rate(Double)
    case other
  }
  struct RequestWorkScheduler {
    let reserve: (URL) -> (OperationQueue, String)
    let release: (String) -> Void
  }
  private static let operations: [OperationQueue] = (0..<4).map { index in
    let queue = OperationQueue()
    queue.name = "YINASharedShows.\(index)"
    queue.qualityOfService = .utility
    queue.maxConcurrentOperationCount = 1
    return queue
  }
  private static var laneByRoot: [String: (index: Int, count: Int)] = [:]
  private static var laneLoads = [0, 0, 0, 0]
  private let requestWorkScheduler: RequestWorkScheduler
  private let sharingWorkScheduler: RequestWorkScheduler
  private static func reserveLane(for url: URL) -> (OperationQueue, String) {
    // A root with work in flight retains its serial lane. A new root chooses
    // the least occupied lane, so one stalled root leaves other lanes usable.
    let key = url.standardizedFileURL.path
    if var assignment = laneByRoot[key] {
      assignment.count += 1
      laneByRoot[key] = assignment
      laneLoads[assignment.index] += 1
      return (operations[assignment.index], key)
    }
    let index = laneLoads.indices.min { laneLoads[$0] < laneLoads[$1] }!
    laneByRoot[key] = (index, 1)
    laneLoads[index] += 1
    return (operations[index], key)
  }
  private static func releaseLane(_ key: String) {
    guard var assignment = laneByRoot[key] else { return }
    laneLoads[assignment.index] -= 1
    assignment.count -= 1
    if assignment.count == 0 { laneByRoot.removeValue(forKey: key) }
    else { laneByRoot[key] = assignment }
  }
  static let participantID: UUID = {
    let key = "sharedShowParticipantID"
    if let value = AppEnvironment.defaults.string(forKey: key), let id = UUID(uuidString: value) { return id }
    let id = UUID()
    AppEnvironment.defaults.set(id.uuidString, forKey: key)
    return id
  }()

  let writerID = UUID()
  private weak var player: PlayerCore?
  private var timer: Timer?
  private var lanLiveTimer: Timer?
  private var generation = 0
  private var enableToken: UInt64 = 0
  private var membershipEpoch: UInt64 = 0
  var generationToken: Int { generation }
  private var revision: UInt64 = 0
  private var busy = false
  private var pendingFinal: Sample?
  private var finalCallbacks: [() -> Void] = []
  private var finalizingGeneration: Int?
  private var pendingCurrent: Sample?
  private var lastSample: Sample?
  private var lastPublished: Sample?
  private var lastBroadRefresh = Date.distantPast
  private struct Membership: Sendable {
    let root: URL?
    let showID: UUID?
    let path: String?
    let expiresAt: Date
  }
  private var membership: Membership?
  private var requestBusy = false
  private var requestPollBusy = false
  private var requestPollTimer: Timer?
  private var requestToken: UInt64 = 0
  private var requestState: SharedShowDownloadRequest?
  private var requestEpisode: ShowEpisodeIndexReader.Episode?
  private var requestRoot: URL?
  private var applyingRemote = false
  private var remoteMediaIntents: Set<URL> = []
  private var endedByStopCommand = false
  private var lastControlCheckpoint: TimeInterval = 0
  private var lanUserPaused = false
  private var lanBarrierGeneration: UInt64 = 0
  private var lanSeekGeneration: UInt64 = 0
  private var lanWaitingForReady = false
  private var lanPlayAtHostTime: Double?
  private var lanLocalReady = false
  private var lanPeerReady: [UUID: Bool] = [:]
  private var lanRestartPending = false
  private var lanLastAppliedSeekGeneration: UInt64?
  private var lanLastAppliedPath: String?
  private var lanScheduledResume: DispatchWorkItem?
  private var lanBaseRate = 1.0
  private var lanAppliedBaseRate: Double?
  private var lanLastTrimTime: Double = 0
  private var lanObservedPosition: Double?
  private var lanObservedAt: Double?
  private var lanExpectedSeekPosition: Double?
  private var lanSeekRequestedAt = 0.0
  private var lanFilteredPhaseError: Double?
  private var lanObservedPaused = false
  private var lanRequiresObservedPause = false
  private var lanFreshReadinessGeneration: UInt64?
  private var lanNeedsCalibratedJoinSeek = false
  private var lanPendingLocalPause: Bool?
  private var lanPendingLocalSeekGeneration: UInt64?
  var lanReadinessDiagnostic: String {
    "barrier=\(lanBarrierGeneration) waiting=\(lanWaitingForReady) local=\(lanLocalReady) " +
    "peers=\(lanPeerReady) restart=\(lanRestartPending) target=\(String(describing: lanExpectedSeekPosition)) " +
    "paused=\(lanObservedPaused) fresh=\(String(describing: lanFreshReadinessGeneration)) " +
    "cache=\(player?.info.pausedForCache ?? false) seeking=\(player?.info.isSeeking ?? false) " +
    "clock=\(SharedShowLAN.shared.clockCalibrated)"
  }
  var lanReadyForSharedPlayback: Bool {
    !lanWaitingForReady && lanLocalReady && player?.info.state == .playing &&
      (isHosting || (lanFollowingRoomID != nil && SharedShowLAN.shared.clockCalibrated))
  }
  private var lanCommandRestore: (userPaused: Bool, baseRate: Double, seekGeneration: UInt64)?
  private var lanCommandTarget: URL?
  private(set) var lanFollowingRoomID: UUID?
  private var lanRoomID: UUID?
  var hostingRoomID: UUID? { isHosting ? lanRoomID : nil }
  private var lanRevision: UInt64 = 0
  private var lanState: SharedShowLAN.State?
  private var lanResolveToken: UInt64 = 0
  private var pendingLANPath: String?
  private var wantsLANEpisodeSwitch = false
  private var lanSwitchSent = false
  private var lanFolderPromptShown = false
  private var lanRootHint = ""
  private var lanCommandOverride: SharedShowLAN.State?
  private var hostingSuppressed = false
  private var pendingAutoHost = false
  private static let localHostName = String(ProcessInfo.processInfo.hostName.prefix(60))
  private(set) var isHosting = false
  private(set) var followingWriter: UUID?
  private var followingParticipant: UUID?
  private var followingShowID: UUID?
  private var acceptedHostRevision: UInt64 = 0
  private var acceptedQueueRevision: UInt64 = 0
  private(set) var hostQueueItems: [String] = []
  private(set) var hostQueueCurrent: String?
  private var pendingRemoteTarget: URL?
  private var pendingRemoteSince: TimeInterval?
  private var remoteOpenGeneration: UInt64 = 0
  private var remoteOpenFailures = 0
  private var remoteOpenFailedPath: String?
  private var unavailableAttempts = 0
  private(set) var watchStatus: String?
  private(set) var root: URL?
  private(set) var showID: UUID?
  private(set) var relativePath: String?
  private var contextMedia: URL?
  private(set) var positions: [SharedShowStore.Progress] = []
  private(set) var status: String?
  private(set) var requestStatus: String?

  private struct Sample: Sendable {
    let generation: Int
    let media: URL
    let position: Double
    let duration: Double
    let activity: SharedShowStore.Progress.Activity
    let date: Date
    var rate = 1.0
    var hosting = false
    var shouldWrite = true
    var refreshPeers = true
    var playlistPaths: [String] = []
    var awaitingNextEpisode = false
  }

  init(player: PlayerCore, requestWorkScheduler: RequestWorkScheduler? = nil,
       sharingWorkScheduler: RequestWorkScheduler? = nil) {
    self.player = player
    self.requestWorkScheduler = requestWorkScheduler ?? .init(reserve: Self.reserveLane,
                                                               release: Self.releaseLane)
    self.sharingWorkScheduler = sharingWorkScheduler ?? .init(reserve: Self.reserveLane,
                                                               release: Self.releaseLane)
  }

  deinit {
    timer?.invalidate()
    lanLiveTimer?.invalidate()
    requestPollTimer?.invalidate()
  }

  func start() {
    timer?.invalidate()
    let media = player?.info.currentURL
    if isHosting && (lanWaitingForReady || lanUserPaused), let player, player.info.state.active {
      applyingRemote = true; player.pause(); applyingRemote = false
    }
    if media == lanCommandTarget {
      lanCommandTarget = nil
      lanCommandRestore = nil
    }
    let remoteChange = lanFollowingRoomID != nil ||
      (followingWriter != nil && media.map { remoteMediaIntents.contains($0) } == true)
    if let media, remoteChange {
      if media == pendingRemoteTarget {
        // The latest requested episode has loaded. Older in-flight targets
        // can no longer justify preserving follow on a future local open.
        remoteMediaIntents.removeAll()
        pendingRemoteTarget = nil
        pendingRemoteSince = nil
        remoteOpenFailures = 0
        remoteOpenFailedPath = nil
      } else { remoteMediaIntents.remove(media) }
    }
    generation += 1
    finalizingGeneration = nil
    if !remoteChange {
      pendingAutoHost = true
      hostingSuppressed = false
    }
    root = nil
    showID = nil
    relativePath = nil
    contextMedia = nil
    positions = []
    status = nil
    lastSample = nil
    lastPublished = nil
    lastBroadRefresh = .distantPast
    membership = nil
    pendingCurrent = nil
    if !remoteChange {
      followingWriter = nil
      followingParticipant = nil
      followingShowID = nil
      remoteMediaIntents.removeAll()
      hostQueueItems = []
      hostQueueCurrent = nil
    }
    endedByStopCommand = false
    watchStatus = isHosting ? "Hosting Watch Together · \(writerID.uuidString.prefix(6))" :
      lanFollowingRoomID != nil ? "Watching with host" :
      followingWriter.map { "Following host \($0.uuidString.prefix(6))" }
    checkpoint()
    scheduleTimer()
  }

  private func scheduleTimer() {
    timer?.invalidate()
    let interval: TimeInterval = isHosting ? 10 : followingWriter != nil ?
      (unavailableAttempts >= 3 ? 10 : 2) : membership?.root == nil && membership != nil ? 30 : 10
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkpoint(refreshPeers: false) }
    }
    timer?.tolerance = interval / 10
  }

  private func scheduleLANLiveTimer() {
    lanLiveTimer?.invalidate()
    guard isHosting else { lanLiveTimer = nil; return }
    // Keep the transport heartbeat off the archive/write queue.
    lanLiveTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.publishLANState() }
    }
    lanLiveTimer?.tolerance = 0.02
  }

  func stop() {
    if !endedByStopCommand && (isHosting || followingWriter != nil || lanFollowingRoomID != nil) {
      watchStatus = isHosting ? "Hosting Watch Together · waiting for next episode" :
        "Waiting for host's next episode"
      checkpoint(refreshPeers: false)
      scheduleTimer()
      changed()
      return
    }
    timer?.invalidate(); timer = nil
    if isHosting { SharedShowLAN.shared.stopHosting() }
    if lanFollowingRoomID != nil { SharedShowLAN.shared.leave(); lanFollowingRoomID = nil }
    isHosting = false
    scheduleLANLiveTimer()
    checkpoint(stopped: true)
  }

  func fileEnded(dueToStopCommand: Bool) { endedByStopCommand = endedByStopCommand || dueToStopCommand }

  func localStopRequested() { endedByStopCommand = true }

  /// Player retirement and application quit are distinct from natural EOF.
  func shutdown() {
    timer?.invalidate(); timer = nil
    lanLiveTimer?.invalidate(); lanLiveTimer = nil
    if isHosting { SharedShowLAN.shared.stopHosting() }
    if lanFollowingRoomID != nil { SharedShowLAN.shared.leave(); lanFollowingRoomID = nil }
    isHosting = false
    pendingAutoHost = false
    checkpoint(stopped: true)
  }

  func saveFinal(media: URL?, position: Double?, duration: Double?, sourceGeneration: Int? = nil,
                 completion: (() -> Void)? = nil) {
    let sampleGeneration = sourceGeneration ??
      (player?.info.currentURL == media ? generation : generation - 1)
    // A final callback can arrive after a new file has started. Publishing it
    // then would replace the newer episode's single writer record on disk.
    guard sampleGeneration == generation else { completion?(); return }
    timer?.invalidate()
    timer = nil
    guard let media, media.isFileURL, let position, let duration,
          position.isFinite, duration.isFinite, duration > 0 else {
      stop()
      completion?()
      return
    }
    if let completion { finalCallbacks.append(completion) }
    finalizingGeneration = sampleGeneration
    let sample = Sample(generation: sampleGeneration, media: media, position: min(duration, max(0, position)),
                        duration: duration, activity: .stopped, date: Date())
    lastSample = sample
    enqueue(sample)
  }

  func requestFinalCheckpoint(completion: @escaping () -> Void) {
    saveFinal(media: player?.info.currentURL, position: player?.info.videoPosition?.second,
              duration: player?.info.videoDuration?.second, completion: completion)
  }

  func checkpoint(stopped: Bool = false, refreshPeers: Bool = true) {
    if !stopped && finalizingGeneration == generation { return }
    guard let player else { return }
    let sample: Sample
    if player.info.state.loaded, let media = player.info.currentURL, media.isFileURL {
      guard let position = player.info.videoPosition?.second, let duration = player.info.videoDuration?.second,
            position.isFinite, duration.isFinite, duration > 0 else { return }
      var current = Sample(generation: generation, media: media, position: min(duration, max(0, position)), duration: duration,
                      activity: stopped ? .stopped : player.info.state == .paused ? .paused : .playing,
                      date: Date(), rate: player.info.playSpeed, hosting: isHosting && !stopped)
      if current.activity == .paused && !current.hosting, let previous = lastPublished,
         previous.media == current.media, previous.activity == .paused, !previous.hosting,
         abs(previous.position - current.position) < 0.01, abs(previous.rate - current.rate) < 0.001 {
        current.shouldWrite = false
      }
      current.refreshPeers = refreshPeers
      if isHosting { current.playlistPaths = player.info.playlist.map(\.filename) }
      sample = current
      lastSample = current
    } else if stopped, let lastSample {
      sample = Sample(generation: lastSample.generation, media: lastSample.media, position: lastSample.position, duration: lastSample.duration,
                      activity: .stopped, date: Date())
    } else if (isHosting || followingWriter != nil), let previous = lastSample {
      sample = Sample(generation: generation, media: previous.media, position: previous.position,
                      duration: previous.duration, activity: .paused, date: Date(), rate: previous.rate,
                      hosting: isHosting, shouldWrite: isHosting, refreshPeers: refreshPeers,
                      playlistPaths: previous.playlistPaths,
                      awaitingNextEpisode: isHosting && !endedByStopCommand)
    } else { return }
    if !sample.shouldWrite && !sample.refreshPeers && followingWriter == nil && sample.date.timeIntervalSince(lastBroadRefresh) < 30 { return }
    if let membership, membership.root == nil, sample.date < membership.expiresAt,
       !isHosting && followingWriter == nil { return }
    if isHosting && !stopped { publishLANState() }
    enqueue(sample)
  }

  private func enqueue(_ sample: Sample) {
    if busy {
      if sample.activity == .stopped {
        pendingFinal = sample
        if pendingCurrent?.generation == sample.generation { pendingCurrent = nil }
      } else { pendingCurrent = sample }
      return
    }
    submit(sample)
  }

  private func submit(_ sample: Sample) {
    busy = true
    revision += 1
    let revision = revision
    let generation = sample.generation
    let writer = writerID
    let participant = Self.participantID
    let cachedMembership = membership
    let membershipEpoch = self.membershipEpoch
    let previousPositions = positions
    let previousBroadRefresh = lastBroadRefresh
    let following = lanFollowingRoomID == nil ? followingWriter : nil
    let hostParticipant = followingParticipant
    let followingShow = followingShowID
    let watchIntent = remoteOpenGeneration
    let (lane, laneKey) = Self.reserveLane(for: cachedMembership?.root ?? sample.media.deletingLastPathComponent())
    lane.addOperation { [weak self] in
      var resolvedRoot: URL?
      var resolvedID: UUID?
      var resolvedPath: String?
      var positions = previousPositions
      var status: String?
      var nextMembership = cachedMembership
      var broadRefresh = previousBroadRefresh
      var published = false
      var hostRecord: SharedShowStore.Progress?
      var hostQueue: SharedShowStore.QueueRecord?
      var playableTarget: URL?
      do {
        let store: SharedShowStore?
        if let cached = cachedMembership, sample.date < cached.expiresAt,
           cached.root != nil || (!sample.hosting && following == nil) {
          store = try cached.root.map { try SharedShowStore(root: $0) }
          resolvedID = cached.showID
          resolvedPath = cached.path
        } else {
          store = try SharedShowStore.discover(for: sample.media)
          if let store {
            let descriptor = try store.descriptor()
            resolvedID = descriptor.showID
            resolvedPath = store.relativePath(for: sample.media)
            nextMembership = Membership(root: store.root, showID: resolvedID, path: resolvedPath,
                                        expiresAt: sample.date.addingTimeInterval(60))
          } else {
            nextMembership = Membership(root: nil, showID: nil, path: nil,
                                        expiresAt: sample.date.addingTimeInterval(30))
          }
        }
        if let store, let path = resolvedPath, let showID = resolvedID {
          resolvedRoot = store.root
          // Capture other writers before writing this checkpoint. No other person's
          // position automatically overrides local watch-later or playback state.
          if sample.refreshPeers || sample.date.timeIntervalSince(previousBroadRefresh) >= 30 {
            positions = try store.progress(showID: showID).filter { $0.writerID != writer }
            broadRefresh = sample.date
          } else if let following, let hostParticipant,
                    let host = try store.progress(showID: showID, participantID: hostParticipant,
                                                  writerID: following) {
            positions.removeAll { $0.writerID == following }
            positions.append(host)
          }
          if let following, let hostParticipant, followingShow == showID {
            hostRecord = try store.progress(showID: showID, participantID: hostParticipant,
                                            writerID: following)
            if let hostRecord, SharedPlaybackSync.target(for: hostRecord) != nil {
              hostQueue = try store.queue(showID: showID, participantID: hostParticipant,
                                          writerID: following)
              if let hostQueue, hostQueue.current == hostRecord.relativePath,
                 hostQueue.items.contains(hostRecord.relativePath) {
                // The current file was already resolved before mpv loaded it.
                // Rechecking the full transfer catalog on every 2s sync would
                // turn a cheap host heartbeat into a broad filesystem walk.
                playableTarget = hostRecord.relativePath == path ? sample.media :
                  try store.resolvePlayable(path: hostRecord.relativePath, showID: showID)
              }
            }
          }
          if sample.shouldWrite {
            try store.publish(.init(showID: showID, participantID: participant, writerID: writer,
              revision: revision, updatedAt: sample.date, relativePath: path, position: sample.position,
              duration: sample.duration, activity: sample.activity, playbackRate: sample.rate, watchTogether: false))
            published = true
          }
          status = "Progress saved to show folder"
        }
      } catch {
        nextMembership = Membership(root: nil, showID: nil, path: nil, expiresAt: sample.date.addingTimeInterval(10))
        status = "Shared progress unavailable; playback continues locally"
      }
      let rootHint: String
      if let resolvedRoot,
         let volume = try? resolvedRoot.resourceValues(forKeys: [.volumeURLKey]).volume,
         volume.path.hasPrefix("/Volumes/"),
         resolvedRoot.path.hasPrefix(volume.path) {
        rootHint = String(resolvedRoot.path.dropFirst(volume.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      } else { rootHint = "" }
      let result = (resolvedRoot, resolvedID, positions, status, resolvedPath, nextMembership,
                    broadRefresh, published, hostRecord, hostQueue, playableTarget, rootHint)
      DispatchQueue.main.async { [weak self] in
        Self.releaseLane(laneKey)
        guard let self else { return }
        self.busy = false
        if self.generation == generation && self.membershipEpoch == membershipEpoch {
          self.root = result.0
          self.showID = result.1
          self.positions = result.2
          self.status = result.3
          self.relativePath = result.4
          self.membership = result.5
          self.lastBroadRefresh = result.6
          if result.7 { self.lastPublished = sample }
          self.contextMedia = sample.media
          self.lanRootHint = result.11
          if self.isHosting, let command = self.lanCommandOverride,
             self.relativePath == command.relativePath {
            self.applyLANTransport(command)
          }
          if self.lanFollowingRoomID != nil,
             self.relativePath == self.lanState?.relativePath {
            self.pendingLANPath = nil
            if let lanState = self.lanState { self.applyLANState(lanState) }
          }
          if !self.isHosting && self.lanFollowingRoomID == nil && self.pendingAutoHost && !self.hostingSuppressed,
             self.showID != nil, self.player?.info.state.loaded == true {
            self.pendingAutoHost = false
            self.hostWatchTogether()
          }
          if self.isHosting && (self.lanState == nil || self.lanState?.relativePath != self.relativePath) {
            self.publishLANState()
          }
          if self.lanFollowingRoomID != nil && self.wantsLANEpisodeSwitch {
            if self.showID == self.lanState?.showID { self.sendLANControl() }
            else { self.leaveWatchTogether() }
          }
          if self.remoteOpenGeneration == watchIntent {
            self.synchronize(host: result.8, queue: result.9, playableTarget: result.10)
          }
          self.changed()
          if self.timer != nil { self.scheduleTimer() }
        }
        let hasNextFinal = self.pendingFinal != nil
        if let final = self.pendingFinal {
          self.pendingFinal = nil
          self.submit(final)
        } else if let current = self.pendingCurrent {
          self.pendingCurrent = nil
          self.submit(current)
        }
        if sample.activity == .stopped && !hasNextFinal {
          let callbacks = self.finalCallbacks
          self.finalCallbacks.removeAll()
          callbacks.forEach { $0() }
        }
      }
    }
  }

  func hostWatchTogether() {
    guard showID != nil else { return }
    SharedShowLAN.shared.leave()
    lanFollowingRoomID = nil
    clearFollowing()
    isHosting = true
    pendingAutoHost = false
    hostingSuppressed = false
    lanRoomID = UUID()
    lanRevision = 0
    lanUserPaused = player?.info.state != .playing
    lanBaseRate = player?.info.playSpeed ?? 1
    lanAppliedBaseRate = lanBaseRate
    lanLocalReady = false
    lanPeerReady.removeAll()
    lanBarrierGeneration = 0
    lanSeekGeneration = 0
    lanLastAppliedPath = relativePath
    lanLastAppliedSeekGeneration = 0
    watchStatus = "Hosting Watch Together · \(writerID.uuidString.prefix(6))"
    scheduleTimer()
    scheduleLANLiveTimer()
    checkpoint()
    changed()
  }

  func follow(_ record: SharedShowStore.Progress) {
    guard record.showID == showID,
          record.writerID != writerID, SharedPlaybackSync.target(for: record) != nil else { return }
    clearFollowing()
    isHosting = false
    followingWriter = record.writerID
    followingParticipant = record.participantID
    followingShowID = record.showID
    acceptedHostRevision = 0
    acceptedQueueRevision = 0
    hostQueueItems = []
    hostQueueCurrent = nil
    pendingRemoteTarget = nil
    pendingRemoteSince = nil
    remoteOpenGeneration &+= 1
    remoteOpenFailures = 0
    remoteOpenFailedPath = nil
    unavailableAttempts = 0
    watchStatus = "Following host \(record.writerID.uuidString.prefix(6))"
    scheduleTimer()
    checkpoint(refreshPeers: true)
    changed()
  }

  func leaveWatchTogether() {
    lanScheduledResume?.cancel(); lanScheduledResume = nil
    restoreLANBaseRate()
    if isHosting { SharedShowLAN.shared.stopHosting() }
    if lanFollowingRoomID != nil { SharedShowLAN.shared.leave(); lanFollowingRoomID = nil }
    isHosting = false
    scheduleLANLiveTimer()
    hostingSuppressed = true
    pendingAutoHost = false
    clearFollowing()
    watchStatus = nil
    scheduleTimer()
    checkpoint()
    changed()
  }

  /// A local transport action takes control back. Remote actions call through
  /// the same PlayerCore API under the applyingRemote guard, preventing loops.
  var shouldDeferLocalResume: Bool { (isHosting || lanFollowingRoomID != nil) && lanWaitingForReady }
  var requiresExactSharedShowSeek: Bool { isHosting || lanFollowingRoomID != nil }

  private func beginLANBarrier() {
    lanBarrierGeneration &+= 1
    lanWaitingForReady = true
    lanPlayAtHostTime = nil
    lanLocalReady = false
    lanRequiresObservedPause = true
    lanFreshReadinessGeneration = nil
    lanScheduledResume?.cancel(); lanScheduledResume = nil
    if isHosting { lanPeerReady = lanPeerReady.mapValues { _ in false } }
    if let player, player.info.state == .playing {
      applyingRemote = true
      player.pause()
      applyingRemote = false
    }
    player?.refreshSharedShowReadiness(generation: lanBarrierGeneration)
  }

  func playbackSeekingObserved() {
    guard isHosting || lanFollowingRoomID != nil else { return }
    lanRestartPending = true
    playbackObservation(position: nil, observedAt: nil, cachePaused: player?.info.pausedForCache ?? false, seeking: true)
  }

  func playbackRestartObserved() {
    guard isHosting || lanFollowingRoomID != nil else { return }
    lanRestartPending = false
    playbackObservation(position: nil, observedAt: nil, cachePaused: player?.info.pausedForCache ?? false, seeking: false)
  }

  func playbackPauseObserved(_ paused: Bool) {
    guard isHosting || lanFollowingRoomID != nil else { return }
    lanObservedPaused = paused
    playbackObservation(position: nil, observedAt: nil,
      cachePaused: player?.info.pausedForCache ?? false,
      seeking: player?.info.isSeeking ?? true)
  }

  func playbackObservation(position: Double?, observedAt: Double?, cachePaused: Bool,
                           seeking: Bool, barrierGeneration: UInt64? = nil,
                           enginePaused: Bool? = nil) {
    guard isHosting || lanFollowingRoomID != nil else { return }
    if let barrierGeneration, barrierGeneration != lanBarrierGeneration { return }
    if let barrierGeneration { lanFreshReadinessGeneration = barrierGeneration }
    if let enginePaused { lanObservedPaused = enginePaused }
    if let position, position.isFinite, let observedAt {
      lanObservedPosition = position
      lanObservedAt = observedAt
    }
    let reachedSeek = lanExpectedSeekPosition.map { target in
      guard let position, let observedAt else { return false }
      return observedAt >= lanSeekRequestedAt && abs(position - target) < 0.15
    } ?? true
    if reachedSeek { lanExpectedSeekPosition = nil }
    let ready = player?.info.state.loaded == true && !cachePaused && !seeking &&
      !lanRestartPending && reachedSeek && (!lanRequiresObservedPause ||
        (lanObservedPaused && lanFreshReadinessGeneration == lanBarrierGeneration))
    guard ready != lanLocalReady else {
      if ready && lanFollowingRoomID != nil { correctLANRate() }
      return
    }
    lanLocalReady = ready
    if isHosting {
      if !ready && !lanUserPaused && !lanWaitingForReady { beginLANBarrier(); publishLANState() }
      else { completeLANBarrierIfReady() }
    } else if lanFollowingRoomID != nil {
      SharedShowLAN.shared.reportLocalReadiness(ready: ready, generation: lanBarrierGeneration)
      if !ready, let player, player.info.state == .playing {
        applyingRemote = true; player.pause(); applyingRemote = false
      }
    }
  }

  func lanPeerReadinessChanged(ready: Bool, generation: UInt64, peerID: UUID) {
    guard isHosting, generation == lanBarrierGeneration else { return }
    lanPeerReady[peerID] = ready
    if !ready && !lanUserPaused && !lanWaitingForReady { beginLANBarrier(); publishLANState() }
    else { completeLANBarrierIfReady() }
  }

  func lanPeerDisconnected(peerID: UUID) {
    lanPeerReady.removeValue(forKey: peerID)
    completeLANBarrierIfReady()
  }

  func lanClockInvalidated() {
    guard lanFollowingRoomID != nil else { return }
    lanLocalReady = false
    lanWaitingForReady = true
    lanScheduledResume?.cancel(); lanScheduledResume = nil
    if let player, player.info.state == .playing {
      applyingRemote = true; player.pause(); applyingRemote = false
    }
    SharedShowLAN.shared.reportLocalReadiness(ready: false, generation: lanBarrierGeneration)
  }

  func lanClockCalibrated() {
    guard lanFollowingRoomID != nil, let state = lanState else { return }
    lanLocalReady = false
    lanWaitingForReady = state.waitingForReady
    lanRequiresObservedPause = true
    lanFreshReadinessGeneration = nil
    SharedShowLAN.shared.reportLocalReadiness(ready: false, generation: lanBarrierGeneration)
    if let player, player.info.state == .playing {
      applyingRemote = true; player.pause(); applyingRemote = false
    }
    if lanNeedsCalibratedJoinSeek, player?.info.state.loaded == true {
      lanNeedsCalibratedJoinSeek = false
      applyLANTransport(state, explicitCommand: true)
    }
    player?.refreshSharedShowReadiness(generation: lanBarrierGeneration)
  }

  func lanHostWoke() {
    guard isHosting else { return }
    beginLANBarrier()
    publishLANState()
  }

  func cancelLANCommand(stopSubmittedOpen: Bool = false) {
    guard isHosting, let restore = lanCommandRestore else { return }
    lanResolveToken &+= 1
    if let target = lanCommandTarget {
      player?.cancelSharedShowMediaPreparation(for: target)
      if stopSubmittedOpen { player?.cancelSharedShowCommandOpen(for: target) }
    }
    lanCommandTarget = nil
    lanCommandRestore = nil
    lanUserPaused = restore.userPaused
    lanBaseRate = restore.baseRate
    lanSeekGeneration = restore.seekGeneration
    lanExpectedSeekPosition = nil
    lanRestartPending = false
    beginLANBarrier()
    publishLANState()
  }

  private func completeLANBarrierIfReady() {
    guard isHosting, lanWaitingForReady, lanLocalReady, lanPeerReady.values.allSatisfy({ $0 }),
          !lanUserPaused else { return }
    lanWaitingForReady = false
    lanPlayAtHostTime = ProcessInfo.processInfo.systemUptime + 0.5
    publishLANState()
    scheduleLANResume(generation: lanBarrierGeneration, hostTime: lanPlayAtHostTime!)
  }

  private func scheduleLANResume(generation: UInt64, hostTime: Double) {
    lanScheduledResume?.cancel()
    let localDeadline = hostTime - ((SharedShowLAN.shared.estimatedHostTime() ?? ProcessInfo.processInfo.systemUptime) - ProcessInfo.processInfo.systemUptime)
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.lanBarrierGeneration == generation, !self.lanUserPaused,
            !self.lanWaitingForReady, self.lanLocalReady, let player = self.player else { return }
      self.lanRequiresObservedPause = false
      self.applyingRemote = true
      player.resume()
      self.applyingRemote = false
      self.lanScheduledResume = nil
    }
    lanScheduledResume = item
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, localDeadline - ProcessInfo.processInfo.systemUptime), execute: item)
  }

  private func restoreLANBaseRate() {
    guard let player else { return }
    applyingRemote = true; player.setSpeed(lanBaseRate); applyingRemote = false
  }

  func localControlChanged(_ intent: ControlIntent = .other) {
    guard !applyingRemote else { return }
    guard isHosting || lanFollowingRoomID != nil else {
      if followingWriter != nil { leaveWatchTogether() }
      return
    }
    switch intent {
    case .pause(let paused):
      lanUserPaused = paused
      if lanFollowingRoomID != nil { lanPendingLocalPause = paused }
      if paused { lanScheduledResume?.cancel(); lanScheduledResume = nil; lanPlayAtHostTime = nil }
      else if isHosting || lanFollowingRoomID != nil { beginLANBarrier() }
    case .seek(let target):
      lanSeekGeneration &+= 1
      if lanFollowingRoomID != nil { lanPendingLocalSeekGeneration = lanSeekGeneration }
      lanRestartPending = true
      lanExpectedSeekPosition = target
      lanSeekRequestedAt = ProcessInfo.processInfo.systemUptime
      beginLANBarrier()
    case .rate(let rate): lanBaseRate = rate
    case .other: break
    }
    if lanFollowingRoomID != nil {
      sendLANControl(intent: intent)
      return
    }
    if isHosting {
      publishLANState(intent: intent)
      // Archive progress separately from live transport, with a bounded write rate.
      guard ProcessInfo.processInfo.systemUptime - lastControlCheckpoint >= 1 else { return }
      lastControlCheckpoint = ProcessInfo.processInfo.systemUptime
      DispatchQueue.main.async { [weak self] in self?.checkpoint() }
    }
  }

  /// A local open or playlist edit is an explicit takeover. Remote opens call
  /// this through PlayerCore while applyingRemote is true.
  func localMediaChangeRequested() {
    guard !applyingRemote else { return }
    if lanFollowingRoomID != nil {
      wantsLANEpisodeSwitch = true
      lanSwitchSent = false
      return
    }
    if followingWriter != nil { leaveWatchTogether() }
    else if isHosting {
      beginLANBarrier()
      publishLANState()
      checkpoint()
    }
  }

  private func publishLANState(intent: ControlIntent? = nil) {
    guard isHosting, let roomID = lanRoomID, let showID, let relativePath,
          let player, player.info.currentURL == contextMedia,
          let position = player.info.videoPosition?.second,
          let duration = player.info.videoDuration?.second,
          position.isFinite, duration.isFinite, duration > 0 else { return }
    if let prior = lanState, prior.showID != showID {
      SharedShowLAN.shared.stopHosting()
      lanRoomID = UUID()
      lanRevision = 0
      lanState = nil
      lanCommandOverride = nil
      publishLANState()
      return
    }
    if let override = lanCommandOverride, override.relativePath != relativePath,
       Date().timeIntervalSince(override.emittedAt) < 20 { return }
    let sampleTime = ProcessInfo.processInfo.systemUptime
    let projected = lanObservedPosition.flatMap { observed -> Double? in
      guard let observedAt = lanObservedAt, sampleTime - observedAt < 0.5,
            sampleTime >= observedAt else { return nil }
      let scheduled = lanPlayAtHostTime.map { sampleTime < $0 } ?? false
      return observed + (lanUserPaused || lanWaitingForReady || scheduled ? 0 : sampleTime - observedAt) * lanBaseRate
    }
    var advertisedPosition = lanExpectedSeekPosition ?? min(duration, max(0, projected ?? position))
    if case .seek(let target) = intent { advertisedPosition = min(duration, max(0, target)) }
    let advertisedRate: Double
    if case .rate(let requested) = intent { advertisedRate = requested }
    else { advertisedRate = lanBaseRate }
    lanRevision &+= 1
    let state = SharedShowLAN.State(roomID: roomID, showID: showID,
      hostName: Self.localHostName,
      title: String((player.info.currentURL?.deletingPathExtension().lastPathComponent ?? "Movie").prefix(120)),
      rootHint: lanRootHint,
      relativePath: relativePath,
      position: advertisedPosition, duration: duration,
      paused: lanUserPaused || lanWaitingForReady,
      rate: advertisedRate,
      revision: lanRevision, emittedAt: Date(), awaitingNextEpisode: !player.info.state.loaded,
      epoch: roomID, hostTime: sampleTime,
      playAtHostTime: lanPlayAtHostTime, barrierGeneration: lanBarrierGeneration,
      seekGeneration: lanSeekGeneration, waitingForReady: lanWaitingForReady,
      userPaused: lanUserPaused)
    lanState = state
    SharedShowLAN.shared.host(session: self, state: state)
  }

  func acceptLANCommand(_ command: SharedShowLAN.State, revision: UInt64) {
    lanRevision = max(lanRevision, revision)
    lanCommandOverride = command
    lanUserPaused = command.userPaused
    lanSeekGeneration = command.seekGeneration
    lanBarrierGeneration = command.barrierGeneration
    lanWaitingForReady = command.waitingForReady
    lanPlayAtHostTime = command.playAtHostTime
  }

  func canonicalLANCommand(_ command: SharedShowLAN.State, revision: UInt64) -> SharedShowLAN.State {
    let current = lanState
    let duration = player?.info.videoDuration?.second ?? command.duration
    let position = command.seekGeneration != (current?.seekGeneration ?? 0) ? command.position :
      (lanObservedPosition ?? player?.info.videoPosition?.second ?? command.position)
    return SharedShowLAN.State(roomID: command.roomID, showID: command.showID,
      hostName: Self.localHostName, title: command.title, rootHint: lanRootHint,
      relativePath: command.relativePath, position: min(duration, max(0, position)),
      duration: duration, paused: lanUserPaused || lanWaitingForReady,
      rate: lanBaseRate, revision: revision, emittedAt: Date(),
      awaitingNextEpisode: false, epoch: command.roomID,
      hostTime: ProcessInfo.processInfo.systemUptime, playAtHostTime: lanPlayAtHostTime,
      barrierGeneration: lanBarrierGeneration, seekGeneration: lanSeekGeneration,
      waitingForReady: lanWaitingForReady, userPaused: lanUserPaused)
  }

  func yieldLANHosting() {
    isHosting = false
    scheduleLANLiveTimer()
    hostingSuppressed = true
    lanRoomID = nil
    lanState = nil
    watchStatus = nil
    scheduleTimer()
    changed()
  }

  func beginLANFollow(_ room: SharedShowLAN.Room) {
    lanScheduledResume?.cancel(); lanScheduledResume = nil
    if isHosting { SharedShowLAN.shared.stopHosting() }
    isHosting = false
    scheduleLANLiveTimer()
    hostingSuppressed = true
    pendingAutoHost = false
    clearFollowing()
    lanFollowingRoomID = room.id
    lanState = nil
    lanLastAppliedPath = nil
    lanLastAppliedSeekGeneration = nil
    lanNeedsCalibratedJoinSeek = false
    lanLocalReady = false
    lanWaitingForReady = true
    lanRequiresObservedPause = true
    lanFreshReadinessGeneration = nil
    lanUserPaused = room.paused
    lanBaseRate = room.rate
    lanAppliedBaseRate = nil
    lanPendingLocalPause = nil
    lanPendingLocalSeekGeneration = nil
    lanResolveToken &+= 1
    pendingLANPath = nil
    wantsLANEpisodeSwitch = false
    lanSwitchSent = false
    lanFolderPromptShown = false
    if let player, player.info.state == .playing {
      applyingRemote = true; player.pause(); applyingRemote = false
    }
    watchStatus = "Connecting to \(room.hostName)"
    scheduleTimer()
    changed()
  }

  func endLANFollow(_ message: String) {
    guard lanFollowingRoomID != nil else { return }
    if let player, player.info.state == .playing {
      applyingRemote = true; player.pause(); applyingRemote = false
    }
    lanFollowingRoomID = nil
    lanScheduledResume?.cancel(); lanScheduledResume = nil
    restoreLANBaseRate()
    lanAppliedBaseRate = nil
    lanPendingLocalPause = nil
    lanPendingLocalSeekGeneration = nil
    hostingSuppressed = true
    pendingAutoHost = false
    lanState = nil
    lanResolveToken &+= 1
    pendingLANPath = nil
    wantsLANEpisodeSwitch = false
    lanSwitchSent = false
    if let pendingRemoteTarget { player?.cancelSharedShowMediaPreparation(for: pendingRemoteTarget) }
    pendingRemoteTarget = nil
    watchStatus = message
    scheduleTimer()
    changed()
  }

  private func sendLANControl(intent: ControlIntent = .other) {
    guard let state = lanState, lanFollowingRoomID == state.roomID,
          let player, player.info.state.loaded,
          let media = player.info.currentURL,
          media == contextMedia || media == pendingRemoteTarget,
          let showID, showID == state.showID,
          let relativePath,
          let position = player.info.videoPosition?.second,
          let duration = player.info.videoDuration?.second,
          position.isFinite, duration.isFinite, duration > 0 else { return }
    let target: Double
    if case .seek(let requested) = intent { target = requested }
    else { target = position }
    let rate: Double
    if case .rate(let requested) = intent { rate = requested }
    else { rate = lanBaseRate }
    let command = SharedShowLAN.State(roomID: state.roomID, showID: showID,
      hostName: state.hostName, title: String(media.deletingPathExtension().lastPathComponent.prefix(120)),
      rootHint: state.rootHint,
      relativePath: relativePath, position: min(duration, max(0, target)), duration: duration,
      paused: lanUserPaused || lanWaitingForReady, rate: rate,
      revision: state.revision, emittedAt: Date(), awaitingNextEpisode: false,
      epoch: state.epoch, hostTime: state.hostTime, playAtHostTime: nil,
      barrierGeneration: lanBarrierGeneration, seekGeneration: lanSeekGeneration,
      waitingForReady: lanWaitingForReady, userPaused: lanUserPaused)
    guard relativePath == state.relativePath || wantsLANEpisodeSwitch else { return }
    if wantsLANEpisodeSwitch && lanSwitchSent { return }
    SharedShowLAN.shared.sendClientControl(command, switchEpisode: relativePath != state.relativePath,
                                           expectedPath: state.relativePath)
    if wantsLANEpisodeSwitch {
      lanSwitchSent = true
      let roomID = state.roomID
      DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
        guard let self, self.lanFollowingRoomID == roomID, self.wantsLANEpisodeSwitch,
              self.lanSwitchSent else { return }
        self.wantsLANEpisodeSwitch = false
        self.lanSwitchSent = false
        if let latest = self.lanState { self.applyLANState(latest) }
      }
    }
  }

  func applyLANState(_ state: SharedShowLAN.State) {
    guard lanFollowingRoomID == state.roomID, state.isValid else { return }
    if let pending = lanPendingLocalSeekGeneration {
      guard state.seekGeneration >= pending else { return }
      lanPendingLocalSeekGeneration = nil
    }
    lanState = state
    lanSeekGeneration = state.seekGeneration
    let newBarrier = state.barrierGeneration != lanBarrierGeneration
    if newBarrier {
      lanBarrierGeneration = state.barrierGeneration
      lanLocalReady = false
      lanRequiresObservedPause = true
      lanFreshReadinessGeneration = nil
      lanScheduledResume?.cancel(); lanScheduledResume = nil
      player?.refreshSharedShowReadiness(generation: lanBarrierGeneration)
    }
    lanWaitingForReady = state.waitingForReady || !SharedShowLAN.shared.clockCalibrated
    lanPlayAtHostTime = state.playAtHostTime
    if lanPendingLocalPause == state.userPaused { lanPendingLocalPause = nil }
    lanUserPaused = lanPendingLocalPause ?? state.userPaused
    lanBaseRate = state.rate
    if !lanWaitingForReady && !lanLocalReady {
      player?.refreshSharedShowReadiness(generation: lanBarrierGeneration)
    }
    if wantsLANEpisodeSwitch {
      if relativePath == state.relativePath,
         player?.info.currentURL == contextMedia, player?.info.state.loaded == true {
        wantsLANEpisodeSwitch = false
        lanSwitchSent = false
      } else { return }
    }
    guard !state.awaitingNextEpisode else {
      watchStatus = "Waiting for the host's next episode"
      changed()
      return
    }
    guard let player else { return }
    if showID == state.showID && relativePath == state.relativePath &&
       player.info.state.loaded &&
       (player.info.currentURL == contextMedia || player.info.currentURL == pendingRemoteTarget) {
      applyLANTransport(state)
      return
    }
    // One pending lookup per target. A newer episode invalidates its completion.
    if pendingLANPath == state.relativePath { return }
    if let pendingRemoteTarget { player.cancelSharedShowMediaPreparation(for: pendingRemoteTarget) }
    pendingRemoteTarget = nil
    pendingLANPath = state.relativePath
    lanResolveToken &+= 1
    let token = lanResolveToken
    watchStatus = "Finding \(state.title) on this Mac"
    changed()
    SharedShowLAN.shared.resolve(state, preferredRoot: root) { [weak self] url in
      guard let self, self.lanFollowingRoomID == state.roomID,
            self.lanResolveToken == token else { return }
      guard let url else {
        self.pendingLANPath = nil
        self.watchStatus = "Mount the shared show to watch \(state.title)"
        self.changed()
        if !self.lanFolderPromptShown && NSApp.isRunning {
          self.lanFolderPromptShown = true
          let panel = NSOpenPanel()
          panel.message = "Choose the mounted shared show folder"
          panel.canChooseDirectories = true
          panel.canChooseFiles = false
          panel.allowsMultipleSelection = false
          panel.begin { [weak self] response in
            guard let self, self.lanFollowingRoomID == state.roomID,
                  response == .OK, let selected = panel.url else { return }
            self.root = selected
            self.applyLANState(state)
          }
        }
        return
      }
      self.pendingRemoteTarget = url
      self.watchStatus = "Opening \(state.title)"
      self.changed()
      self.applyingRemote = true
      player.openURLsAsync([url], shouldAutoLoad: false) { [weak self] count in
        guard let self, self.lanFollowingRoomID == state.roomID,
              self.lanResolveToken == token else { return }
        if count != 1 {
          self.pendingRemoteTarget = nil
          self.pendingLANPath = nil
          self.watchStatus = "Could not open \(state.title)"
          self.changed()
        }
      }
      self.applyingRemote = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
        guard let self, self.lanFollowingRoomID == state.roomID,
              self.lanResolveToken == token, self.pendingLANPath == state.relativePath else { return }
        self.player?.cancelSharedShowMediaPreparation(for: url)
        self.pendingRemoteTarget = nil
        self.pendingLANPath = nil
        self.watchStatus = "Waiting for \(state.title)"
        self.changed()
      }
    }
  }

  private func applyLANTransport(_ state: SharedShowLAN.State, explicitCommand: Bool = false) {
    guard let player, let duration = player.info.videoDuration?.second else { return }
    applyingRemote = true
    defer { applyingRemote = false }
    let effectiveUserPaused = lanFollowingRoomID != nil ? lanUserPaused : state.userPaused
    let hostNow = SharedShowLAN.shared.estimatedHostTime() ?? state.hostTime
    let futureStart = state.playAtHostTime.map { $0 > hostNow } ?? false
    if lanFollowingRoomID != nil, let playAt = state.playAtHostTime,
       hostNow - playAt > 0.02, player.info.state == .paused,
       !effectiveUserPaused {
      lanLocalReady = false
      lanWaitingForReady = true
      SharedShowLAN.shared.reportLocalReadiness(ready: false, generation: state.barrierGeneration)
      return
    }
    if (state.paused || lanWaitingForReady || futureStart || effectiveUserPaused) &&
        player.info.state != .paused { player.pause() }
    let needsExactSeek = explicitCommand || (lanFollowingRoomID != nil &&
      (lanLastAppliedPath != state.relativePath ||
       lanLastAppliedSeekGeneration != state.seekGeneration))
    if needsExactSeek {
      if lanFollowingRoomID != nil && !SharedShowLAN.shared.clockCalibrated {
        lanNeedsCalibratedJoinSeek = true
      }
      lanLastAppliedPath = state.relativePath
      lanLastAppliedSeekGeneration = state.seekGeneration
      lanRestartPending = true
      lanLocalReady = false
      let expected = SharedShowTimeline.projectedPosition(state, atHostTime: hostNow)
      let destination = min(max(0, duration - 0.5), max(0, expected))
      lanExpectedSeekPosition = destination
      lanSeekRequestedAt = ProcessInfo.processInfo.systemUptime
      player.seek(absoluteSecond: destination)
      if lanFollowingRoomID != nil {
        SharedShowLAN.shared.reportLocalReadiness(ready: false, generation: state.barrierGeneration)
      }
    }
    if lanAppliedBaseRate == nil || abs((lanAppliedBaseRate ?? 0) - state.rate) > 0.001 {
      lanAppliedBaseRate = state.rate
      player.setSpeed(state.rate)
    }
    if lanWaitingForReady || effectiveUserPaused { return }
    if let playAt = state.playAtHostTime, futureStart, player.info.state == .paused {
      scheduleLANResume(generation: state.barrierGeneration, hostTime: playAt)
    } else if player.info.state == .paused && lanLocalReady {
      player.resume()
    }
    watchStatus = isHosting ? "Hosting Watch Together · \(writerID.uuidString.prefix(6))" :
      "Watching with \(state.hostName)"
    changed()
  }

  private func correctLANRate() {
    guard lanFollowingRoomID != nil, !lanWaitingForReady, !lanUserPaused,
          let state = lanState, let player, let observed = lanObservedPosition,
          let observedAt = lanObservedAt else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lanLastTrimTime >= 0.2 else { return }
    guard now >= observedAt, now - observedAt < 0.4 else { return }
    lanLastTrimTime = now
    let hostNow = SharedShowLAN.shared.estimatedHostTime(at: now) ?? state.hostTime
    let expected = SharedShowTimeline.projectedPosition(state, atHostTime: hostNow)
    let actual = observed + (now - observedAt) * player.info.playSpeed
    let phase = expected - actual
    lanFilteredPhaseError = lanFilteredPhaseError.map { 0.8 * $0 + 0.2 * phase } ?? phase
    let rate = SharedShowTimeline.trimmedRate(baseRate: lanBaseRate,
                                              expectedPosition: actual + (lanFilteredPhaseError ?? 0),
                                              actualPosition: actual)
    if abs(player.info.playSpeed - rate) > 0.001 {
      player.setSharedShowCorrectionRate(rate)
    }
  }

  func applyLANCommand(_ state: SharedShowLAN.State, completion: @escaping (Bool) -> Void) {
    guard isHosting, lanRoomID == state.roomID, state.showID == showID,
          state.isValid, let player else { completion(false); return }
    func applyIntent() -> Bool {
      let seekChanged = state.seekGeneration != lanSeekGeneration
      let startingPlayback = lanUserPaused && !state.userPaused
      lanUserPaused = state.userPaused
      lanBaseRate = state.rate
      if seekChanged {
        lanRestartPending = true
        lanExpectedSeekPosition = state.position
        lanSeekRequestedAt = ProcessInfo.processInfo.systemUptime
      }
      if seekChanged || startingPlayback { beginLANBarrier() }
      if seekChanged { lanSeekGeneration = state.seekGeneration }
      if state.userPaused {
        lanScheduledResume?.cancel(); lanScheduledResume = nil
        lanPlayAtHostTime = nil
      }
      return seekChanged
    }
    if relativePath == state.relativePath && player.info.state.loaded {
      let seekChanged = applyIntent()
      applyLANTransport(state, explicitCommand: seekChanged)
      completion(true)
      return
    }
    lanCommandRestore = (lanUserPaused, lanBaseRate, lanSeekGeneration)
    lanCommandTarget = nil
    _ = applyIntent()
    if !lanWaitingForReady { beginLANBarrier() }
    publishLANState()
    lanResolveToken &+= 1
    let token = lanResolveToken
    let generation = self.generation
    SharedShowLAN.shared.resolve(state, preferredRoot: root) { [weak self] url in
      guard let self, self.isHosting, self.lanRoomID == state.roomID,
            self.lanResolveToken == token, self.generation == generation else {
        completion(false); return
      }
      guard let url else {
        self.cancelLANCommand()
        completion(false)
        return
      }
      self.lanCommandTarget = url
      self.applyingRemote = true
      player.openURLsAsync([url], shouldAutoLoad: false) { [weak self] count in
        guard let self, self.lanResolveToken == token else { completion(false); return }
        if count != 1 { self.cancelLANCommand() }
        else { player.pause() }
        completion(count == 1)
      }
      self.applyingRemote = false
    }
  }

  func playlistChanged() {
    if isHosting { checkpoint(refreshPeers: false) }
  }

  private func clearFollowing() {
    if let pendingRemoteTarget { player?.cancelSharedShowMediaPreparation(for: pendingRemoteTarget) }
    followingWriter = nil
    followingParticipant = nil
    followingShowID = nil
    remoteMediaIntents.removeAll()
    pendingRemoteTarget = nil
    pendingRemoteSince = nil
    remoteOpenGeneration &+= 1
    remoteOpenFailures = 0
    remoteOpenFailedPath = nil
    acceptedHostRevision = 0
    acceptedQueueRevision = 0
    hostQueueItems = []
    hostQueueCurrent = nil
    unavailableAttempts = 0
  }

  private func synchronize(host record: SharedShowStore.Progress?, queue: SharedShowStore.QueueRecord?,
                           playableTarget: URL?) {
    guard lanFollowingRoomID == nil else { return }
    guard let followingWriter, let followingParticipant, let followingShowID,
          let player else { return }
    guard showID == followingShowID else {
      watchStatus = "Waiting for the shared show folder"
      changed()
      return
    }
    guard let record, record.writerID == followingWriter,
          record.participantID == followingParticipant, record.showID == followingShowID else {
      watchStatus = "Waiting for the host"
      changed()
      return
    }
    guard record.revision >= acceptedHostRevision else { return }
    let age = Date().timeIntervalSince(record.updatedAt)
    guard age >= 0, age <= SharedPlaybackSync.maximumAge else {
      watchStatus = "Waiting for a fresh host update"
      changed()
      return
    }
    if record.revision > acceptedHostRevision { acceptedHostRevision = record.revision }
    if record.watchTogether != true || record.activity == .stopped {
      clearFollowing()
      watchStatus = "The host ended Watch Together"
      scheduleTimer()
      changed()
      return
    }
    guard let target = SharedPlaybackSync.target(for: record),
          let queue, queue.writerID == followingWriter,
          queue.participantID == followingParticipant, queue.showID == followingShowID,
          queue.revision >= acceptedQueueRevision else {
      watchStatus = "Waiting for the host's shared queue"
      changed()
      return
    }
    let queueAge = Date().timeIntervalSince(queue.updatedAt)
    guard queueAge >= 0, queueAge <= 30 else {
      watchStatus = "Waiting for a fresh shared queue"
      changed()
      return
    }
    acceptedQueueRevision = queue.revision
    hostQueueItems = queue.items
    hostQueueCurrent = queue.current
    if queue.current == nil {
      watchStatus = "Waiting for the host's next episode"
      changed()
      return
    }
    guard queue.current == record.relativePath, queue.items.contains(record.relativePath) else {
      watchStatus = "Waiting for the host's shared queue"
      changed()
      return
    }
    if relativePath == record.relativePath && !player.info.state.loaded {
      watchStatus = "Waiting for the host's next episode"
      changed()
      return
    }
    guard let playableTarget else {
      unavailableAttempts = min(3, unavailableAttempts + 1)
      watchStatus = "Waiting for \(URL(fileURLWithPath: record.relativePath).lastPathComponent) to finish downloading"
      scheduleTimer()
      changed()
      return
    }
    unavailableAttempts = 0
    guard relativePath == record.relativePath, player.info.state.loaded,
          player.info.currentURL == contextMedia else {
      openRemoteEpisode(playableTarget, host: record)
      return
    }
    pendingRemoteTarget = nil
    remoteMediaIntents.remove(playableTarget)
    guard let position = player.info.videoPosition?.second,
          let duration = player.info.videoDuration?.second else { return }
    applyingRemote = true
    defer { applyingRemote = false }
    if target.paused && player.info.state != .paused { player.pause() }
    if abs(player.info.playSpeed - target.rate) > 0.001 { player.setSpeed(target.rate) }
    let destination = min(max(0, duration - 0.5), target.position)
    if abs(position - destination) > SharedPlaybackSync.seekTolerance { player.seek(absoluteSecond: destination) }
    if !target.paused && player.info.state == .paused { player.resume() }
    watchStatus = "Following host \(record.writerID.uuidString.prefix(6)) · \(queue.items.count) queued"
    changed()
  }

  private func openRemoteEpisode(_ url: URL, host: SharedShowStore.Progress) {
    guard let player else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if pendingRemoteTarget == url, let since = pendingRemoteSince, now - since < 20 { return }
    let timedOut = pendingRemoteTarget == url
    if timedOut { player.cancelSharedShowMediaPreparation(for: url) }
    if remoteOpenFailedPath != url.path {
      remoteOpenFailedPath = url.path
      remoteOpenFailures = 0
    }
    if timedOut { remoteOpenFailures += 1 }
    guard remoteOpenFailures < 3 else {
      watchStatus = "Could not open host episode \(url.lastPathComponent)"
      changed()
      return
    }
    pendingRemoteTarget = url
    pendingRemoteSince = now
    remoteMediaIntents.insert(url)
    remoteOpenGeneration &+= 1
    let openGeneration = remoteOpenGeneration
    watchStatus = "Opening host episode \(url.lastPathComponent)"
    changed()
    applyingRemote = true
    player.openURLsAsync([url], shouldAutoLoad: false) { [weak self] count in
      guard let self, self.remoteOpenGeneration == openGeneration,
            self.followingWriter == host.writerID else { return }
      if count != 1 {
        self.remoteMediaIntents.remove(url)
        self.pendingRemoteTarget = nil
        self.pendingRemoteSince = nil
        self.remoteOpenFailures += 1
        self.unavailableAttempts = min(3, self.unavailableAttempts + 1)
        self.watchStatus = "Waiting for host episode \(url.lastPathComponent)"
        self.scheduleTimer()
        self.changed()
      }
    }
    applyingRemote = false
  }

  /// An explicit enable action uses the nearest existing show identity, or the
  /// open file's containing folder for a new show. All share I/O stays off UI.
  func enableSharing(completion: @escaping @MainActor (String?) -> Void = { _ in }) {
    guard let media = player?.info.currentURL, media.isFileURL else { return }
    let generation = self.generation
    enableToken &+= 1
    membershipEpoch &+= 1
    let token = enableToken
    status = "Enabling shared progress…"
    changed()
    let (lane, laneKey) = sharingWorkScheduler.reserve(media.deletingLastPathComponent())
    let releaseLane = sharingWorkScheduler.release
    lane.addOperation { [weak self] in
      let failure: String?
      do {
        let store = try SharedShowStore.discover(for: media)
          ?? SharedShowStore(root: media.deletingLastPathComponent())
        guard store.relativePath(for: media) != nil else { throw SharedShowStore.Failure.unsafePath }
        _ = try store.enable()
        failure = nil
      } catch {
        failure = Self.enableFailureDescription(error)
      }
      DispatchQueue.main.async { [weak self] in
        releaseLane(laneKey)
        guard let self else { return }
        guard self.generation == generation, self.enableToken == token,
              self.player?.info.currentURL == media else { return }
        self.membershipEpoch &+= 1
        self.status = failure.map { "Couldn’t enable sharing: \($0)" } ?? "Shared progress enabled"
        if failure == nil { self.membership = nil }
        self.changed()
        completion(failure)
        if failure == nil { self.checkpoint() }
      }
    }
  }

  private nonisolated static func enableFailureDescription(_ error: Error) -> String {
    switch error {
    case SharedShowStore.Failure.unsafePath: return "the open file is no longer accessible"
    case SharedShowStore.Failure.invalidRecord: return "the existing show metadata is invalid"
    case SharedShowStore.Failure.identityChanged: return "the existing show identity changed"
    case SharedShowStore.Failure.tooLarge: return "the existing show metadata is too large"
    case SharedShowStore.Failure.io(let code): return String(cString: strerror(code))
    default: return error.localizedDescription
    }
  }

  func request(_ episode: ShowEpisodeIndexReader.Episode, snapshot: ShowEpisodeIndexReader.Snapshot) {
    guard !requestBusy, !episode.ambiguous, episode.isFresh(),
          let root = snapshot.root, let showID = snapshot.showID else { return }
    revision += 1
    let record = SharedShowStore.Demand(showID: showID, requestID: UUID(), participantID: Self.participantID,
      writerID: writerID, revision: revision, updatedAt: Date(), relativePath: episode.path,
      hashString: episode.hashString, fileIndex: episode.fileIndex, cancelled: false)
    requestToken &+= 1
    requestState = SharedShowDownloadRequest(record: record)
    requestEpisode = episode
    requestRoot = root
    requestStatus = requestState?.status
    changed()
    publishRequest(record, episode: episode, root: root, token: requestToken)
  }

  var canRetryRequest: Bool { !requestBusy && requestState?.canRetry == true }
  var canWithdrawRequest: Bool { requestState?.canWithdraw == true }
  var requestFileName: String? { requestState?.record.relativePath.split(separator: "/").last.map(String.init) }

  func retryRequest() {
    guard canRetryRequest, let episode = requestEpisode, let root = requestRoot else { return }
    revision += 1
    requestToken &+= 1
    requestPollTimer?.invalidate(); requestPollTimer = nil
    let record = requestState!.advance(revision: revision, cancelled: false)
    requestStatus = requestState?.status
    changed()
    publishRequest(record, episode: episode, root: root, token: requestToken)
  }

  func withdrawRequest() {
    guard canWithdrawRequest, let episode = requestEpisode, let root = requestRoot else { return }
    revision += 1
    requestToken &+= 1
    requestPollTimer?.invalidate(); requestPollTimer = nil
    let record = requestState!.advance(revision: revision, cancelled: true)
    requestStatus = requestState?.status
    changed()
    publishRequest(record, episode: episode, root: root, token: requestToken)
  }

  private func publishRequest(_ record: SharedShowStore.Demand,
                              episode: ShowEpisodeIndexReader.Episode, root: URL, token: UInt64) {
    requestBusy = true
    let (lane, laneKey) = requestWorkScheduler.reserve(root)
    let releaseLane = requestWorkScheduler.release
    lane.addOperation { [weak self] in
      let succeeded: Bool
      do {
        let store = try SharedShowStore(root: root)
        if !record.cancelled {
          guard Date().timeIntervalSince(record.updatedAt) < ShowEpisodeIndexReader.freshnessLimit else {
            throw SharedShowStore.Failure.invalidRecord
          }
          try store.validateRequestPath(episode.path)
          // A retry revalidates the same transfer before publishing a newer
          // revision. A withdrawal remains possible when media has vanished.
          let catalog = try store.catalog(checkLocalFiles: false)
          guard catalog.showID == record.showID, catalog.episodes.contains(where: {
            !$0.ambiguous && $0.isFresh() && $0.path == episode.path &&
            $0.hashString == episode.hashString && $0.fileIndex == episode.fileIndex
          }) else { throw SharedShowStore.Failure.invalidRecord }
        }
        try store.publish(record)
        succeeded = true
      } catch { succeeded = false }
      DispatchQueue.main.async { [weak self] in
        releaseLane(laneKey)
        guard let self, self.requestToken == token,
              self.requestState?.record.revision == record.revision else { return }
        self.requestBusy = false
        self.requestState?.publicationFinished(for: record.revision, succeeded: succeeded)
        self.requestStatus = self.requestState?.status
        self.changed()
        if succeeded && !record.cancelled { self.scheduleRequestPoll() }
      }
    }
  }

  private func scheduleRequestPoll() {
    requestPollTimer?.invalidate(); requestPollTimer = nil
    requestState?.expireIfNeeded()
    requestStatus = requestState?.status
    guard requestState?.shouldPoll == true else { return }
    requestPollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.pollRequestReceipts() }
    }
    requestPollTimer?.tolerance = 1
    pollRequestReceipts()
  }

  private func pollRequestReceipts() {
    requestState?.expireIfNeeded()
    if requestState?.shouldPoll != true {
      requestPollTimer?.invalidate(); requestPollTimer = nil
      requestStatus = requestState?.status
      changed()
      return
    }
    guard !requestBusy, !requestPollBusy, let requestState,
          let root = requestRoot else { return }
    requestPollBusy = true
    let record = requestState.record
    let token = requestToken
    let (lane, laneKey) = requestWorkScheduler.reserve(root)
    let releaseLane = requestWorkScheduler.release
    lane.addOperation { [weak self] in
      let result: Result<[SharedShowStore.Receipt], Error>
      do { result = .success(try SharedShowStore(root: root).receipts(showID: record.showID,
                                                                    requestID: record.requestID)) }
      catch { result = .failure(error) }
      DispatchQueue.main.async { [weak self] in
        releaseLane(laneKey)
        guard let self else { return }
        self.requestPollBusy = false
        guard self.requestToken == token,
              self.requestState?.record.revision == record.revision else { return }
        switch result {
        case .success(let receipts): self.requestState?.observe(receipts, for: record.revision)
        case .failure: self.requestState?.receiptReadFailed(for: record.revision)
        }
        self.requestStatus = self.requestState?.status
        if self.requestState?.shouldPoll != true {
          self.requestPollTimer?.invalidate(); self.requestPollTimer = nil
        }
        self.changed()
      }
    }
  }

  func resume(_ record: SharedShowStore.Progress) {
    guard let player, player.info.state.loaded, let media = player.info.currentURL,
          media == contextMedia, record.showID == showID else { return }
    // Only offer a seek in the already-open file. No missing path enters mpv.
    guard record.relativePath == relativePath,
          let duration = player.info.videoDuration?.second, record.position < duration else { return }
    player.seek(absoluteSecond: record.position)
  }

  private func changed() {
    if let player { NotificationCenter.default.post(name: .yinaSharedShowChanged, object: player) }
  }
}
