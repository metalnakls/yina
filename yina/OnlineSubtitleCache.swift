import Foundation
import CryptoKit

/// Downloaded subtitles are user-selected files, retained in Application Support.
/// All callers perform this local disk work off the main thread. No media or NAS
/// metadata is read to form a cache key.
struct OnlineSubtitleCache {
  let root: URL
  private let fm = FileManager.default

  private struct Manifest: Codable {
    var files: [String]
    var selected: [String]
  }

  func subtitles(for media: URL) -> [URL] {
    let folder = mediaFolder(media)
    guard let manifest = readManifest(in: folder) else { return [] }
    return manifest.selected.compactMap { relative in
      guard manifest.files.contains(relative), safeRelativePath(relative) else { return nil }
      let file = folder.appendingPathComponent(relative)
      return valid(file) ? file : nil
    }
  }

  /// Retain earlier downloads as well as the latest selection. Write the manifest
  /// last, so an interrupted write cannot replace a working selection with gaps.
  func store(_ urls: [URL], for media: URL) throws -> [URL] {
    let folder = mediaFolder(media)
    var manifest = readManifest(in: folder) ?? Manifest(files: [], selected: [])
    var selected: [String] = []
    for url in urls {
      let data = try Data(contentsOf: url)
      guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
      let name = url.lastPathComponent
      guard safeName(name) else { throw CocoaError(.fileWriteInvalidFileName) }
      let relative = "\(digest(data))/\(name)"
      let file = folder.appendingPathComponent(relative)
      try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !valid(file) { try data.write(to: file, options: .atomic) }
      if !manifest.files.contains(relative) { manifest.files.append(relative) }
      if !selected.contains(relative) { selected.append(relative) }
    }
    guard !selected.isEmpty else { return [] }
    manifest.selected = selected
    try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    return selected.map { folder.appendingPathComponent($0) }
  }

  func download(for key: String) -> URL? {
    let folder = downloadFolder(key)
    guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
    return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.first(where: valid)
  }

  func storeDownload(_ data: Data, filename: String, key: String) throws -> URL {
    guard !data.isEmpty, safeName(filename) else { throw CocoaError(.fileWriteInvalidFileName) }
    let folder = downloadFolder(key)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent(filename)
    try data.write(to: file, options: .atomic)
    return file
  }

  private func mediaFolder(_ media: URL) -> URL {
    let identity = media.isFileURL ? media.standardizedFileURL.absoluteString : media.absoluteString
    return root.appendingPathComponent("Media", isDirectory: true)
      .appendingPathComponent(digest(Data(identity.utf8)), isDirectory: true)
  }

  private func downloadFolder(_ key: String) -> URL {
    root.appendingPathComponent("Downloads", isDirectory: true)
      .appendingPathComponent(digest(Data(key.utf8)), isDirectory: true)
  }

  private func readManifest(in folder: URL) -> Manifest? {
    guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else { return nil }
    return try? JSONDecoder().decode(Manifest.self, from: data)
  }

  private func valid(_ file: URL) -> Bool {
    guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
    return values.isRegularFile == true && (values.fileSize ?? 0) > 0
  }

  private func safeRelativePath(_ path: String) -> Bool {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 2 && parts.allSatisfy { safeName(String($0)) }
  }

  private func safeName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
