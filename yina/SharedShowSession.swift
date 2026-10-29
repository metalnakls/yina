import AppKit

extension Notification.Name {
  static let yinaSharedShowChanged = Notification.Name("yinaSharedShowChanged")
}

/// One player owns one writer file. Bounded lanes keep a stalled share from
/// blocking every other session while each session retains its write order.
@MainActor
final class SharedShowSession {
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
  private var generation = 0
  var generationToken: Int { generation }
  private var revision: UInt64 = 0
  private var busy = false
  private var pendingFinal: Sample?
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

  init(player: PlayerCore, requestWorkScheduler: RequestWorkScheduler? = nil) {
    self.player = player
    self.requestWorkScheduler = requestWorkScheduler ?? .init(reserve: Self.reserveLane,
                                                               release: Self.releaseLane)
  }

  deinit {
    timer?.invalidate()
    requestPollTimer?.invalidate()
  }

  func start() {
    timer?.invalidate()
    let media = player?.info.currentURL
    let remoteChange = followingWriter != nil && media.map { remoteMediaIntents.contains($0) } == true
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
      followingWriter.map { "Following host \($0.uuidString.prefix(6))" }
    checkpoint()
    scheduleTimer()
  }

  private func scheduleTimer() {
    timer?.invalidate()
    let interval: TimeInterval = isHosting ? 2 : followingWriter != nil ?
      (unavailableAttempts >= 3 ? 10 : 2) : membership?.root == nil && membership != nil ? 30 : 10
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkpoint(refreshPeers: false) }
    }
    timer?.tolerance = interval / 10
  }

  func stop() {
    if !endedByStopCommand && (isHosting || followingWriter != nil) {
      watchStatus = isHosting ? "Hosting Watch Together · waiting for next episode" :
        "Waiting for host's next episode"
      checkpoint(refreshPeers: false)
      scheduleTimer()
      changed()
      return
    }
    timer?.invalidate(); timer = nil
    isHosting = false
    checkpoint(stopped: true)
  }

  func fileEnded(dueToStopCommand: Bool) { endedByStopCommand = endedByStopCommand || dueToStopCommand }

  func localStopRequested() { endedByStopCommand = true }

  func saveFinal(media: URL?, position: Double?, duration: Double?, sourceGeneration: Int? = nil) {
    let sampleGeneration = sourceGeneration ??
      (player?.info.currentURL == media ? generation : generation - 1)
    // A final callback can arrive after a new file has started. Publishing it
    // then would replace the newer episode's single writer record on disk.
    guard sampleGeneration == generation else { return }
    timer?.invalidate()
    timer = nil
    guard let media, media.isFileURL, let position, let duration,
          position.isFinite, duration.isFinite, duration > 0 else {
      stop()
      return
    }
    let sample = Sample(generation: sampleGeneration, media: media, position: min(duration, max(0, position)),
                        duration: duration, activity: .stopped, date: Date())
    lastSample = sample
    enqueue(sample)
  }

  func checkpoint(stopped: Bool = false, refreshPeers: Bool = true) {
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
    let previousPositions = positions
    let previousBroadRefresh = lastBroadRefresh
    let following = followingWriter
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
      var publishedQueue: SharedShowStore.QueueRecord?
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
            if sample.hosting {
              var queueItems: [String] = []
              var seen: [String: Int] = [:]
              var queueBytes = 0
              for filename in sample.playlistPaths where filename.hasPrefix("/") && queueItems.count < 1_023 {
                guard let relative = store.relativePath(for: URL(fileURLWithPath: filename)),
                      relative != ".yina.json", relative.split(separator: "/").first != ".yina" else { continue }
                let key = relative.precomposedStringWithCanonicalMapping.lowercased()
                guard seen[key] == nil,
                      queueBytes + relative.utf8.count <= 256 * 1024 - path.utf8.count else { continue }
                seen[key] = queueItems.count
                queueItems.append(relative)
                queueBytes += relative.utf8.count
              }
              let currentKey = path.precomposedStringWithCanonicalMapping.lowercased()
              if let index = seen[currentKey] { queueItems[index] = path }
              else { queueItems.append(path) }
              let queue = SharedShowStore.QueueRecord(showID: showID, participantID: participant,
                writerID: writer, revision: revision, updatedAt: sample.date,
                items: queueItems, current: sample.awaitingNextEpisode ? nil : path)
              try store.publishQueue(queue)
              publishedQueue = queue
            }
            try store.publish(.init(showID: showID, participantID: participant, writerID: writer,
              revision: revision, updatedAt: sample.date, relativePath: path, position: sample.position,
              duration: sample.duration, activity: sample.activity, playbackRate: sample.rate, watchTogether: sample.hosting))
            published = true
          }
          status = "Progress saved to show folder"
        }
      } catch {
        nextMembership = Membership(root: nil, showID: nil, path: nil, expiresAt: sample.date.addingTimeInterval(10))
        status = "Shared progress unavailable; playback continues locally"
      }
      let result = (resolvedRoot, resolvedID, positions, status, resolvedPath, nextMembership,
                    broadRefresh, published, hostRecord, hostQueue, playableTarget, publishedQueue)
      DispatchQueue.main.async { [weak self] in
        Self.releaseLane(laneKey)
        guard let self else { return }
        self.busy = false
        if self.generation == generation {
          self.root = result.0
          self.showID = result.1
          self.positions = result.2
          self.status = result.3
          self.relativePath = result.4
          self.membership = result.5
          self.lastBroadRefresh = result.6
          if result.7 { self.lastPublished = sample }
          self.contextMedia = sample.media
          if self.isHosting, let queue = result.11 {
            self.hostQueueItems = queue.items
            self.hostQueueCurrent = queue.current
          }
          if self.remoteOpenGeneration == watchIntent {
            self.synchronize(host: result.8, queue: result.9, playableTarget: result.10)
          }
          self.changed()
          if self.timer != nil { self.scheduleTimer() }
        }
        if let final = self.pendingFinal {
          self.pendingFinal = nil
          self.submit(final)
        } else if let current = self.pendingCurrent {
          self.pendingCurrent = nil
          self.submit(current)
        }
      }
    }
  }

  func hostWatchTogether() {
    guard showID != nil else { return }
    clearFollowing()
    isHosting = true
    watchStatus = "Hosting Watch Together · \(writerID.uuidString.prefix(6))"
    scheduleTimer()
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
    isHosting = false
    clearFollowing()
    watchStatus = nil
    scheduleTimer()
    checkpoint()
    changed()
  }

  /// A local transport action takes control back. Remote actions call through
  /// the same PlayerCore API under the applyingRemote guard, preventing loops.
  func localControlChanged() {
    guard !applyingRemote else { return }
    if followingWriter != nil { leaveWatchTogether() }
    if isHosting, ProcessInfo.processInfo.systemUptime - lastControlCheckpoint >= 1 {
      lastControlCheckpoint = ProcessInfo.processInfo.systemUptime
      DispatchQueue.main.async { [weak self] in self?.checkpoint() }
    }
  }

  /// A local open or playlist edit is an explicit takeover. Remote opens call
  /// this through PlayerCore while applyingRemote is true.
  func localMediaChangeRequested() {
    guard !applyingRemote else { return }
    if followingWriter != nil { leaveWatchTogether() }
    else if isHosting { checkpoint() }
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

  /// Root selection is explicit. Opening a normal media file never creates a
  /// descriptor in a guessed season/library folder.
  func enableSharing(in window: NSWindow?) {
    guard let media = player?.info.currentURL, media.isFileURL else { return }
    Utility.quickOpenPanel(title: "Choose the Show Folder", chooseDir: true,
                          dir: media.deletingLastPathComponent(), sheetWindow: window) { [weak self] root in
      guard let self else { return }
      self.status = "Enabling shared progress…"
      self.changed()
      let (lane, laneKey) = Self.reserveLane(for: root)
      lane.addOperation { [weak self] in
        let result: String
        do {
          let store = try SharedShowStore(root: root.resolvingSymlinksInPath())
          guard store.relativePath(for: media) != nil else { throw SharedShowStore.Failure.unsafePath }
          _ = try store.enable()
          result = "Shared progress enabled"
        } catch { result = "Couldn’t enable sharing in this folder" }
        DispatchQueue.main.async { [weak self] in
          Self.releaseLane(laneKey)
          guard let self, self.player?.info.currentURL == media else { return }
          self.status = result
          self.membership = nil
          self.changed()
          self.checkpoint()
        }
      }
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
