// xcrun swiftc -parse-as-library yina/SharedShowStore.swift yina/ShowEpisodeIndexReader.swift other/tests/shared-show-smb-publish-smoke.swift -o /tmp/yina-shared-smb-publish-smoke
// /tmp/yina-shared-smb-publish-smoke /path/to/local-or-mounted-parent
import Foundation

@main
struct SharedShowSMBPublishSmoke {
  static func main() throws {
    guard (2...3).contains(CommandLine.arguments.count) else {
      fatalError("Pass a writable parent directory and optional --expect-fallback")
    }
    let files = FileManager.default
    let parent = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let root = parent.appendingPathComponent(".yina-publish-smoke-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: root) }

    let lock = NSLock()
    var ids: [UUID] = []
    var errors: [String] = []
    let creators = CommandLine.arguments.last == "--expect-fallback" ? 2 : 12
    DispatchQueue.concurrentPerform(iterations: creators) { _ in
      do {
        let id = try SharedShowStore(root: root).enable().showID
        lock.lock(); ids.append(id); lock.unlock()
      } catch {
        lock.lock(); errors.append(String(describing: error)); lock.unlock()
      }
    }
    precondition(errors.isEmpty, "Concurrent enable errors: \(errors)")
    precondition(ids.count == creators && Set(ids).count == 1, "Concurrent publishers disagreed")
    let descriptor = try SharedShowStore(root: root).descriptor()
    precondition(descriptor.showID == ids[0], "Published identity differs")
    let contents = try files.contentsOfDirectory(atPath: root.appendingPathComponent(".yina").path)
    precondition(contents == ["show.json"], "Unexpected metadata or abandoned lock: \(contents)")

    if CommandLine.arguments.count == 3 {
      precondition(["--expect-fallback", "--stress-fallback"].contains(CommandLine.arguments[2]))
      let blocked = root.appendingPathComponent("blocked", isDirectory: true)
      let metadata = blocked.appendingPathComponent(".yina", isDirectory: true)
      let publishLock = metadata.appendingPathComponent(".show.json.publish-lock", isDirectory: true)
      try files.createDirectory(at: publishLock, withIntermediateDirectories: true)
      do {
        _ = try SharedShowStore(root: blocked).enable()
        fatalError("An abandoned publication lock was ignored")
      } catch SharedShowStore.Failure.io(let code) where code == EBUSY {
        precondition(files.fileExists(atPath: publishLock.path), "Another publisher's lock was removed")
        precondition(!files.fileExists(atPath: metadata.appendingPathComponent("show.json").path),
                     "A locked identity was published")
      }
      try files.removeItem(at: publishLock)
      _ = try SharedShowStore(root: blocked).enable()
    }
    print("PASS: \(creators) concurrent creators published one immutable identity at \(root.path)")
  }
}
