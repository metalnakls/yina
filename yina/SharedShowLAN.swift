import AppKit
import Network

/// Host-clock projection and small, bounded speed correction. All times are
/// monotonic seconds; wall-clock dates never determine playback position.
enum SharedShowTimeline {
  static func projectedPosition(_ state: SharedShowLAN.State, atHostTime time: Double) -> Double {
    let elapsed: Double
    if state.paused || state.waitingForReady { elapsed = 0 }
    else { elapsed = max(0, time - max(state.hostTime, state.playAtHostTime ?? state.hostTime)) }
    return min(state.duration, max(0, state.position + elapsed * state.rate))
  }

  static func trimmedRate(baseRate: Double, expectedPosition: Double, actualPosition: Double) -> Double {
    let drift = expectedPosition - actualPosition
    guard baseRate.isFinite, baseRate > 0, drift.isFinite, abs(drift) > 0.008 else { return baseRate }
    return baseRate * (1 + min(0.01, max(-0.01, drift * 0.1)))
  }
}

extension Notification.Name {
  static let yinaSharedRoomsChanged = Notification.Name("yinaSharedRoomsChanged")
}

/// Ephemeral LAN transport. The .yina folder remains an archive and identity store;
/// discovery and live commands never wait for an SMB read.
@MainActor
final class SharedShowLAN {
  static let shared = SharedShowLAN()
  static let serviceType = "_yina-watch._tcp"
  private static let maximumFrame = 16 * 1024
  private static let maximumPeers = 8

  struct Room: Equatable {
    let id: UUID
    let showID: UUID
    let hostName: String
    let title: String
    let relativePath: String
    let position: Double
    let duration: Double
    let paused: Bool
    let rate: Double
  }

  struct State: Codable {
    var version = 6
    let roomID: UUID
    let showID: UUID
    let hostName: String
    let title: String
    var rootHint: String = ""
    let relativePath: String
    let position: Double
    let duration: Double
    let paused: Bool
    let rate: Double
    let revision: UInt64
    let emittedAt: Date
    let awaitingNextEpisode: Bool
    let epoch: UUID
    let hostTime: Double
    let playAtHostTime: Double?
    let barrierGeneration: UInt64
    let seekGeneration: UInt64
    let waitingForReady: Bool
    let userPaused: Bool

    init(roomID: UUID, showID: UUID, hostName: String, title: String, rootHint: String = "",
         relativePath: String, position: Double, duration: Double, paused: Bool, rate: Double,
         revision: UInt64, emittedAt: Date, awaitingNextEpisode: Bool,
         epoch: UUID? = nil, hostTime: Double = ProcessInfo.processInfo.systemUptime,
         playAtHostTime: Double? = nil, barrierGeneration: UInt64 = 0,
         seekGeneration: UInt64 = 0, waitingForReady: Bool = false, userPaused: Bool? = nil) {
      self.roomID = roomID
      self.showID = showID
      self.hostName = hostName
      self.title = title
      self.rootHint = rootHint
      self.relativePath = relativePath
      self.position = position
      self.duration = duration
      self.paused = paused
      self.rate = rate
      self.revision = revision
      self.emittedAt = emittedAt
      self.awaitingNextEpisode = awaitingNextEpisode
      self.epoch = epoch ?? roomID
      self.hostTime = hostTime
      self.playAtHostTime = playAtHostTime
      self.barrierGeneration = barrierGeneration
      self.seekGeneration = seekGeneration
      self.waitingForReady = waitingForReady
      self.userPaused = userPaused ?? paused
    }

    var isValid: Bool {
      version == 6 && SharedShowStore.safePath(relativePath) &&
        relativePath != ".yina.json" && relativePath.split(separator: "/").first != ".yina" &&
        hostName.utf8.count <= 120 && title.utf8.count <= 240 &&
        (rootHint.isEmpty || SharedShowStore.safePath(rootHint)) &&
        position.isFinite && duration.isFinite && duration > 0 && position >= 0 && position <= duration &&
        rate.isFinite && (0.1...8).contains(rate) && revision > 0 &&
        hostTime.isFinite && hostTime >= 0 &&
        (playAtHostTime == nil || (playAtHostTime!.isFinite && playAtHostTime! >= 0)) &&
        (!waitingForReady || paused)
    }
    var room: Room { Room(id: roomID, showID: showID, hostName: hostName,
                          title: title, relativePath: relativePath, position: position,
                          duration: duration, paused: paused, rate: rate) }
  }

