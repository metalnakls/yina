import AppKit
import Foundation
import Network

struct ShowFolder { let folderURL: URL }
enum ShowFolderSnapshotStore { static func loadCards() -> [ShowFolder] { [] } }
final class SharedShowStore {
  static func safePath(_ path: String) -> Bool {
    !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") &&
      path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
  init(root: URL) throws {}
  func descriptor() throws -> Descriptor { Descriptor() }
  func resolvePlayable(path: String, showID: UUID) throws -> URL? { nil }
  struct Descriptor { let showID = UUID() }
}
@MainActor final class SharedShowSession {
  var receivedStates: [SharedShowLAN.State] = []
  var receivedCommands: [SharedShowLAN.State] = []
  var endMessages: [String] = []
  var checkpoints = 0
  var commandDelay: TimeInterval = 0
  var holdNextCommand = false
  var heldCompletion: ((Bool) -> Void)?
  var cancelledCommands = 0
  func beginLANFollow(_ room: SharedShowLAN.Room) {}
  func endLANFollow(_ status: String) { endMessages.append(status) }
  func applyLANState(_ state: SharedShowLAN.State) { receivedStates.append(state) }
  func applyLANCommand(_ command: SharedShowLAN.State, completion: @escaping (Bool) -> Void) {
    receivedCommands.append(command)
    if holdNextCommand {
      holdNextCommand = false
      heldCompletion = completion
    } else if commandDelay > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + commandDelay) { completion(true) }
    } else { completion(true) }
  }
  func checkpoint() { checkpoints += 1 }
  func acceptLANRevision(_ revision: UInt64) {}
  func acceptLANCommand(_ state: SharedShowLAN.State, revision: UInt64) {}
  func yieldLANHosting() {}
  func lanPeerReadinessChanged(ready: Bool, generation: UInt64, peerID: UUID) {}
  func lanPeerDisconnected(peerID: UUID) {}
  func lanClockInvalidated() {}
  func lanClockCalibrated() {}
  func lanHostWoke() {}
  func cancelLANCommand(stopSubmittedOpen: Bool = false) { cancelledCommands += 1 }
  func canonicalLANCommand(_ command: SharedShowLAN.State, revision: UInt64) -> SharedShowLAN.State {
    SharedShowLAN.State(roomID: command.roomID, showID: command.showID,
      hostName: command.hostName, title: command.title, rootHint: command.rootHint,
      relativePath: command.relativePath, position: command.position,
      duration: command.duration, paused: command.paused, rate: command.rate,
      revision: revision, emittedAt: Date(), awaitingNextEpisode: false,
      epoch: command.epoch, seekGeneration: command.seekGeneration)
  }
}
@MainActor final class PlayerCore { let sharedShow = SharedShowSession() }

