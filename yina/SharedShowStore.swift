import CryptoKit
import Darwin
import Foundation

/// Glass's portable show protocol. Filesystem operations are synchronous by design:
/// callers run them on a bounded utility queue, never in a view or on the main thread.
final class SharedShowStore {
  enum Failure: Error { case unsafePath, invalidRecord, tooLarge, io(Int32), identityChanged }
  struct Descriptor: Codable, Sendable {
    var schemaVersion = 2
    let showID: UUID
    let createdAt: Date
  }
  struct Progress: Codable, Sendable {
    enum Activity: String, Codable, Sendable { case playing, paused, stopped }
    var schemaVersion = 1
    let showID: UUID
    let participantID: UUID
    let writerID: UUID
    let revision: UInt64
    let updatedAt: Date
    let relativePath: String
    let position: Double
    let duration: Double
    let activity: Activity
    // Optional YINA extensions. Glass ignores these and continues reading the
    // same schema-one progress record; old records never become live hosts.
    var playbackRate: Double? = nil
    var watchTogether: Bool? = nil

    var isValid: Bool {
      schemaVersion == 1 && SharedShowStore.safePath(relativePath) &&
      position.isFinite && duration.isFinite && position >= 0 && duration > 0 && position <= duration &&
      (playbackRate.map { $0.isFinite && $0 >= 0.01 && $0 <= 100 } ?? true)
    }
  }
  struct Demand: Codable, Sendable {
    var schemaVersion = 1
    let showID: UUID
    let requestID: UUID
    let participantID: UUID
    let writerID: UUID
    let revision: UInt64
    let updatedAt: Date
    let relativePath: String
    let hashString: String
    let fileIndex: Int
    let cancelled: Bool
  }
  private struct Fragment: Decodable {
    let schemaVersion: Int
    let showID: UUID
    let writerID: UUID
    let index: ShowEpisodeIndexReader.Manifest
  }

