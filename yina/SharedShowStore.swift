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

  private static func object(_ data: Data, keys: Set<String>) throws -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys).isSubset(of: keys) else { throw Failure.invalidRecord }
    return object
  }

  private static func strictDescriptor(_ data: Data) throws -> Descriptor {
    let value = try object(data, keys: ["schemaVersion", "showID", "createdAt"])
    guard Set(value.keys) == ["schemaVersion", "showID", "createdAt"],
          let descriptor = try? decoder().decode(Descriptor.self, from: data),
          descriptor.schemaVersion == 2 else { throw Failure.invalidRecord }
    return descriptor
  }

  private static func strictLegacyIndex(_ data: Data) throws -> (Descriptor, Data) {
    let value = try object(data, keys: ["schemaVersion", "hashString", "capturedAt", "episodes"])
    guard Set(value.keys) == ["schemaVersion", "hashString", "capturedAt", "episodes"],
          let records = value["episodes"] as? [[String: Any]],
          records.count <= 20_000 else { throw Failure.invalidRecord }
    for record in records {
      guard Set(record.keys).isSubset(of: ["id", "relativePath", "season", "episode",
                                           "bytesCompleted", "totalBytes", "wanted"]),
            let identity = record["id"] as? [String: Any],
            Set(identity.keys) == ["hashString", "fileIndex"] else { throw Failure.invalidRecord }
    }
    guard let snapshot = ShowEpisodeIndexReader.decode(data),
          let manifest = try? JSONDecoder().decode(ShowEpisodeIndexReader.Manifest.self, from: data) else {
      throw Failure.invalidRecord
    }
    let descriptor = Descriptor(showID: legacyShowID(hash: manifest.hashString), createdAt: snapshot.capturedAt)
    return (descriptor, try encoder().encode(descriptor))
  }

  private static func recognizedLegacy(_ data: Data) throws -> (Descriptor, Data, Data?) {
    let version = try object(data, keys: ["schemaVersion", "showID", "createdAt",
                                          "hashString", "capturedAt", "episodes"])["schemaVersion"] as? Int
    if version == 2 {
      return (try strictDescriptor(data), data, nil)
    }
    if version == 1 {
      let (identity, descriptorBytes) = try strictLegacyIndex(data)
      return (identity, descriptorBytes, data)
    }
    throw Failure.invalidRecord
  }

  private static func isUnsupportedAtomicRename(_ code: Int32) -> Bool {
    code == ENOTSUP || code == EOPNOTSUPP
  }

  private static func syncDirectory(_ fd: Int32) throws {
    if fsync(fd) != 0 && errno != EINVAL && !isUnsupportedAtomicRename(errno) {
      throw Failure.io(errno)
    }
  }

  private func fileExists(_ path: String) throws -> Bool {
    let directory: Int32
    let name: String
    do { (directory, name) = try parent(path) }
    catch Failure.io(let code) where code == ENOENT { return false }
    defer { close(directory) }
    var info = stat()
    if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
      guard (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.unsafePath }
      return true
    }
    if errno == ENOENT { return false }
    throw Failure.io(errno)
  }

  /// Migrate only recognized, fully validated legacy files. A destination
  /// conflict is never overwritten, and the original stays until both files
  /// have been published and re-read byte-for-byte.
  private func migrateLegacy() throws -> Descriptor {
    let original = try read(".yina.json", limit: ShowEpisodeIndexReader.maximumBytes)
    let (identity, descriptorBytes, indexBytes) = try Self.recognizedLegacy(original)
    if let indexBytes {
      try publishImmutable(indexBytes, at: ".yina/legacy-index.json", limit: ShowEpisodeIndexReader.maximumBytes)
    } else if try fileExists(".yina/legacy-index.json") {
      throw Failure.invalidRecord
    }
    try publishImmutable(descriptorBytes, at: ".yina/show.json", limit: ShowEpisodeIndexReader.maximumBytes)
    guard try read(".yina/show.json", limit: ShowEpisodeIndexReader.maximumBytes) == descriptorBytes,
          (try indexBytes.map { try read(".yina/legacy-index.json", limit: ShowEpisodeIndexReader.maximumBytes) == $0 }) ?? true
    else { throw Failure.identityChanged }
    // Move the root file to a unique quarantine name atomically, then compare
    // the moved bytes. A concurrent replacement is restored exclusively; if
    // the root name was recreated meanwhile, both files are preserved.
    let metadata = try directory([".yina"])
    defer { close(metadata) }
    let quarantine = ".legacy-root-\(UUID().uuidString).pending"
    if renameatx_np(rootFD, ".yina.json", metadata, quarantine, UInt32(RENAME_EXCL)) != 0 {
      if errno == ENOENT { return identity } // A matching migration completed elsewhere.
      throw Failure.io(errno)
    }
    let quarantined: Data
    do { quarantined = try read(".yina/\(quarantine)", limit: ShowEpisodeIndexReader.maximumBytes) }
    catch Failure.io(let code) where code == ENOENT {
      return identity // Another matching migrator finalized this quarantine.
    }
    catch {
      // A failed read must not make an unknown file disappear from discovery.
      // Restore it if the original name is still free; otherwise preserve both.
      guard renameatx_np(metadata, quarantine, rootFD, ".yina.json", UInt32(RENAME_EXCL)) == 0 else {
        throw Failure.identityChanged
      }
      throw error
    }
    if quarantined != original {
      guard renameatx_np(metadata, quarantine, rootFD, ".yina.json", UInt32(RENAME_EXCL)) == 0 else {
        throw Failure.identityChanged // Keep the quarantine copy when the root name is occupied.
      }
      throw Failure.identityChanged
    }
    guard unlinkat(metadata, quarantine, 0) == 0 else { throw Failure.io(errno) }
    try Self.syncDirectory(metadata)
    return identity
  }

  private func recoverQuarantine(descriptorBytes: Data, indexBytes: Data?) throws {
    var entries = 0
    let names = try children(".yina", entries: &entries).filter {
      $0.hasPrefix(".legacy-root-") && $0.hasSuffix(".pending")
    }
    guard !names.isEmpty else { return }
    let metadata = try directory([".yina"])
    defer { close(metadata) }
    for name in names {
      let bytes: Data
      do { bytes = try read(".yina/\(name)", limit: ShowEpisodeIndexReader.maximumBytes) }
      catch Failure.io(let code) where code == ENOENT { continue }
      let (_, expectedDescriptor, expectedIndex) = try Self.recognizedLegacy(bytes)
      guard expectedDescriptor == descriptorBytes, expectedIndex == indexBytes else {
        throw Failure.identityChanged
      }
      var info = stat()
      if fstatat(metadata, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
        if errno == ENOENT { continue }
        throw Failure.io(errno)
      }
      guard (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.unsafePath }
      let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
      // A second process may be between its rename and byte comparison. Let
      // that process finish its own marker; only finalize an older orphan.
      if Date().timeIntervalSince1970 - modified < 30 { continue }
      if unlinkat(metadata, name, 0) != 0 && errno != ENOENT { throw Failure.io(errno) }
    }
    try Self.syncDirectory(metadata)
  }

  func descriptor() throws -> Descriptor {
    if try fileExists(".yina.json") {
      do { _ = try migrateLegacy() }
      catch Failure.io(let code) where code == ENOENT {
        // Another writer may have completed the same move between the
        // no-follow existence check and the initial read.
      }
      catch Failure.io(let code) where Self.isUnsupportedAtomicRename(code) {
        // Some mounted filesystems cannot publish a no-replace rename. Keep
        // recognized legacy metadata readable, but never write through it.
        let data = try read(".yina.json", limit: ShowEpisodeIndexReader.maximumBytes)
        return try Self.recognizedLegacy(data).0
      }
    }
    if try !fileExists(".yina/show.json"), try fileExists(".yina/legacy-index.json") {
      // A crash after publishing the inventory but before the descriptor is
      // recoverable without touching the original bytes.
      let index = try read(".yina/legacy-index.json", limit: ShowEpisodeIndexReader.maximumBytes)
      let (_, descriptorBytes) = try Self.strictLegacyIndex(index)
      do { try publishImmutable(descriptorBytes, at: ".yina/show.json", limit: 512 * 1024) }
      catch Failure.io(let code) where Self.isUnsupportedAtomicRename(code) {
        return try Self.strictLegacyIndex(index).0 // Read-only until publication is supported.
      }
    }
    let bytes = try read(".yina/show.json", limit: ShowEpisodeIndexReader.maximumBytes)
    let identity = try Self.strictDescriptor(bytes)
    let index = try fileExists(".yina/legacy-index.json")
      ? read(".yina/legacy-index.json", limit: ShowEpisodeIndexReader.maximumBytes) : nil
    if let index {
      let (legacyIdentity, _) = try Self.strictLegacyIndex(index)
      guard legacyIdentity.showID == identity.showID else { throw Failure.identityChanged }
    }
    try recoverQuarantine(descriptorBytes: bytes, indexBytes: index)
    return identity
  }

  /// Explicit opt-in at a user-selected show root. Existing metadata is immutable.
  func enable() throws -> Descriptor {
    if try fileExists(".yina/show.json") || fileExists(".yina.json") {
      let identity = try descriptor()
      guard try !fileExists(".yina.json") else { throw Failure.io(ENOTSUP) }
      return identity
    }
    if try fileExists(".yina/legacy-index.json") {
      let identity = try descriptor()
      guard try fileExists(".yina/show.json") else { throw Failure.io(ENOTSUP) }
      return identity
    }
    let value = Descriptor(showID: UUID(), createdAt: Date())
    do { try publishImmutable(Self.encoder().encode(value), at: ".yina/show.json", limit: 512 * 1024) }
    catch Failure.invalidRecord { return try descriptor() } // Another creator won; validate its descriptor.
    return value
  }

  static func discover(for media: URL) throws -> SharedShowStore? {
    guard media.isFileURL else { return nil }
    guard let file = canonicalURL(media) else { return nil }
    var folder = file.deletingLastPathComponent()
    let volume = try? folder.resourceValues(forKeys: [.volumeURLKey]).volume
    for _ in 0..<12 {
      let store = try SharedShowStore(root: folder)
      if try store.fileExists(".yina/show.json") || store.fileExists(".yina.json") {
        _ = try store.descriptor() // A malformed nearer record stops discovery.
        return store
      }
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
    let legacyData: Data
    if try fileExists(".yina/legacy-index.json") {
      legacyData = try read(".yina/legacy-index.json", limit: ShowEpisodeIndexReader.maximumBytes)
      let (legacyDescriptor, _) = try Self.strictLegacyIndex(legacyData)
      guard legacyDescriptor.showID == identity.showID else { throw Failure.identityChanged }
      if let legacy = ShowEpisodeIndexReader.decode(legacyData), let first = legacy.episodes.first {
        byHash[first.hashString] = legacy
      }
    } else if try fileExists(".yina.json") {
      let original = try read(".yina.json", limit: ShowEpisodeIndexReader.maximumBytes)
      let (legacyIdentity, _, index) = try Self.recognizedLegacy(original)
      guard legacyIdentity.showID == identity.showID else { throw Failure.identityChanged }
      legacyData = index ?? Data()
      if let legacy = ShowEpisodeIndexReader.decode(legacyData), let first = legacy.episodes.first {
        byHash[first.hashString] = legacy
      }
    } else { legacyData = Data() }
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

  private func requireWritableDescriptor(_ showID: UUID) throws {
    guard try descriptor().showID == showID else { throw Failure.identityChanged }
    guard try fileExists(".yina/show.json"), try !fileExists(".yina.json") else {
      throw Failure.io(ENOTSUP)
    }
  }

  func publish(_ record: Progress) throws {
    guard record.isValid else { throw Failure.invalidRecord }
    try requireWritableDescriptor(record.showID)
    let path = ".yina/progress/\(record.participantID.uuidString.lowercased())/\(record.writerID.uuidString.lowercased()).json"
    if let previous = try existing(path, as: Progress.self) {
      guard previous.isValid, previous.showID == record.showID, previous.participantID == record.participantID,
            previous.writerID == record.writerID, previous.revision < record.revision else { throw Failure.invalidRecord }
    }
    try atomicWrite(Self.encoder().encode(record), path: path)
  }

  func publish(_ record: Demand) throws {
    guard record.schemaVersion == 1, Self.safePath(record.relativePath), Self.validHash(record.hashString),
          record.fileIndex >= 0 else { throw Failure.invalidRecord }
    try requireWritableDescriptor(record.showID)
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

  /// Publish a descriptor or migration snapshot without replacing anything at
  /// the destination, including a file created concurrently by another writer.
  private func publishImmutable(_ data: Data, at path: String, limit: Int) throws {
    guard data.count <= limit else { throw Failure.tooLarge }
    if try fileExists(path) {
      guard try read(path, limit: limit) == data else { throw Failure.invalidRecord }
      return
    }
    let (directory, name) = try parent(path, create: true)
    defer { close(directory) }
    let temporary = ".\(UUID().uuidString).tmp"
    let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw Failure.io(errno) }
    defer { close(fd); unlinkat(directory, temporary, 0) }
    try writeAll(data, to: fd)
    guard fsync(fd) == 0 else { throw Failure.io(errno) }
    if renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) != 0 {
      var code = errno
      if Self.isUnsupportedAtomicRename(code) {
        if linkat(directory, temporary, directory, name, 0) == 0 {
          guard unlinkat(directory, temporary, 0) == 0 else { throw Failure.io(errno) }
          try Self.syncDirectory(directory)
          return
        }
        code = errno
      }
      if code == EEXIST {
        guard try read(path, limit: limit) == data else { throw Failure.invalidRecord }
        return
      }
      throw Failure.io(code)
    }
    try Self.syncDirectory(directory)
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
