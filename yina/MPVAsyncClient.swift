import Foundation

/// Nonblocking libmpv submissions. The controller owns the handle and feeds copied
/// replies from its event consumer; completions always arrive on the main queue.
/// No render thread or UI thread waits for a reply, including during shutdown.
final class MPVAsyncClient {
  enum Value {
    case flag(Bool), integer(Int64), double(Double), string(String)
  }

  private typealias Completion = (Any?, Int32) -> Void
  private struct PendingReply {
    let completion: Completion
    let deadline: TimeInterval
  }
  private let lock = NSLock()
  private var handle: OpaquePointer?
  private var nextID: UInt64 = 1 << 63
  private var replies: [UInt64: PendingReply] = [:]
  private var deadlineTimer: DispatchSourceTimer?
  private var latest: [String: Value] = [:]
  private var writing: Set<String> = []
  private var generation: UInt64 = 0
  private var writeEpoch: [String: UInt64] = [:]
  private var latestCommands: [String: [String]] = [:]
  private var runningCommands: Set<String> = []
  private var commandEpoch: [String: UInt64] = [:]

  func activate(_ handle: OpaquePointer) {
    lock.lock()
    self.handle = handle
    generation &+= 1
    lock.unlock()
  }

  func invalidate() {
    lock.lock()
    handle = nil
    generation &+= 1
    let cancelled = replies.values.map(\.completion)
    replies.removeAll()
    deadlineTimer?.cancel()
    deadlineTimer = nil
    latest.removeAll()
    writing.removeAll()
    latestCommands.removeAll()
    runningCommands.removeAll()
    commandEpoch.removeAll()
    writeEpoch.removeAll()
    lock.unlock()
    DispatchQueue.main.async {
      cancelled.forEach { $0(nil, MPV_ERROR_UNINITIALIZED.rawValue) }
    }
  }

  @discardableResult
  private func submit(_ completion: @escaping Completion,
                      operation: (OpaquePointer, UInt64) -> Int32) -> Int32 {
    lock.lock()
    guard let handle else {
      lock.unlock()
      DispatchQueue.main.async { completion(nil, MPV_ERROR_UNINITIALIZED.rawValue) }
      return MPV_ERROR_UNINITIALIZED.rawValue
    }
    nextID &+= 1
    let id = nextID
    replies[id] = PendingReply(completion: completion,
                               deadline: ProcessInfo.processInfo.systemUptime + 10)
    if deadlineTimer == nil {
      let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
      timer.schedule(deadline: .now() + 1, repeating: .seconds(1), leeway: .milliseconds(100))
      timer.setEventHandler { [weak self] in self?.expireReplies() }
      deadlineTimer = timer
      timer.resume()
    }
    // Async libmpv APIs copy input and enqueue; they never wait for the player core.
    let error = operation(handle, id)
    lock.unlock()
    if error < 0 { finish(id, value: nil, error: error) }
    return error
  }

  /// One timer owns all reply deadlines and sleeps when there are no requests.
  private func expireReplies() {
    lock.lock()
    let now = ProcessInfo.processInfo.systemUptime
    let expired = replies.filter { $0.value.deadline <= now }.map(\.key)
    let completions = expired.compactMap { replies.removeValue(forKey: $0)?.completion }
    if replies.isEmpty {
      deadlineTimer?.cancel()
      deadlineTimer = nil
    }
    lock.unlock()
    guard !completions.isEmpty else { return }
    DispatchQueue.main.async {
      completions.forEach { $0(nil, MPV_ERROR_GENERIC.rawValue) }
    }
  }

  private func finish(_ id: UInt64, value: Any?, error: Int32) {
    lock.lock()
    let completion = replies.removeValue(forKey: id)?.completion
    if replies.isEmpty {
      deadlineTimer?.cancel()
      deadlineTimer = nil
    }
    lock.unlock()
    guard let completion else { return }
    DispatchQueue.main.async { completion(value, error) }
  }

