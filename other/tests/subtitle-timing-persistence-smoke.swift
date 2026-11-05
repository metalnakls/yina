// Compile with yina/SubtitleTimingStore.swift. No app windows or personal media.
import Foundation
@main struct TimingPersistenceSmoke {
  static func main() throws {
    let fm = FileManager.default
    let fixture = fm.temporaryDirectory.appendingPathComponent("subtitle-timing-\(UUID().uuidString)")
    try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: fixture) }
    let first = fixture.appendingPathComponent("first.srt")
    let second = fixture.appendingPathComponent("second.srt")
    let relocated = fixture.appendingPathComponent("cached.srt")
    try Data("First release".utf8).write(to: first)
    try Data("Second release".utf8).write(to: second)
    try fm.copyItem(at: first, to: relocated)
    let video = URL(fileURLWithPath: "/Volumes/TV/Show/S05E05.mkv")
    let a = SubtitleTimingContext(media: video, track: .external(first))
    let b = SubtitleTimingContext(media: video, track: .external(second))
    let nextVideo = SubtitleTimingContext(media: video.deletingLastPathComponent().appendingPathComponent("S05E06.mkv"), track: .external(first))
    let store = SubtitleTimingStore(root: fixture.appendingPathComponent("settings"))
    try store.save(-15, for: a)
    try store.save(30.1, for: b)
    try store.save(4, for: nextVideo)
    let restarted = SubtitleTimingStore(root: store.root)
    precondition(restarted.load(a) == -15 && restarted.load(b) == 30.1 && restarted.load(nextVideo) == 4,
                 "Offsets must be isolated by both subtitle track and video, across restart")
    precondition(restarted.load(SubtitleTimingContext(media: video, track: .external(relocated))) == -15,
                 "Cache relocation changed a subtitle's timing identity")
    let embedded = SubtitleTimingContext(media: video, track: .embedded(3))
    try store.save(2.5, for: embedded)
    precondition(restarted.load(embedded) == 2.5 && restarted.load(SubtitleTimingContext(media: video, track: .embedded(4))) == nil)
    try store.save(0, for: a)
    precondition(restarted.load(a) == 0, "Reset must persist")
    try fm.removeItem(at: first)
    try store.save(-4, for: a)
    try Data("First release".utf8).write(to: first)
    precondition(restarted.load(a) == -4, "Adjustment while the payload was purged lost the track identity")

    var session = SubtitleTimingSession()
    let initial = session.select(a, slot: .primary)!
    let edit = session.edit(-15, context: a, slot: .primary)
    precondition(!session.prepareRestore(0, request: initial), "Late disk read overwrote an edit")
    precondition(!session.observe(0, slot: .primary).accepted, "Stale player echo overwrote an edit")
    session.confirm(-15, request: edit)
    let switchToB = session.select(b, slot: .primary)!
    precondition(!session.isCurrent(edit), "Track switch accepted the previous track's request")
    precondition(session.prepareRestore(30.1, request: switchToB))
    precondition(!session.observe(-15, slot: .primary).accepted, "Old track delay leaked into the new track")
    session.confirm(30.1, request: switchToB)
    let keyboard = session.observe(31, slot: .primary)
    precondition(keyboard.accepted && keyboard.save?.context == b, "Keyboard adjustment saved to the wrong track")
    let secondary = session.select(a, slot: .secondary)!
    precondition(session.prepareRestore(0, request: secondary) && session.selection(.primary) == b,
                 "Secondary selection changed primary timing")
    session.reset()
    precondition(!session.prepareRestore(30.1, request: switchToB), "Previous video's restore survived a media reset")
    print("PASS: video/track isolation, restart, relocated payloads, embedded tracks, reset, cache purge/redownload, stale restores/echoes, keyboard edits, primary/secondary separation, media change")
  }
}