  private struct Packet: Codable {
    enum Kind: String, Codable { case hello, state, command, switchEpisode, goodbye, ack, incompatible, ping, pong, readiness }
    let version: Int
    let kind: Kind
    let roomID: UUID
    var state: State? = nil
    var commandID: UUID? = nil
    var expectedPath: String? = nil
    var sentAt: Double? = nil
    var receivedAt: Double? = nil
    var respondedAt: Double? = nil
    var ready: Bool? = nil
    var generation: UInt64? = nil
    var accepted: Bool? = nil
  }

  private struct VersionEnvelope: Decodable {
    let version: Int
    let roomID: UUID
  }

  // NW callbacks hop to MainActor before touching this mutable connection state.
  private final class Peer: @unchecked Sendable {
    let id = UUID()
    let connection: NWConnection
    let endpoint: NWEndpoint?
    var joined = false
    var lastSeen = Date()
    var sending = false
    var pending: [Packet] = []
    init(_ connection: NWConnection, endpoint: NWEndpoint? = nil) {
      self.connection = connection
      self.endpoint = endpoint
    }
  }

  // Every Network.framework callback enters on the main queue, matching the
  // session's actor isolation. Filesystem resolution runs on a utility lane.
  private let queue = DispatchQueue.main
  private var browser: NWBrowser?
  private var listener: NWListener?
  private var hostSession: SharedShowSession?
  private var hostState: State?
  private var hostPeers: [ObjectIdentifier: Peer] = [:]
  private var probes: [NWEndpoint: Peer] = [:]
  private var incompatibleEndpoints: Set<NWEndpoint> = []
  private var endpoints: [UUID: NWEndpoint] = [:]
  private var discovered: [UUID: (room: Room, seen: Date)] = [:]
  private var client: Peer?
  private var clientSession: SharedShowSession?
  private var clientRoomID: UUID?
  private var clientShowID: UUID?
  private var acceptedRevision: UInt64 = 0
  private var acceptedEpoch: UUID?
  private var acceptedBarrierGeneration: UInt64?
  private var clock = SharedShowClock()
  private var clockResetAt: Double?
  private var pingTimer: Timer?
  private var lastPingTick: Double?
  private var latestClientState: State?
  private var seenCommands: [(id: UUID, accepted: Bool)] = []
  private var hostCommandBusy = false
  private var hostCommandInFlightID: UUID?
  private var hostCommandInFlightPeer: Peer?
  private var hostCommandInFlightRoomID: UUID?
  private var hostCommandToken: UUID?
  private var hostCommandQueue: [(peer: Peer, packet: Packet)] = []
  private var clientControlQueue: [Packet] = []
  private var clientControlSentAt: Double?
  private var clientControlLastRetry: Double?
  private var clientControlTimer: Timer?
  private var sweepTimer: Timer?
  private var wakeObserver: NSObjectProtocol?
  private static let mediaQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "YINASharedRoomMedia"
    queue.qualityOfService = .utility
    queue.maxConcurrentOperationCount = 2
    return queue
  }()

  var rooms: [Room] {
    return discovered.values.map(\.room).sorted {
      $0.hostName.localizedStandardCompare($1.hostName) == .orderedAscending
    }
  }

  var clockUncertainty: Double? { clock.uncertainty }
  /// A clock estimate coarser than 12 ms cannot support near-frame playback.
  static func clockReadyForPlayback(_ estimate: SharedShowClock) -> Bool {
    estimate.calibrated && (estimate.uncertainty ?? .infinity) <= 0.012
  }
  var clockCalibrated: Bool { Self.clockReadyForPlayback(clock) }
  var clockReadyForPlayback: Bool { clockCalibrated }
  var incompatibleHostCount: Int { incompatibleEndpoints.count }
  var pendingControlCount: Int { clientControlQueue.count }

  private init() {
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.handleWake() }
    }
  }

  private func handleWake() {
    if hostSession != nil { hostSession?.lanHostWoke() }
    invalidateClientClock()
  }

  private func invalidateClientClock() {
    guard let client, let roomID = clientRoomID else { return }
    clock = SharedShowClock()
    clockResetAt = ProcessInfo.processInfo.systemUptime
    clientSession?.lanClockInvalidated()
    let now = ProcessInfo.processInfo.systemUptime
    lastPingTick = now
    send(Packet(version: 6, kind: .ping, roomID: roomID, sentAt: now), to: client)
  }

  func estimatedHostTime(at localTime: Double = ProcessInfo.processInfo.systemUptime) -> Double? {
    clock.hostTime(at: localTime)
  }

  func startDiscovery() {
    guard browser == nil else { return }
    let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
    self.browser = browser
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      Task { @MainActor in self?.browserChanged(results) }
    }
    browser.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        if case .failed = state { self?.browser = nil; browser.cancel() }
      }
    }
    browser.start(queue: queue)
    sweepTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.pruneRooms() }
    }
  }

  private func browserChanged(_ results: Set<NWBrowser.Result>) {
    let active = Set(results.map(\.endpoint))
    for endpoint in probes.keys where !active.contains(endpoint) {
      probes.removeValue(forKey: endpoint)?.connection.cancel()
      incompatibleEndpoints.remove(endpoint)
      for (id, stored) in endpoints where stored == endpoint {
        endpoints.removeValue(forKey: id)
        discovered.removeValue(forKey: id)
      }
    }
    incompatibleEndpoints.formIntersection(active)
    for result in results.prefix(Self.maximumPeers) where probes[result.endpoint] == nil {
      let connection = NWConnection(to: result.endpoint, using: .tcp)
      let peer = Peer(connection, endpoint: result.endpoint)
      probes[result.endpoint] = peer
      connection.stateUpdateHandler = { [weak self, weak peer] state in
        Task { @MainActor in
          guard let self, let peer else { return }
          switch state {
          case .ready:
            self.send(Packet(version: 6, kind: .hello, roomID: UUID()), to: peer)
            self.receive(on: peer) { [weak self] packet in self?.probeReceived(packet, from: peer) }
          case .failed, .cancelled:
            self.probes.removeValue(forKey: result.endpoint)
          default: break
          }
        }
      }
      connection.start(queue: queue)
    }
    changed()
  }

  private func probeReceived(_ packet: Packet, from peer: Peer) {
    guard packet.kind == .state, let state = packet.state, state.isValid,
          let endpoint = peer.endpoint, probes[endpoint] === peer,
          state.roomID == packet.roomID else { return }
    discovered[state.roomID] = (state.room, Date())
    endpoints[state.roomID] = endpoint
    peer.lastSeen = Date()
    changed()
  }

  private func pruneRooms() {
    let stale = discovered.filter { Date().timeIntervalSince($0.value.seen) > 8 }.map(\.key)
    guard !stale.isEmpty else { return }
    for id in stale { discovered.removeValue(forKey: id); endpoints.removeValue(forKey: id) }
    changed()
  }

  func host(session: SharedShowSession, state: State) {
    guard state.isValid else { return }
    if hostSession !== session || hostState?.roomID != state.roomID {
      if hostSession !== session { hostSession?.yieldLANHosting() }
      stopHosting()
      hostSession = session
      do {
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(name: "YINA-\(state.roomID.uuidString.prefix(8))", type: Self.serviceType)
        listener.newConnectionHandler = { [weak self] connection in
          Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] status in
          Task { @MainActor in if case .failed = status { self?.stopHosting() } }
        }
        self.listener = listener
        listener.start(queue: queue)
      } catch {
        hostSession = nil
        return
      }
    }
    hostState = state
    broadcast(state)
  }

  func stopHosting() {
    if let state = hostState {
      let packet = Packet(version: 6, kind: .goodbye, roomID: state.roomID)
      for peer in hostPeers.values { send(packet, to: peer) }
    }
    listener?.cancel(); listener = nil
    for peer in hostPeers.values { peer.connection.cancel() }
    hostPeers.removeAll()
    hostSession = nil
    hostState = nil
    seenCommands.removeAll()
    hostCommandQueue.removeAll()
    hostCommandBusy = false
    hostCommandInFlightID = nil
    hostCommandInFlightPeer = nil
    hostCommandInFlightRoomID = nil
    hostCommandToken = nil
  }

  private func accept(_ connection: NWConnection) {
    guard hostPeers.count < Self.maximumPeers else { connection.cancel(); return }
    let peer = Peer(connection)
    let key = ObjectIdentifier(peer)
    hostPeers[key] = peer
    connection.stateUpdateHandler = { [weak self, weak peer] status in
      Task { @MainActor in
        guard let self, let peer else { return }
        switch status {
        case .ready:
          self.receive(on: peer) { [weak self] packet in self?.hostReceived(packet, from: peer) }
        case .failed, .cancelled: self.connectionEnded(peer)
        default: break
        }
      }
    }
    connection.start(queue: queue)
  }

  private func hostReceived(_ packet: Packet, from peer: Peer) {
    guard let current = hostState else { return }
    switch packet.kind {
    case .hello:
      peer.joined = packet.roomID == current.roomID
      if peer.joined {
        hostSession?.lanPeerReadinessChanged(ready: false, generation: current.barrierGeneration, peerID: peer.id)
      }
      if let latest = hostState {
        send(Packet(version: 6, kind: .state, roomID: latest.roomID, state: latest), to: peer)
      }
    case .command, .switchEpisode:
      guard peer.joined, packet.roomID == current.roomID,
            let id = packet.commandID else { return }
      if let prior = seenCommands.first(where: { $0.id == id }) {
        send(Packet(version: 6, kind: .ack, roomID: current.roomID,
                    commandID: id, accepted: prior.accepted), to: peer)
        return
      }
      if hostCommandInFlightID == id || hostCommandQueue.contains(where: { $0.packet.commandID == id }) {
        return
      }
      if hostCommandBusy, packet.kind == .command,
         let command = packet.state, command.isValid, command.userPaused,
         command.showID == current.showID, command.epoch == current.epoch,
         let interruptedID = hostCommandInFlightID,
         let interruptedPeer = hostCommandInFlightPeer,
         let interruptedRoomID = hostCommandInFlightRoomID {
        hostCommandQueue.insert((peer, packet), at: 0)
        hostCommandToken = nil // Late completion cannot revive the interrupted action.
        hostSession?.cancelLANCommand(stopSubmittedOpen: true)
        finishHostCommand(interruptedID, accepted: false, peer: interruptedPeer,
                          roomID: interruptedRoomID)
        return
      }
      hostCommandQueue.append((peer, packet))
      guard hostCommandQueue.count <= 32 else { connectionEnded(peer); return }
      drainHostCommands()
    case .ping:
      guard peer.joined, packet.roomID == current.roomID, let origin = packet.sentAt else { return }
      let received = ProcessInfo.processInfo.systemUptime
      send(Packet(version: 6, kind: .pong, roomID: current.roomID,
                  sentAt: origin, receivedAt: received,
                  respondedAt: ProcessInfo.processInfo.systemUptime), to: peer)
    case .readiness:
      guard peer.joined, packet.roomID == current.roomID,
            let ready = packet.ready, let generation = packet.generation,
            generation == current.barrierGeneration else { return }
      hostSession?.lanPeerReadinessChanged(ready: ready, generation: generation, peerID: peer.id)
    case .state, .goodbye, .ack, .incompatible, .pong: break
    }
  }

  private func drainHostCommands() {
    guard !hostCommandBusy, !hostCommandQueue.isEmpty else { return }
    let (peer, packet) = hostCommandQueue.removeFirst()
    guard let id = packet.commandID else { drainHostCommands(); return }
    hostCommandBusy = true
    hostCommandInFlightID = id
    hostCommandInFlightPeer = peer
    hostCommandInFlightRoomID = packet.roomID
    let token = UUID()
    hostCommandToken = token
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self, weak peer] in
      guard let self, let peer, self.hostCommandToken == token else { return }
      self.hostSession?.cancelLANCommand(stopSubmittedOpen: true)
      self.finishHostCommand(id, accepted: false, peer: peer, roomID: packet.roomID)
    }
    guard let current = hostState, peer.joined, hostPeers[ObjectIdentifier(peer)] === peer,
          packet.roomID == current.roomID, let incoming = packet.state, incoming.isValid,
          incoming.showID == current.showID, incoming.roomID == current.roomID,
          incoming.epoch == current.epoch, incoming.revision <= current.revision,
          (packet.kind == .command &&
             (incoming.relativePath == current.relativePath || incoming.userPaused) ||
           packet.kind == .switchEpisode && packet.expectedPath == current.relativePath &&
             incoming.relativePath != current.relativePath) else {
      finishHostCommand(id, accepted: false, peer: peer, roomID: packet.roomID)
      return
    }
    let command: State
    if incoming.userPaused && packet.kind == .command &&
       incoming.relativePath != current.relativePath {
      // A pause may pass an episode switch in flight. It always pauses the
      // host's current episode; it must never reopen the old path.
      command = State(roomID: current.roomID, showID: current.showID,
        hostName: current.hostName, title: current.title, rootHint: current.rootHint,
        relativePath: current.relativePath, position: current.position,
        duration: current.duration, paused: true, rate: incoming.rate,
        revision: incoming.revision, emittedAt: Date(), awaitingNextEpisode: false,
        epoch: current.epoch, hostTime: current.hostTime,
        barrierGeneration: current.barrierGeneration,
        seekGeneration: current.seekGeneration, userPaused: true)
    } else { command = incoming }
    hostSession?.applyLANCommand(command) { [weak self] applied in
      guard let self, self.hostCommandToken == token else { return }
      guard applied, let latest = self.hostState, latest.roomID == current.roomID,
            latest.epoch == current.epoch,
            (latest.relativePath == current.relativePath || latest.revision == current.revision),
            let canonical = self.hostSession?.canonicalLANCommand(command,
              revision: latest.revision + 1) else {
        self.finishHostCommand(id, accepted: false, peer: peer, roomID: current.roomID)
        return
      }
      self.hostState = canonical
      self.hostSession?.acceptLANCommand(canonical, revision: canonical.revision)
      self.broadcast(canonical)
      self.hostSession?.checkpoint()
      self.finishHostCommand(id, accepted: true, peer: peer, roomID: current.roomID)
    }
    if hostSession == nil { finishHostCommand(id, accepted: false, peer: peer, roomID: current.roomID) }
  }

  private func finishHostCommand(_ id: UUID, accepted: Bool, peer: Peer, roomID: UUID) {
    seenCommands.append((id, accepted))
    if seenCommands.count > 256 { seenCommands.removeFirst(seenCommands.count - 256) }
    if hostPeers[ObjectIdentifier(peer)] === peer {
      send(Packet(version: 6, kind: .ack, roomID: roomID,
                  commandID: id, accepted: accepted), to: peer)
    }
    hostCommandBusy = false
    hostCommandInFlightID = nil
    hostCommandInFlightPeer = nil
    hostCommandInFlightRoomID = nil
    hostCommandToken = nil
    drainHostCommands()
  }

  @discardableResult func join(_ room: Room, player: PlayerCore) -> Bool {
    if client != nil && clientRoomID == room.id { return true }
    guard let endpoint = endpoints[room.id], discovered[room.id] != nil else { return false }
    leave()
    let connection = NWConnection(to: endpoint, using: .tcp)
    let peer = Peer(connection, endpoint: endpoint)
    client = peer
    clientSession = player.sharedShow
    clientRoomID = room.id
    clientShowID = room.showID
    acceptedRevision = 0
    acceptedEpoch = nil
    acceptedBarrierGeneration = nil
    clock = SharedShowClock()
    clockResetAt = nil
    latestClientState = nil
    lastPingTick = nil
    player.sharedShow.beginLANFollow(room)
    connection.stateUpdateHandler = { [weak self, weak peer] status in
      Task { @MainActor in
        guard let self, let peer, self.client === peer else { return }
        switch status {
        case .ready:
          self.send(Packet(version: 6, kind: .hello, roomID: room.id), to: peer)
          self.receive(on: peer) { [weak self] packet in self?.clientReceived(packet, from: peer) }
          self.startPinging(peer)
        case .failed, .cancelled:
          self.disconnectClient("The host disconnected")
        default: break
        }
      }
    }
    connection.start(queue: queue)
    return true
  }

  private func clientReceived(_ packet: Packet, from peer: Peer) {
    guard client === peer, packet.roomID == clientRoomID else { return }
    if packet.kind == .incompatible {
      disconnectClient("Watch Together requires YINA 6 on both Macs")
      return
    }
    if packet.kind == .goodbye { disconnectClient("The host ended Watch Together"); return }
    if packet.kind == .ack, let id = packet.commandID,
       clientControlQueue.first?.commandID == id {
      guard packet.accepted == true else {
        disconnectClient("The host rejected a Watch Together control")
        return
      }
      clientControlQueue.removeFirst()
      clientControlSentAt = nil
      clientControlLastRetry = nil
      drainClientControl()
      return
    }
    if packet.kind == .pong, let t0 = packet.sentAt, let t1 = packet.receivedAt,
       let t2 = packet.respondedAt {
      if let clockResetAt, t0 < clockResetAt { return }
      let wasCalibrated = clockReadyForPlayback
      clock.observe(clientSend: t0, hostReceive: t1, hostSend: t2,
                    clientReceive: ProcessInfo.processInfo.systemUptime)
      if acceptedRevision > 0 {
        if wasCalibrated && !clockReadyForPlayback { clientSession?.lanClockInvalidated() }
        if !wasCalibrated && clockReadyForPlayback { clientSession?.lanClockCalibrated() }
      }
      return
    }
    guard packet.kind == .state, let state = packet.state, state.isValid,
          state.showID == clientShowID,
          state.roomID == packet.roomID, state.revision > acceptedRevision else { return }
    if let acceptedEpoch, acceptedEpoch != state.epoch {
      disconnectClient("The host restarted Watch Together; join the room again")
      return
    }
    acceptedEpoch = state.epoch
    if acceptedBarrierGeneration != state.barrierGeneration {
      acceptedBarrierGeneration = state.barrierGeneration
      clock = SharedShowClock()
      let now = ProcessInfo.processInfo.systemUptime
      clockResetAt = now
      send(Packet(version: 6, kind: .ping, roomID: packet.roomID, sentAt: now), to: peer)
    }
    clock.seed(hostTime: state.hostTime, localReceive: ProcessInfo.processInfo.systemUptime)
    acceptedRevision = state.revision
    latestClientState = state
    clientSession?.applyLANState(state)
  }

  func sendClientControl(_ state: State, switchEpisode: Bool = false,
                         expectedPath: String? = nil) {
    guard client != nil, let roomID = clientRoomID, roomID == state.roomID,
          acceptedRevision > 0 else { return }
    let urgentPause = state.userPaused && !clientControlQueue.isEmpty
    var command = state
    command = State(roomID: state.roomID, showID: state.showID, hostName: state.hostName,
                    title: state.title, rootHint: state.rootHint,
                    relativePath: state.relativePath, position: state.position,
                    duration: state.duration, paused: state.paused, rate: state.rate,
                    revision: acceptedRevision, emittedAt: Date(), awaitingNextEpisode: false,
                    epoch: state.epoch, hostTime: ProcessInfo.processInfo.systemUptime,
                    playAtHostTime: state.playAtHostTime,
                    barrierGeneration: state.barrierGeneration,
                    seekGeneration: state.seekGeneration,
                    waitingForReady: state.waitingForReady, userPaused: state.userPaused)
    if urgentPause {
      // A user pause outranks an episode open or seek still awaiting its ACK.
      // Address the host's current path if that earlier action was a switch.
      if let current = latestClientState, current.relativePath != command.relativePath {
        command = State(roomID: state.roomID, showID: state.showID,
          hostName: state.hostName, title: current.title, rootHint: state.rootHint,
          relativePath: current.relativePath, position: current.position,
          duration: current.duration, paused: true, rate: state.rate,
          revision: acceptedRevision, emittedAt: Date(), awaitingNextEpisode: false,
          epoch: current.epoch, seekGeneration: current.seekGeneration,
          userPaused: true)
      }
      clientControlQueue.removeAll()
      clientControlSentAt = nil
      clientControlLastRetry = nil
    }
    clientControlQueue.append(Packet(version: 6,
      kind: switchEpisode && !urgentPause ? .switchEpisode : .command,
      roomID: roomID, state: command, commandID: UUID(),
      expectedPath: switchEpisode && !urgentPause ? expectedPath : nil))
    guard clientControlQueue.count <= 32 else {
      disconnectClient("Too many Watch Together controls are waiting for the host")
      return
    }
    drainClientControl()
  }

  private func drainClientControl() {
    guard let client, let packet = clientControlQueue.first else {
      clientControlTimer?.invalidate(); clientControlTimer = nil
      return
    }
    guard clientControlSentAt == nil else { return }
    send(packet, to: client)
    clientControlSentAt = ProcessInfo.processInfo.systemUptime
    clientControlLastRetry = clientControlSentAt
    if clientControlTimer == nil {
      clientControlTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, let client = self.client,
                let packet = self.clientControlQueue.first,
                let sentAt = self.clientControlSentAt else { return }
          let age = ProcessInfo.processInfo.systemUptime - sentAt
          if age > 30 {
            self.disconnectClient("The host did not acknowledge a Watch Together control")
          } else if age > 3 && ProcessInfo.processInfo.systemUptime -
                      (self.clientControlLastRetry ?? sentAt) >= 3 {
            self.send(packet, to: client)
            self.clientControlLastRetry = ProcessInfo.processInfo.systemUptime
          }
        }
      }
    }
  }

  func leave() {
    pingTimer?.invalidate(); pingTimer = nil
    clientControlTimer?.invalidate(); clientControlTimer = nil
    clientControlQueue.removeAll(); clientControlSentAt = nil; clientControlLastRetry = nil
    client?.connection.cancel()
    client = nil
    clientSession = nil
    clientRoomID = nil
    clientShowID = nil
    acceptedRevision = 0
    acceptedEpoch = nil
    acceptedBarrierGeneration = nil
    clock = SharedShowClock()
    clockResetAt = nil
    latestClientState = nil
    lastPingTick = nil
  }

  func reportLocalReadiness(ready: Bool, generation: UInt64) {
    guard let client, let roomID = clientRoomID, acceptedRevision > 0 else { return }
    if ready && !clockReadyForPlayback { return }
    send(Packet(version: 6, kind: .readiness, roomID: roomID,
                ready: ready, generation: generation), to: client)
  }

  private func startPinging(_ peer: Peer) {
    pingTimer?.invalidate()
    guard let roomID = clientRoomID else { return }
    send(Packet(version: 6, kind: .ping, roomID: roomID,
                sentAt: ProcessInfo.processInfo.systemUptime), to: peer)
    lastPingTick = ProcessInfo.processInfo.systemUptime
    pingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self, weak peer] _ in
      MainActor.assumeIsolated {
        guard let self, let peer, self.client === peer, let roomID = self.clientRoomID else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let previous = self.lastPingTick, now - previous > 8 {
          self.invalidateClientClock()
          return
        }
        self.lastPingTick = now
        self.send(Packet(version: 6, kind: .ping, roomID: roomID,
                         sentAt: now), to: peer)
      }
    }
  }

  /// The user has chosen this room before any file is examined. Look for its
  /// identity on this Mac's mounts; never use a path supplied by the host.
  func resolve(_ state: State, preferredRoot: URL?, completion: @escaping (URL?) -> Void) {
    guard state.isValid else { completion(nil); return }
    let recentRoots = ShowFolderSnapshotStore.loadCards().map(\.folderURL)
    Self.mediaQueue.addOperation {
      var seen = Set<String>()
      var resolved: URL?
      func tryRoot(_ candidate: URL) -> Bool {
        guard seen.insert(candidate.path).inserted else { return false }
        guard let store = try? SharedShowStore(root: candidate),
              (try? store.descriptor().showID) == state.showID else { return false }
        resolved = try? store.resolvePlayable(path: state.relativePath, showID: state.showID)
        return resolved != nil
      }
      if let preferredRoot { _ = tryRoot(preferredRoot) }
      if resolved == nil && !state.rootHint.isEmpty {
        let mounts = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                            options: [.skipHiddenVolumes]) ?? []
        for mount in mounts where resolved == nil {
          _ = tryRoot(mount.appendingPathComponent(state.rootHint, isDirectory: true))
        }
      }
      for root in recentRoots where resolved == nil { _ = tryRoot(root) }
      if resolved == nil {
        let mounts = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                            options: [.skipHiddenVolumes]) ?? []
        var frontier = mounts.sorted { ($0.path.hasPrefix("/Volumes/") ? 0 : 1) <
                                       ($1.path.hasPrefix("/Volumes/") ? 0 : 1) }.map { ($0, 0) }
        var cursor = 0
        while cursor < frontier.count && cursor < 512 && resolved == nil {
          let (folder, depth) = frontier[cursor]
          cursor += 1
          if tryRoot(folder) { break }
          guard depth < 7, let children = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
          for child in children.prefix(128) where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if frontier.count >= 512 { break }
            frontier.append((child, depth + 1))
          }
        }
      }
      DispatchQueue.main.async { completion(resolved) }
    }
  }

  private func disconnectClient(_ status: String) {
    guard client != nil else { return }
    pingTimer?.invalidate(); pingTimer = nil
    clientControlTimer?.invalidate(); clientControlTimer = nil
    clientControlQueue.removeAll(); clientControlSentAt = nil
    client?.connection.cancel()
    client = nil
    clientRoomID = nil
    clientShowID = nil
    acceptedRevision = 0
    acceptedEpoch = nil
    acceptedBarrierGeneration = nil
    clock = SharedShowClock()
    clockResetAt = nil
    latestClientState = nil
    lastPingTick = nil
    let session = clientSession
    clientSession = nil
    session?.endLANFollow(status)
  }

  private func broadcast(_ state: State) {
    let packet = Packet(version: 6, kind: .state, roomID: state.roomID, state: state)
    for peer in hostPeers.values where peer.joined { send(packet, to: peer) }
    for peer in hostPeers.values where !peer.joined {
      send(packet, to: peer)
    }
  }

  private func send(_ packet: Packet, to peer: Peer) {
    // Only snapshots are replaceable. Commands, readiness, and handshakes stay
    // in order; an overloaded connection fails visibly instead of losing one.
    if packet.kind == .state { peer.pending.removeAll { $0.kind == .state } }
    peer.pending.append(packet)
    guard peer.pending.count <= 64 else { peer.connection.cancel(); return }
    drain(peer)
  }

  private func drain(_ peer: Peer) {
    guard !peer.sending, !peer.pending.isEmpty else { return }
    let packet = peer.pending.removeFirst()
    guard let data = try? JSONEncoder().encode(packet), data.count <= Self.maximumFrame else {
      peer.connection.cancel()
      return
    }
    var length = UInt32(data.count).bigEndian
    var frame = withUnsafeBytes(of: &length) { Data($0) }
    frame.append(data)
    peer.sending = true
    peer.connection.send(content: frame, completion: .contentProcessed { [weak self, weak peer] error in
      Task { @MainActor in
        guard let self, let peer else { return }
        peer.sending = false
        if error != nil { peer.connection.cancel() }
        else { self.drain(peer) }
      }
    })
  }

  private func receive(on peer: Peer, handler: @escaping (Packet) -> Void) {
    read(4, from: peer.connection) { [weak self, weak peer] header in
      guard let self, let peer else { return }
      guard let header else { self.connectionEnded(peer); return }
      let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      guard length > 0, length <= Self.maximumFrame else { self.connectionEnded(peer); return }
      self.read(Int(length), from: peer.connection) { [weak self, weak peer] data in
        guard let self, let peer else { return }
        guard let data else { self.connectionEnded(peer); return }
        guard let envelope = try? JSONDecoder().decode(VersionEnvelope.self, from: data) else {
          self.connectionEnded(peer)
          return
        }
        guard envelope.version == 6 else {
          if self.client === peer {
            self.disconnectClient("Watch Together requires YINA 6 on both Macs")
          } else if let endpoint = peer.endpoint, self.probes[endpoint] === peer {
            self.incompatibleEndpoints.insert(endpoint)
            self.changed()
            peer.connection.cancel()
          } else {
            self.send(Packet(version: 6, kind: .incompatible, roomID: envelope.roomID), to: peer)
            // Let the incompatibility frame enter the network stack first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { peer.connection.cancel() }
          }
          return
        }
        guard let packet = try? JSONDecoder().decode(Packet.self, from: data) else {
          self.connectionEnded(peer)
          return
        }
        handler(packet)
        self.receive(on: peer, handler: handler)
      }
    }
  }

  private func connectionEnded(_ peer: Peer) {
    if client === peer { disconnectClient("The host disconnected") }
    if let endpoint = peer.endpoint, probes[endpoint] === peer {
      probes.removeValue(forKey: endpoint)
      for (id, value) in endpoints where value == endpoint {
        endpoints.removeValue(forKey: id)
        discovered.removeValue(forKey: id)
      }
      changed()
    }
    hostCommandQueue.removeAll { $0.peer === peer }
    let interrupted = hostCommandInFlightPeer === peer
    if interrupted { hostCommandToken = nil }
    if hostPeers.removeValue(forKey: ObjectIdentifier(peer)) != nil, peer.joined {
      hostSession?.lanPeerDisconnected(peerID: peer.id)
    }
    if interrupted, let id = hostCommandInFlightID,
       let roomID = hostCommandInFlightRoomID {
      hostSession?.cancelLANCommand(stopSubmittedOpen: true)
      finishHostCommand(id, accepted: false, peer: peer, roomID: roomID)
    }
    peer.connection.cancel()
  }

  private func read(_ count: Int, from connection: NWConnection, collected: Data = Data(),
                    completion: @escaping (Data?) -> Void) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: count - collected.count) {
      [weak self] data, _, complete, error in
      Task { @MainActor in
        guard let self, error == nil, !complete else { completion(nil); return }
        var result = collected
        if let data { result.append(data) }
        if result.count == count { completion(result) }
        else if result.count < count { self.read(count, from: connection, collected: result, completion: completion) }
        else { completion(nil) }
      }
    }
  }

  private func changed() {
    NotificationCenter.default.post(name: .yinaSharedRoomsChanged, object: self)
  }
}
