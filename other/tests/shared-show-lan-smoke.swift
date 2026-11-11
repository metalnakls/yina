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
  func beginLANFollow(_ room: SharedShowLAN.Room) {}
  func endLANFollow(_ status: String) { endMessages.append(status) }
  func applyLANState(_ state: SharedShowLAN.State) { receivedStates.append(state) }
  func applyLANCommand(_ command: SharedShowLAN.State, completion: @escaping (Bool) -> Void) {
    receivedCommands.append(command)
    completion(true)
  }
  func checkpoint() { checkpoints += 1 }
  func acceptLANRevision(_ revision: UInt64) {}
  func acceptLANCommand(_ state: SharedShowLAN.State, revision: UInt64) {}
  func yieldLANHosting() {}
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
    var object: [String: Any] = ["version": 1, "kind": kind, "roomID": roomID.uuidString]
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
    let host = SharedShowSession()
    let client = PlayerCore()
    let roomID = UUID(), showID = UUID()
    func state(_ revision: UInt64, paused: Bool = false, path: String = "A.mkv") -> SharedShowLAN.State {
      SharedShowLAN.State(roomID: roomID, showID: showID, hostName: "Loopback Host", title: "Episode A",
        relativePath: path, position: 4, duration: 30, paused: paused, rate: 1,
        revision: revision, emittedAt: Date(), awaitingNextEpisode: false)
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
    precondition(host.receivedCommands[0].relativePath == "A.mkv", "Wrong command path")
    lan.sendClientControl(state(13, paused: true, path: "../escape.mkv"))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    precondition(host.receivedCommands.count == 1, "Invalid path command reached session")
    let raw = RawPeer(roomID: roomID)
    wait("raw peer ready") { raw.ready }
    raw.send(kind: "hello", roomID: roomID)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    let duplicateID = UUID()
    raw.send(kind: "command", roomID: roomID, state: state(13, paused: true), commandID: duplicateID)
    raw.send(kind: "command", roomID: roomID, state: state(13, paused: true), commandID: duplicateID)
    wait("raw command") { host.receivedCommands.count == 2 }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    precondition(host.receivedCommands.count == 2, "Duplicate command delivered")
    raw.send(kind: "command", roomID: UUID(), state: state(14), commandID: UUID())
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    precondition(host.receivedCommands.count == 2, "Wrong-room command delivered")
    raw.connection.cancel()
    lan.stopHosting()
    wait("disconnect") { !client.sharedShow.endMessages.isEmpty }
    wait("room removal") { !lan.rooms.contains { $0.id == roomID } }
    print("PASS: Bonjour discovery/freshness, passive update without echo, client command/canonical broadcast, invalid path/wrong-room rejection, dedupe, disconnect, room removal")
  }
}