  let root: URL
  private let rootFD: Int32
  private let maximumEntries = 4096
  private let maximumAggregateBytes = 64 * 1024 * 1024
  private struct ProgressStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ info: stat) {
      device = info.st_dev
      inode = info.st_ino
      size = info.st_size
      modifiedSeconds = info.st_mtimespec.tv_sec
      modifiedNanoseconds = info.st_mtimespec.tv_nsec
      changedSeconds = info.st_ctimespec.tv_sec
      changedNanoseconds = info.st_ctimespec.tv_nsec
    }
  }
  private struct CachedProgress {
    let stamp: ProgressStamp
    let record: Progress?
    let expiresAt: Date
  }
  private static let progressCacheLock = NSLock()
  private static var progressCache: [String: CachedProgress] = [:]

  init(root: URL) throws {
    guard root.isFileURL else { throw Failure.unsafePath }
    guard let canonical = Self.canonicalURL(root) else { throw Failure.io(errno) }
    self.root = canonical
    // Walk using directory descriptors so an ancestor symlink cannot redirect a
    // read or write outside the selected root, including during a replacement.
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw Failure.io(errno) }
    for part in self.root.pathComponents.dropFirst() {
      let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      let error = errno
      close(fd)
      guard next >= 0 else { throw Failure.io(error) }
      fd = next
    }
    rootFD = fd
  }

  deinit { close(rootFD) }

  /// Foundation intentionally retains some macOS aliases such as /var. Resolve
  /// the selected root once before the no-follow descriptor walk.
  private static func canonicalURL(_ url: URL) -> URL? {
    guard let path = realpath(url.path, nil) else { return nil }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path))
  }

  static func safePath(_ path: String) -> Bool {
    !path.isEmpty && path.utf8.count <= 4096 && !path.hasPrefix("/") &&
      !path.contains("\\") && !path.contains("\0") &&
      path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".."
      }
  }

  static func validHash(_ hash: String) -> Bool {
    !hash.isEmpty && hash.utf8.count <= 128 && hash.lowercased().utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }

  static func legacyShowID(hash: String) -> UUID {
    var bytes = Array(SHA256.hash(data: Data(("glass-yina-show-v2:" +
      hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x40
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    // Each decoder owns its formatters. One broad refresh may decode thousands
    // of dates, but no formatter is shared between concurrent mount lanes.
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    decoder.dateDecodingStrategy = .custom { decoder in
      let value = try decoder.singleValueContainer().decode(String.self)
      if let date = fractional.date(from: value) { return date }
      guard let date = whole.date(from: value) else { throw Failure.invalidRecord }
      return date
    }
    return decoder
  }

  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var value = encoder.singleValueContainer()
      try value.encode(formatter.string(from: date))
    }
    return encoder
  }

  func descriptor() throws -> Descriptor {
    let data = try read(".yina.json", limit: ShowEpisodeIndexReader.maximumBytes)
    if let descriptor = try? Self.decoder().decode(Descriptor.self, from: data), descriptor.schemaVersion == 2 {
      return descriptor
    }
    if let legacy = ShowEpisodeIndexReader.decode(data),
       let manifest = try? JSONDecoder().decode(ShowEpisodeIndexReader.Manifest.self, from: data) {
      return Descriptor(showID: Self.legacyShowID(hash: manifest.hashString), createdAt: legacy.capturedAt)
    }
    throw Failure.invalidRecord
  }

  /// Explicit opt-in at a user-selected show root. Existing metadata is immutable.
  func enable() throws -> Descriptor {
    let value = Descriptor(showID: UUID(), createdAt: Date())
    let fd = openat(rootFD, ".yina.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
    if fd < 0 {
      guard errno == EEXIST else { throw Failure.io(errno) }
      return try descriptor()
    }
    defer { close(fd) }
    try writeAll(Self.encoder().encode(value), to: fd)
    guard fsync(fd) == 0 else { throw Failure.io(errno) }
    return value
  }

  static func discover(for media: URL) throws -> SharedShowStore? {
    guard media.isFileURL else { return nil }
    guard let file = canonicalURL(media) else { return nil }
    var folder = file.deletingLastPathComponent()
    let volume = try? folder.resourceValues(forKeys: [.volumeURLKey]).volume
    for _ in 0..<12 {
      let store = try SharedShowStore(root: folder)
      var info = stat()
      if fstatat(store.rootFD, ".yina.json", &info, AT_SYMLINK_NOFOLLOW) == 0 {
        _ = try store.descriptor() // A malformed nearer record stops discovery.
        return store
      }
      guard errno == ENOENT else { throw Failure.io(errno) }
      let parent = folder.deletingLastPathComponent()
      if folder == volume || parent == folder { break }
      folder = parent
    }
    return nil
  }

  func relativePath(for media: URL) -> String? {
    guard let file = Self.canonicalURL(media)?.path else { return nil }
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard file.hasPrefix(prefix) else { return nil }
    let path = String(file.dropFirst(prefix.count))
    return Self.safePath(path) ? path : nil
  }

  func catalog(at now: Date = Date()) throws -> ShowEpisodeIndexReader.Snapshot {
    let identity = try descriptor()
    var byHash: [String: ShowEpisodeIndexReader.Snapshot] = [:]
    let legacyData = try read(".yina.json", limit: ShowEpisodeIndexReader.maximumBytes)
    if let legacy = ShowEpisodeIndexReader.decode(legacyData), let first = legacy.episodes.first {
      byHash[first.hashString] = legacy
    }
    var entries = 0
    var bytes = legacyData.count
    let decoder = Self.decoder()
    for writer in try children(".yina/transfers", entries: &entries) {
      guard let writerID = UUID(uuidString: writer) else { continue }
      for name in try children(".yina/transfers/\(writer)", entries: &entries) where name.hasSuffix(".json") {
        let hash = String(name.dropLast(5))
        guard Self.validHash(hash) else { continue }
        let path = ".yina/transfers/\(writer)/\(name)"
        guard let data = try? read(path, limit: min(ShowEpisodeIndexReader.maximumBytes, maximumAggregateBytes - bytes)) else { continue }
        bytes += data.count
        guard bytes < maximumAggregateBytes else { throw Failure.tooLarge }
        guard let fragment = try? decoder.decode(Fragment.self, from: data),
              fragment.schemaVersion == 1, fragment.showID == identity.showID, fragment.writerID == writerID,
              fragment.index.hashString.lowercased() == hash.lowercased(),
              let indexData = try? JSONEncoder().encode(fragment.index),
              let snapshot = ShowEpisodeIndexReader.decode(indexData) else { continue }
        let key = hash.lowercased()
        if let old = byHash[key] {
          // A future timestamp must not displace an already usable snapshot.
          if snapshot.capturedAt > now && old.capturedAt <= now { continue }
          if old.capturedAt <= now && snapshot.capturedAt <= old.capturedAt { continue }
        }
        byHash[key] = snapshot
      }
    }
    var all = byHash.values.flatMap(\.episodes)
    guard all.count <= 20_000 else { throw Failure.tooLarge }
    // Different torrents can describe the same path; never pick a download target
    // or claim readiness arbitrarily. Keep one visibly unknown record.
    let counts = Dictionary(grouping: all, by: { $0.path.precomposedStringWithCanonicalMapping.lowercased() })
    var seen = Set<String>()
    all = all.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.filter {
      seen.insert($0.path.precomposedStringWithCanonicalMapping.lowercased()).inserted
    }
    for index in all.indices {
      let key = all[index].path.precomposedStringWithCanonicalMapping.lowercased()
      all[index].ambiguous = (counts[key]?.count ?? 0) > 1
      if index < 128 {
        do {
          all[index].localSize = try regularSize(all[index].path)
          all[index].exists = true
        } catch Failure.io(let code) where code == ENOENT {
          all[index].exists = false
        } catch Failure.io(let code) where code == ELOOP || code == ENOTDIR {
          throw Failure.unsafePath
        } catch Failure.unsafePath {
          throw Failure.unsafePath
        } catch {
          // A disconnected share or denied access is unknown, not missing.
          all[index].exists = nil
        }
      }
    }
    return .init(capturedAt: all.map(\.capturedAt).max() ?? identity.createdAt, episodes: all,
                 root: root, showID: identity.showID)
  }

  func progress(showID: UUID, at now: Date = Date()) throws -> [Progress] {
    guard try descriptor().showID == showID else { throw Failure.identityChanged }
    var entries = 0
    var bytes = 0
    var records: [Progress] = []
    let decoder = Self.decoder()
    for participant in try children(".yina/progress", entries: &entries) {
      guard let participantID = UUID(uuidString: participant) else { continue }
      for name in try children(".yina/progress/\(participant)", entries: &entries) where name.hasSuffix(".json") {
        guard let writerID = UUID(uuidString: String(name.dropLast(5))),
              let result = try? cachedProgress(".yina/progress/\(participant)/\(name)",
                limit: min(512 * 1024, maximumAggregateBytes - bytes), decoder: decoder, at: now) else { continue }
        bytes += result.1
        guard bytes < maximumAggregateBytes else { throw Failure.tooLarge }
        guard let record = result.0, record.isValid,
              record.showID == showID, record.participantID == participantID, record.writerID == writerID,
              record.updatedAt <= now else { continue }
        records.append(record)
      }
    }
    return records.sorted { $0.updatedAt > $1.updatedAt }
  }

  /// Frequent follow updates need only the selected writer. A wider scan still
  /// runs periodically to discover new participants and changed records.
  func progress(showID: UUID, participantID: UUID, writerID: UUID, at now: Date = Date()) throws -> Progress? {
    guard try descriptor().showID == showID else { throw Failure.identityChanged }
    let path = ".yina/progress/\(participantID.uuidString.lowercased())/\(writerID.uuidString.lowercased()).json"
    let record: Progress?
    do { (record, _) = try cachedProgress(path, limit: 512 * 1024, decoder: Self.decoder(), at: now) }
    catch Failure.io(let code) where code == ENOENT { return nil }
    guard let record, record.isValid,
          record.showID == showID, record.participantID == participantID,
          record.writerID == writerID, record.updatedAt <= now else { return nil }
    return record
  }

  private func cachedProgress(_ path: String, limit: Int, decoder: JSONDecoder, at now: Date) throws -> (Progress?, Int) {
    guard limit > 0 else { throw Failure.tooLarge }
    let (directory, name) = try parent(path)
    defer { close(directory) }
    var info = stat()
    guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.io(errno) }
    guard (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.unsafePath }
    guard info.st_size >= 0 && info.st_size <= limit else { throw Failure.tooLarge }
    let stamp = ProgressStamp(info)
    let key = root.path + "/" + path
    if let hit = Self.progressCacheLock.withLock({ Self.progressCache[key] }),
       hit.stamp == stamp, hit.expiresAt > now { return (hit.record, Int(info.st_size)) }
    let data = try read(path, limit: limit)
    let record = try? decoder.decode(Progress.self, from: data)
    Self.progressCacheLock.withLock {
      if Self.progressCache.count >= maximumEntries { Self.progressCache.removeAll(keepingCapacity: true) }
      Self.progressCache[key] = CachedProgress(stamp: stamp, record: record,
                                              expiresAt: now.addingTimeInterval(15))
    }
    return (record, data.count)
  }

  func publish(_ record: Progress) throws {
    guard record.isValid, try descriptor().showID == record.showID else { throw Failure.invalidRecord }
    let path = ".yina/progress/\(record.participantID.uuidString.lowercased())/\(record.writerID.uuidString.lowercased()).json"
    if let previous = try existing(path, as: Progress.self) {
      guard previous.isValid, previous.showID == record.showID, previous.participantID == record.participantID,
            previous.writerID == record.writerID, previous.revision < record.revision else { throw Failure.invalidRecord }
    }
    try atomicWrite(Self.encoder().encode(record), path: path)
  }

  func publish(_ record: Demand) throws {
    guard record.schemaVersion == 1, Self.safePath(record.relativePath), Self.validHash(record.hashString),
          record.fileIndex >= 0, try descriptor().showID == record.showID else { throw Failure.invalidRecord }
    let path = ".yina/demand/\(record.writerID.uuidString.lowercased()).json"
    if let previous = try existing(path, as: Demand.self) {
      guard previous.showID == record.showID, previous.writerID == record.writerID,
            previous.participantID == record.participantID, previous.revision < record.revision else { throw Failure.invalidRecord }
    }
    try atomicWrite(Self.encoder().encode(record), path: path)
  }

  private func existing<T: Decodable>(_ path: String, as type: T.Type) throws -> T? {
    do { return try Self.decoder().decode(type, from: read(path, limit: 512 * 1024)) }
    catch Failure.io(let code) where code == ENOENT { return nil }
  }

  func regularSize(_ path: String) throws -> UInt64 {
    let (directory, name) = try parent(path)
    defer { close(directory) }
    var info = stat()
    guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.io(errno) }
    guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else { throw Failure.unsafePath }
    return UInt64(info.st_size)
  }

  func validateRequestPath(_ path: String) throws {
    do { _ = try regularSize(path) }
    catch Failure.io(let code) where code == ENOENT { return }
  }

  private func directory(_ parts: [String], create: Bool = false) throws -> Int32 {
    var fd = dup(rootFD)
    guard fd >= 0 else { throw Failure.io(errno) }
    do {
      for part in parts {
        if create, mkdirat(fd, part, 0o755) != 0 && errno != EEXIST { throw Failure.io(errno) }
        let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else { throw Failure.io(errno) }
        close(fd)
        fd = next
      }
      return fd
    } catch { close(fd); throw error }
  }

  private func parent(_ path: String, create: Bool = false) throws -> (Int32, String) {
    guard Self.safePath(path) else { throw Failure.unsafePath }
    let parts = path.split(separator: "/").map(String.init)
    return (try directory(Array(parts.dropLast()), create: create), parts.last!)
  }

  private func children(_ path: String, entries: inout Int) throws -> [String] {
    let fd: Int32
    do { fd = try directory(path.split(separator: "/").map(String.init)) }
    catch Failure.io(let code) where code == ENOENT { return [] }
    guard let stream = fdopendir(fd) else { close(fd); throw Failure.io(errno) }
    defer { closedir(stream) }
    var result: [String] = []
    while let entry = readdir(stream) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if name == "." || name == ".." { continue }
      entries += 1
      guard entries <= maximumEntries else { throw Failure.tooLarge }
      result.append(name)
    }
    return result.sorted()
  }

  private func read(_ path: String, limit: Int) throws -> Data {
    guard limit > 0 else { throw Failure.tooLarge }
    let (directory, name) = try parent(path)
    defer { close(directory) }
    let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw Failure.io(errno) }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.unsafePath }
    guard info.st_size >= 0 && info.st_size <= limit else { throw Failure.tooLarge }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    guard let data = try handle.read(upToCount: limit + 1), data.count <= limit else { throw Failure.tooLarge }
    return data
  }

  private func atomicWrite(_ data: Data, path: String) throws {
    guard data.count <= 512 * 1024 else { throw Failure.tooLarge }
    let (directory, name) = try parent(path, create: true)
    defer { close(directory) }
    let temporary = ".\(UUID().uuidString).tmp"
    let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw Failure.io(errno) }
    defer { close(fd); unlinkat(directory, temporary, 0) }
    try writeAll(data, to: fd)
    guard fsync(fd) == 0, renameat(directory, temporary, directory, name) == 0 else { throw Failure.io(errno) }
  }

  private func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if written < 0 && errno == EINTR { continue }
        guard written > 0 else { throw Failure.io(errno) }
        offset += written
      }
    }
  }
}

