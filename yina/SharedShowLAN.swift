import AppKit
import Network

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
    var version = 1
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

    var isValid: Bool {
      version == 1 && SharedShowStore.safePath(relativePath) &&
        relativePath != ".yina.json" && relativePath.split(separator: "/").first != ".yina" &&
        hostName.utf8.count <= 120 && title.utf8.count <= 240 &&
        (rootHint.isEmpty || SharedShowStore.safePath(rootHint)) &&
        position.isFinite && duration.isFinite && duration > 0 && position >= 0 && position <= duration &&
        rate.isFinite && (0.1...8).contains(rate) && revision > 0 &&
        abs(emittedAt.timeIntervalSinceNow) < 15
    }
    var room: Room { Room(id: roomID, showID: showID, hostName: hostName,
                          title: title, relativePath: relativePath, position: position,
                          duration: duration, paused: paused, rate: rate) }
  }

  private struct Packet: Codable {
    enum Kind: String, Codable { case hello, state, command, switchEpisode, goodbye }
    let version: Int
    let kind: Kind
    let roomID: UUID
    var state: State? = nil
    var commandID: UUID? = nil
  }

  // NW callbacks hop to MainActor before touching this mutable connection state.
  private final class Peer: @unchecked Sendable {
    let connection: NWConnection
    let endpoint: NWEndpoint?
    var joined = false
    var lastSeen = Date()
    var outstandingFrames = 0
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
  private var endpoints: [UUID: NWEndpoint] = [:]
  private var discovered: [UUID: (room: Room, seen: Date)] = [:]
  private var client: Peer?
  private var clientSession: SharedShowSession?
  private var clientRoomID: UUID?
  private var clientShowID: UUID?
  private var acceptedRevision: UInt64 = 0
  private var seenCommands: [UUID] = []
  private var sweepTimer: Timer?
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
      for (id, stored) in endpoints where stored == endpoint {
        endpoints.removeValue(forKey: id)
        discovered.removeValue(forKey: id)
      }
    }
    for result in results.prefix(Self.maximumPeers) where probes[result.endpoint] == nil {
      let connection = NWConnection(to: result.endpoint, using: .tcp)
      let peer = Peer(connection, endpoint: result.endpoint)
      probes[result.endpoint] = peer
      connection.stateUpdateHandler = { [weak self, weak peer] state in
        Task { @MainActor in
          guard let self, let peer else { return }
          switch state {
          case .ready:
            self.send(Packet(version: 1, kind: .hello, roomID: UUID()), to: peer)
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
      let packet = Packet(version: 1, kind: .goodbye, roomID: state.roomID)
      for peer in hostPeers.values { send(packet, to: peer) }
    }
    listener?.cancel(); listener = nil
    for peer in hostPeers.values { peer.connection.cancel() }
    hostPeers.removeAll()
    hostSession = nil
    hostState = nil
    seenCommands.removeAll()
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
        case .failed, .cancelled: self.hostPeers.removeValue(forKey: key)
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
      send(Packet(version: 1, kind: .state, roomID: current.roomID, state: current), to: peer)
    case .command, .switchEpisode:
      guard peer.joined, packet.roomID == current.roomID,
            let command = packet.state, command.isValid,
            command.showID == current.showID, command.roomID == current.roomID,
            let id = packet.commandID, !seenCommands.contains(id),
            command.revision <= current.revision,
            current.revision - command.revision <= 4,
            (packet.kind == .command && command.relativePath == current.relativePath ||
             packet.kind == .switchEpisode && command.revision == current.revision) else { return }
      seenCommands.append(id)
      if seenCommands.count > 256 { seenCommands.removeFirst(seenCommands.count - 256) }
      hostSession?.applyLANCommand(command) { [weak self] applied in
        guard let self, applied else { return }
        guard let latest = self.hostState, latest.roomID == current.roomID,
              (latest.relativePath == current.relativePath || latest.revision == current.revision) else { return }
        let canonical = State(roomID: latest.roomID, showID: latest.showID,
          hostName: latest.hostName, title: command.title, rootHint: latest.rootHint,
          relativePath: command.relativePath,
          position: command.position, duration: command.duration, paused: command.paused,
          rate: command.rate, revision: latest.revision + 1, emittedAt: Date(),
          awaitingNextEpisode: false)
        self.hostState = canonical
        self.hostSession?.acceptLANCommand(canonical, revision: canonical.revision)
        self.broadcast(canonical)
        self.hostSession?.checkpoint()
      }
    case .state, .goodbye: break
    }
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
    player.sharedShow.beginLANFollow(room)
    connection.stateUpdateHandler = { [weak self, weak peer] status in
      Task { @MainActor in
        guard let self, let peer, self.client === peer else { return }
        switch status {
        case .ready:
          self.send(Packet(version: 1, kind: .hello, roomID: room.id), to: peer)
          self.receive(on: peer) { [weak self] packet in self?.clientReceived(packet, from: peer) }
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
    if packet.kind == .goodbye { disconnectClient("The host ended Watch Together"); return }
    guard packet.kind == .state, let state = packet.state, state.isValid,
          state.showID == clientShowID,
          state.roomID == packet.roomID, state.revision > acceptedRevision else { return }
    acceptedRevision = state.revision
    clientSession?.applyLANState(state)
  }

  func sendClientControl(_ state: State, switchEpisode: Bool = false) {
    guard let client, let roomID = clientRoomID, roomID == state.roomID,
          acceptedRevision > 0 else { return }
    var command = state
    command = State(roomID: state.roomID, showID: state.showID, hostName: state.hostName,
                    title: state.title, rootHint: state.rootHint,
                    relativePath: state.relativePath, position: state.position,
                    duration: state.duration, paused: state.paused, rate: state.rate,
                    revision: acceptedRevision, emittedAt: Date(), awaitingNextEpisode: false)
    send(Packet(version: 1, kind: switchEpisode ? .switchEpisode : .command, roomID: roomID,
                state: command, commandID: UUID()), to: client)
  }

  func leave() {
    client?.connection.cancel()
    client = nil
    clientSession = nil
    clientRoomID = nil
    clientShowID = nil
    acceptedRevision = 0
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
    client?.connection.cancel()
    client = nil
    clientRoomID = nil
    clientShowID = nil
    acceptedRevision = 0
    let session = clientSession
    clientSession = nil
    session?.endLANFollow(status)
  }

  private func broadcast(_ state: State) {
    let packet = Packet(version: 1, kind: .state, roomID: state.roomID, state: state)
    for peer in hostPeers.values where peer.joined { send(packet, to: peer) }
    for peer in hostPeers.values where !peer.joined {
      send(packet, to: peer)
    }
  }

  private func send(_ packet: Packet, to peer: Peer) {
    guard let data = try? JSONEncoder().encode(packet), data.count <= Self.maximumFrame else { return }
    guard peer.outstandingFrames < 4 else { return }
    var length = UInt32(data.count).bigEndian
    var frame = withUnsafeBytes(of: &length) { Data($0) }
    frame.append(data)
    peer.outstandingFrames += 1
    peer.connection.send(content: frame, completion: .contentProcessed { [weak peer] error in
      Task { @MainActor in
        guard let peer else { return }
        peer.outstandingFrames = max(0, peer.outstandingFrames - 1)
        if error != nil { peer.connection.cancel() }
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
        guard
              let packet = try? JSONDecoder().decode(Packet.self, from: data),
              packet.version == 1 else { self.connectionEnded(peer); return }
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
    hostPeers.removeValue(forKey: ObjectIdentifier(peer))
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