  /// Returns true only for replies belonging to this bridge. mpv-owned payloads
  /// are copied before the event consumer calls mpv_wait_event again.
  func consume(_ event: mpv_event) -> Bool {
    guard event.reply_userdata >= (1 << 63),
          event.event_id == MPV_EVENT_GET_PROPERTY_REPLY ||
          event.event_id == MPV_EVENT_SET_PROPERTY_REPLY ||
          event.event_id == MPV_EVENT_COMMAND_REPLY else { return false }
    var value: Any?
    if event.error >= 0, event.event_id == MPV_EVENT_GET_PROPERTY_REPLY,
       let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
       let data = property.data {
      if property.format == MPV_FORMAT_STRING,
         let string = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
        value = String(cString: string)
      } else if property.format == MPV_FORMAT_NODE {
        value = try? MPVNode.parse(data.assumingMemoryBound(to: mpv_node.self).pointee)
      }
    }
    finish(event.reply_userdata, value: value, error: event.error)
    return true
  }

  func get(_ names: [String], strings: Bool = false, completion: @escaping ([String: Any]) -> Void) {
    let names = Array(Set(names))
    guard !names.isEmpty else { DispatchQueue.main.async { completion([:]) }; return }
    // Each reply is delivered on main, so the aggregate has a single owner.
    var remaining = names.count
    var values: [String: Any] = [:]
    for name in names {
      submit({ value, error in
        if error >= 0, let value { values[name] = value }
        remaining -= 1
        if remaining == 0 { completion(values) }
      }, operation: { handle, id in
        mpv_get_property_async(handle, id, name, strings ? MPV_FORMAT_STRING : MPV_FORMAT_NODE)
      })
    }
  }

  @discardableResult
  func command(_ arguments: [String], completion: @escaping (Int32) -> Void = { _ in }) -> Int32 {
    return submit({ _, error in completion(error) }, operation: { handle, id in
      let strings = arguments.map { strdup($0) }
      defer { strings.forEach { free($0) } }
      var pointers = strings.map { UnsafePointer<CChar>($0) } + [nil]
      return mpv_command_async(handle, id, &pointers)
    })
  }

  func set(_ name: String, _ value: Value, completion: @escaping (Int32) -> Void = { _ in }) {
    submit({ _, error in completion(error) }, operation: { handle, id in
      switch value {
      case .flag(let flag):
        var value: Int32 = flag ? 1 : 0
        return mpv_set_property_async(handle, id, name, MPV_FORMAT_FLAG, &value)
      case .integer(var value):
        return mpv_set_property_async(handle, id, name, MPV_FORMAT_INT64, &value)
      case .double(var value):
        return mpv_set_property_async(handle, id, name, MPV_FORMAT_DOUBLE, &value)
      case .string(let value):
        return value.withCString { string in
          var pointer: UnsafePointer<CChar>? = string
          return mpv_set_property_async(handle, id, name, MPV_FORMAT_STRING, &pointer)
        }
      }
    })
  }

  /// At most one outstanding write and one latest value per continuous control.
  /// Discrete transport commands use set/command instead to retain every action.
  func setLatest(_ name: String, _ value: Value) {
    lock.lock()
    guard handle != nil else { lock.unlock(); return }
    latest[name] = value
    let start = writing.insert(name).inserted
    let epoch = generation
    let token = writeEpoch[name, default: 0]
    lock.unlock()
    if start { writeNext(name, generation: epoch, token: token) }
  }

  private func writeNext(_ name: String, generation epoch: UInt64, token: UInt64) {
    lock.lock()
    guard epoch == generation, token == writeEpoch[name, default: 0] else { lock.unlock(); return }
    guard let value = latest.removeValue(forKey: name) else {
      writing.remove(name)
      lock.unlock()
      return
    }
    lock.unlock()
    set(name, value) { [weak self] _ in self?.writeNext(name, generation: epoch, token: token) }
  }
  /// Drop superseded animation frames before enqueueing its exact final state.
  /// An already submitted write stays ordered before the following final writes.
  func discardLatest(_ names: [String]) {
    lock.lock()
    for name in names {
      latest.removeValue(forKey: name)
      writing.remove(name)
      writeEpoch[name, default: 0] &+= 1
    }
    lock.unlock()
  }

  /// Submit the final value of every coalesced control before a subsequent
  /// checkpoint, stop, or quit command. In-flight writes were submitted first;
  /// old completion callbacks cannot enqueue a stale value after this barrier.
  func flushLatest() {
    precondition(Thread.isMainThread)
    lock.lock()
    guard handle != nil else { lock.unlock(); return }
    let properties = latest
    let commands = latestCommands
    let propertyKeys = writing.union(latest.keys)
    let commandKeys = runningCommands.union(latestCommands.keys)
    latest.removeAll()
    latestCommands.removeAll()
    writing.removeAll()
    runningCommands.removeAll()
    for name in propertyKeys { writeEpoch[name, default: 0] &+= 1 }
    for key in commandKeys { commandEpoch[key, default: 0] &+= 1 }
    lock.unlock()
    for (name, value) in properties { set(name, value) }
    for (_, arguments) in commands { command(arguments) }
  }

  func commandLatest(_ key: String, arguments: [String]) {
    lock.lock()
    guard handle != nil else { lock.unlock(); return }
    latestCommands[key] = arguments
    let start = runningCommands.insert(key).inserted
    let epoch = generation
    let token = commandEpoch[key, default: 0]
    lock.unlock()
    if start { runNextCommand(key, generation: epoch, token: token) }
  }

  private func runNextCommand(_ key: String, generation epoch: UInt64, token: UInt64) {
    lock.lock()
    guard epoch == generation, token == commandEpoch[key, default: 0] else { lock.unlock(); return }
    guard let arguments = latestCommands.removeValue(forKey: key) else {
      runningCommands.remove(key)
      lock.unlock()
      return
    }
    lock.unlock()
    command(arguments) { [weak self] _ in self?.runNextCommand(key, generation: epoch, token: token) }
  }

}
