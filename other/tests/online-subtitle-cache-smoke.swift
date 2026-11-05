// Compile with yina/OnlineSubtitleCache.swift; uses only a disposable local folder.
import Foundation

@main struct SubtitleCacheSmoke {
  static func main() throws {
    let fm = FileManager.default
    let fixture = fm.temporaryDirectory.appendingPathComponent("subtitle-cache-\(UUID().uuidString)")
    try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: fixture) }
    let root = fixture.appendingPathComponent("persistent")
    let cache = OnlineSubtitleCache(root: root)
    let media = URL(fileURLWithPath: "/Volumes/TV/The Walking Dead/S05E05.mkv")
    let other = URL(fileURLWithPath: "/Volumes/TV/Another Show/S05E05.mkv")
    let source = fixture.appendingPathComponent("subtitle.srt")
    let first = Data("1\n00:00:01,000 --> 00:00:02,000\nFirst subtitle\n".utf8)
    try first.write(to: source)
    let saved = try cache.store([source], for: media)
    try fm.removeItem(at: source)
    let restarted = OnlineSubtitleCache(root: root)
    precondition(restarted.subtitles(for: media) == saved, "Restart lost the media association")
    let retained = try Data(contentsOf: saved[0])
    precondition(retained == first, "Temporary source deletion lost the subtitle")
    precondition(restarted.subtitles(for: other).isEmpty, "Same episode name matched another show")
    let second = Data("Different subtitle release".utf8)
    try second.write(to: source)
    let newer = try cache.store([source], for: media)
    precondition(newer != saved && restarted.subtitles(for: media) == newer,
                 "Same filename overwrote another release or failed to retain selection")
    precondition(fm.fileExists(atPath: saved[0].path), "New selection deleted an earlier download")
    let item = try cache.storeDownload(first, filename: "provider.srt", key: "opensubtitles:123")
    precondition(restarted.download(for: "opensubtitles:123")?.resolvingSymlinksInPath() == item.resolvingSymlinksInPath(), "Provider ID cache was lost on restart")
    precondition(restarted.download(for: "opensubtitles:456") == nil, "Different provider file IDs collided")
    do {
      _ = try cache.storeDownload(first, filename: "../escape.srt", key: "bad")
      preconditionFailure("Accepted a path outside the cache")
    } catch {}
    try fm.removeItem(at: newer[0])
    precondition(restarted.subtitles(for: media).isEmpty, "Missing payload must be a cache miss")
    let manifest = newer[0].deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("manifest.json")
    try Data("not JSON".utf8).write(to: manifest)
    precondition(restarted.subtitles(for: media).isEmpty, "Corrupt manifest must be a cache miss")
    print("PASS: restart persistence, deleted temporary files, show separation, release preservation, selected release, provider IDs, invalid paths, missing files, corrupt manifest")
  }
}
