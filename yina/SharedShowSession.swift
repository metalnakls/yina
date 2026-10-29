import AppKit

extension Notification.Name {
  static let yinaSharedShowChanged = Notification.Name("yinaSharedShowChanged")
}

/// One player owns one writer file. A single bounded queue handles all SMB work;
/// slow shares cannot accumulate timer jobs or block the UI thread.
@MainActor
final class SharedShowSession {
  private static let operations: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "YINASharedShows"
    queue.qualityOfService = .utility
    queue.maxConcurrentOperationCount = 1
    return queue
  }()
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
  private var revision: UInt64 = 0
  private var busy = false
  private var pendingFinal: Sample?
  private var pendingCurrent: Sample?
  private var lastSample: Sample?
  private var requestBusy = false
  private var applyingRemote = false
  private var lastControlCheckpoint: TimeInterval = 0
  private(set) var isHosting = false
  private(set) var followingWriter: UUID?
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
  }

  init(player: PlayerCore) { self.player = player }

  func start() {
    timer?.invalidate()
    generation += 1
    root = nil
    showID = nil
    relativePath = nil
    contextMedia = nil
    positions = []
    status = nil
    requestStatus = nil
    lastSample = nil
    pendingCurrent = nil
    // Following never crosses into a newly opened file without another choice.
    followingWriter = nil
    watchStatus = isHosting ? "Hosting Watch Together · \(writerID.uuidString.prefix(6))" : nil
    checkpoint()
    scheduleTimer()
  }

  private func scheduleTimer() {
    timer?.invalidate()
    let interval: TimeInterval = isHosting || followingWriter != nil ? 2 : 10
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkpoint() }
    }
    timer?.tolerance = interval / 10
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    checkpoint(stopped: true)
  }

  func saveFinal(media: URL?, position: Double?, duration: Double?) {
    timer?.invalidate()
    timer = nil
    guard let media, media.isFileURL, let position, let duration,
          position.isFinite, duration.isFinite, duration > 0 else { stop(); return }
    let sample = Sample(generation: generation, media: media, position: min(duration, max(0, position)),
                        duration: duration, activity: .stopped, date: Date())
    lastSample = sample
    enqueue(sample)
  }

  func checkpoint(stopped: Bool = false) {
    guard let player else { return }
    let sample: Sample
    if player.info.state.loaded, let media = player.info.currentURL, media.isFileURL {
      player.syncPositionIfNeeded()
      guard let position = player.info.videoPosition?.second, let duration = player.info.videoDuration?.second,
            position.isFinite, duration.isFinite, duration > 0 else { return }
      sample = Sample(generation: generation, media: media, position: min(duration, max(0, position)), duration: duration,
                      activity: stopped ? .stopped : player.info.state == .paused ? .paused : .playing,
                      date: Date(), rate: player.info.playSpeed, hosting: isHosting && !stopped)
      lastSample = sample
    } else if stopped, let lastSample {
      sample = Sample(generation: lastSample.generation, media: lastSample.media, position: lastSample.position, duration: lastSample.duration,
                      activity: .stopped, date: Date())
    } else { return }
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
    Self.operations.addOperation { [weak self] in
      var resolvedRoot: URL?
      var resolvedID: UUID?
      var resolvedPath: String?
      var positions: [SharedShowStore.Progress] = []
      var status: String?
      do {
        if let store = try SharedShowStore.discover(for: sample.media),
           let path = store.relativePath(for: sample.media) {
          let descriptor = try store.descriptor()
          resolvedRoot = store.root
          resolvedID = descriptor.showID
          resolvedPath = path
          // Capture other writers before writing this checkpoint. No other person's
          // position automatically overrides local watch-later or playback state.
          positions = try store.progress(showID: descriptor.showID).filter { $0.writerID != writer }
          try store.publish(.init(showID: descriptor.showID, participantID: participant, writerID: writer,
            revision: revision, updatedAt: sample.date, relativePath: path, position: sample.position,
            duration: sample.duration, activity: sample.activity, playbackRate: sample.rate, watchTogether: sample.hosting))
          status = "Progress saved to show folder"
        }
      } catch { status = "Shared progress unavailable; playback continues locally" }
      let result = (resolvedRoot, resolvedID, positions, status, resolvedPath)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.busy = false
        if self.generation == generation {
          self.root = result.0
          self.showID = result.1
          self.positions = result.2
          self.status = result.3
          self.relativePath = result.4
          self.contextMedia = sample.media
          self.synchronize()
          self.changed()
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
    followingWriter = nil
    isHosting = true
    watchStatus = "Hosting Watch Together · \(writerID.uuidString.prefix(6))"
    scheduleTimer()
    checkpoint()
    changed()
  }

  func follow(_ record: SharedShowStore.Progress) {
    guard record.showID == showID, record.relativePath == relativePath,
          record.writerID != writerID, SharedPlaybackSync.target(for: record) != nil else { return }
    isHosting = false
    followingWriter = record.writerID
    watchStatus = "Following host \(record.writerID.uuidString.prefix(6))"
    scheduleTimer()
    synchronize()
    checkpoint()
    changed()
  }

  func leaveWatchTogether() {
    isHosting = false
    followingWriter = nil
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

  private func synchronize() {
    guard let followingWriter, let player, player.info.state.loaded,
          player.info.currentURL == contextMedia else { return }
    let host = positions.first(where: { $0.writerID == followingWriter && $0.showID == showID })
    if let host, host.watchTogether != true || host.activity == .stopped {
      self.followingWriter = nil
      watchStatus = "The host ended Watch Together"
      scheduleTimer()
      return
    }
    guard let record = host,
          record.relativePath == relativePath,
          let target = SharedPlaybackSync.target(for: record),
          let position = player.info.videoPosition?.second,
          let duration = player.info.videoDuration?.second else {
      watchStatus = "Waiting for the host on this episode; playing locally"
      return
    }
    applyingRemote = true
    defer { applyingRemote = false }
    if target.paused && player.info.state != .paused { player.pause() }
    if abs(player.info.playSpeed - target.rate) > 0.001 { player.setSpeed(target.rate) }
    let destination = min(max(0, duration - 0.5), target.position)
    if abs(position - destination) > SharedPlaybackSync.seekTolerance { player.seek(absoluteSecond: destination) }
    if !target.paused && player.info.state == .paused { player.resume() }
    watchStatus = "Following host \(record.writerID.uuidString.prefix(6))"
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
      Self.operations.addOperation { [weak self] in
        let result: String
        do {
          let store = try SharedShowStore(root: root.resolvingSymlinksInPath())
          guard store.relativePath(for: media) != nil else { throw SharedShowStore.Failure.unsafePath }
          _ = try store.enable()
          result = "Shared progress enabled"
        } catch { result = "Couldn’t enable sharing in this folder" }
        DispatchQueue.main.async { [weak self] in
          guard let self, self.player?.info.currentURL == media else { return }
          self.status = result
          self.changed()
          self.checkpoint()
        }
      }
    }
  }

  func request(_ episode: ShowEpisodeIndexReader.Episode, snapshot: ShowEpisodeIndexReader.Snapshot) {
    guard !requestBusy, !episode.ambiguous, episode.isFresh(),
          let root = snapshot.root, let showID = snapshot.showID else { return }
    requestBusy = true
    let generation = generation
    revision += 1
    let record = SharedShowStore.Demand(showID: showID, requestID: UUID(), participantID: Self.participantID,
      writerID: writerID, revision: revision, updatedAt: Date(), relativePath: episode.path,
      hashString: episode.hashString, fileIndex: episode.fileIndex, cancelled: false)
    requestStatus = "Saving download request…"
    changed()
    Self.operations.addOperation { [weak self] in
      let message: String
      do {
        let store = try SharedShowStore(root: root)
        guard Date().timeIntervalSince(record.updatedAt) < ShowEpisodeIndexReader.freshnessLimit else {
          throw SharedShowStore.Failure.invalidRecord
        }
        try store.validateRequestPath(episode.path)
        // Revalidate the exact transfer and path immediately before publishing.
        let catalog = try store.catalog()
        guard catalog.showID == showID, catalog.episodes.contains(where: {
          !$0.ambiguous && $0.isFresh() && $0.path == episode.path &&
          $0.hashString == episode.hashString && $0.fileIndex == episode.fileIndex
        }) else { throw SharedShowStore.Failure.invalidRecord }
        try store.publish(record)
        message = "Request saved for Glass; waiting for availability"
      } catch { message = "Couldn’t save the download request" }
      DispatchQueue.main.async { [weak self] in
        self?.requestBusy = false
        if self?.generation == generation {
          self?.requestStatus = message
          self?.changed()
        }
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
