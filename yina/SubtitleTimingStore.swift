import Foundation
import CryptoKit

enum SubtitleTimingTrack: Equatable {
  case embedded(Int)
  case external(URL)
}

struct SubtitleTimingContext: Equatable {
  let media: URL
  let track: SubtitleTimingTrack
}

/// Small user settings survive cache purges. Call only from the timing worker queue.
final class SubtitleTimingStore {
  let root: URL
  private var externalIdentities: [URL: String] = [:]

  init(root: URL) { self.root = root }

  func load(_ context: SubtitleTimingContext) -> Double? {
    guard let data = try? Data(contentsOf: file(context)),
          let delay = try? JSONDecoder().decode(Double.self, from: data), delay.isFinite else { return nil }
    return delay
  }

  func save(_ delay: Double, for context: SubtitleTimingContext) throws {
    guard delay.isFinite else { return }
    let destination = file(context)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONEncoder().encode(delay).write(to: destination, options: .atomic)
  }

  private func file(_ context: SubtitleTimingContext) -> URL {
    let media = context.media.isFileURL ? context.media.standardizedFileURL.absoluteString : context.media.absoluteString
    let track: String
    switch context.track {
    case .embedded(let sourceID): track = "embedded:\(sourceID)"
    case .external(let url):
      // Content identity survives temporary-file recovery and cache relocation.
      if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
        track = "external:\(digest(data))"
        externalIdentities[url.standardizedFileURL] = track
      } else if let knownIdentity = externalIdentities[url.standardizedFileURL] {
        track = knownIdentity
      } else {
        track = "external-path:\(url.standardizedFileURL.absoluteString)"
      }
    }
    return root.appendingPathComponent(digest(Data("\(media)\n\(track)".utf8)) + ".json")
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

/// Main-thread selection state. A stale read cannot restore over a newer track or edit.
struct SubtitleTimingSession {
  enum Slot: Hashable { case primary, secondary }
  struct Request {
    let slot: Slot
    let context: SubtitleTimingContext
    let revision: UInt64
  }
  private struct State {
    var context: SubtitleTimingContext?
    var revision: UInt64 = 0
    var pending = false
    var expected: Double?
    var value: Double = 0
  }
  private var states: [Slot: State] = [:]

  func selection(_ slot: Slot) -> SubtitleTimingContext? { states[slot]?.context }

  mutating func select(_ context: SubtitleTimingContext?, slot: Slot) -> Request? {
    var state = states[slot] ?? State()
    guard state.context != context else { return nil }
    state.context = context
    state.revision &+= 1
    state.pending = context != nil
    state.expected = nil
    state.value = 0
    states[slot] = state
    return context.map { Request(slot: slot, context: $0, revision: state.revision) }
  }

  mutating func edit(_ delay: Double, context: SubtitleTimingContext, slot: Slot) -> Request {
    var state = states[slot] ?? State()
    state.context = context
    state.revision &+= 1
    state.pending = true
    state.expected = delay
    state.value = delay
    states[slot] = state
    return Request(slot: slot, context: context, revision: state.revision)
  }

  func isCurrent(_ request: Request) -> Bool {
    states[request.slot]?.context == request.context && states[request.slot]?.revision == request.revision
  }

  mutating func prepareRestore(_ delay: Double, request: Request) -> Bool {
    guard isCurrent(request) else { return false }
    states[request.slot]?.expected = delay
    states[request.slot]?.value = delay
    return true
  }

  mutating func confirm(_ delay: Double, request: Request) {
    guard isCurrent(request), states[request.slot]?.expected == delay else { return }
    states[request.slot]?.pending = false
    states[request.slot]?.expected = nil
  }

  mutating func observe(_ delay: Double, slot: Slot) -> (accepted: Bool, save: Request?) {
    guard var state = states[slot], let context = state.context else { return (true, nil) }
    if state.pending {
      guard state.expected == delay else { return (false, nil) }
      state.pending = false
      state.expected = nil
      states[slot] = state
      return (true, nil)
    }
    guard state.value != delay else { return (true, nil) }
    state.value = delay
    states[slot] = state
    return (true, Request(slot: slot, context: context, revision: state.revision))
  }

  mutating func reset() {
    for slot in [Slot.primary, .secondary] {
      var state = states[slot] ?? State()
      state.revision &+= 1
      state.context = nil
      state.pending = false
      state.expected = nil
      states[slot] = state
    }
  }
}