/// Shared-folder synchronization is intentionally explicit and tolerant of small
/// drift. A stale, future, stopped, or non-host record never controls a player.
enum SharedPlaybackSync {
  struct Target: Equatable {
    let position: Double
    let rate: Double
    let paused: Bool
  }
  static let maximumAge: TimeInterval = 10
  static let seekTolerance: Double = 0.75

  /// Standard mpv shortcuts bypass PlayerCore's transport methods. Recognize
  /// them without rewriting the command or changing the user's key bindings.
  static func isTransportCommand(_ action: [String]) -> Bool {
    let prefixes: Set<String> = ["no-osd", "osd-auto", "osd-bar", "osd-msg", "osd-msg-bar",
                                 "raw", "expand-properties", "repeatable", "async", "sync"]
    let command = action.drop(while: { prefixes.contains($0) || $0.hasPrefix("{") })
    guard let name = command.first else { return false }
    if ["seek", "frame-step", "frame-back-step", "playlist-next", "playlist-prev",
        "playlist-play-index", "stop"].contains(name) { return true }
    guard ["set", "add", "multiply", "cycle", "cycle-values"].contains(name),
          command.count >= 2 else { return false }
    return ["pause", "speed", "time-pos", "percent-pos", "chapter", "playlist-pos"]
      .contains(command[command.index(after: command.startIndex)])
  }

  static func target(for record: SharedShowStore.Progress, at now: Date = Date()) -> Target? {
    let age = now.timeIntervalSince(record.updatedAt)
    guard record.isValid, record.watchTogether == true, record.activity != .stopped,
          age >= 0, age <= maximumAge else { return nil }
    let rate = record.playbackRate ?? 1
    let advancing = record.activity == .playing ? age * rate : 0
    // Synchronization must never seek to EOF and advance a manual playlist.
    let position = min(max(0, record.duration - 0.5), record.position + advancing)
    return Target(position: position, rate: rate, paused: record.activity == .paused)
  }
}