@MainActor final class RawPeer {
  let connection: NWConnection
  var ready = false
  init(roomID: UUID) {
    let service = "YINA-" + String(roomID.uuidString.prefix(8))
    connection = NWConnection(to: .service(name: service, type: SharedShowLAN.serviceType, domain: "local.", interface: nil), using: .tcp)
    connection.stateUpdateHandler = { [weak self] status in
      Task { @MainActor in if case .ready = status { self?.ready = true } }
    }
    connection.start(queue: .main)
  }
  func send(kind: String, roomID: UUID, state: SharedShowLAN.State? = nil, commandID: UUID? = nil) {
    var object: [String: Any] = ["version": 6, "kind": kind, "roomID": roomID.uuidString]
    if let state {
      object["state"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
    }
    if let commandID { object["commandID"] = commandID.uuidString }
    let payload = try! JSONSerialization.data(withJSONObject: object)
    var length = UInt32(payload.count).bigEndian
    var frame = withUnsafeBytes(of: &length) { Data($0) }
    frame.append(payload)
    connection.send(content: frame, completion: .contentProcessed { _ in })
  }
}

@main struct LANLoopbackTest {
  @MainActor static func main() {
    let lan = SharedShowLAN.shared
    var clock = SharedShowClock()
    clock.observe(clientSend: 10, hostReceive: 12.04, hostSend: 12.05, clientReceive: 10.09)
    precondition(clock.calibrated && abs((clock.offset ?? 0) - 2) < 0.001, "Clock offset")
    precondition(abs((clock.uncertainty ?? 0) - 0.04) < 0.001, "Clock uncertainty")
    clock.observe(clientSend: 20, hostReceive: 24, hostSend: 24.01, clientReceive: 23)
    precondition(abs((clock.offset ?? 0) - 2) < 0.001, "High RTT sample distorted clock")
    var poorClock = SharedShowClock()
    poorClock.observe(clientSend: 0, hostReceive: 2.15,
                      hostSend: 2.16, clientReceive: 0.31)
    precondition(!SharedShowLAN.clockReadyForPlayback(poorClock),
                 "High-latency clock released playback barrier")
    poorClock.observe(clientSend: 1, hostReceive: 3.004,
                      hostSend: 3.005, clientReceive: 1.009)
    precondition(SharedShowLAN.clockReadyForPlayback(poorClock),
                 "Good clock sample did not release calibration hold")
    let host = SharedShowSession()
    let client = PlayerCore()
    let roomID = UUID(), showID = UUID()
    func state(_ revision: UInt64, paused: Bool = false, path: String = "A.mkv") -> SharedShowLAN.State {
      SharedShowLAN.State(roomID: roomID, showID: showID, hostName: "Loopback Host", title: "Episode A",
        relativePath: path, position: 4, duration: 30, paused: paused, rate: 1,
        revision: revision, emittedAt: Date(), awaitingNextEpisode: false)
    }
    precondition(abs(SharedShowTimeline.trimmedRate(baseRate: 1, expectedPosition: 1.02,
                                                   actualPosition: 1) - 1.002) < 0.00001,
                 "20ms drift did not receive small speed trim")
    precondition(SharedShowTimeline.trimmedRate(baseRate: 1, expectedPosition: 1.005,
                                                actualPosition: 1) == 1,
                 "Sub-frame noise should not trim")
    let heartbeat = SharedShowLAN.State(roomID: roomID, showID: showID,
      hostName: "Host", title: "A", relativePath: "A.mkv", position: 10, duration: 100,
      paused: false, rate: 1, revision: 1, emittedAt: Date(), awaitingNextEpisode: false,
      hostTime: 10, playAtHostTime: 5)
    precondition(SharedShowTimeline.projectedPosition(heartbeat, atHostTime: 12) == 12,
                 "A later heartbeat double-counted scheduled playback")
    for oscillator in [-0.0001, 0.0001] {
      var actual = -0.02
      var maxTrim = 0.0
      for step in 0..<600 {
        let expected = Double(step) * 0.1
        let jitter = sin(Double(step) * 0.73) * 0.003
        let rate = SharedShowTimeline.trimmedRate(baseRate: 1,
          expectedPosition: expected, actualPosition: actual + jitter)
        maxTrim = max(maxTrim, abs(rate - 1))
        actual += rate * (1 + oscillator) * 0.1
      }
      precondition(maxTrim <= 0.010001, "Speed correction exceeded 1%")
      precondition(abs(actual - 60) < 0.012, "20ms offset failed to converge")
    }
    func wait(_ label: String, timeout: TimeInterval = 8, _ condition: () -> Bool) {
      let deadline = Date(timeIntervalSinceNow: timeout)
      while !condition() && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
      precondition(condition(), "Timeout: \(label)")
    }
    lan.startDiscovery()
    lan.host(session: host, state: state(1))
    wait("discovery") { lan.rooms.contains { $0.id == roomID } }
    // Keep advertising beyond the discovery expiry to catch rooms that vanish
    // when a probe receives only the first host state.
    for revision in 2...11 {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.4))
      lan.host(session: host, state: state(UInt64(revision)))
      precondition(lan.rooms.contains { $0.id == roomID }, "Live room disappeared")
    }
    let room = lan.rooms.first { $0.id == roomID }!
    precondition(lan.join(room, player: client), "Join failed")
    wait("initial client state") { client.sharedShow.receivedStates.last?.revision == 11 }
    lan.host(session: host, state: state(12, paused: true))
    wait("passive state update") { client.sharedShow.receivedStates.last?.revision == 12 }
    precondition(host.receivedCommands.isEmpty, "Passive update echoed a command")
    lan.sendClientControl(state(12, paused: false))
    wait("client command") { host.receivedCommands.count == 1 }
    wait("canonical broadcast") { client.sharedShow.receivedStates.last?.revision == 13 }
    wait("command ack") { lan.pendingControlCount == 0 }
    precondition(host.receivedCommands[0].relativePath == "A.mkv", "Wrong command path")
    host.commandDelay = 0.3
    lan.sendClientControl(state(13, paused: true))
    lan.sendClientControl(state(13, paused: false))
    precondition(lan.pendingControlCount == 2, "Controls were dropped instead of queued")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    precondition(host.receivedCommands.count == 2, "Second control ran before first ACK")
    wait("ordered controls") { host.receivedCommands.count == 3 && lan.pendingControlCount == 0 }
    host.commandDelay = 0
    host.holdNextCommand = true
    lan.sendClientControl(state(15, path: "B.mkv"), switchEpisode: true, expectedPath: "A.mkv")
    wait("stalled episode command") { host.receivedCommands.count == 4 }
    lan.sendClientControl(state(15, paused: true, path: "B.mkv"))
    wait("urgent pause bypass") { host.receivedCommands.count == 5 && lan.pendingControlCount == 0 }
    precondition(host.cancelledCommands == 1, "Urgent pause did not cancel stalled episode open")
    precondition(host.receivedCommands.last?.relativePath == "A.mkv", "Pause did not address host path")
    host.heldCompletion?(true)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    precondition(client.sharedShow.receivedStates.last?.revision == 16,
                 "Late completion revived interrupted episode switch")
    let raw = RawPeer(roomID: roomID)
    wait("raw peer ready") { raw.ready }
    raw.send(kind: "hello", roomID: roomID)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    let duplicateID = UUID()
    raw.send(kind: "command", roomID: roomID, state: state(16, paused: true), commandID: duplicateID)
    raw.send(kind: "command", roomID: roomID, state: state(16, paused: true), commandID: duplicateID)
    wait("raw command") { host.receivedCommands.count == 6 }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    precondition(host.receivedCommands.count == 6, "Duplicate command delivered")
    raw.send(kind: "command", roomID: roomID, state: state(17, paused: true, path: "../escape.mkv"),
             commandID: UUID())
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    precondition(host.receivedCommands.count == 6, "Invalid path command reached session")
    raw.send(kind: "command", roomID: UUID(), state: state(17), commandID: UUID())
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    precondition(host.receivedCommands.count == 6, "Wrong-room command delivered")
    lan.host(session: host, state: state(18, path: "B.mkv"))
    raw.send(kind: "command", roomID: roomID, state: state(17, paused: true), commandID: UUID())
    wait("stale-path pause") { host.receivedCommands.count == 7 }
    precondition(host.receivedCommands.last?.relativePath == "B.mkv",
                 "A pause raced a switch and reopened the old path")
    raw.connection.cancel()
    lan.stopHosting()
    wait("disconnect") { !client.sharedShow.endMessages.isEmpty }
    wait("room removal") { !lan.rooms.contains { $0.id == roomID } }
    print("PASS: Bonjour discovery/freshness, passive update without echo, client command/canonical broadcast, invalid path/wrong-room rejection, dedupe, disconnect, room removal")
  }
}
